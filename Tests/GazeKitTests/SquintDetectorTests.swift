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
    if detector.add(left: 0.30, right: 0.30, at: frame(index)) != nil { fires += 1 }
  }

  #expect(fires == 0)
  #expect(detector.openBaseline == 0.30)
  #expect(!detector.isSquinting)
}

@Test func narrowedRunStartsOnceAtTheHold() {
  var detector = SquintDetector()
  for index in 0..<30 {
    #expect(detector.add(left: 0.30, right: 0.30, at: frame(index)) == nil)
  }

  var starts: [Int] = []
  for index in 30..<90 {
    if detector.add(left: 0.19, right: 0.19, at: frame(index)) == .started {
      starts.append(index)
    }
  }

  #expect(starts == [44])
  #expect(detector.isSquinting)
}

@Test func openFramesForTheReleaseDurationReArmASecondSquint() {
  var detector = SquintDetector()
  for index in 0..<30 {
    _ = detector.add(left: 0.30, right: 0.30, at: frame(index))
  }

  var firstRun: [Int] = []
  for index in 30..<60 {
    if detector.add(left: 0.19, right: 0.19, at: frame(index)) == .started {
      firstRun.append(index)
    }
  }
  #expect(firstRun == [44])
  #expect(detector.isSquinting)

  // 0.25 s of open frames at 30 Hz: the frame at index 68 is 0.2667 s after
  // the opening began, the first to reach the release window.
  var ended: [Int] = []
  for index in 60...68 {
    if detector.add(left: 0.30, right: 0.30, at: frame(index)) == .ended {
      ended.append(index)
    }
  }
  #expect(ended == [68])
  #expect(!detector.isSquinting)

  var secondRun: [Int] = []
  for index in 69..<120 {
    if detector.add(left: 0.19, right: 0.19, at: frame(index)) == .started {
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
    if detector.add(left: value, right: value, at: frame(index)) == .started {
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
    if detector.add(left: value, right: value, at: frame(index)) == .started {
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
    if detector.add(left: value, right: value, at: frame(index)) == .started {
      starts.append(index)
    }
  }

  #expect(starts == [23])
}

@Test func baselineAdaptsTowardsSustainedOpenFrames() {
  var detector = SquintDetector()

  for index in 0..<300 {
    #expect(detector.add(left: 0.40, right: 0.40, at: frame(index)) == nil)
    #expect(detector.openBaseline <= 0.45)
  }

  #expect(abs(detector.openBaseline - 0.40) < 0.01)
}

@Test func nonFiniteInputReturnsNothingAndChangesNothing() {
  var detector = SquintDetector()

  #expect(detector.add(left: .nan, right: 0.30, at: 0.0) == nil)
  #expect(detector.add(left: 0.30, right: .nan, at: 0.1) == nil)
  #expect(detector.openBaseline == 0.30)
}

@Test func resetRestoresTheInitialBaseline() {
  var detector = SquintDetector()
  for index in 0..<30 {
    _ = detector.add(left: 0.40, right: 0.40, at: frame(index))
  }
  #expect(detector.openBaseline > SquintDetector.initialOpenBaseline)

  detector.reset()

  #expect(detector.openBaseline == SquintDetector.initialOpenBaseline)
}

@Test func resetDropsAnActiveSquint() {
  var detector = SquintDetector()
  for index in 0..<30 {
    _ = detector.add(left: 0.19, right: 0.19, at: frame(index))
  }
  #expect(detector.isSquinting)

  detector.reset()

  #expect(!detector.isSquinting)
}
