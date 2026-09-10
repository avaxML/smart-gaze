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

@Test func irregularStationarySamplesYieldLiteralFirstFixation() {
  var detector = FixationDetector(window: 0.6, dispersionThreshold: 160)
  var timestamps: [TimeInterval] = []
  var time = 0.0

  for index in 0..<180 {
    time += index.isMultiple(of: 2) ? 0.031 : 0.037
    timestamps.append(time)
  }

  var fixations: [Fixation] = []
  for timestamp in timestamps {
    if let fixation = detector.add(CGPoint(x: 100, y: 100), at: timestamp) {
      fixations.append(fixation)
    }
  }

  #expect(fixations.count == 1)
  #expect(fixations.first?.startedAt == timestamps[0])
  #expect(fixations.first?.duration == timestamps[18] - timestamps[0])
  #expect(fixations.first?.sampleCount == 19)
  #expect(fixations.first?.centroid == CGPoint(x: 100, y: 100))
}

@Test func irregularNearBoundarySamplesYieldFixation() {
  var detector = FixationDetector(window: 0.5, dispersionThreshold: 100)
  let timestamps: [TimeInterval] = [0.0, 0.17, 0.41, 0.60]
  var fixations: [Fixation] = []

  for timestamp in timestamps {
    if let fixation = detector.add(CGPoint(x: 50, y: 50), at: timestamp) {
      fixations.append(fixation)
    }
  }

  #expect(fixations.count == 1)
  #expect(fixations.first?.startedAt == 0.0)
  #expect(fixations.first?.sampleCount == 4)
}

@Test func movingOutsideThresholdThenSettlingYieldsTwoFixations() {
  var detector = FixationDetector(window: 0.6, dispersionThreshold: 100)
  var fixations: [Fixation] = []
  var time = 0.0
  let step = 0.05

  for _ in 0..<20 {
    time += step
    if let fixation = detector.add(CGPoint(x: 100, y: 100), at: time) {
      fixations.append(fixation)
    }
  }

  for _ in 0..<4 {
    time += step
    if let fixation = detector.add(CGPoint(x: 900, y: 900), at: time) {
      fixations.append(fixation)
    }
  }

  for _ in 0..<20 {
    time += step
    if let fixation = detector.add(CGPoint(x: 100, y: 100), at: time) {
      fixations.append(fixation)
    }
  }

  #expect(fixations.count == 2)
  #expect(fixations.last?.centroid == CGPoint(x: 100, y: 100))
}

@Test func longGapDoesNotFabricateDwell() {
  var detector = FixationDetector(window: 1.0, dispersionThreshold: 100)
  var fixations: [Fixation] = []

  _ = detector.add(CGPoint(x: 100, y: 100), at: 0.0)

  var time = 5.0
  for index in 0..<40 {
    time += index.isMultiple(of: 2) ? 0.031 : 0.037
    if let fixation = detector.add(CGPoint(x: 100, y: 100), at: time) {
      fixations.append(fixation)
    }
  }

  #expect(fixations.count == 1)
  #expect((fixations.first?.startedAt ?? 0) >= 5.0)
}

@Test func resetRearmsForIrregularSamples() {
  var detector = FixationDetector(window: 0.6, dispersionThreshold: 160)
  var fixationCount = 0
  var time = 0.0

  func feed() {
    for index in 0..<40 {
      time += index.isMultiple(of: 2) ? 0.031 : 0.037
      if detector.add(CGPoint(x: 100, y: 100), at: time) != nil {
        fixationCount += 1
      }
    }
  }

  feed()
  #expect(fixationCount == 1)

  detector.reset()
  #expect(detector.sampleCount == 0)
  #expect(detector.currentDispersion == 0)

  feed()
  #expect(fixationCount == 2)
}

@Test func duplicateAndOutOfOrderSamplesAreIgnored() {
  var detector = FixationDetector(window: 1.0, dispersionThreshold: 100)

  _ = detector.add(CGPoint(x: 100, y: 100), at: 0.0)
  _ = detector.add(CGPoint(x: 100, y: 100), at: 0.5)
  _ = detector.add(CGPoint(x: 100, y: 100), at: 0.5)
  _ = detector.add(CGPoint(x: 100, y: 100), at: 0.4)

  #expect(detector.sampleCount == 2)
}

@Test func exactWindowBoundaryDoesNotRetainAnExtraSample() {
  var detector = FixationDetector(window: 1, dispersionThreshold: 100)
  for time in [0.0, 0.5, 1.0, 1.5] {
    _ = detector.add(CGPoint(x: 100, y: 100), at: time)
  }
  #expect(detector.sampleCount == 3)
}

@Test func aLongGapRearmsAnAlreadyLatchedFixation() {
  var detector = FixationDetector(window: 1, dispersionThreshold: 100)
  var fixations: [Fixation] = []
  for time in [0.0, 0.5, 1.0, 5.0, 5.5, 6.0] {
    if let fixation = detector.add(CGPoint(x: 100, y: 100), at: time) {
      fixations.append(fixation)
    }
  }
  #expect(fixations.count == 2)
  #expect(fixations.last?.startedAt == 5)
  #expect(fixations.last?.duration == 1)
}
