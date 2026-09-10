import CoreGraphics
import Testing

@testable import GazeKit

private func projectivelyEqual(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: Double = 1e-9) -> Bool {
  abs(Double(lhs.x) - Double(rhs.x)) <= tolerance
    && abs(Double(lhs.y) - Double(rhs.y)) <= tolerance
}

/// Reference values derived from the hand-written homography
/// H = [[2, 1, 5], [1, 3, 7], [0.001, 0.002, 1]] applied to the source square.
@Test func knownProjectiveMapMatchesHandComputedDestinations() throws {
  let source = [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 100, y: 0),
    CGPoint(x: 0, y: 100),
    CGPoint(x: 100, y: 100),
  ]
  let destination = [
    CGPoint(x: 5, y: 7),
    CGPoint(x: 186.36363636363637, y: 97.27272727272727),
    CGPoint(x: 87.5, y: 255.83333333333334),
    CGPoint(x: 234.6153846153846, y: 313.0769230769231),
  ]

  let transform = try #require(ProjectiveTransform(source: source, destination: destination))

  for (point, expected) in zip(source, destination) {
    let mapped = try #require(transform.map(point))
    #expect(projectivelyEqual(mapped, expected, tolerance: 1e-9))
  }

  let interior = try #require(transform.map(CGPoint(x: 25, y: 75)))
  #expect(
    projectivelyEqual(
      interior, CGPoint(x: 110.63829787234043, y: 218.72340425531914), tolerance: 1e-9))
}

@Test func scaleAndTranslationMapsLiteralPoint() throws {
  let source = [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 0, y: 1),
    CGPoint(x: 1, y: 1),
    CGPoint(x: 1, y: 0),
  ]
  let destination = [
    CGPoint(x: 10, y: 20),
    CGPoint(x: 10, y: 120),
    CGPoint(x: 110, y: 120),
    CGPoint(x: 110, y: 20),
  ]

  let transform = try #require(ProjectiveTransform(source: source, destination: destination))
  let mapped = try #require(transform.map(CGPoint(x: 0.25, y: 0.5)))
  #expect(projectivelyEqual(mapped, CGPoint(x: 35, y: 70), tolerance: 1e-9))
}

@Test func inverseRoundTripsScaleAndTranslationLiterally() throws {
  let source = [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 0, y: 1),
    CGPoint(x: 1, y: 1),
    CGPoint(x: 1, y: 0),
  ]
  let destination = [
    CGPoint(x: 10, y: 20),
    CGPoint(x: 10, y: 120),
    CGPoint(x: 110, y: 120),
    CGPoint(x: 110, y: 20),
  ]

  let transform = try #require(ProjectiveTransform(source: source, destination: destination))
  let inverse = try #require(transform.inverse)

  // x' = 10 + 100x, y' = 20 + 100y  =>  x = (x' - 10)/100, y = (y' - 20)/100.
  let restored = try #require(inverse.map(CGPoint(x: 35, y: 70)))
  #expect(projectivelyEqual(restored, CGPoint(x: 0.25, y: 0.5), tolerance: 1e-9))

  let forwardAgain = try #require(transform.map(restored))
  #expect(projectivelyEqual(forwardAgain, CGPoint(x: 35, y: 70), tolerance: 1e-9))
}

@Test func identityCorrespondenceMapsPointsToThemselves() throws {
  let points = [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 0, y: 512),
    CGPoint(x: 512, y: 512),
    CGPoint(x: 512, y: 0),
  ]
  let transform = try #require(ProjectiveTransform(source: points, destination: points))
  let mapped = try #require(transform.map(CGPoint(x: 123.5, y: 456.25)))
  #expect(projectivelyEqual(mapped, CGPoint(x: 123.5, y: 456.25), tolerance: 1e-9))
}

@Test func collinearSourcePointsAreRejected() {
  let source = [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 1, y: 1),
    CGPoint(x: 2, y: 2),
    CGPoint(x: 3, y: 3),
  ]
  let destination = [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 0, y: 512),
    CGPoint(x: 512, y: 512),
    CGPoint(x: 512, y: 0),
  ]
  #expect(ProjectiveTransform(source: source, destination: destination) == nil)
}

@Test func duplicateDestinationPointsAreRejected() {
  let source = [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 0, y: 512),
    CGPoint(x: 512, y: 512),
    CGPoint(x: 512, y: 0),
  ]
  let destination = [
    CGPoint(x: 10, y: 10),
    CGPoint(x: 10, y: 10),
    CGPoint(x: 20, y: 20),
    CGPoint(x: 30, y: 30),
  ]
  #expect(ProjectiveTransform(source: source, destination: destination) == nil)
}

@Test func nonFiniteSourcePointIsRejected() {
  let source = [
    CGPoint(x: 0, y: 0),
    CGPoint(x: CGFloat.nan, y: 512),
    CGPoint(x: 512, y: 512),
    CGPoint(x: 512, y: 0),
  ]
  let destination = [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 0, y: 512),
    CGPoint(x: 512, y: 512),
    CGPoint(x: 512, y: 0),
  ]
  #expect(ProjectiveTransform(source: source, destination: destination) == nil)
}

@Test func wrongPointCountIsRejected() {
  let source = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 512), CGPoint(x: 512, y: 512)]
  let destination = [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 0, y: 512),
    CGPoint(x: 512, y: 512),
    CGPoint(x: 512, y: 0),
  ]
  #expect(ProjectiveTransform(source: source, destination: destination) == nil)
}

@Test func singularMatrixHasNoInverse() throws {
  let singular = try #require(
    ProjectiveTransform(matrix: [1, 0, 0, 0, 1, 0, 0, 0, 0])
  )
  #expect(singular.inverse == nil)
}

