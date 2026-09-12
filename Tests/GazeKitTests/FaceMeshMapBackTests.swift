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
  let crop = try #require(FaceCrop(center: CGPoint(x: 250, y: 100), side: 100, rotationRadians: 0))
  let frameSize = CGSize(width: 400, height: 200)

  let result = try mapCropLandmarksToFrame(
    cropLandmarks: landmarks, cropPixelSize: 192, crop: crop, frameSize: frameSize)

  // pixelX = 200 + 96/192*100 = 250, pixelY = 50 + 96/192*100 = 100.
  #expect(result.pixelSpace.count == 1)
  #expect(near(result.pixelSpace[0].x, 250))
  #expect(near(result.pixelSpace[0].y, 100))
  #expect(near(result.pixelSpace[0].z, 10.0 / 192 * 100))

  // normalized = pixel / frame.
  #expect(near(Double(result.normalized[0].x), 250.0 / 400))
  #expect(near(Double(result.normalized[0].y), 100.0 / 200))
}

@Test func rotatedCropMapsCropPixelsThroughTheRotation() throws {
  let landmarks: [SIMD3<Float>] = [
    SIMD3(0, 0, 8),
    SIMD3(192, 192, 0),
  ]
  let crop = try #require(
    FaceCrop(center: CGPoint(x: 200, y: 200), side: 100, rotationRadians: .pi / 2))
  let frameSize = CGSize(width: 400, height: 400)

  let result = try mapCropLandmarksToFrame(
    cropLandmarks: landmarks, cropPixelSize: 192, crop: crop, frameSize: frameSize)

  // scale = 100/192; crop (0, 0) -> center + R*(-50, -50) = (250, 150).
  #expect(near(result.pixelSpace[0].x, 250))
  #expect(near(result.pixelSpace[0].y, 150))
  #expect(near(result.pixelSpace[0].z, 8.0 * 100 / 192))

  // crop (192, 192) -> center + R*(50, 50) = (150, 250).
  #expect(near(result.pixelSpace[1].x, 150))
  #expect(near(result.pixelSpace[1].y, 250))

  #expect(near(Double(result.normalized[0].x), 250.0 / 400))
  #expect(near(Double(result.normalized[0].y), 150.0 / 400))
}

@Test func emptyLandmarksProduceEmptyOutput() throws {
  let crop = try #require(FaceCrop(center: CGPoint(x: 50, y: 50), side: 100, rotationRadians: 0))
  let result = try mapCropLandmarksToFrame(
    cropLandmarks: [], cropPixelSize: 192, crop: crop, frameSize: CGSize(width: 400, height: 400))
  #expect(result.normalized.isEmpty)
  #expect(result.pixelSpace.isEmpty)
}

@Test func nonPositiveCropPixelSizeThrowsInvalidCrop() throws {
  let crop = try #require(FaceCrop(center: CGPoint(x: 50, y: 50), side: 100, rotationRadians: 0))
  #expect(throws: FaceMeshMapBackError.invalidCrop) {
    try mapCropLandmarksToFrame(
      cropLandmarks: [SIMD3(0, 0, 0)],
      cropPixelSize: 0,
      crop: crop,
      frameSize: CGSize(width: 400, height: 400))
  }
}

@Test func degenerateFaceCropIsRejected() {
  #expect(FaceCrop(center: .zero, side: 0, rotationRadians: 0) == nil)
  #expect(FaceCrop(center: CGPoint(x: CGFloat.nan, y: 0), side: 100, rotationRadians: 0) == nil)
  #expect(FaceCrop(center: .zero, side: 100, rotationRadians: .infinity) == nil)
}

@Test func nonPositiveFrameSizeThrowsInvalidFrame() throws {
  let crop = try #require(FaceCrop(center: CGPoint(x: 50, y: 50), side: 100, rotationRadians: 0))
  #expect(throws: FaceMeshMapBackError.invalidFrame) {
    try mapCropLandmarksToFrame(
      cropLandmarks: [SIMD3(0, 0, 0)], cropPixelSize: 192, crop: crop, frameSize: .zero)
  }
}
