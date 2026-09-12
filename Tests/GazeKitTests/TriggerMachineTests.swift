import CoreGraphics
import Foundation
import GazeKit
import Testing

// Fixation has no public initializer; build one the way a real caller would,
// by feeding a tight cluster through FixationDetector. With window 1.0 and a
// constant point, this always yields startedAt == start and duration == 1.0.
private func fixation(at point: CGPoint, startingAt start: TimeInterval) -> Fixation {
  var detector = FixationDetector(window: 1.0, dispersionThreshold: 200)
  for step in 0..<10 {
    _ = detector.add(point, at: start + Double(step) * 0.1)
  }
  return detector.add(point, at: start + 1.0)!
}

@Test func modifierModeIgnoresGazeAlone() {
  var machine = TriggerMachine(mode: .modifierHeld)

  #expect(machine.handle(.gaze(CGPoint(x: 10, y: 20), 0.0)) == [])
  #expect(machine.handle(.gaze(CGPoint(x: 30, y: 40), 0.1)) == [])
  #expect(machine.state == .idle)
}

@Test func modifierModeDownGazeUpFiresOneCaptureAtLastGazePoint() {
  var machine = TriggerMachine(mode: .modifierHeld)

  #expect(machine.handle(.modifierDown(0.0)) == [])
  #expect(machine.state == .settling(since: 0.0))

  #expect(
    machine.handle(.gaze(CGPoint(x: 5, y: 5), 0.1)) == [.showReticle(at: CGPoint(x: 5, y: 5))])
  #expect(machine.state == .armed(region: CGPoint(x: 5, y: 5), since: 0.0))

  #expect(
    machine.handle(.gaze(CGPoint(x: 9, y: 9), 0.2)) == [.showReticle(at: CGPoint(x: 9, y: 9))])
  #expect(machine.state == .armed(region: CGPoint(x: 9, y: 9), since: 0.0))

  #expect(
    machine.handle(.modifierUp(0.3))
      == [.capture(at: CGPoint(x: 9, y: 9)), .hideReticle])
  #expect(machine.state == .firing(region: CGPoint(x: 9, y: 9)))
}

@Test func modifierUpWithNoGazeProducesNoCapture() {
  var machine = TriggerMachine(mode: .modifierHeld)

  #expect(machine.handle(.modifierDown(0.0)) == [])
  #expect(machine.handle(.modifierUp(0.1)) == [])
  #expect(machine.state == .idle)
}

@Test func dwellModeFixationFiresOneCapture() {
  var machine = TriggerMachine(mode: .passiveDwell)
  let point = CGPoint(x: 12, y: 34)

  #expect(machine.handle(.fixation(fixation(at: point, startingAt: 0.0))) == [.capture(at: point)])
  #expect(machine.state == .firing(region: point))
}

@Test func dwellModeSecondFixationInsideCooldownProducesNoCaptureThenFiresAfterExpiry() {
  var machine = TriggerMachine(mode: .passiveDwell, cooldown: 3.0)
  let point = CGPoint(x: 12, y: 34)

  #expect(machine.handle(.fixation(fixation(at: point, startingAt: 0.0))) == [.capture(at: point)])
  #expect(machine.state == .firing(region: point))

  #expect(machine.handle(.fixation(fixation(at: point, startingAt: 1.5))) == [])
  #expect(machine.state == .cooldown(until: 4.0))

  // The cooldown has expired but the bubble is still up, so nothing fires.
  #expect(machine.handle(.fixation(fixation(at: point, startingAt: 4.1))) == [])
  #expect(machine.state == .idle)

  _ = machine.handle(.presentationEnded(5.0))
  #expect(machine.handle(.fixation(fixation(at: point, startingAt: 5.1))) == [.capture(at: point)])
  #expect(machine.state == .firing(region: point))
}

