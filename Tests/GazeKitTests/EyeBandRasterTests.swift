import CoreGraphics
import Testing

@testable import GazeKit

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

private func uniformSource(width: Int, height: Int, colour: SIMD3<Float>) throws -> ArrayPixelSource
{
  let rgb = (0..<(width * height)).flatMap { _ in [colour.x, colour.y, colour.z] }
  return try #require(ArrayPixelSource(width: width, height: height, rgb: rgb))
}

@Test func eyeBandRGBHasTheBlazeGazeShapeAndCount() throws {
  let colour = SIMD3<Float>(0.2, 0.4, 0.8)
  let source = try uniformSource(width: 600, height: 400, colour: colour)

  let output = try eyeBandRGB(from: source, landmarks: literalLandmarks(), frameSize: literalFrame)

  #expect(output.count == 512 * 128 * 3)
}

@Test func eyeBandRGBOfAUniformFrameStaysUniform() throws {
  let colour = SIMD3<Float>(0.2, 0.4, 0.8)
  let source = try uniformSource(width: 600, height: 400, colour: colour)

  let output = try eyeBandRGB(from: source, landmarks: literalLandmarks(), frameSize: literalFrame)

  for pixel in stride(from: 0, to: output.count, by: 3) {
    #expect(abs(output[pixel] - colour.x) <= 1e-5)
    #expect(abs(output[pixel + 1] - colour.y) <= 1e-5)
    #expect(abs(output[pixel + 2] - colour.z) <= 1e-5)
  }
}

@Test func missingFaceGeometryThrowsNoFaceGeometry() throws {
  let source = try uniformSource(width: 600, height: 400, colour: SIMD3(0, 0, 0))
  let tooFew = makeLandmarks([:], count: 10)

  #expect(throws: EyeBandRasterError.noFaceGeometry) {
    try eyeBandRGB(from: source, landmarks: tooFew, frameSize: literalFrame)
  }
}

@Test func collapsedQuadThrowsNoFaceGeometry() throws {
  let source = try uniformSource(width: 600, height: 400, colour: SIMD3(0, 0, 0))
  let center = normalized(300, 200, in: literalFrame)
  let collapsed = makeLandmarks([
    103: center,
    150: center,
    379: center,
    332: center,
    4: center,
    151: normalized(300, 150, in: literalFrame),
    195: normalized(300, 250, in: literalFrame),
  ])

  #expect(throws: EyeBandRasterError.noFaceGeometry) {
    try eyeBandRGB(from: source, landmarks: collapsed, frameSize: literalFrame)
  }
}
