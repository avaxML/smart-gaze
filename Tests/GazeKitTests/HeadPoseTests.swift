import Foundation
import Testing

@testable import GazeKit

private let tolerance = 1e-9

private typealias RotationMatrix = (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)

private func rotationMatrix(axis rawAxis: SIMD3<Double>, angle: Double) -> RotationMatrix {
  let axis = rawAxis / magnitude(rawAxis)
  let x = axis.x
  let y = axis.y
  let z = axis.z
  let c = cos(angle)
  let s = sin(angle)
  let t = 1 - c
  let r0 = SIMD3<Double>(t * x * x + c, t * x * y - s * z, t * x * z + s * y)
  let r1 = SIMD3<Double>(t * x * y + s * z, t * y * y + c, t * y * z - s * x)
  let r2 = SIMD3<Double>(t * x * z - s * y, t * y * z + s * x, t * z * z + c)
  return (r0, r1, r2)
}

private func apply(_ rows: RotationMatrix, to vector: SIMD3<Double>) -> SIMD3<Double> {
  SIMD3<Double>(
    rows.0.x * vector.x + rows.0.y * vector.y + rows.0.z * vector.z,
    rows.1.x * vector.x + rows.1.y * vector.y + rows.1.z * vector.z,
    rows.2.x * vector.x + rows.2.y * vector.y + rows.2.z * vector.z
  )
}

private func near(_ actual: SIMD3<Double>, _ expected: SIMD3<Double>) -> Bool {
  abs(actual.x - expected.x) <= tolerance
    && abs(actual.y - expected.y) <= tolerance
    && abs(actual.z - expected.z) <= tolerance
}

private func magnitude(_ vector: SIMD3<Double>) -> Double {
  (vector.x * vector.x + vector.y * vector.y + vector.z * vector.z).squareRoot()
}

private let identityRotation = RigidRotation(
  matrix: (SIMD3<Double>(1, 0, 0), SIMD3<Double>(0, 1, 0), SIMD3<Double>(0, 0, 1)))

private let nonCoplanarPoints: [SIMD3<Double>] = [
  SIMD3(0, 0, 0),
  SIMD3(1, 0, 0),
  SIMD3(0, 1, 0),
  SIMD3(0, 0, 1),
  SIMD3(1, 1, 0),
  SIMD3(1, 0, 1),
  SIMD3(0, 1, 1),
  SIMD3(1, 1, 1),
]

@Test func identityRecoversIdentityMatrix() throws {
  let rotation = try kabschRotation(canonical: nonCoplanarPoints, observed: nonCoplanarPoints)

  #expect(near(rotation.matrix.0, SIMD3<Double>(1, 0, 0)))
  #expect(near(rotation.matrix.1, SIMD3<Double>(0, 1, 0)))
  #expect(near(rotation.matrix.2, SIMD3<Double>(0, 0, 1)))
}

@Test func ninetyDegreesAboutZIsRecovered() throws {
  let expected = rotationMatrix(axis: SIMD3<Double>(0, 0, 1), angle: .pi / 2)
  let observed = nonCoplanarPoints.map { apply(expected, to: $0) }

  let rotation = try kabschRotation(canonical: nonCoplanarPoints, observed: observed)

  #expect(near(rotation.matrix.0, expected.0))
  #expect(near(rotation.matrix.1, expected.1))
  #expect(near(rotation.matrix.2, expected.2))
}

@Test func thirtyDegreesAboutYIsRecovered() throws {
  let expected = rotationMatrix(axis: SIMD3<Double>(0, 1, 0), angle: .pi / 6)
  let observed = nonCoplanarPoints.map { apply(expected, to: $0) }

  let rotation = try kabschRotation(canonical: nonCoplanarPoints, observed: observed)

  #expect(near(rotation.matrix.0, expected.0))
  #expect(near(rotation.matrix.1, expected.1))
  #expect(near(rotation.matrix.2, expected.2))
}

@Test func translationOfObservedPointsIsIgnored() throws {
  let expected = rotationMatrix(axis: SIMD3<Double>(1, 1, 0), angle: .pi / 5)
  let observed = nonCoplanarPoints.map { apply(expected, to: $0) }
  let translated = observed.map { $0 + SIMD3<Double>(12.5, -7.0, 3.25) }

  let rotation = try kabschRotation(canonical: nonCoplanarPoints, observed: translated)

  #expect(near(rotation.matrix.0, expected.0))
  #expect(near(rotation.matrix.1, expected.1))
  #expect(near(rotation.matrix.2, expected.2))
}

