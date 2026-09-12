import CoreGraphics
import Testing

@testable import GazeKit

private func rectIsClose(_ lhs: CGRect, _ rhs: CGRect, tolerance: Double = 1e-9) -> Bool {
  abs(Double(lhs.minX) - Double(rhs.minX)) <= tolerance
    && abs(Double(lhs.minY) - Double(rhs.minY)) <= tolerance
    && abs(Double(lhs.width) - Double(rhs.width)) <= tolerance
    && abs(Double(lhs.height) - Double(rhs.height)) <= tolerance
}

private func rect(of crop: FaceCrop) -> CGRect {
  CGRect(
    x: Double(crop.center.x) - crop.side / 2,
    y: Double(crop.center.y) - crop.side / 2,
    width: crop.side,
    height: crop.side)
}

private func near(_ actual: Double, _ expected: Double, tolerance: Double = 1e-9) -> Bool {
  abs(actual - expected) <= tolerance
}

private func syntheticLandmarks() -> [SIMD3<Double>] {
  var landmarks = [SIMD3<Double>](repeating: SIMD3(300, 300, 0), count: 468)
  landmarks[33] = SIMD3(200, 200, 0)
  landmarks[263] = SIMD3(400, 300, 0)
  landmarks[152] = SIMD3(300, 420, 0)
  return landmarks
}

@Test func expansionFactorIsOneAndAHalf() {
  #expect(FaceCrop.expansionFactor == 1.5)
}

@Test func centeredBoxFlipsBottomLeftToTopLeftAndExpands() throws {
  // A 100x200 box at Vision's normalized bottom-left origin (0.4, 0.4) in a
  // 1000x1000 frame sits at pixel x in [400, 500], and, measured from the
  // top, y in [400, 600] (bottom-left corner is 400 up from the bottom, i.e.
  // 600 down from the top; the box spans 200px above that).
  let box = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.2)
  let frame = CGSize(width: 1000, height: 1000)

  let crop = try #require(FaceCrop.seed(visionBoundingBox: box, frameSize: frame))

  // side = max(100, 200) * 1.5 = 300, centered on (450, 500).
  let expected = CGRect(x: 300, y: 350, width: 300, height: 300)
  #expect(rectIsClose(rect(of: crop), expected))
}

@Test func cropIsClampedWhenExpansionWouldLeaveTheFrame() throws {
  let box = CGRect(x: 0.0, y: 0.9, width: 0.1, height: 0.1)
  let frame = CGSize(width: 1000, height: 1000)

  let crop = try #require(FaceCrop.seed(visionBoundingBox: box, frameSize: frame))

  // side = 100 * 1.5 = 150, centered at pixel (50, 50), so the crop is
  // pushed to stay inside [0, 1000] on both axes rather than spilling past
  // the top-left corner.
  #expect(crop.center.x == 75)
  #expect(crop.center.y == 75)
  #expect(crop.side == 150)
}

@Test func cropSideShrinksToFitAFrameSmallerThanTheExpandedBox() throws {
  let box = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
  let frame = CGSize(width: 100, height: 100)

  let crop = try #require(FaceCrop.seed(visionBoundingBox: box, frameSize: frame))

  // side = 80 * 1.5 = 120, larger than the 100px frame on both axes.
  #expect(crop.side == 100)
  #expect(crop.center.x == 50)
  #expect(crop.center.y == 50)
}

@Test func largeFaceBoxInAWideFrameYieldsASquareCrop() throws {
  let box = CGRect(x: 0, y: 0, width: 0.9, height: 0.9)
  let frame = CGSize(width: 1280, height: 720)

  let crop = try #require(FaceCrop.seed(visionBoundingBox: box, frameSize: frame))

  // widthPx = 1152, heightPx = 648, raw side = 1152 * 1.5 = 1728, clamped to
  // min(1728, 1280, 720) = 720 before the independent-axis clamp runs, so the
  // 1280-wide frame cannot stretch the crop into a 1280x720 rectangle.
  let expected = CGRect(x: 216, y: 0, width: 720, height: 720)
  #expect(rectIsClose(rect(of: crop), expected))
}

