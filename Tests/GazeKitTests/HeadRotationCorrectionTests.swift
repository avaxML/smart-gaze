import CoreGraphics
import Foundation
import GazeKit
import Testing

private let correction = HeadRotationCorrection(
  referenceYawRadians: 0, referencePitchRadians: 0,
  yawGainPointsPerRadian: 2000, pitchGainPointsPerRadian: 2000)

@Test func yawRotationMovesThePointAgainstTheGain() {
  let corrected = correction.correct(
    CGPoint(x: 500, y: 300), yawRadians: 0.1, pitchRadians: 0)
  #expect(abs(corrected.x - 300) <= 1e-9)
  #expect(corrected.y == 300)
}

@Test func pitchRotationMovesThePointAgainstTheGain() {
  let corrected = correction.correct(
    CGPoint(x: 500, y: 300), yawRadians: 0, pitchRadians: 0.1)
  #expect(corrected.x == 500)
  #expect(abs(corrected.y - 100) <= 1e-9)
}

@Test func theReferencePoseIsLeftUntouched() {
  let point = CGPoint(x: 500, y: 300)
  #expect(correction.correct(point, yawRadians: 0, pitchRadians: 0) == point)
}

@Test func aNonFinitePoseLeavesThePointAlone() {
  let point = CGPoint(x: 500, y: 300)
  #expect(correction.correct(point, yawRadians: .nan, pitchRadians: 0) == point)
  #expect(correction.correct(point, yawRadians: 0, pitchRadians: .infinity) == point)
}

/// Forty samples on a yaw sweep with the pitch held fixed, so the x residual
/// follows `400 + 1500 * (yaw - 0.02)` and the y residual is constant.
private func yawSweepSamples() -> [HeadRotationFit.Sample] {
  let target = CGPoint(x: 400, y: 300)
  return (0..<40).map { index in
    let yaw = -0.2 + 0.4 * Double(index) / 39
    return HeadRotationFit.Sample(
      projected: CGPoint(x: 400 + 1500 * (yaw - 0.02), y: target.y),
      yawRadians: yaw, pitchRadians: 0)
  }
}

@Test func fitRecoversTheKnownYawSlopeAndLeavesPitchAtZero() {
  let fit = HeadRotationFit.fit(
    samples: yawSweepSamples(), target: CGPoint(x: 400, y: 300), referenceYawRadians: 0.02,
    referencePitchRadians: 0)
  #expect(fit != nil)
  #expect(abs((fit?.yawGainPointsPerRadian ?? 0) - 1500) <= 1e-6)
  #expect(fit?.pitchGainPointsPerRadian == 0)
}

@Test func fewerThanTwentySamplesGiveNoFit() {
  let fit = HeadRotationFit.fit(
    samples: Array(yawSweepSamples().prefix(19)), target: CGPoint(x: 400, y: 300),
    referenceYawRadians: 0.02, referencePitchRadians: 0)
  #expect(fit == nil)
}

@Test func aYawRangeBelowTheMinimumGivesNoYawGain() {
  let short = (0..<30).map { index in
    let yaw = -0.05 + 0.1 * Double(index) / 29
    return HeadRotationFit.Sample(
      projected: CGPoint(x: 9000 * yaw, y: 0), yawRadians: yaw, pitchRadians: 0)
  }
  let fit = HeadRotationFit.fit(
    samples: short, target: .zero, referenceYawRadians: 0, referencePitchRadians: 0)
  #expect(fit?.yawGainPointsPerRadian == 0)
}

@Test func anOversizedGainIsClamped() {
  let steep = (0..<40).map { index in
    let yaw = -0.2 + 0.4 * Double(index) / 39
    return HeadRotationFit.Sample(
      projected: CGPoint(x: 9000 * yaw, y: 0), yawRadians: yaw, pitchRadians: 0)
  }
  let fit = HeadRotationFit.fit(
    samples: steep, target: .zero, referenceYawRadians: 0, referencePitchRadians: 0)
  #expect(fit?.yawGainPointsPerRadian == HeadRotationFit.maximumGainPointsPerRadian)
}

@Test func sweepCoverageReportsThePoseRanges() {
  let two = [
    HeadRotationFit.Sample(projected: .zero, yawRadians: -0.1, pitchRadians: 0),
    HeadRotationFit.Sample(projected: .zero, yawRadians: 0.2, pitchRadians: 0.05),
  ]
  let coverage = HeadRotationFit.sweepCoverage(two)
  #expect(abs(coverage.yaw - 0.3) <= 1e-12)
  #expect(abs(coverage.pitch - 0.05) <= 1e-12)
}

@Test func aNonFiniteStoredReferenceLeavesThePointAlone() {
  let broken = HeadRotationCorrection(
    referenceYawRadians: .nan, referencePitchRadians: 0,
    yawGainPointsPerRadian: 2000, pitchGainPointsPerRadian: 2000)
  let point = CGPoint(x: 500, y: 300)
  #expect(broken.correct(point, yawRadians: 0.1, pitchRadians: 0) == point)
  #expect(!broken.isPlausible)
}

@Test func anAbsurdStoredReferenceIsImplausible() {
  let broken = HeadRotationCorrection(
    referenceYawRadians: 1e300, referencePitchRadians: 0,
    yawGainPointsPerRadian: 100, pitchGainPointsPerRadian: 0)

  #expect(!broken.isPlausible)
}
