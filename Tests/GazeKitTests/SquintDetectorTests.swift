import CoreGraphics
import Foundation
import GazeKit
import Testing

private let frameInterval = 1.0 / 30.0

private func frame(_ index: Int) -> TimeInterval {
  Double(index) * frameInterval
}

@Test func openFramesNeverFireAndKeepTheBaseline() {
  var detector = SquintDetector()
  var fires = 0

  for index in 0..<30 {
    if detector.add(left: 0.30, right: 0.30, pitchRadians: 0, irisDrop: nil, at: frame(index))
      != nil
    {
      fires += 1
    }
  }

  #expect(fires == 0)
  #expect(detector.openBaseline == 0.30)
  #expect(!detector.isSquinting)
}

@Test func narrowedRunStartsOnceAtTheHold() {
  var detector = SquintDetector()
  for index in 0..<30 {
    #expect(
      detector.add(left: 0.30, right: 0.30, pitchRadians: 0, irisDrop: nil, at: frame(index)) == nil
    )
  }

  var starts: [Int] = []
  for index in 30..<90 {
    if detector.add(left: 0.19, right: 0.19, pitchRadians: 0, irisDrop: nil, at: frame(index))
      == .started
    {
      starts.append(index)
    }
  }

  #expect(starts == [44])
  #expect(detector.isSquinting)
}

@Test func openFramesForTheReleaseDurationReArmASecondSquint() {
  var detector = SquintDetector()
  for index in 0..<30 {
    _ = detector.add(left: 0.30, right: 0.30, pitchRadians: 0, irisDrop: nil, at: frame(index))
  }

  var firstRun: [Int] = []
  for index in 30..<60 {
    if detector.add(left: 0.19, right: 0.19, pitchRadians: 0, irisDrop: nil, at: frame(index))
      == .started
    {
      firstRun.append(index)
    }
  }
  #expect(firstRun == [44])
  #expect(detector.isSquinting)

  // 0.25 s of open frames at 30 Hz: the frame at index 68 is 0.2667 s after
  // the opening began, the first to reach the release window.
  var ended: [Int] = []
  for index in 60...68 {
    if detector.add(left: 0.30, right: 0.30, pitchRadians: 0, irisDrop: nil, at: frame(index))
      == .ended
    {
      ended.append(index)
    }
  }
  #expect(ended == [68])
  #expect(!detector.isSquinting)

  var secondRun: [Int] = []
  for index in 69..<120 {
    if detector.add(left: 0.19, right: 0.19, pitchRadians: 0, irisDrop: nil, at: frame(index))
      == .started
    {
      secondRun.append(index)
    }
  }
  #expect(secondRun == [83])
}

@Test func closedFrameInsideANarrowedRunDoesNotBreakIt() {
  var detector = SquintDetector()
  var starts: [Int] = []

  for index in 0..<20 {
    let value = index == 10 ? 0.10 : 0.19
    if detector.add(left: value, right: value, pitchRadians: 0, irisDrop: nil, at: frame(index))
      == .started
    {
      starts.append(index)
    }
  }

  #expect(starts == [14])
}

@Test func shortOpeningInsideANarrowedRunDoesNotBreakIt() {
  var detector = SquintDetector()
  var starts: [Int] = []

  for index in 0..<20 {
    let value = (3...5).contains(index) ? 0.30 : 0.19
    if detector.add(left: value, right: value, pitchRadians: 0, irisDrop: nil, at: frame(index))
      == .started
    {
      starts.append(index)
    }
  }

  #expect(starts == [14])
}

@Test func longOpeningInsideANarrowedRunBreaksIt() {
  var detector = SquintDetector()
  var starts: [Int] = []

  for index in 0..<30 {
    let value = (3...8).contains(index) ? 0.30 : 0.19
    if detector.add(left: value, right: value, pitchRadians: 0, irisDrop: nil, at: frame(index))
      == .started
    {
      starts.append(index)
    }
  }

  #expect(starts == [23])
}

@Test func baselineAdaptsTowardsSustainedOpenFrames() {
  var detector = SquintDetector()

  for index in 0..<300 {
    #expect(
      detector.add(left: 0.40, right: 0.40, pitchRadians: 0, irisDrop: nil, at: frame(index)) == nil
    )
    #expect(detector.openBaseline <= 0.45)
  }

  #expect(abs(detector.openBaseline - 0.40) < 0.01)
}

@Test func nonFiniteInputReturnsNothingAndChangesNothing() {
  var detector = SquintDetector()

  #expect(
    detector.add(left: .nan, right: 0.30, pitchRadians: 0, irisDrop: nil, at: 0.0) == nil)
  #expect(
    detector.add(left: 0.30, right: .nan, pitchRadians: 0, irisDrop: nil, at: 0.1) == nil)
  #expect(detector.openBaseline == 0.30)
}

@Test func resetRestoresTheInitialBaseline() {
  var detector = SquintDetector()
  for index in 0..<30 {
    _ = detector.add(left: 0.40, right: 0.40, pitchRadians: 0, irisDrop: nil, at: frame(index))
  }
  #expect(detector.openBaseline > SquintDetector.initialOpenBaseline)

  detector.reset()

  #expect(detector.openBaseline == SquintDetector.initialOpenBaseline)
}

@Test func resetDropsAnActiveSquint() {
  var detector = SquintDetector()
  for index in 0..<30 {
    _ = detector.add(left: 0.19, right: 0.19, pitchRadians: 0, irisDrop: nil, at: frame(index))
  }
  #expect(detector.isSquinting)

  detector.reset()

  #expect(!detector.isSquinting)
}

