import Foundation
import Testing

@testable import GazeKit

private let tolerance = 1e-9
private let rotationTolerance = 1e-6

private typealias RotationMatrix = (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)

private func rotationAboutY(_ angle: Double) -> RotationMatrix {
  let c = cos(angle)
  let s = sin(angle)
  return (
    SIMD3<Double>(c, 0, s),
    SIMD3<Double>(0, 1, 0),
    SIMD3<Double>(-s, 0, c)
  )
}

private func apply(_ rows: RotationMatrix, to vector: SIMD3<Double>) -> SIMD3<Double> {
  SIMD3<Double>(
    rows.0.x * vector.x + rows.0.y * vector.y + rows.0.z * vector.z,
    rows.1.x * vector.x + rows.1.y * vector.y + rows.1.z * vector.z,
    rows.2.x * vector.x + rows.2.y * vector.y + rows.2.z * vector.z
  )
}

private func magnitude(_ vector: SIMD3<Double>) -> Double {
  (vector.x * vector.x + vector.y * vector.y + vector.z * vector.z).squareRoot()
}

private func difference(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
  magnitude(a - b)
}

private let imageSize = SIMD2<Double>(1920, 1080)

@Test func identityLandmarksRecoverIdentityRotation() throws {
  let result = try headPoseInputs(landmarks: CanonicalFaceModel.vertices, imageSize: imageSize)

  #expect(abs(result.rotation.matrix.0.x - 1) <= tolerance)
  #expect(abs(result.rotation.matrix.0.y - 0) <= tolerance)
  #expect(abs(result.rotation.matrix.0.z - 0) <= tolerance)
  #expect(abs(result.rotation.matrix.1.x - 0) <= tolerance)
  #expect(abs(result.rotation.matrix.1.y - 1) <= tolerance)
  #expect(abs(result.rotation.matrix.1.z - 0) <= tolerance)
  #expect(abs(result.rotation.matrix.2.x - 0) <= tolerance)
  #expect(abs(result.rotation.matrix.2.y - 0) <= tolerance)
  #expect(abs(result.rotation.matrix.2.z - 1) <= tolerance)
}

@Test func identityHeadVectorIsUnitLength() throws {
  let result = try headPoseInputs(landmarks: CanonicalFaceModel.vertices, imageSize: imageSize)

  #expect(abs(magnitude(result.headVector) - 1) <= tolerance)
}

@Test func twentyDegreesAboutYIsRecovered() throws {
  let expected = rotationAboutY(20 * Double.pi / 180)
  let observed = CanonicalFaceModel.vertices.map { apply(expected, to: $0) }

  let result = try headPoseInputs(landmarks: observed, imageSize: imageSize)

  #expect(abs(result.rotation.matrix.0.x - expected.0.x) <= rotationTolerance)
  #expect(abs(result.rotation.matrix.0.y - expected.0.y) <= rotationTolerance)
  #expect(abs(result.rotation.matrix.0.z - expected.0.z) <= rotationTolerance)
  #expect(abs(result.rotation.matrix.1.x - expected.1.x) <= rotationTolerance)
  #expect(abs(result.rotation.matrix.1.y - expected.1.y) <= rotationTolerance)
  #expect(abs(result.rotation.matrix.1.z - expected.1.z) <= rotationTolerance)
  #expect(abs(result.rotation.matrix.2.x - expected.2.x) <= rotationTolerance)
  #expect(abs(result.rotation.matrix.2.y - expected.2.y) <= rotationTolerance)
  #expect(abs(result.rotation.matrix.2.z - expected.2.z) <= rotationTolerance)
}

@Test func wrongLandmarkCountThrows() {
  let landmarks = Array(CanonicalFaceModel.vertices.prefix(10))

  #expect(throws: FaceLandmarkError.wrongLandmarkCount(got: 10, need: 468)) {
    try headPoseInputs(landmarks: landmarks, imageSize: imageSize)
  }
}

@Test func nonFiniteLandmarkThrowsWithItsIndex() {
  var landmarks = CanonicalFaceModel.vertices
  landmarks[200].y = Double.nan

  #expect(throws: FaceLandmarkError.nonFiniteLandmark(index: 200)) {
    try headPoseInputs(landmarks: landmarks, imageSize: imageSize)
  }
}

@Test func infiniteLandmarkThrowsWithItsIndex() {
  var landmarks = CanonicalFaceModel.vertices
  landmarks[7].y = Double.infinity

  #expect(throws: FaceLandmarkError.nonFiniteLandmark(index: 7)) {
    try headPoseInputs(landmarks: landmarks, imageSize: imageSize)
  }
}

@Test func modelVectorsRoundTripTheDoubles() throws {
  let result = try headPoseInputs(landmarks: CanonicalFaceModel.vertices, imageSize: imageSize)
  let vectors = result.modelVectors
  let floatTolerance = 1e-5

  #expect(abs(Double(vectors.headVector.x) - result.headVector.x) <= floatTolerance)
  #expect(abs(Double(vectors.headVector.y) - result.headVector.y) <= floatTolerance)
  #expect(abs(Double(vectors.headVector.z) - result.headVector.z) <= floatTolerance)
  #expect(
    abs(Double(vectors.faceOriginCentimeters.x) - result.faceOrigin.centimetres.x)
      <= floatTolerance * abs(result.faceOrigin.centimetres.x)
  )
  #expect(
    abs(Double(vectors.faceOriginCentimeters.y) - result.faceOrigin.centimetres.y)
      <= floatTolerance * abs(result.faceOrigin.centimetres.y)
  )
  #expect(
    abs(Double(vectors.faceOriginCentimeters.z) - result.faceOrigin.centimetres.z)
      <= floatTolerance * abs(result.faceOrigin.centimetres.z)
  )
}

@Test func headVectorMatchesTheStoredRotation() throws {
  let result = try headPoseInputs(landmarks: CanonicalFaceModel.vertices, imageSize: imageSize)

  #expect(difference(headVector(from: result.rotation), result.headVector) <= 1e-12)
}
