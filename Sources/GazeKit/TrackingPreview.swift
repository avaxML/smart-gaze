import CoreGraphics
import Foundation

/// One bounded input into the preview reducer. Timestamps are monotonic
/// seconds and samples share the coordinate space of `TrackingPreview.bounds`.
public enum TrackingPreviewInput: Equatable, Sendable {
  case sample(CGPoint, TimeInterval)
  case trackingLost(TimeInterval)
  case modifierDown(TimeInterval)
  case modifierUp(TimeInterval)
  case blink(BlinkEvent, TimeInterval)
  case presentationEnded(TimeInterval)
  case reset
}

/// Why an input did not reach the production pipeline. Rejected input is never
/// silently dropped: it is recorded and clears any stale tracking state.
public enum TrackingPreviewIssue: Equatable, Sendable {
  case nonFiniteSample(timestamp: TimeInterval)
  case outOfBoundsSample(CGPoint, timestamp: TimeInterval)
  case nonMonotonicTimestamp(previous: TimeInterval, received: TimeInterval)
  case blinkWhileUntracked(timestamp: TimeInterval)
}

/// A pure reducer over the real `FixationDetector` and `TriggerMachine`.
///
/// It owns no camera, network or timers. A rejected or lost sample always
/// clears the detector and the machine's arming so no stale gaze can fire.
public struct TrackingPreview: Sendable {
  public let mode: ActivationMode
  public let bounds: CGRect
  public let cooldown: TimeInterval
  public let dispersionThreshold: Double

  public private(set) var state: TriggerState = .idle
  public private(set) var isTracking = false
  public private(set) var sampleCount = 0
  public private(set) var rejectedSampleCount = 0
  public private(set) var dispersion: Double = 0
  public private(set) var lastGazePoint: CGPoint?
  public private(set) var currentFixation: Fixation?
  public private(set) var lastLocalCapturePoint: CGPoint?
  public private(set) var localTriggerCount = 0
  public private(set) var lastIssue: TrackingPreviewIssue?
  public private(set) var lastTimestamp: TimeInterval?
  public var isPresenting: Bool { machine.isPresenting }

  /// Live progress toward the current dwell window, from the real detector
  /// buffer span and dispersion. `0` when no cluster is forming.
  public var dwellProgress: Double { detector.progress }

  private var detector: FixationDetector
  private var machine: TriggerMachine
  public let dwellWindow: TimeInterval

  public init(
    mode: ActivationMode = .modifierHeld,
    cooldown: TimeInterval = 3.0,
    bounds: CGRect = CGRect(x: 0, y: 0, width: 640, height: 400),
    dwellWindow: TimeInterval = 1.2,
    dispersionThreshold: Double = 160
  ) {
    self.mode = mode
    self.bounds = bounds
    self.cooldown = cooldown
    self.dwellWindow = dwellWindow
    self.dispersionThreshold = dispersionThreshold
    self.machine = TriggerMachine(mode: mode, cooldown: cooldown)
    self.detector = FixationDetector(
      window: dwellWindow, dispersionThreshold: dispersionThreshold)
  }

  @discardableResult
  public mutating func handle(_ input: TrackingPreviewInput) -> [TriggerEffect] {
    switch input {
    case .sample(let point, let time):
      return handleSample(point, at: time)
    case .trackingLost(let time):
      return clearTracking(at: time)
    case .modifierDown(let time):
      guard advance(to: time) else { return [] }
      return apply(machine.handle(.modifierDown(time)))
    case .modifierUp(let time):
      guard advance(to: time) else { return [] }
      return apply(machine.handle(.modifierUp(time)))
    case .blink(let event, let time):
      return handleBlink(event, at: time)
    case .presentationEnded(let time):
      guard advance(to: time) else { return [] }
      return apply(machine.handle(.presentationEnded(time)))
    case .reset:
      reset()
      return []
    }
  }

  public mutating func reset() {
    detector = FixationDetector(
      window: dwellWindow, dispersionThreshold: dispersionThreshold)
    machine = TriggerMachine(mode: mode, cooldown: cooldown)
    state = .idle
    isTracking = false
    sampleCount = 0
    rejectedSampleCount = 0
    dispersion = 0
    lastGazePoint = nil
    currentFixation = nil
    lastLocalCapturePoint = nil
    localTriggerCount = 0
    lastIssue = nil
    lastTimestamp = nil
  }

  private mutating func handleSample(_ point: CGPoint, at time: TimeInterval) -> [TriggerEffect] {
    guard advance(to: time) else { return [] }
    guard point.x.isFinite, point.y.isFinite else {
      lastIssue = .nonFiniteSample(timestamp: time)
      rejectedSampleCount += 1
      return clearTracking(at: time)
    }
    guard bounds.contains(point) else {
      lastIssue = .outOfBoundsSample(point, timestamp: time)
      rejectedSampleCount += 1
      return clearTracking(at: time)
    }

    lastIssue = nil
    isTracking = true
    sampleCount += 1
    lastGazePoint = point

    var effects = machine.handle(.gaze(point, time))
    if let fixation = detector.add(point, at: time) {
      currentFixation = fixation
      effects += machine.handle(.fixation(fixation))
    }
    dispersion = detector.currentDispersion
    // A fixation is only "current" while the gaze stays inside the threshold.
    // Once movement breaks it, do not keep presenting the old fixation.
    if dispersion >= dispersionThreshold {
      currentFixation = nil
    }
    return apply(effects)
  }

  private mutating func handleBlink(_ event: BlinkEvent, at time: TimeInterval) -> [TriggerEffect] {
    guard advance(to: time) else { return [] }
    // The production `TriggerMachine` keeps the last gaze point across
    // `faceLost`, so a blink after loss would otherwise capture a stale point.
    guard isTracking, lastGazePoint != nil else {
      lastIssue = .blinkWhileUntracked(timestamp: time)
      return []
    }
    return apply(machine.handle(.blink(event, time)))
  }

  /// Drops the live gaze, the fixation buffer and any arming. Used for tracking
  /// loss and for rejected samples so a stale cluster can never fire.
  @discardableResult
  private mutating func clearTracking(at time: TimeInterval) -> [TriggerEffect] {
    isTracking = false
    lastGazePoint = nil
    currentFixation = nil
    dispersion = 0
    detector.reset()
    return apply(machine.handle(.faceLost(time)))
  }

  private mutating func advance(to time: TimeInterval) -> Bool {
    guard time.isFinite else {
      lastIssue = .nonFiniteSample(timestamp: time)
      clearTracking(at: time)
      return false
    }
    if let last = lastTimestamp, time < last {
      lastIssue = .nonMonotonicTimestamp(previous: last, received: time)
      clearTracking(at: time)
      return false
    }
    lastTimestamp = time
    return true
  }

  private mutating func apply(_ effects: [TriggerEffect]) -> [TriggerEffect] {
    for effect in effects {
      if case .capture(let point) = effect {
        lastLocalCapturePoint = point
        localTriggerCount += 1
      }
    }
    state = machine.state
    return effects
  }
}
