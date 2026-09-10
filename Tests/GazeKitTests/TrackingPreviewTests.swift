import CoreGraphics
import Foundation
import GazeKit
import Testing

private func cluster(
  _ preview: inout TrackingPreview,
  at point: CGPoint,
  from start: TimeInterval,
  count: Int,
  step: TimeInterval = 0.1
) -> [TriggerEffect] {
  var effects: [TriggerEffect] = []
  for index in 0..<count {
    effects += preview.handle(.sample(point, start + Double(index) * step))
  }
  return effects
}

@Test func modifierHeldFiresOnlyOnModifierRelease() {
  var preview = TrackingPreview(mode: .modifierHeld)

  #expect(preview.handle(.modifierDown(0.0)) == [])
  #expect(
    preview.handle(.sample(CGPoint(x: 5, y: 5), 0.1)) == [.showReticle(at: CGPoint(x: 5, y: 5))])
  #expect(preview.state == .armed(region: CGPoint(x: 5, y: 5), since: 0.0))

  let effects = preview.handle(.modifierUp(0.2))
  #expect(effects == [.capture(at: CGPoint(x: 5, y: 5)), .hideReticle])
  #expect(preview.localTriggerCount == 1)
  #expect(preview.lastLocalCapturePoint == CGPoint(x: 5, y: 5))
}

@Test func modifierHeldIgnoresGazeWithoutModifier() {
  var preview = TrackingPreview(mode: .modifierHeld)

  #expect(preview.handle(.sample(CGPoint(x: 5, y: 5), 0.0)) == [])
  #expect(preview.handle(.sample(CGPoint(x: 6, y: 6), 0.1)) == [])
  #expect(preview.localTriggerCount == 0)
  #expect(preview.state == .idle)
}

@Test func passiveDwellFiresOnceFromSustainedCluster() {
  var preview = TrackingPreview(
    mode: .passiveDwell, dwellWindow: 1.0, dispersionThreshold: 100)
  let effects = cluster(&preview, at: CGPoint(x: 10, y: 10), from: 0.0, count: 11)

  #expect(effects == [.capture(at: CGPoint(x: 10, y: 10))])
  #expect(preview.localTriggerCount == 1)
  #expect(preview.lastLocalCapturePoint == CGPoint(x: 10, y: 10))
  #expect(preview.state == .firing(region: CGPoint(x: 10, y: 10)))
}

@Test func passiveDwellSuppressesSecondFixationInsideCooldownThenFiresAfterExpiry() {
  var preview = TrackingPreview(
    mode: .passiveDwell, cooldown: 3.0, dwellWindow: 1.0, dispersionThreshold: 100)

  _ = cluster(&preview, at: CGPoint(x: 10, y: 10), from: 0.0, count: 11)
  #expect(preview.localTriggerCount == 1)

  _ = cluster(&preview, at: CGPoint(x: 100, y: 100), from: 1.1, count: 3)
  _ = cluster(&preview, at: CGPoint(x: 20, y: 20), from: 1.6, count: 11)
  #expect(preview.localTriggerCount == 1)
  #expect(preview.state == .cooldown(until: 4.0))

  _ = cluster(&preview, at: CGPoint(x: 100, y: 100), from: 2.7, count: 3)
  _ = cluster(&preview, at: CGPoint(x: 30, y: 30), from: 3.0, count: 11)
  #expect(preview.localTriggerCount == 2)
  #expect(preview.lastLocalCapturePoint == CGPoint(x: 30, y: 30))
}

@Test func doubleBlinkFiresAtLastGazePoint() {
  var preview = TrackingPreview(mode: .doubleBlink)

  #expect(preview.handle(.sample(CGPoint(x: 6, y: 8), 0.0)) == [])
  #expect(preview.handle(.blink(.blink, 0.1)) == [])
  #expect(preview.handle(.blink(.doubleBlink, 0.3)) == [.capture(at: CGPoint(x: 6, y: 8))])
  #expect(preview.localTriggerCount == 1)
}

@Test func doubleBlinkWithoutGazeNeverCaptures() {
  var preview = TrackingPreview(mode: .doubleBlink)

  #expect(preview.handle(.blink(.doubleBlink, 0.0)) == [])
  #expect(preview.localTriggerCount == 0)
  #expect(preview.state == .idle)
}

@Test func trackingLossClearsFixationAndPreventsStaleTrigger() {
  var preview = TrackingPreview(
    mode: .passiveDwell, dwellWindow: 1.0, dispersionThreshold: 100)

  _ = cluster(&preview, at: CGPoint(x: 10, y: 10), from: 0.0, count: 10)
  #expect(preview.localTriggerCount == 0)

  #expect(preview.handle(.trackingLost(0.95)) == [])
  #expect(preview.isTracking == false)
  #expect(preview.currentFixation == nil)

  #expect(preview.handle(.sample(CGPoint(x: 10, y: 10), 1.0)) == [])
  #expect(preview.localTriggerCount == 0)
  #expect(preview.sampleCount == 11)
}

