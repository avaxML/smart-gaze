import CoreGraphics
import Foundation
import GazeKit
import Testing

@Test func rejectsWrongPointCount() {
  let five = Array(repeating: CGPoint.zero, count: 5)
  let seven = Array(repeating: CGPoint.zero, count: 7)
  let six = Array(repeating: CGPoint.zero, count: 6)

  #expect(EyeLandmarks(points: five) == nil)
  #expect(EyeLandmarks(points: seven) == nil)
  #expect(EyeLandmarks(points: six) != nil)
}

@Test func wideOpenEyeHasHighEAR() {
  let eye = EyeLandmarks(points: [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 2, y: 3),
    CGPoint(x: 8, y: 3),
    CGPoint(x: 10, y: 0),
    CGPoint(x: 8, y: -3),
    CGPoint(x: 2, y: -3),
  ])!

  #expect(abs(eyeAspectRatio(eye) - 0.6) < 1e-9)
}

@Test func closedEyeHasLowEAR() {
  let eye = EyeLandmarks(points: [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 2, y: 0.2),
    CGPoint(x: 8, y: 0.2),
    CGPoint(x: 10, y: 0),
    CGPoint(x: 8, y: -0.2),
    CGPoint(x: 2, y: -0.2),
  ])!

  #expect(abs(eyeAspectRatio(eye) - 0.04) < 1e-9)
}

@Test func zeroWidthEyeReturnsZero() {
  let eye = EyeLandmarks(points: [
    CGPoint(x: 5, y: 5),
    CGPoint(x: 2, y: 3),
    CGPoint(x: 8, y: 3),
    CGPoint(x: 5, y: 5),
    CGPoint(x: 8, y: -3),
    CGPoint(x: 2, y: -3),
  ])!

  #expect(eyeAspectRatio(eye) == 0)
}

@Test func singleClosedFrameIsNoise() {
  var detector = BlinkDetector(minFrames: 2)

  #expect(detector.add(left: 0.5, right: 0.5, at: 0.0) == nil)
  #expect(detector.add(left: 0.1, right: 0.1, at: 0.1) == nil)
  #expect(detector.add(left: 0.5, right: 0.5, at: 0.2) == nil)
}

@Test func twoClosedFramesThenOpenCountsOneBlink() {
  var detector = BlinkDetector(minFrames: 2)
  var events: [BlinkEvent] = []

  _ = detector.add(left: 0.5, right: 0.5, at: 0.0)
  _ = detector.add(left: 0.1, right: 0.1, at: 0.1)
  _ = detector.add(left: 0.1, right: 0.1, at: 0.2)
  if let event = detector.add(left: 0.5, right: 0.5, at: 0.3) {
    events.append(event)
  }

  #expect(events == [.blink])
}

@Test func twoBlinksInsideWindowYieldBlinkThenDoubleBlink() {
  var detector = BlinkDetector(doubleBlinkWindow: 0.6)
  var events: [BlinkEvent] = []

  if let event = blink(&detector, at: 0.1) { events.append(event) }
  if let event = blink(&detector, at: 0.4) { events.append(event) }

  #expect(events == [.blink, .doubleBlink])
}

@Test func twoBlinksOutsideWindowYieldTwoBlinks() {
  var detector = BlinkDetector(doubleBlinkWindow: 0.6)
  var events: [BlinkEvent] = []

  if let event = blink(&detector, at: 0.1) { events.append(event) }
  if let event = blink(&detector, at: 4.8) { events.append(event) }

  #expect(events == [.blink, .blink])
}

@Test func blinkRateCountsTrailingMinute() {
  var detector = BlinkDetector()

  for index in 0..<10 {
    _ = blink(&detector, at: Double(index) * 5.0)
  }

  #expect(detector.blinkRate == 10)
}

@Test func resetClearsState() {
  var detector = BlinkDetector()

  for index in 0..<5 {
    _ = blink(&detector, at: Double(index))
  }

  detector.reset()

  #expect(detector.blinkRate == 0)
}

private func blink(_ detector: inout BlinkDetector, at timestamp: TimeInterval) -> BlinkEvent? {
  _ = detector.add(left: 0.1, right: 0.1, at: timestamp)
  _ = detector.add(left: 0.1, right: 0.1, at: timestamp + 0.1)
  return detector.add(left: 0.5, right: 0.5, at: timestamp + 0.2)
}
