import CoreGraphics
import Testing

@testable import GazeKit

private func approximatelyEqual(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>, tolerance: Float) -> Bool
{
  abs(lhs.x - rhs.x) <= tolerance
    && abs(lhs.y - rhs.y) <= tolerance
    && abs(lhs.z - rhs.z) <= tolerance
}

private func distance(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Float {
  let delta = lhs - rhs
  return (delta.x * delta.x + delta.y * delta.y + delta.z * delta.z).squareRoot()
}

private func fullRegion(width: Int, height: Int) -> CGRect {
  CGRect(x: 0, y: 0, width: Double(width), height: Double(height))
}

private func makeSource(width: Int, height: Int, rgb: [Float]) throws -> ArrayPixelSource {
  try #require(ArrayPixelSource(width: width, height: height, rgb: rgb))
}

private let distinct2x2: [Float] = [
  1, 0, 0,
  0, 1, 0,
  0, 0, 1,
  0.25, 0.5, 0.75,
]

private let graded4x4 = (0..<48).map { Float($0) / 48 }

@Test func arrayPixelSourceRejectsMismatchedBufferLength() throws {
  #expect(ArrayPixelSource(width: 2, height: 2, rgb: [Float](repeating: 0, count: 11)) == nil)
  let valid = try makeSource(width: 2, height: 2, rgb: [Float](repeating: 0, count: 12))
  #expect(valid.width == 2)
  #expect(valid.height == 2)
}

@Test func bilinearAtIntegralCoordinatesReturnsTheExactPixel() throws {
  let source = try makeSource(width: 2, height: 2, rgb: distinct2x2)
  #expect(approximatelyEqual(bilinearRGB(source, x: 0, y: 0), SIMD3(1, 0, 0), tolerance: 1e-6))
  #expect(approximatelyEqual(bilinearRGB(source, x: 1, y: 0), SIMD3(0, 1, 0), tolerance: 1e-6))
  #expect(approximatelyEqual(bilinearRGB(source, x: 0, y: 1), SIMD3(0, 0, 1), tolerance: 1e-6))
  #expect(
    approximatelyEqual(bilinearRGB(source, x: 1, y: 1), SIMD3(0.25, 0.5, 0.75), tolerance: 1e-6))
}

@Test func bilinearAtTheMidpointAveragesTheFourPixels() throws {
  let source = try makeSource(width: 2, height: 2, rgb: distinct2x2)
  #expect(
    approximatelyEqual(
      bilinearRGB(source, x: 0.5, y: 0.5), SIMD3(0.3125, 0.375, 0.4375), tolerance: 1e-6))
}

@Test func bilinearClampsOutsideTheBounds() throws {
  let source = try makeSource(width: 2, height: 2, rgb: distinct2x2)
  let atOrigin = bilinearRGB(source, x: 0, y: 0.5)
  #expect(approximatelyEqual(atOrigin, SIMD3(0.5, 0, 0.5), tolerance: 1e-6))
  #expect(approximatelyEqual(bilinearRGB(source, x: -5, y: 0.5), atOrigin, tolerance: 1e-6))

  let atLastColumn = bilinearRGB(source, x: 1, y: 0.5)
  #expect(approximatelyEqual(atLastColumn, SIMD3(0.125, 0.75, 0.375), tolerance: 1e-6))
  #expect(approximatelyEqual(bilinearRGB(source, x: 7, y: 0.5), atLastColumn, tolerance: 1e-6))
}

@Test func singlePixelSourceReturnsThatPixelForEveryCoordinate() throws {
  let source = try makeSource(width: 1, height: 1, rgb: [0.2, 0.4, 0.6])
  #expect(
    approximatelyEqual(bilinearRGB(source, x: 0, y: 0), SIMD3(0.2, 0.4, 0.6), tolerance: 1e-6))
  #expect(
    approximatelyEqual(bilinearRGB(source, x: -3, y: 7), SIMD3(0.2, 0.4, 0.6), tolerance: 1e-6))
  #expect(
    approximatelyEqual(bilinearRGB(source, x: 100, y: -100), SIMD3(0.2, 0.4, 0.6), tolerance: 1e-6))
}

@Test func resampledRGBOutputLengthMatchesDimensions() throws {
  let source = try makeSource(width: 4, height: 4, rgb: graded4x4)
  let output = try resampledRGB(source, from: fullRegion(width: 4, height: 4), width: 3, height: 2)
  #expect(output.count == 3 * 2 * 3)
}