@Test func largeFaceBoxInATallFrameYieldsASquareCrop() throws {
  let box = CGRect(x: 0, y: 0, width: 0.9, height: 0.9)
  let frame = CGSize(width: 720, height: 1280)

  let crop = try #require(FaceCrop.seed(visionBoundingBox: box, frameSize: frame))

  // widthPx = 648, heightPx = 1152, raw side = 1152 * 1.5 = 1728, clamped to
  // min(1728, 720, 1280) = 720 before the independent-axis clamp runs, so the
  // 1280-tall frame cannot stretch the crop into a 720x1280 rectangle.
  let expected = CGRect(x: 0, y: 344, width: 720, height: 720)
  #expect(rectIsClose(rect(of: crop), expected))
}

@Test func zeroOrNegativeFrameSizeIsRejected() {
  let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
  #expect(FaceCrop.seed(visionBoundingBox: box, frameSize: .zero) == nil)
  #expect(
    FaceCrop.seed(visionBoundingBox: box, frameSize: CGSize(width: -100, height: 100)) == nil)
}

@Test func nonFiniteFrameSizeIsRejected() {
  let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
  #expect(
    FaceCrop.seed(visionBoundingBox: box, frameSize: CGSize(width: CGFloat.nan, height: 100))
      == nil)
  #expect(
    FaceCrop.seed(visionBoundingBox: box, frameSize: CGSize(width: 100, height: CGFloat.infinity))
      == nil)
}

@Test func degenerateBoundingBoxIsRejected() {
  let frame = CGSize(width: 1000, height: 1000)
  #expect(
    FaceCrop.seed(
      visionBoundingBox: CGRect(x: 0.1, y: 0.1, width: 0, height: 0.2), frameSize: frame) == nil)
  #expect(
    FaceCrop.seed(
      visionBoundingBox: CGRect(x: .nan, y: 0.1, width: 0.2, height: 0.2), frameSize: frame) == nil)
}

@Test func trackingUsesEyeCornersForRotationAndLandmarkExtentForTheBox() throws {
  let crop = try #require(
    FaceCrop.tracking(
      landmarks: syntheticLandmarks(), frameSize: CGSize(width: 1000, height: 1000)))

  // p263 - p33 = (200, 100); the box spans x 200...400 and y 200...420.
  #expect(near(crop.rotationRadians, atan2(100, 200)))
  #expect(near(Double(crop.center.x), 300))
  #expect(near(Double(crop.center.y), 310))
  #expect(near(crop.side, 220 * 1.5))
}

@Test func trackingFoldsAMirroredRotationBackToTheSameNearLevelAngle() throws {
  var landmarks = syntheticLandmarks()
  landmarks[33] = SIMD3(400, 300, 0)
  landmarks[263] = SIMD3(200, 200, 0)

  let crop = try #require(
    FaceCrop.tracking(landmarks: landmarks, frameSize: CGSize(width: 1000, height: 1000)))

  #expect(near(crop.rotationRadians, atan2(100, 200)))
  #expect(!near(crop.rotationRadians, atan2(100, 200) + .pi))
}

@Test func trackingRejectsTheWrongLandmarkCount() {
  #expect(FaceCrop.tracking(landmarks: [], frameSize: CGSize(width: 100, height: 100)) == nil)
  var landmarks = syntheticLandmarks()
  landmarks.removeLast()
  #expect(
    FaceCrop.tracking(landmarks: landmarks, frameSize: CGSize(width: 100, height: 100)) == nil)
}

@Test func trackingRejectsNonFiniteCoordinates() {
  var landmarks = syntheticLandmarks()
  landmarks[0] = SIMD3(.nan, 300, 0)
  #expect(
    FaceCrop.tracking(landmarks: landmarks, frameSize: CGSize(width: 100, height: 100)) == nil)

  landmarks = syntheticLandmarks()
  landmarks[10] = SIMD3(300, .infinity, 0)
  #expect(
    FaceCrop.tracking(landmarks: landmarks, frameSize: CGSize(width: 100, height: 100)) == nil)
}

@Test func trackingRejectsACollapsedBox() {
  let landmarks = [SIMD3<Double>](repeating: SIMD3(300, 300, 0), count: 468)
  #expect(
    FaceCrop.tracking(landmarks: landmarks, frameSize: CGSize(width: 100, height: 100)) == nil)
}

