import CoreGraphics
import Foundation
import Testing

@testable import GazeKit

private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

/// A known affine gaze-to-screen relation with no quadratic terms, so its
/// inverse below is exact: `screenX = 100 + 800 * gaze.x`, `screenY = 200 + 400 * gaze.y`.
private let truthXCoefficients = [100.0, 800.0, 0.0, 0.0, 0.0, 0.0]
private let truthYCoefficients = [200.0, 400.0, 0.0, 0.0, 0.0, 0.0]

@Test func targetGridHasNineFitPointsOnTheThreeByThreeGrid() {
  let plan = CalibrationTargetPlan(inset: 0.1)
  #expect(plan.fitTargets.count == 9)
  #expect(plan.fitTargets[0] == NormalizedGazePoint(x: 0.1, y: 0.1))
  #expect(plan.fitTargets[1] == NormalizedGazePoint(x: 0.1, y: 0.9))
  #expect(plan.fitTargets[5] == NormalizedGazePoint(x: 0.5, y: 0.5))
  #expect(plan.fitTargets[8] == NormalizedGazePoint(x: 0.9, y: 0.5))
  // No two consecutive targets share a row, so a drifting posture cannot
  // masquerade as a vertical gain.
  for pair in zip(plan.fitTargets, plan.fitTargets.dropFirst()) {
    #expect(pair.0.y != pair.1.y)
  }
}

@Test func targetGridInsetsEveryFitPointFromTheEdges() {
  let plan = CalibrationTargetPlan(inset: 0.15)
  for target in plan.fitTargets {
    #expect(target.x >= 0.15 && target.x <= 0.85)
    #expect(target.y >= 0.15 && target.y <= 0.85)
  }
}

@Test func heldOutTargetsAreFourAndDisjointFromTheFitGrid() {
  let plan = CalibrationTargetPlan(inset: 0.1)
  #expect(plan.validationTargets.count == 4)
  for validationTarget in plan.validationTargets {
    #expect(!plan.fitTargets.contains(validationTarget))
  }
  #expect(abs(plan.validationTargets[0].x - 0.3) <= 1e-9)
  #expect(abs(plan.validationTargets[0].y - 0.3) <= 1e-9)
  #expect(abs(plan.validationTargets[1].x - 0.7) <= 1e-9)
  #expect(abs(plan.validationTargets[1].y - 0.3) <= 1e-9)
  #expect(abs(plan.validationTargets[2].x - 0.3) <= 1e-9)
  #expect(abs(plan.validationTargets[2].y - 0.7) <= 1e-9)
  #expect(abs(plan.validationTargets[3].x - 0.7) <= 1e-9)
  #expect(abs(plan.validationTargets[3].y - 0.7) <= 1e-9)
}

@Test func screenPointMapsNormalizedTargetsIntoTheGivenBounds() {
  let point = CalibrationTargetPlan.screenPoint(
    for: NormalizedGazePoint(x: 0.25, y: 0.75), in: CGRect(x: 100, y: 50, width: 800, height: 600))
  #expect(point == CGPoint(x: 300, y: 500))
}

@Test func tightBurstIsAcceptedWithItsCentroid() {
  let samples = [
    NormalizedGazePoint(x: 0.50, y: 0.50),
    NormalizedGazePoint(x: 0.51, y: 0.49),
    NormalizedGazePoint(x: 0.49, y: 0.51),
  ]
  let quality = BurstEvaluator.evaluate(samples, dispersionThreshold: 0.08)
  guard case .accepted(let centroid, let horizontalSpan, let verticalSpan) = quality else {
    Issue.record("expected the burst to be accepted, got \(quality)")
    return
  }
  #expect(centroid == NormalizedGazePoint(x: 0.5, y: 0.5))
  #expect(abs(horizontalSpan - 0.02) <= 1e-12)
  #expect(abs(verticalSpan - 0.02) <= 1e-12)
}

@Test func dispersedBurstWithOneOutlierIsRejected() {
  let samples = [
    NormalizedGazePoint(x: 0.50, y: 0.50),
    NormalizedGazePoint(x: 0.51, y: 0.49),
    NormalizedGazePoint(x: 0.90, y: 0.50),
  ]
  let quality = BurstEvaluator.evaluate(samples, dispersionThreshold: 0.08)
  guard case .dispersed(let dispersion) = quality else {
    Issue.record("expected a dispersed burst, got \(quality)")
    return
  }
  #expect(dispersion >= 0.39)
}

