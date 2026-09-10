import CoreGraphics
import Testing

@testable import GazeKit

private func pointIsClose(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: Double = 1e-9) -> Bool {
  abs(Double(lhs.x) - Double(rhs.x)) <= tolerance
    && abs(Double(lhs.y) - Double(rhs.y)) <= tolerance
}

private func makeLandmarks(_ overrides: [Int: CGPoint], count: Int = 468) -> [CGPoint] {
  var points = [CGPoint](repeating: .zero, count: count)
  for (index, point) in overrides {
    points[index] = point
  }
  return points
}

private func normalized(_ x: Double, _ y: Double, in size: CGSize) -> CGPoint {
  CGPoint(x: x / Double(size.width), y: y / Double(size.height))
}

private let literalFrame = CGSize(width: 600, height: 400)

private func literalLandmarks() -> [CGPoint] {
  makeLandmarks([
    103: normalized(100, 100, in: literalFrame),
    150: normalized(100, 300, in: literalFrame),
    379: normalized(500, 300, in: literalFrame),
    332: normalized(500, 100, in: literalFrame),
    4: normalized(300, 200, in: literalFrame),
    151: normalized(300, 150, in: literalFrame),
    195: normalized(300, 250, in: literalFrame),
  ])
}

@Test func literalPaddedQuadMatchesHandComputedPoints() throws {
  let geometry = try #require(
    EyeBandGeometry.compute(landmarks: literalLandmarks(), frameSize: literalFrame))

  let expectedQuad = [
    CGPoint(x: 20, y: 80),
    CGPoint(x: 20, y: 320),
    CGPoint(x: 580, y: 320),
    CGPoint(x: 580, y: 80),
  ]
  #expect(geometry.sourceQuad.count == 4)
  for (actual, expected) in zip(geometry.sourceQuad, expectedQuad) {
    #expect(pointIsClose(actual, expected, tolerance: 1e-9))
  }
}

@Test func literalBandRowsAreTruncatedTo149UpTo362() throws {
  let geometry = try #require(
    EyeBandGeometry.compute(landmarks: literalLandmarks(), frameSize: literalFrame))
  #expect(geometry.bandRowRange == 149..<362)
}

@Test func transformMapsBandLandmarksOntoLiteralWarpPoints() throws {
  let geometry = try #require(
    EyeBandGeometry.compute(landmarks: literalLandmarks(), frameSize: literalFrame))

  let top = try #require(geometry.transform.map(CGPoint(x: 300, y: 150)))
  let bottom = try #require(geometry.transform.map(CGPoint(x: 300, y: 250)))

  #expect(pointIsClose(top, CGPoint(x: 256, y: 149.33333333333334), tolerance: 1e-6))
  #expect(pointIsClose(bottom, CGPoint(x: 256, y: 362.6666666666667), tolerance: 1e-6))

  let inverse = try #require(geometry.transform.inverse)
  let restored = try #require(inverse.map(top))
  #expect(pointIsClose(restored, CGPoint(x: 300, y: 150), tolerance: 1e-6))
}

@Test func fewerThan468LandmarksIsRejected() {
  let points = makeLandmarks([:], count: 467)
  #expect(EyeBandGeometry.compute(landmarks: points, frameSize: literalFrame) == nil)
}

@Test func extraLandmarksAreAccepted() throws {
  let geometry = try #require(
    EyeBandGeometry.compute(landmarks: literalLandmarks(), frameSize: literalFrame))
  #expect(geometry.bandRowRange == 149..<362)

  var padded = literalLandmarks()
  padded.append(contentsOf: [CGPoint](repeating: .zero, count: 10))
  let extended = try #require(EyeBandGeometry.compute(landmarks: padded, frameSize: literalFrame))
  #expect(extended.bandRowRange == 149..<362)
}

@Test func nonPositiveOrNonFiniteFrameSizeIsRejected() {
  let points = literalLandmarks()
  #expect(EyeBandGeometry.compute(landmarks: points, frameSize: .zero) == nil)
  #expect(
    EyeBandGeometry.compute(landmarks: points, frameSize: CGSize(width: -600, height: 400)) == nil)
  #expect(
    EyeBandGeometry.compute(
      landmarks: points, frameSize: CGSize(width: CGFloat.nan, height: 400)) == nil)
  #expect(
    EyeBandGeometry.compute(
      landmarks: points, frameSize: CGSize(width: 600, height: CGFloat.infinity)) == nil)
}

@Test func nonFiniteLandmarkIsRejected() {
  var points = literalLandmarks()
  points[103] = CGPoint(x: CGFloat.nan, y: 0.25)
  #expect(EyeBandGeometry.compute(landmarks: points, frameSize: literalFrame) == nil)

  var infinite = literalLandmarks()
  infinite[195] = CGPoint(x: 0.5, y: CGFloat.infinity)
  #expect(EyeBandGeometry.compute(landmarks: infinite, frameSize: literalFrame) == nil)
}

@Test func reversedBandIsRejected() {
  var points = literalLandmarks()
  points[151] = normalized(300, 300, in: literalFrame)
  points[195] = normalized(300, 150, in: literalFrame)
  #expect(EyeBandGeometry.compute(landmarks: points, frameSize: literalFrame) == nil)
}

@Test func collapsedQuadIsRejected() {
  let center = normalized(300, 200, in: literalFrame)
  let points = makeLandmarks([
    103: center,
    150: center,
    379: center,
    332: center,
    4: center,
    151: normalized(300, 150, in: literalFrame),
    195: normalized(300, 250, in: literalFrame),
  ])
  #expect(EyeBandGeometry.compute(landmarks: points, frameSize: literalFrame) == nil)
}

@Test func topRowClampsToZeroWhenWarpedAboveTheCrop() throws {
  var points = literalLandmarks()
  points[151] = normalized(300, 0, in: literalFrame)
  points[195] = normalized(300, 250, in: literalFrame)
  let geometry = try #require(EyeBandGeometry.compute(landmarks: points, frameSize: literalFrame))
  #expect(geometry.bandRowRange == 0..<362)
}

@Test func bottomRowClampsTo512WhenWarpedBelowTheCrop() throws {
  var points = literalLandmarks()
  points[151] = normalized(300, 150, in: literalFrame)
  points[195] = normalized(300, 400, in: literalFrame)
  let geometry = try #require(EyeBandGeometry.compute(landmarks: points, frameSize: literalFrame))
  #expect(geometry.bandRowRange == 149..<512)
}

@Test func borderPaddingIsNotClampedToTheFrame() throws {
  let points = makeLandmarks([
    103: normalized(10, 10, in: literalFrame),
    150: normalized(10, 390, in: literalFrame),
    379: normalized(590, 390, in: literalFrame),
    332: normalized(590, 10, in: literalFrame),
    4: normalized(300, 200, in: literalFrame),
    151: normalized(300, 150, in: literalFrame),
    195: normalized(300, 250, in: literalFrame),
  ])
  let geometry = try #require(EyeBandGeometry.compute(landmarks: points, frameSize: literalFrame))

  // dx = 10 - 300 = -290, dy = 10 - 200 = -190.
  #expect(pointIsClose(geometry.sourceQuad[0], CGPoint(x: -106, y: -28), tolerance: 1e-9))
  // dx = 590 - 300 = 290, dy = 10 - 200 = -190.
  #expect(pointIsClose(geometry.sourceQuad[3], CGPoint(x: 706, y: -28), tolerance: 1e-9))
}
