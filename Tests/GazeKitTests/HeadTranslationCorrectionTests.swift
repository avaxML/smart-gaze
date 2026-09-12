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