@Test func emptyBurstIsDispersed() {
  #expect(
    BurstEvaluator.evaluate([], dispersionThreshold: 0.08) == .dispersed(dispersion: .infinity))
}

private func makeRun(dispersionThreshold: Double = 0.08) -> CalibrationRun {
  CalibrationRun(
    plan: CalibrationTargetPlan(inset: 0.1),
    bounds: bounds,
    dispersionThreshold: dispersionThreshold,
    distanceCentimeters: 55)
}

/// A gaze reading that, once run back through `truthXCoefficients` /
/// `truthYCoefficients`, projects exactly onto `target`'s screen point. Used
/// as the fit sample so `solveCalibration` recovers that known relation.
private func gazeReading(landingOn target: NormalizedGazePoint) -> NormalizedGazePoint {
  let screenPoint = CalibrationTargetPlan.screenPoint(for: target, in: bounds)
  return NormalizedGazePoint(
    x: (Double(screenPoint.x) - 100) / 800, y: (Double(screenPoint.y) - 200) / 400)
}

private func tightBurst(around target: NormalizedGazePoint) -> [NormalizedGazePoint] {
  let reading = gazeReading(landingOn: target)
  return [reading, reading, reading]
}

@Test func aDispersedBurstIsRetriedRatherThanAcceptedIntoTheFit() {
  var run = makeRun()
  guard case .fitting(targetIndex: 0) = run.stage else {
    Issue.record("expected to start on the first fit target")
    return
  }

  let dispersed = [
    NormalizedGazePoint(x: 0.1, y: 0.1),
    NormalizedGazePoint(x: 0.9, y: 0.1),
  ]
  let outcome = run.submitBurst(dispersed)
  guard case .retryTarget = outcome else {
    Issue.record("expected retryTarget, got \(outcome)")
    return
  }
  #expect(run.stage == .fitting(targetIndex: 0))
}

@Test func fittingAdvancesThroughAllNineTargetsThenSolves() {
  var run = makeRun()
  for (index, target) in CalibrationTargetPlan(inset: 0.1).fitTargets.enumerated() {
    let outcome = run.submitBurst(tightBurst(around: target))
    if index < 8 {
      #expect(outcome == .advancedToNextFitTarget)
      #expect(run.stage == .fitting(targetIndex: index + 1))
    } else {
      #expect(outcome == .advancedToNextFitTarget)
      #expect(run.stage == .sweeping)
    }
  }
}

@Test func validationAfterAPerfectFitReportsNearZeroResidualsPerAxis() {
  var run = makeRun()
  let plan = CalibrationTargetPlan(inset: 0.1)
  for target in plan.fitTargets {
    _ = run.submitBurst(tightBurst(around: target))
  }
  _ = run.submitSweep([])

  var finalOutcome: CalibrationSubmitOutcome?
  for target in plan.validationTargets {
    finalOutcome = run.submitBurst(tightBurst(around: target))
  }

  guard case .completed(let result) = finalOutcome else {
    Issue.record("expected a completed result, got \(String(describing: finalOutcome))")
    return
  }
  #expect(result.horizontalErrorPoints <= 1e-6)
  #expect(result.verticalErrorPoints <= 1e-6)
  #expect(result.distanceCentimeters == 55)
  #expect(run.stage == .finished(result))
}

@Test func abortingMidRunProducesNoResultAndLeavesTheStageAborted() {
  var run = makeRun()
  let plan = CalibrationTargetPlan(inset: 0.1)
  _ = run.submitBurst(tightBurst(around: plan.fitTargets[0]))
  _ = run.submitBurst(tightBurst(around: plan.fitTargets[1]))

  run.abort()

  #expect(run.stage == .aborted)
  #expect(run.currentTargetScreenPoint == nil)
  let outcome = run.submitBurst(tightBurst(around: plan.fitTargets[2]))
  #expect(outcome == .solveFailed(.degenerate))
}

