import CoreVideo
import Testing

@testable import Perception

private func makeBGRAPixelBuffer(width: Int, height: Int, fill: (Int, Int) -> (UInt8, UInt8, UInt8))
  throws -> CVPixelBuffer
{
  var pixelBuffer: CVPixelBuffer?
  let status = CVPixelBufferCreate(
    kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
  let buffer = try #require(status == kCVReturnSuccess ? pixelBuffer : nil)

  CVPixelBufferLockBaseAddress(buffer, [])
  defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

  let base = try #require(CVPixelBufferGetBaseAddress(buffer))
  let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
  for y in 0..<height {
    let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
    for x in 0..<width {
      let (r, g, b) = fill(x, y)
      row[x * 4] = b
      row[x * 4 + 1] = g
      row[x * 4 + 2] = r
      row[x * 4 + 3] = 255
    }
  }
  return buffer
}

@Test func rgbReadsBGRABytesInRGBOrder() throws {
  let buffer = try makeBGRAPixelBuffer(width: 2, height: 2) { x, y in
    if x == 0 && y == 0 { return (255, 0, 0) }
    if x == 1 && y == 0 { return (0, 255, 0) }
    if x == 0 && y == 1 { return (0, 0, 255) }
    return (255, 255, 0)
  }
  let source = try CVPixelBufferSource(pixelBuffer: buffer)

  #expect(source.width == 2)
  #expect(source.height == 2)
  #expect(source.rgb(x: 0, y: 0) == SIMD3<Float>(1, 0, 0))
  #expect(source.rgb(x: 1, y: 0) == SIMD3<Float>(0, 1, 0))
  #expect(source.rgb(x: 0, y: 1) == SIMD3<Float>(0, 0, 1))
  #expect(source.rgb(x: 1, y: 1) == SIMD3<Float>(1, 1, 0))
}

@Test func unsupportedPixelFormatIsRejected() throws {
  var pixelBuffer: CVPixelBuffer?
  let status = CVPixelBufferCreate(
    kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
  let buffer = try #require(status == kCVReturnSuccess ? pixelBuffer : nil)

  #expect(throws: CVPixelBufferSourceError.unsupportedPixelFormat(kCVPixelFormatType_32ARGB)) {
    try CVPixelBufferSource(pixelBuffer: buffer)
  }
}

@Test func sourceOutlivesAnEarlyReturnFromItsBuildingScope() throws {
  func buildSource() throws -> CVPixelBufferSource {
    let buffer = try makeBGRAPixelBuffer(width: 1, height: 1) { _, _ in (10, 20, 30) }
    return try CVPixelBufferSource(pixelBuffer: buffer)
  }

  let source = try buildSource()
  #expect(source.rgb(x: 0, y: 0) == SIMD3<Float>(10.0 / 255, 20.0 / 255, 30.0 / 255))
}