@Test func nonFiniteMatrixIsRejected() {
  #expect(ProjectiveTransform(matrix: [1, 0, 0, 0, 1, 0, 0, 0, Double.nan]) == nil)
  #expect(ProjectiveTransform(matrix: [1, 0, 0, 0, 1, 0]) == nil)
}

@Test func mapRejectsZeroDenominator() throws {
  let transform = try #require(
    ProjectiveTransform(matrix: [1, 0, 0, 0, 1, 0, 1, 0, 0])
  )
  // w = 1*x + 0*y + 0 = x, so x = 0 has no finite image.
  #expect(transform.map(CGPoint(x: 0, y: 5)) == nil)
  #expect(transform.map(CGPoint(x: 4, y: 5)) != nil)
}

@Test func translatedMatrixInvertsAndMapsLiterally() throws {
  // x' = x + 10000, y' = y + 10000; det = 1 despite the largest entry.
  let transform = try #require(
    ProjectiveTransform(matrix: [1, 0, 10000, 0, 1, 10000, 0, 0, 1]))

  let mapped = try #require(transform.map(CGPoint(x: 2, y: 3)))
  #expect(projectivelyEqual(mapped, CGPoint(x: 10002, y: 10003), tolerance: 1e-9))

  let inverse = try #require(transform.inverse)
  let restored = try #require(inverse.map(CGPoint(x: 10002, y: 10003)))
  #expect(projectivelyEqual(restored, CGPoint(x: 2, y: 3), tolerance: 1e-9))
}

@Test func tinyScaledIdentityMapsLiterally() throws {
  // Every entry is scaled by 1e-14, so the raw denominator is 1e-14 yet the
  // homography is still the identity.
  let transform = try #require(
    ProjectiveTransform(matrix: [1e-14, 0, 0, 0, 1e-14, 0, 0, 0, 1e-14]))

  let mapped = try #require(transform.map(CGPoint(x: 2, y: 3)))
  #expect(projectivelyEqual(mapped, CGPoint(x: 2, y: 3), tolerance: 1e-9))

  let inverse = try #require(transform.inverse)
  #expect(projectivelyEqual(try #require(inverse.map(CGPoint(x: 2, y: 3))), CGPoint(x: 2, y: 3)))
}

@Test func equivalentMatrixScalingsMapToTheSameLiterals() throws {
  let base = [2.0, 1, 5, 1, 3, 7, 0.001, 0.002, 1]
  let expected = CGPoint(x: 110.63829787234043, y: 218.72340425531914)

  for scale in [1e-14, 1e-7, 1.0, 1e7, 1e14] {
    let transform = try #require(ProjectiveTransform(matrix: base.map { $0 * scale }))
    let mapped = try #require(transform.map(CGPoint(x: 25, y: 75)))
    #expect(projectivelyEqual(mapped, expected, tolerance: 1e-6))
    #expect(transform.inverse != nil)
  }
}

@Test func highResolutionFaceQuadInvertsLiterally() throws {
  let source = [
    CGPoint(x: 7600, y: 1000),
    CGPoint(x: 7600, y: 1200),
    CGPoint(x: 7800, y: 1200),
    CGPoint(x: 7800, y: 1000),
  ]
  let destination = [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 0, y: 512),
    CGPoint(x: 512, y: 512),
    CGPoint(x: 512, y: 0),
  ]
  let transform = try #require(ProjectiveTransform(source: source, destination: destination))

  for (point, expected) in zip(source, destination) {
    let mapped = try #require(transform.map(point))
    #expect(projectivelyEqual(mapped, expected, tolerance: 1e-6))
  }

  let inverse = try #require(transform.inverse)
  let restored = try #require(inverse.map(CGPoint(x: 512, y: 512)))
  #expect(projectivelyEqual(restored, CGPoint(x: 7800, y: 1200), tolerance: 1e-6))
}

@Test func cancelingDenominatorIsRejectedRelativeToItsTerms() throws {
  // w = x - y vanishes on the diagonal, a genuine pole, but is well away from
  // zero elsewhere.
  let transform = try #require(
    ProjectiveTransform(matrix: [1, 0, 0, 0, 1, 0, 1, -1, 0])
  )
  #expect(transform.map(CGPoint(x: 5, y: 5)) == nil)

  let offDiagonal = try #require(transform.map(CGPoint(x: 6, y: 5)))
  #expect(projectivelyEqual(offDiagonal, CGPoint(x: 6, y: 5), tolerance: 1e-9))
}

@Test func millionPointTranslationStillHasAnInverse() throws {
  let transform = try #require(ProjectiveTransform(matrix: [1, 0, 1e6, 0, 1, 1e6, 0, 0, 1]))
  let inverse = try #require(transform.inverse)
  let point = try #require(inverse.map(CGPoint(x: 1_000_002, y: 1_000_003)))
  #expect(abs(point.x - 2) < 1e-6)
  #expect(abs(point.y - 3) < 1e-6)
}

@Test func extremeHomogeneousGaugesPreserveIdentity() throws {
  for scale in [1e-200, 1e200, 1e308] {
    let transform = try #require(
      ProjectiveTransform(matrix: [scale, 0, 0, 0, scale, 0, 0, 0, scale]))
    let point = try #require(transform.map(CGPoint(x: 2, y: 3)))
    #expect(abs(point.x - 2) < 1e-12)
    #expect(abs(point.y - 3) < 1e-12)
    let inverse = try #require(transform.inverse)
    #expect(inverse.map(CGPoint(x: 2, y: 3)) == CGPoint(x: 2, y: 3))
  }
}

@Test func cancellationInDeterminantIsStillRejected() throws {
  let transform = try #require(ProjectiveTransform(matrix: [1, 1, 0, 1, 1 + 1e-14, 0, 0, 0, 1]))
  #expect(transform.inverse == nil)
}
