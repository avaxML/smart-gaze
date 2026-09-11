import CoreGraphics
import Testing

@testable import GazeKit

private func rectIsClose(_ lhs: CGRect, _ rhs: CGRect, tolerance: Double = 1e-9) -> Bool {
  abs(Double(lhs.minX) - Double(rhs.minX)) <= tolerance
    && abs(Double(lhs.minY) - Double(rhs.minY)) <= tolerance
    && abs(Double(lhs.width) - Double(rhs.width)) <= tolerance
    && abs(Double(lhs.height) - Double(rhs.height)) <= tolerance
}

@Test func expansionFactorIsOneAndAHalf() {
  #expect(FaceCropGeometry.expansionFactor == 1.5)
}

@Test func centeredBoxFlipsBottomLeftToTopLeftAndExpands() throws {
  // A 100x200 box at Vision's normalized bottom-left origin (0.4, 0.4) in a
  // 1000x1000 frame sits at pixel x in [400, 500], and, measured from the
  // top, y in [400, 600] (bottom-left corner is 400 up from the bottom, i.e.
  // 600 down from the top; the box spans 200px above that).
  let box = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.2)
  let frame = CGSize(width: 1000, height: 1000)

  let crop = try #require(
    FaceCropGeometry.expandedFaceCrop(visionBoundingBox: box, frameSize: frame))

  // side = max(100, 200) * 1.5 = 300, centered on (450, 500).
  let expected = CGRect(x: 300, y: 350, width: 300, height: 300)
  #expect(rectIsClose(crop, expected))
}

@Test func cropIsClampedWhenExpansionWouldLeaveTheFrame() throws {
  let box = CGRect(x: 0.0, y: 0.9, width: 0.1, height: 0.1)
  let frame = CGSize(width: 1000, height: 1000)

  let crop = try #require(
    FaceCropGeometry.expandedFaceCrop(visionBoundingBox: box, frameSize: frame))

  // side = 100 * 1.5 = 150, centered at pixel (50, 50), so the crop is
  // pushed to stay inside [0, 1000] on both axes rather than spilling past
  // the top-left corner.
  #expect(crop.minX == 0)
  #expect(crop.minY == 0)
  #expect(crop.width == 150)
  #expect(crop.height == 150)
}

@Test func cropSideShrinksToFitAFrameSmallerThanTheExpandedBox() throws {
  let box = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
  let frame = CGSize(width: 100, height: 100)

  let crop = try #require(
    FaceCropGeometry.expandedFaceCrop(visionBoundingBox: box, frameSize: frame))

  // side = 80 * 1.5 = 120, larger than the 100px frame on both axes.
  #expect(crop.width == 100)
  #expect(crop.height == 100)
  #expect(crop.minX == 0)
  #expect(crop.minY == 0)
}

@Test func largeFaceBoxInAWideFrameYieldsASquareCrop() throws {
  let box = CGRect(x: 0, y: 0, width: 0.9, height: 0.9)
  let frame = CGSize(width: 1280, height: 720)

  let crop = try #require(
    FaceCropGeometry.expandedFaceCrop(visionBoundingBox: box, frameSize: frame))

  // widthPx = 1152, heightPx = 648, raw side = 1152 * 1.5 = 1728, clamped to
  // min(1728, 1280, 720) = 720 before the independent-axis clamp runs, so the
  // 1280-wide frame cannot stretch the crop into a 1280x720 rectangle.
  let expected = CGRect(x: 216, y: 0, width: 720, height: 720)
  #expect(rectIsClose(crop, expected))
}

@Test func largeFaceBoxInATallFrameYieldsASquareCrop() throws {
  let box = CGRect(x: 0, y: 0, width: 0.9, height: 0.9)
  let frame = CGSize(width: 720, height: 1280)

  let crop = try #require(
    FaceCropGeometry.expandedFaceCrop(visionBoundingBox: box, frameSize: frame))

  // widthPx = 648, heightPx = 1152, raw side = 1152 * 1.5 = 1728, clamped to
  // min(1728, 720, 1280) = 720 before the independent-axis clamp runs, so the
  // 1280-tall frame cannot stretch the crop into a 720x1280 rectangle.
  let expected = CGRect(x: 0, y: 344, width: 720, height: 720)
  #expect(rectIsClose(crop, expected))
}

@Test func zeroOrNegativeFrameSizeIsRejected() {
  let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
  #expect(FaceCropGeometry.expandedFaceCrop(visionBoundingBox: box, frameSize: .zero) == nil)
  #expect(
    FaceCropGeometry.expandedFaceCrop(
      visionBoundingBox: box, frameSize: CGSize(width: -100, height: 100)) == nil)
}

@Test func nonFiniteFrameSizeIsRejected() {
  let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
  #expect(
    FaceCropGeometry.expandedFaceCrop(
      visionBoundingBox: box, frameSize: CGSize(width: CGFloat.nan, height: 100)) == nil)
  #expect(
    FaceCropGeometry.expandedFaceCrop(
      visionBoundingBox: box, frameSize: CGSize(width: 100, height: CGFloat.infinity)) == nil)
}

@Test func degenerateBoundingBoxIsRejected() {
  let frame = CGSize(width: 1000, height: 1000)
  #expect(
    FaceCropGeometry.expandedFaceCrop(
      visionBoundingBox: CGRect(x: 0.1, y: 0.1, width: 0, height: 0.2), frameSize: frame) == nil)
  #expect(
    FaceCropGeometry.expandedFaceCrop(
      visionBoundingBox: CGRect(x: .nan, y: 0.1, width: 0.2, height: 0.2), frameSize: frame) == nil)
}