@Test func dwellProgressTracksTheRealDetectorSpan() {
  var preview = TrackingPreview(mode: .passiveDwell, dwellWindow: 1.0, dispersionThreshold: 100)
  #expect(preview.dwellProgress == 0)

  _ = preview.handle(.sample(CGPoint(x: 10, y: 10), 0.0))
  _ = preview.handle(.sample(CGPoint(x: 10, y: 10), 0.4))
  #expect(preview.dwellProgress == 0.4)

  _ = preview.handle(.sample(CGPoint(x: 10, y: 10), 1.0))
  #expect(preview.dwellProgress == 1)
}

@Test func completedFixationIsClearedOnceGazeMoves() {
  var preview = TrackingPreview(
    mode: .passiveDwell, dwellWindow: 1.0, dispersionThreshold: 100)
  _ = cluster(&preview, at: CGPoint(x: 10, y: 10), from: 0.0, count: 11)

  #expect(preview.currentFixation != nil)
  #expect(preview.dwellProgress == 1)

  _ = cluster(&preview, at: CGPoint(x: 500, y: 300), from: 1.1, count: 3)
  #expect(preview.currentFixation == nil)
  #expect(preview.dwellProgress == 0)
}

@Test func resetClearsAllPreviewState() {
  var preview = TrackingPreview(mode: .modifierHeld)
  _ = preview.handle(.modifierDown(0.0))
  _ = preview.handle(.sample(CGPoint(x: 5, y: 5), 0.1))
  _ = preview.handle(.modifierUp(0.2))
  #expect(preview.localTriggerCount == 1)

  #expect(preview.handle(.reset) == [])
  #expect(preview.state == .idle)
  #expect(preview.localTriggerCount == 0)
  #expect(preview.lastLocalCapturePoint == nil)
  #expect(preview.sampleCount == 0)
  #expect(preview.isTracking == false)
  #expect(preview.lastTimestamp == nil)
  #expect(preview.lastIssue == nil)
}

@Test func nonFiniteAndOutOfBoundsSamplesAreRejectedAndReported() {
  var preview = TrackingPreview(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))

  #expect(preview.handle(.sample(CGPoint(x: CGFloat.nan, y: 10), 0.0)) == [])
  #expect(preview.lastIssue == .nonFiniteSample(timestamp: 0.0))

  #expect(preview.handle(.sample(CGPoint(x: 200, y: 10), 0.1)) == [])
  #expect(
    preview.lastIssue == .outOfBoundsSample(CGPoint(x: 200, y: 10), timestamp: 0.1))
  #expect(preview.rejectedSampleCount == 2)
  #expect(preview.sampleCount == 0)

  #expect(preview.handle(.sample(CGPoint(x: 50, y: 50), 0.2)) == [])
  #expect(preview.lastIssue == nil)
  #expect(preview.sampleCount == 1)
}

@Test func nonMonotonicTimestampIsRejectedWithoutMovingState() {
  var preview = TrackingPreview()

  _ = preview.handle(.sample(CGPoint(x: 10, y: 10), 1.0))
  #expect(preview.handle(.sample(CGPoint(x: 10, y: 11), 0.5)) == [])

  #expect(preview.lastIssue == .nonMonotonicTimestamp(previous: 1.0, received: 0.5))
  #expect(preview.sampleCount == 1)
  #expect(preview.lastTimestamp == 1.0)
}

@Test func outOfBoundsSampleClearsTrackingAndPreventsStaleCapture() {
  var preview = TrackingPreview(
    mode: .modifierHeld, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))

  _ = preview.handle(.modifierDown(0.0))
  _ = preview.handle(.sample(CGPoint(x: 5, y: 5), 0.1))
  #expect(preview.state == .armed(region: CGPoint(x: 5, y: 5), since: 0.0))

  #expect(preview.handle(.sample(CGPoint(x: 500, y: 500), 0.2)) == [.hideReticle])
  #expect(preview.isTracking == false)
  #expect(preview.lastGazePoint == nil)
  #expect(preview.state == .idle)

  #expect(preview.handle(.modifierUp(0.3)) == [])
  #expect(preview.localTriggerCount == 0)
}

@Test func trackingLossClearsLastGazeSoDoubleBlinkCannotFireStale() {
  var preview = TrackingPreview(mode: .doubleBlink)

  _ = preview.handle(.sample(CGPoint(x: 6, y: 8), 0.0))
  _ = preview.handle(.trackingLost(0.1))
  #expect(preview.lastGazePoint == nil)

  #expect(preview.handle(.blink(.doubleBlink, 0.2)) == [])
  #expect(preview.localTriggerCount == 0)
  #expect(preview.lastIssue == .blinkWhileUntracked(timestamp: 0.2))
}

@Test func blinkWhileUntrackedIsReportedAndIgnored() {
  var preview = TrackingPreview(mode: .doubleBlink)

  #expect(preview.handle(.blink(.doubleBlink, 0.0)) == [])
  #expect(preview.localTriggerCount == 0)
  #expect(preview.lastIssue == .blinkWhileUntracked(timestamp: 0.0))
}
