import AppKit
import Foundation
import Testing

@testable import SmartGaze

/// Decodes the real in-memory JPEG so the provider sample can never ship as an
/// untested blank render. No disk, no screen capture, no network.
@MainActor
@Test func sampleCodeRendererProducesANonBlankJPEGInMemory() throws {
  let data = try #require(
    SampleCodeRenderer.renderJPEG(code: "let total = values.reduce(0, +)"))

  #expect(Array(data.prefix(2)) == [0xFF, 0xD8])
  let bitmap = try #require(NSBitmapImageRep(data: data))
  #expect(bitmap.pixelsWide == 720)
  #expect(bitmap.pixelsHigh == 420)

  var nonWhitePixels = 0
  for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
      guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
      if color.redComponent < 0.9 || color.greenComponent < 0.9 || color.blueComponent < 0.9 {
        nonWhitePixels += 1
      }
    }
  }

  #expect(nonWhitePixels > 0)
}
