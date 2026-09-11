import Foundation

public struct RigidRotation: Equatable, Sendable {
  public let matrix: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)

  public static func == (lhs: RigidRotation, rhs: RigidRotation) -> Bool {
    lhs.matrix.0 == rhs.matrix.0 && lhs.matrix.1 == rhs.matrix.1
      && lhs.matrix.2 == rhs.matrix.2
  }
}

public enum HeadPoseError: Error, Equatable {
  case landmarkCountMismatch(canonical: Int, observed: Int)
  case tooFewLandmarks(got: Int, need: Int)
  case degenerateConfiguration
}

public func kabschRotation(
  canonical: [SIMD3<Double>],
  observed: [SIMD3<Double>]
) throws -> RigidRotation {
  guard canonical.count == observed.count else {
    throw HeadPoseError.landmarkCountMismatch(
      canonical: canonical.count, observed: observed.count)
  }
  guard canonical.count >= 3 else {
    throw HeadPoseError.tooFewLandmarks(got: canonical.count, need: 3)
  }

  let canonicalCentroid = centroid(canonical)
  let observedCentroid = centroid(observed)

  var h = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
  for index in canonical.indices {
    let canonicalCentered = canonical[index] - canonicalCentroid
    let observedCentered = observed[index] - observedCentroid
    for row in 0..<3 {
      for column in 0..<3 {
        h[row][column] += canonicalCentered[row] * observedCentered[column]
      }
    }
  }

  guard let quaternion = largestEigenvector(quaternionMatrix(h)) else {
    throw HeadPoseError.degenerateConfiguration
  }

  let norm =
    (quaternion[0] * quaternion[0] + quaternion[1] * quaternion[1]
    + quaternion[2] * quaternion[2] + quaternion[3] * quaternion[3]).squareRoot()
  guard norm > 1e-12 else { throw HeadPoseError.degenerateConfiguration }

  let w = quaternion[0] / norm
  let x = quaternion[1] / norm
  let y = quaternion[2] / norm
  let z = quaternion[3] / norm

  let r0 = SIMD3<Double>(1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y))
  let r1 = SIMD3<Double>(2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x))
  let r2 = SIMD3<Double>(2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y))

  return RigidRotation(matrix: (r0, r1, r2))
}

public func headVector(from rotation: RigidRotation) -> SIMD3<Double> {
  let r = rotation.matrix
  // Clamping keeps floating point from pushing the asin argument past 1 and producing NaN.
  let pitch = asin(max(-1, min(1, -r.2.x)))
  let yaw = atan2(r.2.y, r.2.z)
  let roll = atan2(r.1.x, r.0.x)

  let hPitch = -yaw
  let hYaw = pitch
  let hRoll = roll

  let x = cos(hPitch) * sin(hYaw)
  let y = sin(hPitch)
  let z = -cos(hPitch) * cos(hYaw)

  let rotatedX = x * cos(hRoll) - y * sin(hRoll)
  let rotatedY = x * sin(hRoll) + y * cos(hRoll)

  let length = (rotatedX * rotatedX + rotatedY * rotatedY + z * z).squareRoot()
  return SIMD3<Double>(rotatedX / length, rotatedY / length, z / length)
}

public struct MetricFaceOrigin: Equatable, Sendable {
  public let centimetres: SIMD3<Double>
}

/// The vertical field of view assumed when the camera has not reported a
/// measured focal length. Chosen as a plausible webcam lens angle, not a
/// measurement; every depth this fallback produces carries that error.
public let assumedVerticalFieldOfViewDegrees = 60.0

/// The focal length `metricFaceOrigin` actually needs, in pixels of vertical
/// extent. A caller that read one from `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`
/// passes it here directly. `nil`, zero, negative or non-finite falls back to
/// `assumedVerticalFieldOfViewDegrees` converted against the frame's own height,
/// which is exactly today's behaviour.
func resolvedVerticalFocalLengthPixels(
  measured: Double?, imageHeight: Double
) -> Double {
  if let measured, measured.isFinite, measured > 0 {
    return measured
  }
  let halfFieldOfView = assumedVerticalFieldOfViewDegrees / 2 * .pi / 180
  return imageHeight / (2 * tan(halfFieldOfView))
}