@Test func trackingRejectsASideBelowOne() {
  var landmarks = [SIMD3<Double>](repeating: SIMD3(300, 300, 0), count: 468)
  landmarks[263] = SIMD3(300.5, 300, 0)
  #expect(
    FaceCrop.tracking(landmarks: landmarks, frameSize: CGSize(width: 100, height: 100)) == nil)
}

@Test func scaleIsFramePixelsPerCropPixel() throws {
  let crop = try #require(FaceCrop(center: .zero, side: 96, rotationRadians: 0))
  #expect(near(crop.scale(cropPixelSize: 192), 0.5))
}

@Test func cropToFrameWithZeroRotationMapsCornersToTheRectsCorners() throws {
  let crop = try #require(FaceCrop(center: CGPoint(x: 100, y: 100), side: 50, rotationRadians: 0))
  let transform = try #require(crop.cropToFrame(cropPixelSize: 192))

  // rect is (75, 75, 50, 50), so crop (0, 0) -> (75, 75) and
  // (192, 192) -> (125, 125).
  let topLeft = try #require(transform.map(CGPoint(x: 0, y: 0)))
  #expect(near(Double(topLeft.x), 75))
  #expect(near(Double(topLeft.y), 75))

  let bottomRight = try #require(transform.map(CGPoint(x: 192, y: 192)))
  #expect(near(Double(bottomRight.x), 125))
  #expect(near(Double(bottomRight.y), 125))
}

@Test func cropToFrameWithAQuarterTurnMapsAPointByTheFormula() throws {
  let crop = try #require(
    FaceCrop(center: CGPoint(x: 100, y: 100), side: 50, rotationRadians: .pi / 2))
  let transform = try #require(crop.cropToFrame(cropPixelSize: 100))

  // scale = 50/100 = 0.5; crop (100, 0) -> center + R*(25, -25) = (125, 125).
  let mapped = try #require(transform.map(CGPoint(x: 100, y: 0)))
  #expect(near(Double(mapped.x), 125))
  #expect(near(Double(mapped.y), 125))
}

@Test func frameToCropInvertsCropToFrame() throws {
  let crop = try #require(
    FaceCrop(center: CGPoint(x: 37.5, y: -12.25), side: 80, rotationRadians: 0.7))
  let forward = try #require(crop.cropToFrame(cropPixelSize: 192))
  let backward = try #require(crop.frameToCrop(cropPixelSize: 192))

  let point = CGPoint(x: 61.25, y: 148.5)
  let framePoint = try #require(forward.map(point))
  let roundTrip = try #require(backward.map(framePoint))
  #expect(near(Double(roundTrip.x), 61.25))
  #expect(near(Double(roundTrip.y), 148.5))
}

@Test func transformsRejectNonPositiveOrNonFiniteCropPixelSize() throws {
  let crop = try #require(FaceCrop(center: CGPoint(x: 100, y: 100), side: 50, rotationRadians: 0))
  #expect(crop.cropToFrame(cropPixelSize: 0) == nil)
  #expect(crop.cropToFrame(cropPixelSize: -1) == nil)
  #expect(crop.cropToFrame(cropPixelSize: .infinity) == nil)
  #expect(crop.frameToCrop(cropPixelSize: 0) == nil)
  #expect(crop.frameToCrop(cropPixelSize: -1) == nil)
  #expect(crop.frameToCrop(cropPixelSize: .nan) == nil)
}

@Test func initRejectsNonFiniteOrNonPositiveInputs() {
  #expect(FaceCrop(center: .zero, side: 0, rotationRadians: 0) == nil)
  #expect(FaceCrop(center: .zero, side: -1, rotationRadians: 0) == nil)
  #expect(FaceCrop(center: CGPoint(x: CGFloat.nan, y: 0), side: 10, rotationRadians: 0) == nil)
  #expect(FaceCrop(center: .zero, side: .infinity, rotationRadians: 0) == nil)
  #expect(FaceCrop(center: .zero, side: 10, rotationRadians: .nan) == nil)
}
