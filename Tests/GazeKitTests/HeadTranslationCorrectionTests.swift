import CoreGraphics
import Foundation
import GazeKit
import Testing

private let correction = HeadTranslationCorrection(
  referenceOriginCentimeters: SIMD3(1.0, 4.0, 65.0),
  pointsPerCentimeter: SIMD2(50.0, 50.0))

@Test func theCalibrationPoseIsLeftUntouched() {
  let point = CGPoint(x: 800, y: 500)
  #expect(correction.correct(point, faceOriginCentimeters: SIMD3(1.0, 4.0, 65.0)) == point)
}

@Test func aHeadMoveTowardsImageRightPullsThePointBackLeft() {
  let corrected = correction.correct(
    CGPoint(x: 800, y: 500), faceOriginCentimeters: SIMD3(3.0, 4.0, 65.0))
  // 2 cm at 50 pt/cm, 82 percent left for us: 82 pt, taken back.
  #expect(abs(corrected.x - 718) <= 1e-9)
  #expect(corrected.y == 500)
}

@Test func aHeadMoveDownPushesThePointDown() {
  let corrected = correction.correct(
    CGPoint(x: 800, y: 500), faceOriginCentimeters: SIMD3(1.0, 5.0, 65.0))
  #expect(corrected.x == 800)
  #expect(abs(corrected.y - 549.5) <= 1e-9)
}

@Test func depthChangesAreNotCorrectedHere() {
  let point = CGPoint(x: 800, y: 500)
  #expect(correction.correct(point, faceOriginCentimeters: SIMD3(1.0, 4.0, 40.0)) == point)
}

@Test func aNonFiniteOriginLeavesThePointAlone() {
  let point = CGPoint(x: 800, y: 500)
  #expect(correction.correct(point, faceOriginCentimeters: SIMD3(.nan, 4.0, 65.0)) == point)
}

@Test func aLeanBackThatDropsTheFaceInTheFrameIsBoundedNotFollowed() {
  // 15 cm lower in the camera frame at 96 cm depth, as seen live after a lean
  // back against a tilted lid. Uncapped this would be 745 pt.
  let corrected = correction.correct(
    CGPoint(x: 800, y: 500), faceOriginCentimeters: SIMD3(1.0, 19.0, 96.0))
  #expect(abs(corrected.y - (500 + 0.99 * 50 * 3)) <= 1e-9)
  #expect(corrected.x == 800)
}

private let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)

@Test func atTheCalibrationDepthScalingChangesNothing() {
  let point = CGPoint(x: 1500, y: 900)
  #expect(
    correction.scaleForDepth(
      point, faceOriginCentimeters: SIMD3(1.0, 4.0, 65.0), displayBounds: display)
      == point)
}

@Test func leaningBackStretchesTheOffsetFromTheSpotStraightAhead() {
  // Eyes 1 cm right of the camera and 4 cm below it: straight ahead is
  // (864 + 50, 0 + 200). At 1.3x the distance a point 586 pt right and 700 pt
  // below that spot lands 1.3x as far.
  let scaled = correction.scaleForDepth(
    CGPoint(x: 1500, y: 900), faceOriginCentimeters: SIMD3(1.0, 4.0, 84.5), displayBounds: display)
  #expect(abs(scaled.x - (914 + 586 * 1.3)) <= 1e-9)
  #expect(abs(scaled.y - (200 + 700 * 1.3)) <= 1e-9)
}

@Test func depthRatiosBeyondTheBandAreHeldAtTheEdge() {
  let far = correction.scaleForDepth(
    CGPoint(x: 1500, y: 900), faceOriginCentimeters: SIMD3(1.0, 4.0, 200.0), displayBounds: display)
  let atLimit = correction.scaleForDepth(
    CGPoint(x: 1500, y: 900), faceOriginCentimeters: SIMD3(1.0, 4.0, 65.0 * 1.4),
    displayBounds: display)
  #expect(far == atLimit)
  let point = CGPoint(x: 1500, y: 900)
  #expect(
    correction.scaleForDepth(
      point, faceOriginCentimeters: SIMD3(1.0, 4.0, -3.0), displayBounds: display)
      == point)
}