@Test func sustainedFixationAtSameRegionNeverProducesMoreThanOneCapturePerCooldown() {
  var machine = TriggerMachine(mode: .passiveDwell, cooldown: 3.0)
  let point = CGPoint(x: 1, y: 1)
  var captures = 0

  for index in 0..<5 {
    let effects = machine.handle(.fixation(fixation(at: point, startingAt: Double(index) * 0.5)))
    #expect(effects.count <= 1)
    captures += effects.filter { $0 == .capture(at: point) }.count
  }

  #expect(captures == 1)
}

@Test func blinkRateOverCeilingSuppressesCaptureInModifierMode() {
  var machine = TriggerMachine(mode: .modifierHeld, blinkRateCeiling: 40)

  for index in 0..<41 {
    _ = machine.handle(.blink(.blink, Double(index) * 0.5))
  }

  _ = machine.handle(.modifierDown(20.1))
  _ = machine.handle(.gaze(CGPoint(x: 7, y: 7), 20.2))

  #expect(machine.handle(.modifierUp(20.3)) == [.hideReticle])
  #expect(machine.state == .idle)
}

@Test func blinkRateOverCeilingSuppressesCaptureInDwellMode() {
  var machine = TriggerMachine(mode: .passiveDwell, blinkRateCeiling: 40)

  for index in 0..<41 {
    _ = machine.handle(.blink(.blink, Double(index) * 0.5))
  }

  let point = CGPoint(x: 2, y: 2)
  #expect(machine.handle(.fixation(fixation(at: point, startingAt: 20.0))) == [])
  #expect(machine.state == .idle)
}

@Test func faceLostFromArmedReturnsToIdleAndEmitsHideReticle() {
  var machine = TriggerMachine(mode: .modifierHeld)

  _ = machine.handle(.modifierDown(0.0))
  _ = machine.handle(.gaze(CGPoint(x: 3, y: 3), 0.1))

  #expect(machine.handle(.faceLost(0.2)) == [.hideReticle])
  #expect(machine.state == .idle)
}

@Test func faceLostFromIdleIsANoOp() {
  var machine = TriggerMachine(mode: .modifierHeld)

  #expect(machine.handle(.faceLost(0.0)) == [])
  #expect(machine.state == .idle)
}

@Test func dismissedReturnsToIdle() {
  var machine = TriggerMachine(mode: .passiveDwell)
  let point = CGPoint(x: 4, y: 4)

  _ = machine.handle(.fixation(fixation(at: point, startingAt: 0.0)))
  #expect(machine.handle(.dismissed(2.0)) == [.dismissBubble])
  #expect(machine.state == .idle)
}

@Test func doubleBlinkModeFiresAtLastGazePoint() {
  var machine = TriggerMachine(mode: .doubleBlink)

  #expect(machine.handle(.gaze(CGPoint(x: 6, y: 8), 0.0)) == [])
  #expect(machine.handle(.blink(.blink, 0.1)) == [])
  #expect(
    machine.handle(.blink(.doubleBlink, 0.3)) == [.capture(at: CGPoint(x: 6, y: 8))])
  #expect(machine.state == .firing(region: CGPoint(x: 6, y: 8)))
}

@Test func doubleBlinkModeWithNoGazeYetProducesNoCapture() {
  var machine = TriggerMachine(mode: .doubleBlink)

  #expect(machine.handle(.blink(.doubleBlink, 0.0)) == [])
  #expect(machine.state == .idle)
}

@Test func machineNeverEmitsTwoCaptureEffectsFromOneInput() {
  var machine = TriggerMachine(mode: .modifierHeld)

  _ = machine.handle(.modifierDown(0.0))
  _ = machine.handle(.gaze(CGPoint(x: 1, y: 1), 0.1))
  let effects = machine.handle(.modifierUp(0.2))

  #expect(effects.filter { $0 == .capture(at: CGPoint(x: 1, y: 1)) }.count == 1)
}

@Test func modifierModeIgnoresFixationInput() {
  var machine = TriggerMachine(mode: .modifierHeld)
  let point = CGPoint(x: 1, y: 1)

  #expect(machine.handle(.fixation(fixation(at: point, startingAt: 0.0))) == [])
  #expect(machine.state == .idle)
}

