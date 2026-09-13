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
  case squint(SquintEvent, TimeInterval)
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
  case squintWhileUntracked(timestamp: TimeInterval)
}

/// A pure reducer over the real `FixationDetector` and `TriggerMachine`.
///
/// It owns no camera, network or timers. A lost face or a non-finite sample
/// clears the detector and the machine's arming so no stale gaze can fire;
/// an out-of-bounds sample clears only the detector and clamps to the edge.
public struct TrackingPreview: Sendable {
  /// How far behind `lastTimestamp` an input may arrive and still be treated
  /// as frame-level reordering rather than corruption. The gaze sample for a
  /// frame is applied after the observation for the next frame, so its
  /// delivery timestamp is a few milliseconds older than the last input.
  public static let reorderTolerance: TimeInterval = 0.25

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
  public var blinkRate: Double { machine.blinkRate }

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
    dispersionThreshold: Double = 240
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
      switch advance(to: time) {
      case .rejected(let effects): return effects
      case .proceed(let effective): return apply(machine.handle(.modifierDown(effective)))
      }
    case .modifierUp(let time):
      switch advance(to: time) {
      case .rejected(let effects): return effects
      case .proceed(let effective): return apply(machine.handle(.modifierUp(effective)))
      }
    case .blink(let event, let time):
      return handleBlink(event, at: time)
    case .squint(let event, let time):
      return handleSquint(event, at: time)
    case .presentationEnded(let time):
      switch advance(to: time) {
      case .rejected(let effects): return effects
      case .proceed(let effective): return apply(machine.handle(.presentationEnded(effective)))
      }
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
    let effective: TimeInterval
    switch advance(to: time) {
    case .rejected(let effects): return effects
    case .proceed(let at): effective = at
    }
    guard point.x.isFinite, point.y.isFinite else {
      lastIssue = .nonFiniteSample(timestamp: effective)
      rejectedSampleCount += 1
      return clearTracking(at: effective)
    }
    guard bounds.contains(point) else {
      // The map extrapolates past the display edges, and live traces put one
      // sample in seven below the bottom edge while the user read the lower
      // half. Treating that as a lost face dropped the modifier's arming
      // mid-hold, so releases fired almost never. The gaze is real and near
      // an edge: keep the arming alive on the clamped point, and only drop
      // the fixation cluster so nothing dwells off screen.
      lastIssue = .outOfBoundsSample(point, timestamp: effective)
      rejectedSampleCount += 1
      detector.reset()
      currentFixation = nil
      dispersion = 0
      let clamped = CGPoint(
        x: min(max(point.x, bounds.minX), bounds.maxX),
        y: min(max(point.y, bounds.minY), bounds.maxY))
      isTracking = true
      lastGazePoint = clamped
      return apply(machine.handle(.gaze(clamped, effective)))
    }

    lastIssue = nil
    isTracking = true
    sampleCount += 1
    lastGazePoint = point

    var effects = machine.handle(.gaze(point, effective))
    if let fixation = detector.add(point, at: effective) {
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
    let effective: TimeInterval
    switch advance(to: time) {
    case .rejected(let effects): return effects
    case .proceed(let at): effective = at
    }
    // The production `TriggerMachine` keeps the last gaze point across
    // `faceLost`, so a blink after loss would otherwise capture a stale point.
    guard isTracking, lastGazePoint != nil else {
      lastIssue = .blinkWhileUntracked(timestamp: effective)
      return []
    }
    return apply(machine.handle(.blink(event, effective)))
  }

  private mutating func handleSquint(_ event: SquintEvent, at time: TimeInterval) -> [TriggerEffect]
  {
    let effective: TimeInterval
    switch advance(to: time) {
    case .rejected(let effects): return effects
    case .proceed(let at): effective = at
    }
    // As with a blink, the machine keeps the last gaze point across
    // `faceLost`, so a squint after a loss would capture a stale point.
    guard isTracking, lastGazePoint != nil else {
      lastIssue = .squintWhileUntracked(timestamp: effective)
      return []
    }
    return apply(machine.handle(.squint(event, effective)))
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

  /// When an input belongs on the reducer's timeline, or the effects of
  /// rejecting it. A reordered input proceeds at the last timestamp so the
  /// machine and the detector never observe time moving backwards.
  private enum Advance {
    case proceed(TimeInterval)
    case rejected([TriggerEffect])
  }

  private mutating func advance(to time: TimeInterval) -> Advance {
    guard time.isFinite else {
      lastIssue = .nonFiniteSample(timestamp: time)
      return .rejected(clearTracking(at: time))
    }
    if let last = lastTimestamp, time < last {
      guard last - time <= TrackingPreview.reorderTolerance else {
        lastIssue = .nonMonotonicTimestamp(previous: last, received: time)
        return .rejected(clearTracking(at: time))
      }
      return .proceed(last)
    }
    lastTimestamp = time
    return .proceed(time)
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
