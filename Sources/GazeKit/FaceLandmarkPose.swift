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
}

public func headPoseInputs(
  landmarks: [SIMD3<Double>],
  imageSize: SIMD2<Double>
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
  let observedPoints = CanonicalFaceModel.rigidIndices.map { landmarks[$0] }

  let rotation = try kabschRotation(canonical: canonicalPoints, observed: observedPoints)
  let head = headVector(from: rotation)

  let leftEyeCorners = eyeCorners(CanonicalFaceModel.leftEyeHorizontal, in: landmarks)
  let rightEyeCorners = eyeCorners(CanonicalFaceModel.rightEyeHorizontal, in: landmarks)

  let origin = try metricFaceOrigin(
    leftEyeCorners: leftEyeCorners,
    rightEyeCorners: rightEyeCorners,
    rotation: rotation,
    imageSize: imageSize
  )

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

private func eyeCorners(
  _ indices: [Int],
  in landmarks: [SIMD3<Double>]
) -> (SIMD2<Double>, SIMD2<Double>) {
  let first = landmarks[indices[0]]
  let second = landmarks[indices[1]]
  return (SIMD2<Double>(first.x, first.y), SIMD2<Double>(second.x, second.y))
}