@Test func dwellModeIgnoresModifierInputs() {
  var machine = TriggerMachine(mode: .passiveDwell)

  #expect(machine.handle(.modifierDown(0.0)) == [])
  #expect(machine.handle(.modifierUp(0.1)) == [])
  #expect(machine.state == .idle)
}

@Test func doubleBlinkAfterFaceLostFromIdleDoesNotCaptureStaleGaze() {
  var machine = TriggerMachine(mode: .doubleBlink)

  #expect(machine.handle(.gaze(CGPoint(x: 100, y: 100), 0.0)) == [])
  #expect(machine.state == .idle)

  #expect(machine.handle(.faceLost(1.0)) == [])
  #expect(machine.handle(.blink(.doubleBlink, 2.0)) == [])
  #expect(machine.state == .idle)
}

@Test func faceLostFromPristineIdleThenDoubleBlinkProducesNoCapture() {
  var machine = TriggerMachine(mode: .doubleBlink)

  #expect(machine.handle(.faceLost(0.0)) == [])
  #expect(machine.handle(.blink(.doubleBlink, 1.0)) == [])
  #expect(machine.state == .idle)
}

@Test func faceLostAfterFiringCooldownThenDoubleBlinkProducesNoCapture() {
  var machine = TriggerMachine(mode: .doubleBlink, cooldown: 3.0)

  #expect(machine.handle(.gaze(CGPoint(x: 7, y: 7), 0.0)) == [])
  #expect(machine.handle(.blink(.doubleBlink, 0.1)) == [.capture(at: CGPoint(x: 7, y: 7))])
  #expect(machine.state == .firing(region: CGPoint(x: 7, y: 7)))

  #expect(machine.handle(.faceLost(1.0)) == [.hideReticle])
  #expect(machine.state == .idle)

  #expect(machine.handle(.blink(.doubleBlink, 5.0)) == [])
  #expect(machine.state == .idle)
}

@Test func freshGazeAfterFaceLostAllowsLaterDoubleBlinkCapture() {
  var machine = TriggerMachine(mode: .doubleBlink, cooldown: 3.0)

  #expect(machine.handle(.gaze(CGPoint(x: 100, y: 100), 0.0)) == [])
  #expect(machine.handle(.faceLost(1.0)) == [])
  #expect(machine.handle(.blink(.doubleBlink, 2.0)) == [])

  #expect(machine.handle(.gaze(CGPoint(x: 50, y: 60), 2.1)) == [])
  #expect(machine.handle(.blink(.doubleBlink, 2.2)) == [.capture(at: CGPoint(x: 50, y: 60))])
  #expect(machine.state == .firing(region: CGPoint(x: 50, y: 60)))
}

@Test func aVisibleBubbleBlocksFurtherDwellCapturesUntilItGoesAway() {
  var machine = TriggerMachine(mode: .passiveDwell, cooldown: 1.0)
  let first = CGPoint(x: 100, y: 100)
  let second = CGPoint(x: 900, y: 600)

  #expect(machine.handle(.fixation(fixation(at: first, startingAt: 0.0))) == [.capture(at: first)])
  #expect(machine.isPresenting)

  // Well past the cooldown, a fresh fixation elsewhere must not replace the bubble.
  #expect(machine.handle(.fixation(fixation(at: second, startingAt: 10.0))) == [])
  #expect(machine.state == .idle)
  #expect(machine.isPresenting)

  #expect(machine.handle(.presentationEnded(12.0)) == [])
  #expect(!machine.isPresenting)
  #expect(
    machine.handle(.fixation(fixation(at: second, startingAt: 13.0))) == [.capture(at: second)])
}