@Test func recordDistanceOverridesTheValueCarriedIntoTheResult() {
  var run = makeRun()
  let plan = CalibrationTargetPlan(inset: 0.1)
  for target in plan.fitTargets {
    _ = run.submitBurst(tightBurst(around: target))
  }
  run.recordDistance(48)
  _ = run.submitSweep([])

  var finalOutcome: CalibrationSubmitOutcome?
  for target in plan.validationTargets {
    finalOutcome = run.submitBurst(tightBurst(around: target))
  }

  guard case .completed(let result) = finalOutcome else {
    Issue.record("expected a completed result, got \(String(describing: finalOutcome))")
    return
  }
  #expect(result.distanceCentimeters == 48)
}

@Test func currentTargetScreenPointTracksTheActiveStage() {
  var run = makeRun()
  let plan = CalibrationTargetPlan(inset: 0.1)
  #expect(
    run.currentTargetScreenPoint
      == CalibrationTargetPlan.screenPoint(for: plan.fitTargets[0], in: bounds))

  for target in plan.fitTargets {
    _ = run.submitBurst(tightBurst(around: target))
  }
  #expect(run.stage == .sweeping)
  #expect(
    run.currentTargetScreenPoint
      == CalibrationTargetPlan.screenPoint(for: plan.sweepTarget, in: bounds))

  _ = run.submitSweep([])
  #expect(
    run.currentTargetScreenPoint
      == CalibrationTargetPlan.screenPoint(for: plan.validationTargets[0], in: bounds))
}

@Test func acceptedBurstSpansAreReportedAsObservedJitter() {
  var run = makeRun()
  let plan = CalibrationTargetPlan(inset: 0.1)
  let halfHorizontal = 0.01
  let halfVertical = 0.005

  func burst(around target: NormalizedGazePoint) -> [NormalizedGazePoint] {
    [
      NormalizedGazePoint(x: target.x - halfHorizontal, y: target.y - halfVertical),
      NormalizedGazePoint(x: target.x + halfHorizontal, y: target.y + halfVertical),
    ]
  }

  for target in plan.fitTargets { _ = run.submitBurst(burst(around: target)) }
  _ = run.submitSweep([])
  var finalOutcome: CalibrationSubmitOutcome?
  for target in plan.validationTargets { finalOutcome = run.submitBurst(burst(around: target)) }

  guard case .completed(let result) = finalOutcome else {
    Issue.record("expected a completed result, got \(String(describing: finalOutcome))")
    return
  }

  #expect(result.acceptedBurstCount == 9)
  #expect(abs(result.observedHorizontalSpanPoints - 2 * halfHorizontal * 1000) <= 1e-9)
  #expect(abs(result.observedVerticalSpanPoints - 2 * halfVertical * 800) <= 1e-9)
  #expect(
    abs(result.observedDispersionPoints - (2 * halfHorizontal * 1000 + 2 * halfVertical * 800))
      <= 1e-9)
}

@Test func theResultCarriesTheMeanFaceOriginOfTheAcceptedFitBursts() {
  let plan = CalibrationTargetPlan()
  var run = CalibrationRun(
    plan: plan, bounds: CGRect(x: 0, y: 0, width: 1000, height: 600),
    dispersionThreshold: 0.25, distanceCentimeters: 60)
  let fitCount = plan.fitTargets.count
  for index in 0..<fitCount {
    let target = plan.fitTargets[index]
    // Posture drifts 0.1 cm down per target, the pattern a row by row run shows.
    run.recordFaceOrigin(SIMD3(1.0, 3.0 + 0.1 * Double(index), 60.0))
    _ = run.submitBurst([NormalizedGazePoint(x: target.x - 0.5, y: target.y - 0.5)])
  }
  #expect(run.acceptedFitOrigins.count == fitCount)

  _ = run.submitSweep([])
  for target in plan.validationTargets {
    _ = run.submitBurst([NormalizedGazePoint(x: target.x - 0.5, y: target.y - 0.5)])
  }
  guard case .finished(let result) = run.stage else {
    Issue.record("expected a finished run, got \(run.stage)")
    return
  }
  let expectedY = 3.0 + 0.1 * Double(fitCount - 1) / 2
  #expect(result.faceOriginCentimeters?.x == 1.0)
  #expect(abs((result.faceOriginCentimeters?.y ?? 0) - expectedY) <= 1e-9)
  #expect(result.faceOriginCentimeters?.z == 60.0)
}

