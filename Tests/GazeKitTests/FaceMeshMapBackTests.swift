import CoreGraphics
import Testing

@testable import GazeKit

private func near(_ actual: Double, _ expected: Double, tolerance: Double = 1e-9) -> Bool {
  abs(actual - expected) <= tolerance
}

@Test func squareCropMapsCropPixelsToFullFrame() throws {
  // A 100x100 pixel crop at (200, 50) in a 400x200 frame; a landmark at the
  // crop's center in 192-pixel crop space lands at the crop's center pixel.
  let landmarks: [SIMD3<Float>] = [SIMD3(96, 96, 10)]
  let cropRect = CGRect(x: 200, y: 50, width: 100, height: 100)
  let frameSize = CGSize(width: 400, height: 200)

  let result = try mapCropLandmarksToFrame(
    cropLandmarks: landmarks, cropPixelSize: 192, cropRect: cropRect, frameSize: frameSize)

  // pixelX = 200 + 96/192*100 = 250, pixelY = 50 + 96/192*100 = 100.
  #expect(result.pixelSpace.count == 1)
  #expect(near(result.pixelSpace[0].x, 250))
  #expect(near(result.pixelSpace[0].y, 100))
  #expect(near(result.pixelSpace[0].z, 10.0 / 192 * 100))

  // normalized = pixel / frame.
  #expect(near(Double(result.normalized[0].x), 250.0 / 400))
  #expect(near(Double(result.normalized[0].y), 100.0 / 200))
}

@Test func nonSquareCropAgainstTheFrameScalesAxesIndependently() throws {
  // The crop rectangle's own width and height differ (300 x 150), and
  // neither matches the 1000x1000 frame's square aspect: a non-square crop
  // against a non-matching frame.
  let landmarks: [SIMD3<Float>] = [
    SIMD3(0, 0, 0),
    SIMD3(192, 192, 0),
    SIMD3(96, 48, 4),
  ]
  let cropRect = CGRect(x: 100, y: 400, width: 300, height: 150)
  let frameSize = CGSize(width: 1000, height: 1000)

  let result = try mapCropLandmarksToFrame(
    cropLandmarks: landmarks, cropPixelSize: 192, cropRect: cropRect, frameSize: frameSize)

  // Top-left corner of the crop maps to the crop's own origin.
  #expect(near(result.pixelSpace[0].x, 100))
  #expect(near(result.pixelSpace[0].y, 400))

  // Bottom-right corner of the crop maps to its far corner: (100+300, 400+150).
  #expect(near(result.pixelSpace[1].x, 400))
  #expect(near(result.pixelSpace[1].y, 550))

  // Midpoint landmark: scaleX = 300/192, scaleY = 150/192, independently.
  let scaleX = 300.0 / 192
  let scaleY = 150.0 / 192
  #expect(near(result.pixelSpace[2].x, 100 + 96 * scaleX))
  #expect(near(result.pixelSpace[2].y, 400 + 48 * scaleY))
  #expect(near(result.pixelSpace[2].z, 4 * scaleX))

  #expect(near(Double(result.normalized[1].x), 400.0 / 1000))
  #expect(near(Double(result.normalized[1].y), 550.0 / 1000))
}

@Test func emptyLandmarksProduceEmptyOutput() throws {
  let result = try mapCropLandmarksToFrame(
    cropLandmarks: [],
    cropPixelSize: 192,
    cropRect: CGRect(x: 0, y: 0, width: 100, height: 100),
    frameSize: CGSize(width: 400, height: 400))
  #expect(result.normalized.isEmpty)
  #expect(result.pixelSpace.isEmpty)
}

@Test func nonPositiveCropPixelSizeThrowsInvalidCrop() {
  #expect(throws: FaceMeshMapBackError.invalidCrop) {
    try mapCropLandmarksToFrame(
      cropLandmarks: [SIMD3(0, 0, 0)],
      cropPixelSize: 0,
      cropRect: CGRect(x: 0, y: 0, width: 100, height: 100),
      frameSize: CGSize(width: 400, height: 400))
  }
}

@Test func nonPositiveCropRectThrowsInvalidCrop() {
  #expect(throws: FaceMeshMapBackError.invalidCrop) {
    try mapCropLandmarksToFrame(
      cropLandmarks: [SIMD3(0, 0, 0)],
      cropPixelSize: 192,
      cropRect: CGRect(x: 0, y: 0, width: 0, height: 100),
      frameSize: CGSize(width: 400, height: 400))
  }
}

@Test func nonFiniteCropRectThrowsInvalidCrop() {
  #expect(throws: FaceMeshMapBackError.invalidCrop) {
    try mapCropLandmarksToFrame(
      cropLandmarks: [SIMD3(0, 0, 0)],
      cropPixelSize: 192,
      cropRect: CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
      frameSize: CGSize(width: 400, height: 400))
  }
}

@Test func nonPositiveFrameSizeThrowsInvalidFrame() {
  #expect(throws: FaceMeshMapBackError.invalidFrame) {
    try mapCropLandmarksToFrame(
      cropLandmarks: [SIMD3(0, 0, 0)],
      cropPixelSize: 192,
      cropRect: CGRect(x: 0, y: 0, width: 100, height: 100),
      frameSize: .zero)
  }
}