/// Approximates the metric face origin by scaling the pixel IPD to an assumed
/// interpupillary distance. This is not a faithful reconstruction because the
/// upstream method needs iris landmarks 468 to 477, which the base 468-point
/// mesh does not provide.
public func metricFaceOrigin(
  leftEyeCorners: (SIMD2<Double>, SIMD2<Double>),
  rightEyeCorners: (SIMD2<Double>, SIMD2<Double>),
  rotation: RigidRotation,
  imageSize: SIMD2<Double>,
  assumedInterpupillaryCentimetres: Double = 6.3,
  verticalFocalLengthPixels: Double? = nil
) throws -> MetricFaceOrigin {
  let leftMid = (leftEyeCorners.0 + leftEyeCorners.1) / 2
  let rightMid = (rightEyeCorners.0 + rightEyeCorners.1) / 2

  let imageIPD = pixelDistance(rightMid - leftMid)
  guard imageIPD > 1e-9 else { throw HeadPoseError.degenerateConfiguration }

  let focalPx = resolvedVerticalFocalLengthPixels(
    measured: verticalFocalLengthPixels, imageHeight: imageSize.y)

  let r = rotation.matrix
  let theta = atan2(r.0.z, r.2.z)
  let depthCm = focalPx * assumedInterpupillaryCentimetres * cos(theta) / imageIPD

  let eyeMid = (leftMid + rightMid) / 2
  let originX = (eyeMid.x - imageSize.x / 2) * depthCm / focalPx
  let originY = (imageSize.y / 2 - eyeMid.y) * depthCm / focalPx

  return MetricFaceOrigin(centimetres: SIMD3<Double>(originX, originY, depthCm))
}

private func centroid(_ points: [SIMD3<Double>]) -> SIMD3<Double> {
  var sum = SIMD3<Double>.zero
  for point in points {
    sum += point
  }
  return sum / Double(points.count)
}

private func pixelDistance(_ vector: SIMD2<Double>) -> Double {
  (vector.x * vector.x + vector.y * vector.y).squareRoot()
}

private func quaternionMatrix(_ h: [[Double]]) -> [[Double]] {
  let h00 = h[0][0]
  let h01 = h[0][1]
  let h02 = h[0][2]
  let h10 = h[1][0]
  let h11 = h[1][1]
  let h12 = h[1][2]
  let h20 = h[2][0]
  let h21 = h[2][1]
  let h22 = h[2][2]

  return [
    [h00 + h11 + h22, h12 - h21, h20 - h02, h01 - h10],
    [h12 - h21, h00 - h11 - h22, h01 + h10, h20 + h02],
    [h20 - h02, h01 + h10, -h00 + h11 - h22, h12 + h21],
    [h01 - h10, h20 + h02, h12 + h21, -h00 - h11 + h22],
  ]
}

private func largestEigenvector(_ matrix: [[Double]]) -> [Double]? {
  var a = matrix
  var vectors = (0..<4).map { row in
    (0..<4).map { column in row == column ? 1.0 : 0.0 }
  }

  for _ in 0..<100 {
    var largestOffDiagonal = 0.0
    for row in 0..<3 {
      for column in (row + 1)..<4 {
        largestOffDiagonal = max(largestOffDiagonal, abs(a[row][column]))
      }
    }
    if largestOffDiagonal < 1e-12 { break }

    for p in 0..<3 {
      for q in (p + 1)..<4 {
        let apq = a[p][q]
        if apq == 0 { continue }

        let theta = (a[q][q] - a[p][p]) / (2 * apq)
        let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
        let c = 1 / (t * t + 1).squareRoot()
        let s = t * c

        for i in 0..<4 where i != p && i != q {
          let aip = a[i][p]
          let aiq = a[i][q]
          a[i][p] = c * aip - s * aiq
          a[i][q] = s * aip + c * aiq
          a[p][i] = a[i][p]
          a[q][i] = a[i][q]
        }

        let app = a[p][p]
        let aqq = a[q][q]
        a[p][p] = c * c * app - 2 * s * c * apq + s * s * aqq
        a[q][q] = s * s * app + 2 * s * c * apq + c * c * aqq
        a[p][q] = 0
        a[q][p] = 0

        for i in 0..<4 {
          let vip = vectors[i][p]
          let viq = vectors[i][q]
          vectors[i][p] = c * vip - s * viq
          vectors[i][q] = s * vip + c * viq
        }
      }
    }
  }

  var best = 0
  for i in 1..<4 where a[i][i] > a[best][best] {
    best = i
  }

  let eigenvector = (0..<4).map { vectors[$0][best] }
  let norm = eigenvector.reduce(0) { $0 + $1 * $1 }.squareRoot()
  guard norm.isFinite else { return nil }
  return eigenvector
}
