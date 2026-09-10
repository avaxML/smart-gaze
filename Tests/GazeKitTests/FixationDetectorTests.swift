import CoreGraphics
import Foundation
import Testing

@testable import GazeKit

@Test func tightClusterHeldPastWindowYieldsOneFixation() {
  var detector = FixationDetector(window: 1.0, dispersionThreshold: 100)
  var fixationCount = 0

  for step in 0...20 {
    let timestamp = Double(step) * 0.1
    if detector.add(CGPoint(x: 500, y: 500), at: timestamp) != nil {
      fixationCount += 1
    }
  }

  #expect(fixationCount == 1)
}

@Test func spreadBeyondThresholdYieldsNone() {
  var detector = FixationDetector(window: 1.0, dispersionThreshold: 100)
  var fixationCount = 0

  for step in 0...20 {
    let timestamp = Double(step) * 0.1
    let point = step.isMultiple(of: 2) ? CGPoint(x: 0, y: 0) : CGPoint(x: 500, y: 500)
    if detector.add(point, at: timestamp) != nil {
      fixationCount += 1
    }
  }

  #expect(fixationCount == 0)
}

@Test func clusterShorterThanWindowYieldsNone() {
  var detector = FixationDetector(window: 1.0, dispersionThreshold: 100)
  var fixationCount = 0

  for step in 0...5 {
    let timestamp = Double(step) * 0.1
    if detector.add(CGPoint(x: 500, y: 500), at: timestamp) != nil {
      fixationCount += 1
    }
  }

  #expect(fixationCount == 0)
}

@Test func latchHoldsAfterFirstFixation() {
  var detector = FixationDetector(window: 1.0, dispersionThreshold: 100)
  var fixationCount = 0

  for step in 0...40 {
    let timestamp = Double(step) * 0.1
    if detector.add(CGPoint(x: 500, y: 500), at: timestamp) != nil {
      fixationCount += 1
    }
  }

  #expect(fixationCount == 1)
}

@Test func saccadeAwayAndBackYieldsSecondFixation() {
  var detector = FixationDetector(window: 1.0, dispersionThreshold: 100)
  var fixationCount = 0

  for step in 0...15 {
    let timestamp = Double(step) * 0.1
    if detector.add(CGPoint(x: 500, y: 500), at: timestamp) != nil {
      fixationCount += 1
    }
  }

  for step in 16...32 {
    let timestamp = Double(step) * 0.1
    if detector.add(CGPoint(x: 1000, y: 1000), at: timestamp) != nil {
      fixationCount += 1
    }
  }

  #expect(fixationCount == 2)
}

@Test func centroidIsMeanOfInWindowSamples() {
  var detector = FixationDetector(window: 1.0, dispersionThreshold: 100)
  let samples: [(point: CGPoint, timestamp: TimeInterval)] = [
    (CGPoint(x: 0, y: 0), 0.0),
    (CGPoint(x: 10, y: 0), 0.25),
    (CGPoint(x: 20, y: 0), 0.5),
    (CGPoint(x: 0, y: 10), 0.75),
    (CGPoint(x: 0, y: 20), 1.0),
  ]
  var reported: Fixation?

  for sample in samples {
    if let fixation = detector.add(sample.point, at: sample.timestamp) {
      reported = fixation
    }
  }

  #expect(reported?.centroid == CGPoint(x: 6, y: 6))
}

@Test func resetClearsBufferAndRearms() {
  var detector = FixationDetector(window: 1.0, dispersionThreshold: 100)
  var fixationCount = 0

  for step in 0...20 {
    let timestamp = Double(step) * 0.1
    if detector.add(CGPoint(x: 500, y: 500), at: timestamp) != nil {
      fixationCount += 1
    }
  }
  #expect(fixationCount == 1)

  detector.reset()
  #expect(detector.sampleCount == 0)
  #expect(detector.currentDispersion == 0)

  for step in 0...20 {
    let timestamp = Double(step) * 0.1
    if detector.add(CGPoint(x: 500, y: 500), at: timestamp) != nil {
      fixationCount += 1
    }
  }

  #expect(fixationCount == 2)
}

@Test func currentDispersionIsComputedCorrectly() {
  var detector = FixationDetector(window: 1.0, dispersionThreshold: 100)

  _ = detector.add(CGPoint(x: 0, y: 0), at: 0.0)
  _ = detector.add(CGPoint(x: 30, y: 40), at: 0.5)

  #expect(detector.currentDispersion == 70.0)
}

@Test func oldSamplesAreEvicted() {
  var detector = FixationDetector(window: 1.0, dispersionThreshold: 100)

  _ = detector.add(CGPoint(x: 0, y: 0), at: 0.0)
  _ = detector.add(CGPoint(x: 0, y: 0), at: 5.0)

  #expect(detector.sampleCount == 1)
}