@Test func narrowedFramesBelowThePitchBandNeverStartASquint() {
  var detector = SquintDetector()
  var starts: [Int] = []

  for index in 0..<90 {
    if detector.add(left: 0.19, right: 0.19, pitchRadians: -0.25, irisDrop: nil, at: frame(index))
      == .started
    {
      starts.append(index)
    }
  }

  #expect(starts.isEmpty)
  #expect(!detector.isSquinting)
}

@Test func narrowedFramesInsideThePitchBandStartASquint() {
  var detector = SquintDetector()
  var starts: [Int] = []

  for index in 0..<90 {
    if detector.add(left: 0.19, right: 0.19, pitchRadians: -0.05, irisDrop: nil, at: frame(index))
      == .started
    {
      starts.append(index)
    }
  }

  #expect(starts == [14])
}

@Test func aPitchedHeadEndsAStartedSquintImmediately() {
  var detector = SquintDetector()
  for index in 0..<30 {
    _ = detector.add(left: 0.30, right: 0.30, pitchRadians: 0, irisDrop: nil, at: frame(index))
  }
  var starts: [Int] = []
  for index in 30..<60 {
    if detector.add(left: 0.19, right: 0.19, pitchRadians: 0, irisDrop: nil, at: frame(index))
      == .started
    {
      starts.append(index)
    }
  }
  #expect(starts == [44])
  #expect(detector.isSquinting)

  var ended: [Int] = []
  for index in 60..<70 {
    if detector.add(left: 0.19, right: 0.19, pitchRadians: -0.3, irisDrop: nil, at: frame(index))
      == .ended
    {
      ended.append(index)
    }
  }

  #expect(ended == [60])
  #expect(!detector.isSquinting)
}

@Test func sustainedOpenFramesAdaptThePitchBaseline() {
  var detector = SquintDetector()
  for index in 0..<300 {
    _ = detector.add(left: 0.30, right: 0.30, pitchRadians: -0.2, irisDrop: nil, at: frame(index))
  }

  #expect(abs(detector.pitchBaseline - -0.2) < 0.01)

  var starts: [Int] = []
  for index in 300..<360 {
    if detector.add(left: 0.19, right: 0.19, pitchRadians: -0.2, irisDrop: nil, at: frame(index))
      == .started
    {
      starts.append(index)
    }
  }

  #expect(starts == [314])
}

@Test func resetRestoresTheInitialPitchBaseline() {
  var detector = SquintDetector()
  for index in 0..<30 {
    _ = detector.add(left: 0.30, right: 0.30, pitchRadians: -0.4, irisDrop: nil, at: frame(index))
  }
  #expect(detector.pitchBaseline < 0)

  detector.reset()

  #expect(detector.pitchBaseline == 0)
}

@Test func irisDropBeyondToleranceNeverStartsASquint() {
  var detector = SquintDetector()
  var starts: [Int] = []

  for index in 0..<90 {
    if detector.add(left: 0.19, right: 0.19, pitchRadians: 0, irisDrop: 0.3, at: frame(index))
      == .started
    {
      starts.append(index)
    }
  }

  #expect(starts.isEmpty)
  #expect(!detector.isSquinting)
}

@Test func irisDropWithinToleranceStartsASquint() {
  var detector = SquintDetector()
  var starts: [Int] = []

  for index in 0..<90 {
    if detector.add(left: 0.19, right: 0.19, pitchRadians: 0, irisDrop: 0.1, at: frame(index))
      == .started
    {
      starts.append(index)
    }
  }

  #expect(starts == [14])
}

@Test func missingIrisDataLeavesOnlyThePitchGate() {
  var detector = SquintDetector()
  var starts: [Int] = []

  for index in 0..<90 {
    if detector.add(left: 0.19, right: 0.19, pitchRadians: 0, irisDrop: nil, at: frame(index))
      == .started
    {
      starts.append(index)
    }
  }

  #expect(starts == [14])
}

@Test func aGatedFrameInsideANarrowedRunDoesNotBreakIt() {
  var detector = SquintDetector()
  var starts: [Int] = []

  for index in 0..<20 {
    let drop = index == 10 ? 0.3 : 0.1
    if detector.add(left: 0.19, right: 0.19, pitchRadians: 0, irisDrop: drop, at: frame(index))
      == .started
    {
      starts.append(index)
    }
  }

  #expect(starts == [14])
}

@Test func nonFinitePitchAndIrisDropDoNotGate() {
  var detector = SquintDetector()
  var starts: [Int] = []

  for index in 0..<90 {
    if detector.add(
      left: 0.19, right: 0.19, pitchRadians: .nan, irisDrop: .infinity, at: frame(index))
      == .started
    {
      starts.append(index)
    }
  }

  #expect(starts == [14])
}

@Test func aGatedNarrowedFrameReportsSuppression() {
  var detector = SquintDetector()

  #expect(detector.add(left: 0.19, right: 0.19, pitchRadians: -0.3, irisDrop: nil, at: 0) == nil)
  #expect(detector.suppressedNarrowedFrame)

  #expect(detector.add(left: 0.30, right: 0.30, pitchRadians: 0, irisDrop: nil, at: 0.1) == nil)
  #expect(!detector.suppressedNarrowedFrame)
}

@Test func irisDropMeasuresHowLowTheIrisSits() {
  let contour = (0..<71).map { index in
    CGPoint(x: Double(index), y: index < 35 ? 100 : (index == 35 ? 120 : 140))
  }

  #expect(SquintDetector.irisDrop(irisCenter: CGPoint(x: 0, y: 132), contour: contour) == 0.3)
  #expect(SquintDetector.irisDrop(irisCenter: CGPoint(x: 0, y: 120), contour: contour) == 0)
  #expect(SquintDetector.irisDrop(irisCenter: CGPoint(x: 0, y: 100), contour: []) == nil)
}
