import CoreGraphics
import GazeKit
import Vision

extension FaceObservation {
  init?(visionFace face: VNFaceObservation, timestamp: TimeInterval) {
    guard
      let landmarks = face.landmarks,
      let leftEyePoints = Self.imagePoints(from: landmarks.leftEye, in: face.boundingBox),
      let rightEyePoints = Self.imagePoints(from: landmarks.rightEye, in: face.boundingBox),
      let leftEye = EyeLandmarks(points: resample(leftEyePoints, to: 6)),
      let rightEye = EyeLandmarks(points: resample(rightEyePoints, to: 6))
    else { return nil }

    let leftPupil =
      Self.imagePoint(from: landmarks.leftPupil, in: face.boundingBox)
      ?? centroid(of: leftEyePoints)
    let rightPupil =
      Self.imagePoint(from: landmarks.rightPupil, in: face.boundingBox)
      ?? centroid(of: rightEyePoints)

    self.init(
      boundingBox: face.boundingBox,
      yaw: face.yaw?.doubleValue ?? 0,
      pitch: face.pitch?.doubleValue ?? 0,
      roll: face.roll?.doubleValue ?? 0,
      leftEye: leftEye,
      rightEye: rightEye,
      leftPupil: leftPupil,
      rightPupil: rightPupil,
      timestamp: timestamp
    )
  }

  private static func imagePoints(
    from region: VNFaceLandmarkRegion2D?,
    in boundingBox: CGRect
  ) -> [CGPoint]? {
    guard let region, region.pointCount > 0 else { return nil }
    return region.normalizedPoints.map { imagePoint($0, in: boundingBox) }
  }

  private static func imagePoint(
    from region: VNFaceLandmarkRegion2D?,
    in boundingBox: CGRect
  ) -> CGPoint? {
    guard let point = region?.normalizedPoints.first else { return nil }
    return imagePoint(point, in: boundingBox)
  }

  private static func imagePoint(_ point: CGPoint, in boundingBox: CGRect) -> CGPoint {
    CGPoint(
      x: boundingBox.origin.x + point.x * boundingBox.width,
      y: boundingBox.origin.y + point.y * boundingBox.height
    )
  }
}