@Test func mismatchedLandmarkCountsThrow() {
  let canonical: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
  let observed: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0)]

  #expect(throws: HeadPoseError.landmarkCountMismatch(canonical: 3, observed: 2)) {
    try kabschRotation(canonical: canonical, observed: observed)
  }
}

@Test func twoLandmarksThrowTooFewLandmarks() {
  let points: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0)]

  #expect(throws: HeadPoseError.tooFewLandmarks(got: 2, need: 3)) {
    try kabschRotation(canonical: points, observed: points)
  }
}

@Test func headVectorOfIdentityMatchesHandComputedLiterals() {
  let vector = headVector(from: identityRotation)

  #expect(abs(vector.x - 0) <= tolerance)
  #expect(abs(vector.y - 0) <= tolerance)
  #expect(abs(vector.z - (-1)) <= tolerance)
  #expect(abs(magnitude(vector) - 1) <= tolerance)
}

@Test func headVectorIsAlwaysUnitLength() {
  let axes: [(SIMD3<Double>, Double)] = [
    (SIMD3(0, 0, 1), 0),
    (SIMD3(0, 0, 1), .pi / 3),
    (SIMD3(0, 1, 0), .pi / 4),
    (SIMD3(1, 0, 0), .pi / 5),
    (SIMD3(1, 1, 0), .pi / 2),
    (SIMD3(1, 1, 1), .pi / 7),
  ]

  for (axis, angle) in axes {
    let rotation = RigidRotation(matrix: rotationMatrix(axis: axis, angle: angle))
    #expect(abs(magnitude(headVector(from: rotation)) - 1) <= tolerance)
  }
}

@Test func headVectorClampsAsinArgumentPastOne() {
  let rotation = RigidRotation(
    matrix: (SIMD3<Double>(1, 0, 0), SIMD3<Double>(0, 1, 0), SIMD3<Double>(-1.5, 0, 0)))
  let vector = headVector(from: rotation)

  #expect(vector.x.isFinite)
  #expect(vector.y.isFinite)
  #expect(vector.z.isFinite)
  #expect(abs(magnitude(vector) - 1) <= tolerance)
}

@Test func depthScalesInverselyWithPixelIPD() throws {
  let imageSize = SIMD2<Double>(1000, 1000)
  let wide = try metricFaceOrigin(
    leftEyeCorners: (SIMD2(400, 500), SIMD2(400, 500)),
    rightEyeCorners: (SIMD2(600, 500), SIMD2(600, 500)),
    rotation: identityRotation,
    imageSize: imageSize
  )
  let narrow = try metricFaceOrigin(
    leftEyeCorners: (SIMD2(450, 500), SIMD2(450, 500)),
    rightEyeCorners: (SIMD2(550, 500), SIMD2(550, 500)),
    rotation: identityRotation,
    imageSize: imageSize
  )

  #expect(abs(narrow.centimetres.z - 2 * wide.centimetres.z) <= tolerance)
}

@Test func originIsZeroWhenEyesAreCentred() throws {
  let origin = try metricFaceOrigin(
    leftEyeCorners: (SIMD2(450, 250), SIMD2(450, 250)),
    rightEyeCorners: (SIMD2(550, 250), SIMD2(550, 250)),
    rotation: identityRotation,
    imageSize: SIMD2(1000, 500)
  )

  #expect(abs(origin.centimetres.x - 0) <= tolerance)
  #expect(abs(origin.centimetres.y - 0) <= tolerance)
}

@Test func originSignsFollowImageAxes() throws {
  let origin = try metricFaceOrigin(
    leftEyeCorners: (SIMD2(550, 300), SIMD2(550, 300)),
    rightEyeCorners: (SIMD2(650, 300), SIMD2(650, 300)),
    rotation: identityRotation,
    imageSize: SIMD2(1000, 500)
  )

  #expect(origin.centimetres.x > 0)
  #expect(origin.centimetres.y < 0)
}

@Test func zeroPixelIPDThrowsDegenerateConfiguration() {
  #expect(throws: HeadPoseError.degenerateConfiguration) {
    try metricFaceOrigin(
      leftEyeCorners: (SIMD2(500, 250), SIMD2(500, 250)),
      rightEyeCorners: (SIMD2(500, 250), SIMD2(500, 250)),
      rotation: identityRotation,
      imageSize: SIMD2(1000, 500)
    )
  }
}