@Test func theResultCarriesTheMedianImpliedInterpupillaryOfTheAcceptedBursts() {
  var run = makeRun()
  let plan = CalibrationTargetPlan(inset: 0.1)
  let recorded = [6.0, 6.1, 6.2, 6.3, 6.4, 6.5]
  var accepted = 0

  for target in plan.fitTargets {
    run.recordImpliedInterpupillary(recorded[accepted % recorded.count])
    accepted += 1
    _ = run.submitBurst(tightBurst(around: target))
  }
  _ = run.submitSweep([])
  var finalOutcome: CalibrationSubmitOutcome?
  for target in plan.validationTargets {
    run.recordImpliedInterpupillary(recorded[accepted % recorded.count])
    accepted += 1
    finalOutcome = run.submitBurst(tightBurst(around: target))
  }

  guard case .completed(let result) = finalOutcome else {
    Issue.record("expected a completed result, got \(String(describing: finalOutcome))")
    return
  }
  // The recorded values cycle 6.0...6.5 across the 13 accepted bursts; the
  // median of [6.0,6.0,6.0,6.1,6.1,6.2,6.2,6.3,6.3,6.4,6.4,6.5,6.5] is 6.2.
  #expect(result.interpupillaryCentimetres == 6.2)
}

@Test func aRunWithFewerThanTheMinimumRecordedValuesHasNoImpliedInterpupillary() {
  var run = makeRun()
  let plan = CalibrationTargetPlan(inset: 0.1)
  let recorded = [6.0, 6.1, 6.2]
  var next = 0

  for target in plan.fitTargets {
    if next < recorded.count {
      run.recordImpliedInterpupillary(recorded[next])
      next += 1
    }
    _ = run.submitBurst(tightBurst(around: target))
  }
  _ = run.submitSweep([])
  var finalOutcome: CalibrationSubmitOutcome?
  for target in plan.validationTargets {
    if next < recorded.count {
      run.recordImpliedInterpupillary(recorded[next])
      next += 1
    }
    finalOutcome = run.submitBurst(tightBurst(around: target))
  }

  guard case .completed(let result) = finalOutcome else {
    Issue.record("expected a completed result, got \(String(describing: finalOutcome))")
    return
  }
  #expect(result.interpupillaryCentimetres == nil)
}

@Test func aHeadSweepWithAKnownSlopeStoresTheFittedCorrection() {
  var run = makeRun()
  let plan = CalibrationTargetPlan(inset: 0.1)
  for target in plan.fitTargets {
    _ = run.submitBurst(tightBurst(around: target))
  }
  #expect(run.stage == .sweeping)

  let sweepPoint = CalibrationTargetPlan.screenPoint(for: plan.sweepTarget, in: bounds)
  var samples: [HeadRotationFit.Sample] = []
  for index in 0..<40 {
    let yaw = -0.2 + 0.4 * Double(index) / 39
    samples.append(
      HeadRotationFit.Sample(
        projected: CGPoint(x: sweepPoint.x + 1500 * (yaw - 0.02), y: sweepPoint.y),
        yawRadians: yaw, pitchRadians: 0))
  }
  #expect(run.submitSweep(samples) == .advancedToNextValidationTarget)
  #expect(run.stage == .validating(targetIndex: 0))

  var finalOutcome: CalibrationSubmitOutcome?
  for target in plan.validationTargets {
    finalOutcome = run.submitBurst(tightBurst(around: target))
  }
  guard case .completed(let result) = finalOutcome else {
    Issue.record("expected a completed result, got \(String(describing: finalOutcome))")
    return
  }
  #expect(abs((result.headRotationCorrection?.yawGainPointsPerRadian ?? 0) - 1500) <= 1e-6)
}

@Test func aSweepWithNoSamplesCompletesWithoutACorrection() {
  var run = makeRun()
  let plan = CalibrationTargetPlan(inset: 0.1)
  for target in plan.fitTargets {
    _ = run.submitBurst(tightBurst(around: target))
  }
  #expect(run.submitSweep([]) == .advancedToNextValidationTarget)

  var finalOutcome: CalibrationSubmitOutcome?
  for target in plan.validationTargets {
    finalOutcome = run.submitBurst(tightBurst(around: target))
  }
  guard case .completed(let result) = finalOutcome else {
    Issue.record("expected a completed result, got \(String(describing: finalOutcome))")
    return
  }
  #expect(result.headRotationCorrection == nil)
}
