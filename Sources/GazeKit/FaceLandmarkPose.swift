import Foundation

public struct HeadPoseInputs: Equatable, Sendable {
  public let headVector: SIMD3<Double>
  public let faceOrigin: MetricFaceOrigin
  public let rotation: RigidRotation
}

public struct GazeModelVectors: Equatable, Sendable {
  public let headVector: SIMD3<Float>
  public let faceOriginCentimeters: SIMD3<Float>
}

public enum FaceLandmarkError: Error, Equatable {
  case wrongLandmarkCount(got: Int, need: Int)
  case nonFiniteLandmark(index: Int)
  case headVectorNotFacingCamera(z: Double)
  case faceNotInFrontOfCamera(depthCentimetres: Double)
}

public func headPoseInputs(
  landmarks: [SIMD3<Double>],
  imageSize: SIMD2<Double>,
  verticalFocalLengthPixels: Double? = nil,
  interpupillaryCentimetres: Double = defaultInterpupillaryCentimetres
) throws -> HeadPoseInputs {
  guard landmarks.count == CanonicalFaceModel.vertexCount else {
    throw FaceLandmarkError.wrongLandmarkCount(
      got: landmarks.count, need: CanonicalFaceModel.vertexCount)
  }

  for (index, landmark) in landmarks.enumerated() {
    if !landmark.x.isFinite || !landmark.y.isFinite || !landmark.z.isFinite {
      throw FaceLandmarkError.nonFiniteLandmark(index: index)
    }
  }

  let canonicalPoints = CanonicalFaceModel.rigidIndices.map { CanonicalFaceModel.vertices[$0] }
  let observedPoints = CanonicalFaceModel.rigidIndices.map {
    imageLandmarkToCanonicalFrame(landmarks[$0])
  }

  let rotation = try kabschRotation(canonical: canonicalPoints, observed: observedPoints)
  let head = headVector(from: rotation)
  guard head.z < 0 else { throw FaceLandmarkError.headVectorNotFacingCamera(z: head.z) }

  let leftEyeCorners = eyeCorners(CanonicalFaceModel.leftEyeHorizontal, in: landmarks)
  let rightEyeCorners = eyeCorners(CanonicalFaceModel.rightEyeHorizontal, in: landmarks)

  let origin = try metricFaceOrigin(
    leftEyeCorners: leftEyeCorners,
    rightEyeCorners: rightEyeCorners,
    rotation: rotation,
    imageSize: imageSize,
    assumedInterpupillaryCentimetres: interpupillaryCentimetres,
    verticalFocalLengthPixels: verticalFocalLengthPixels
  )
  guard origin.centimetres.z > 0 else {
    throw FaceLandmarkError.faceNotInFrontOfCamera(depthCentimetres: origin.centimetres.z)
  }

  return HeadPoseInputs(headVector: head, faceOrigin: origin, rotation: rotation)
}

extension HeadPoseInputs {
  public var modelVectors: GazeModelVectors {
    GazeModelVectors(
      headVector: SIMD3<Float>(Float(headVector.x), Float(headVector.y), Float(headVector.z)),
      faceOriginCentimeters: SIMD3<Float>(
        Float(faceOrigin.centimetres.x),
        Float(faceOrigin.centimetres.y),
        Float(faceOrigin.centimetres.z)
      )
    )
  }
}

/// Converts a landmark from image space, where x and y are pixel coordinates with y
/// increasing downward, into `CanonicalFaceModel`'s frame, where y increases upward.
///
/// Negates both y and z rather than y alone. A single-axis negation is a reflection
/// with determinant -1, a transform no proper rotation can represent, so `kabschRotation`
/// would silently fit it with a nonsense quaternion. Negating y and z together is a
/// proper 180 degree rotation about x.
///
/// Confirmed against a real face photo run through the pipeline's own crop path: nose
/// tip landmark 4 had the minimum z at -36.95, while temples 234 and 454 sat at 64.2 and
/// 62.8. Smaller z is closer to the camera, matching MediaPipe's documented convention
/// and the direction this negation assumes. End to end that photo produced head vector
/// (-0.012, 0.038, -0.999) and origin (0.38, 1.43, 22.62) cm; negating z on the same
/// landmarks flips the sign of both, which `headPoseInputs` now rejects.
private func imageLandmarkToCanonicalFrame(_ landmark: SIMD3<Double>) -> SIMD3<Double> {
  SIMD3<Double>(landmark.x, -landmark.y, -landmark.z)
}

private func eyeCorners(
  _ indices: [Int],
  in landmarks: [SIMD3<Double>]
) -> (SIMD2<Double>, SIMD2<Double>) {
  let first = landmarks[indices[0]]
  let second = landmarks[indices[1]]
  return (SIMD2<Double>(first.x, first.y), SIMD2<Double>(second.x, second.y))
}