@Test func aVisibleBubbleBlocksArmingInModifierMode() {
  var machine = TriggerMachine(mode: .modifierHeld, cooldown: 1.0)
  let point = CGPoint(x: 5, y: 5)

  _ = machine.handle(.modifierDown(0.0))
  _ = machine.handle(.gaze(point, 0.1))
  #expect(machine.handle(.modifierUp(0.2)) == [.capture(at: point), .hideReticle])

  #expect(machine.handle(.modifierDown(5.0)) == [])
  #expect(machine.state == .idle)
  #expect(machine.handle(.gaze(point, 5.1)) == [])
  #expect(machine.handle(.modifierUp(5.2)) == [])

  _ = machine.handle(.dismissed(6.0))
  #expect(!machine.isPresenting)
  #expect(machine.handle(.modifierDown(7.0)) == [])
  #expect(machine.state == .settling(since: 7.0))
}

@Test func squintModeStartedArmsAndEndedFiresAtTheAimedPoint() {
  var machine = TriggerMachine(mode: .squint)

  #expect(machine.handle(.squint(.started, 0.0)) == [])
  #expect(machine.state == .settling(since: 0.0))

  #expect(
    machine.handle(.gaze(CGPoint(x: 5, y: 5), 0.1)) == [.showReticle(at: CGPoint(x: 5, y: 5))])
  #expect(machine.state == .armed(region: CGPoint(x: 5, y: 5), since: 0.0))

  #expect(
    machine.handle(.gaze(CGPoint(x: 9, y: 9), 0.2)) == [.showReticle(at: CGPoint(x: 9, y: 9))])
  #expect(machine.state == .armed(region: CGPoint(x: 9, y: 9), since: 0.0))

  #expect(
    machine.handle(.squint(.ended, 0.3))
      == [.capture(at: CGPoint(x: 9, y: 9)), .hideReticle])
  #expect(machine.state == .firing(region: CGPoint(x: 9, y: 9)))
}

@Test func squintEndedWithoutStartedProducesNothing() {
  var machine = TriggerMachine(mode: .squint)

  #expect(machine.handle(.squint(.ended, 0.0)) == [])
  #expect(machine.state == .idle)
}

@Test func squintModeSecondSquintInsideCooldownFiresNothing() {
  var machine = TriggerMachine(mode: .squint, cooldown: 3.0)

  #expect(machine.handle(.squint(.started, 0.0)) == [])
  #expect(
    machine.handle(.gaze(CGPoint(x: 6, y: 8), 0.1)) == [.showReticle(at: CGPoint(x: 6, y: 8))])
  #expect(
    machine.handle(.squint(.ended, 0.2))
      == [.capture(at: CGPoint(x: 6, y: 8)), .hideReticle])

  #expect(machine.handle(.squint(.started, 0.3)) == [])
  #expect(machine.handle(.gaze(CGPoint(x: 6, y: 8), 0.4)) == [])
  #expect(machine.handle(.squint(.ended, 0.5)) == [])
  #expect(machine.state == .cooldown(until: 3.2))
}

@Test func squintModeWithNoGazeYetProducesNoCapture() {
  var machine = TriggerMachine(mode: .squint)

  #expect(machine.handle(.squint(.started, 0.0)) == [])
  #expect(machine.state == .settling(since: 0.0))
  #expect(machine.handle(.squint(.ended, 0.1)) == [])
  #expect(machine.state == .idle)
}

@Test func modifierModeIgnoresSquintInput() {
  var machine = TriggerMachine(mode: .modifierHeld)

  #expect(machine.handle(.gaze(CGPoint(x: 6, y: 8), 0.0)) == [])
  #expect(machine.handle(.squint(.started, 0.1)) == [])
  #expect(machine.state == .idle)
}

@Test func squintModeIgnoresBlinkInput() {
  var machine = TriggerMachine(mode: .squint)

  #expect(machine.handle(.gaze(CGPoint(x: 6, y: 8), 0.0)) == [])
  #expect(machine.handle(.blink(.doubleBlink, 0.1)) == [])
  #expect(machine.state == .idle)
}
