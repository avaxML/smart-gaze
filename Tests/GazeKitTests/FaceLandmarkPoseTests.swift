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

private func rotationAboutX(_ angle: Double) -> RotationMatrix {
  let c = cos(angle)
  let s = sin(angle)
  return (
    SIMD3<Double>(1, 0, 0),
    SIMD3<Double>(0, c, -s),
    SIMD3<Double>(0, s, c)
  )
}

private func imageSpaceLandmarks(canonicalFrame points: [SIMD3<Double>]) -> [SIMD3<Double>] {
  points.map { SIMD3<Double>($0.x, -$0.y, -$0.z) }
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
  let landmarks = imageSpaceLandmarks(canonicalFrame: CanonicalFaceModel.vertices)
  let result = try headPoseInputs(landmarks: landmarks, imageSize: imageSize)

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
  let landmarks = imageSpaceLandmarks(canonicalFrame: CanonicalFaceModel.vertices)
  let result = try headPoseInputs(landmarks: landmarks, imageSize: imageSize)

  #expect(abs(magnitude(result.headVector) - 1) <= tolerance)
}

@Test func twentyDegreesAboutYIsRecovered() throws {
  let expected = rotationAboutY(20 * Double.pi / 180)
  let canonicalFrameObserved = CanonicalFaceModel.vertices.map { apply(expected, to: $0) }
  let observed = imageSpaceLandmarks(canonicalFrame: canonicalFrameObserved)

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
  let landmarks = imageSpaceLandmarks(canonicalFrame: CanonicalFaceModel.vertices)
  let result = try headPoseInputs(landmarks: landmarks, imageSize: imageSize)
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

@Test func pitchInImageConventionIsRecovered() throws {
  let expected = rotationAboutX(20 * Double.pi / 180)
  let canonicalFrameObserved = CanonicalFaceModel.vertices.map { apply(expected, to: $0) }
  let observed = imageSpaceLandmarks(canonicalFrame: canonicalFrameObserved)

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

@Test func headVectorVerticalComponentSignMatchesPitchDirection() throws {
  func headVectorY(pitchDegrees degrees: Double) throws -> Double {
    let rotation = rotationAboutX(degrees * Double.pi / 180)
    let canonicalFrameObserved = CanonicalFaceModel.vertices.map { apply(rotation, to: $0) }
    let observed = imageSpaceLandmarks(canonicalFrame: canonicalFrameObserved)
    let result = try headPoseInputs(landmarks: observed, imageSize: imageSize)
    return result.headVector.y
  }

  #expect(try headVectorY(pitchDegrees: 20) < 0)
  #expect(try headVectorY(pitchDegrees: -20) > 0)
}

@Test func headVectorMatchesTheStoredRotation() throws {
  let landmarks = imageSpaceLandmarks(canonicalFrame: CanonicalFaceModel.vertices)
  let result = try headPoseInputs(landmarks: landmarks, imageSize: imageSize)

  #expect(difference(headVector(from: result.rotation), result.headVector) <= 1e-12)
}

@Test func faceTurnedAwayFromCameraThrowsHeadVectorNotFacingCamera() {
  let rotation = rotationAboutY(Double.pi)
  let canonicalFrameObserved = CanonicalFaceModel.vertices.map { apply(rotation, to: $0) }
  let observed = imageSpaceLandmarks(canonicalFrame: canonicalFrameObserved)
  let expectedZ = headVector(from: RigidRotation(matrix: rotation)).z
  #expect(expectedZ >= 0)

  #expect {
    _ = try headPoseInputs(landmarks: observed, imageSize: imageSize)
  } throws: { error in
    guard case FaceLandmarkError.headVectorNotFacingCamera(let z) = error else { return false }
    return abs(z - expectedZ) <= rotationTolerance
  }
}

@Test func measuredFocalLengthScalesRecoveredDepth() throws {
  let landmarks = imageSpaceLandmarks(canonicalFrame: CanonicalFaceModel.vertices)
  let assumed = try headPoseInputs(landmarks: landmarks, imageSize: imageSize)
  let measured = try headPoseInputs(
    landmarks: landmarks, imageSize: imageSize, verticalFocalLengthPixels: 1920)

  let assumedFocalPx = resolvedVerticalFocalLengthPixels(measured: nil, imageHeight: imageSize.y)
  let expectedZ = assumed.faceOrigin.centimetres.z * 1920 / assumedFocalPx

  #expect(abs(measured.faceOrigin.centimetres.z - expectedZ) <= 1e-9)
}

@Test func malformedFocalLengthFallsBackToTheAssumedFieldOfView() throws {
  let landmarks = imageSpaceLandmarks(canonicalFrame: CanonicalFaceModel.vertices)
  let assumed = try headPoseInputs(landmarks: landmarks, imageSize: imageSize)

  for malformed: Double in [0, -935, .nan, .infinity] {
    let fallback = try headPoseInputs(
      landmarks: landmarks, imageSize: imageSize, verticalFocalLengthPixels: malformed)
    #expect(fallback.faceOrigin.centimetres.z == assumed.faceOrigin.centimetres.z)
  }
}

@Test func headYawIsZeroFacingTheCameraAndTwentyDegreesAfterATwentyDegreeTurn() throws {
  let square = try headPoseInputs(
    landmarks: imageSpaceLandmarks(canonicalFrame: CanonicalFaceModel.vertices),
    imageSize: imageSize)
  #expect(abs(headYawRadians(from: square.headVector)) <= tolerance)

  let turned = CanonicalFaceModel.vertices.map {
    apply(rotationAboutY(20 * Double.pi / 180), to: $0)
  }
  let result = try headPoseInputs(
    landmarks: imageSpaceLandmarks(canonicalFrame: turned), imageSize: imageSize)
  #expect(abs(abs(headYawRadians(from: result.headVector)) - 20 * Double.pi / 180) <= 0.02)
}