@Test func identityResampleReproducesTheSource() throws {
  let source = try makeSource(width: 4, height: 4, rgb: graded4x4)
  let output = try resampledRGB(source, from: fullRegion(width: 4, height: 4), width: 4, height: 4)
  #expect(output.count == 48)
  for index in 0..<48 {
    #expect(abs(output[index] - graded4x4[index]) <= 1e-6)
  }
}

@Test func downscalingAUniformImagePreservesTheColour() throws {
  let colour = SIMD3<Float>(0.2, 0.6, 0.9)
  let rgb = (0..<64).flatMap { _ in [colour.x, colour.y, colour.z] }
  let source = try makeSource(width: 8, height: 8, rgb: rgb)
  let output = try resampledRGB(source, from: fullRegion(width: 8, height: 8), width: 2, height: 2)
  #expect(output.count == 12)
  for pixel in 0..<4 {
    let value = SIMD3(output[pixel * 3], output[pixel * 3 + 1], output[pixel * 3 + 2])
    #expect(approximatelyEqual(value, colour, tolerance: 1e-6))
  }
}

@Test func upscalingPreservesTheCorners() throws {
  let source = try makeSource(width: 2, height: 2, rgb: [1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 1])
  let output = try resampledRGB(source, from: fullRegion(width: 2, height: 2), width: 4, height: 4)
  let topLeft = SIMD3(output[0], output[1], output[2])
  let bottomRight = SIMD3(output[45], output[46], output[47])

  #expect(approximatelyEqual(topLeft, SIMD3(1, 0, 0), tolerance: 1e-6))
  #expect(approximatelyEqual(bottomRight, SIMD3(1, 1, 1), tolerance: 1e-6))
  #expect(distance(topLeft, SIMD3(1, 0, 0)) < distance(topLeft, SIMD3(1, 1, 1)))
  #expect(distance(bottomRight, SIMD3(1, 1, 1)) < distance(bottomRight, SIMD3(1, 0, 0)))
}

@Test func resampledDegenerateOutputSizeThrowsEmptyOutput() throws {
  let source = try makeSource(width: 4, height: 4, rgb: graded4x4)
  #expect(throws: RasterError.emptyOutput(width: 0, height: 2)) {
    try resampledRGB(source, from: fullRegion(width: 4, height: 4), width: 0, height: 2)
  }
  #expect(throws: RasterError.emptyOutput(width: 4, height: -1)) {
    try resampledRGB(source, from: fullRegion(width: 4, height: 4), width: 4, height: -1)
  }
}

@Test func warpedPassThroughReproducesTheSource() throws {
  let source = try makeSource(width: 4, height: 4, rgb: graded4x4)
  let sourceCorners = [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 3, y: 0),
    CGPoint(x: 3, y: 3),
    CGPoint(x: 0, y: 3),
  ]
  let destinationCorners = [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 3, y: 0),
    CGPoint(x: 3, y: 3),
    CGPoint(x: 0, y: 3),
  ]
  let transform = try #require(
    ProjectiveTransform(source: sourceCorners, destination: destinationCorners))
  let output = try warpedRGB(source, transform: transform, width: 4, height: 4)
  #expect(output.count == 48)
  for index in 0..<48 {
    #expect(abs(output[index] - graded4x4[index]) <= 1e-5)
  }
}

@Test func warpedRGBOutputLengthMatchesDimensions() throws {
  let source = try makeSource(width: 4, height: 4, rgb: graded4x4)
  let corners = [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 3, y: 0),
    CGPoint(x: 3, y: 3),
    CGPoint(x: 0, y: 3),
  ]
  let transform = try #require(ProjectiveTransform(source: corners, destination: corners))
  let output = try warpedRGB(source, transform: transform, width: 3, height: 2)
  #expect(output.count == 3 * 2 * 3)
}

@Test func warpedDegenerateOutputSizeThrowsEmptyOutput() throws {
  let source = try makeSource(width: 4, height: 4, rgb: graded4x4)
  let corners = [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 3, y: 0),
    CGPoint(x: 3, y: 3),
    CGPoint(x: 0, y: 3),
  ]
  let transform = try #require(ProjectiveTransform(source: corners, destination: corners))
  #expect(throws: RasterError.emptyOutput(width: 0, height: 4)) {
    try warpedRGB(source, transform: transform, width: 0, height: 4)
  }
}

@Test func warpedNonInvertibleTransformThrows() throws {
  let source = try makeSource(width: 2, height: 2, rgb: [Float](repeating: 0, count: 12))
  let singular = try #require(ProjectiveTransform(matrix: [1, 0, 0, 0, 1, 0, 0, 0, 0]))
  #expect(throws: RasterError.nonInvertibleTransform) {
    try warpedRGB(source, transform: singular, width: 2, height: 2)
  }
}
