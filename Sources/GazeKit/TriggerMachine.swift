import CoreGraphics
import Foundation

public enum ActivationMode: String, Codable, CaseIterable, Sendable {
  case modifierHeld, passiveDwell, doubleBlink
}

public enum TriggerState: Equatable, Sendable {
  case idle
  case settling(since: TimeInterval)
  case armed(region: CGPoint, since: TimeInterval)
  case firing(region: CGPoint)
  case cooldown(until: TimeInterval)
}

public enum TriggerInput: Equatable, Sendable {
  case gaze(CGPoint, TimeInterval)
  case fixation(Fixation)
  case modifierDown(TimeInterval)
  case modifierUp(TimeInterval)
  case blink(BlinkEvent, TimeInterval)
  case faceLost(TimeInterval)
  case dismissed(TimeInterval)
}

public enum TriggerEffect: Equatable, Sendable {
  case capture(at: CGPoint)
  case showReticle(at: CGPoint)
  case hideReticle
  case dismissBubble
}

public struct TriggerMachine: Sendable {
  private let mode: ActivationMode
  private let cooldownDuration: TimeInterval
  private let blinkRateCeiling: Double

  public private(set) var state: TriggerState = .idle

  private var lastGazePoint: CGPoint?
  private var blinkTimestamps: [TimeInterval] = []
  // Set when a capture fires; promoted into `.cooldown(until:)` on the next
  // call so a caller can observe the momentary `.firing` state in between.
  private var pendingCooldownUntil: TimeInterval?

  public init(mode: ActivationMode, cooldown: TimeInterval = 3.0, blinkRateCeiling: Double = 40) {
    self.mode = mode
    self.cooldownDuration = cooldown
    self.blinkRateCeiling = blinkRateCeiling
  }

  public mutating func handle(_ input: TriggerInput) -> [TriggerEffect] {
    let now = timestamp(of: input)
    promotePendingTransitions(at: now)

    switch input {
    case .gaze(let point, let time):
      return handleGaze(point, at: time)
    case .fixation(let fixation):
      return handleFixation(fixation)
    case .modifierDown(let time):
      return handleModifierDown(at: time)
    case .modifierUp(let time):
      return handleModifierUp(at: time)
    case .blink(let event, let time):
      return handleBlink(event, at: time)
    case .faceLost:
      lastGazePoint = nil
      return leaveToIdle(emitting: .hideReticle)
    case .dismissed:
      return leaveToIdle(emitting: .dismissBubble)
    }
  }

  private mutating func promotePendingTransitions(at now: TimeInterval) {
    if case .firing = state, let until = pendingCooldownUntil {
      state = .cooldown(until: until)
    }
    if case .cooldown(let until) = state, now >= until {
      state = .idle
      pendingCooldownUntil = nil
    }
  }

  private mutating func leaveToIdle(emitting effect: TriggerEffect) -> [TriggerEffect] {
    guard state != .idle else { return [] }
    state = .idle
    pendingCooldownUntil = nil
    return [effect]
  }

  private mutating func handleGaze(_ point: CGPoint, at time: TimeInterval) -> [TriggerEffect] {
    lastGazePoint = point

    guard mode == .modifierHeld else { return [] }

    switch state {
    case .settling(let since):
      state = .armed(region: point, since: since)
      return [.showReticle(at: point)]
    case .armed(_, let since):
      state = .armed(region: point, since: since)
      return [.showReticle(at: point)]
    default:
      // No modifier held: gaze alone never arms or fires.
      return []
    }
  }

  private mutating func handleFixation(_ fixation: Fixation) -> [TriggerEffect] {
    guard mode == .passiveDwell, state == .idle else { return [] }

    let now = fixation.startedAt + fixation.duration
    return attemptFire(at: fixation.centroid, now: now)
  }

  private mutating func handleModifierDown(at time: TimeInterval) -> [TriggerEffect] {
    guard mode == .modifierHeld, state == .idle else { return [] }
    state = .settling(since: time)
    return []
  }

  private mutating func handleModifierUp(at time: TimeInterval) -> [TriggerEffect] {
    guard mode == .modifierHeld else { return [] }

    switch state {
    case .settling:
      // Modifier released before any gaze arrived: nothing to capture.
      state = .idle
      return []
    case .armed(let region, _):
      let effects = attemptFire(at: region, now: time)
      return effects.isEmpty ? leaveToIdle(emitting: .hideReticle) : effects + [.hideReticle]
    default:
      return []
    }
  }

  private mutating func handleBlink(_ event: BlinkEvent, at time: TimeInterval) -> [TriggerEffect] {
    blinkTimestamps.append(time)
    blinkTimestamps.removeAll { time - $0 > 60 }

    guard mode == .doubleBlink, event == .doubleBlink, state == .idle,
      let region = lastGazePoint
    else {
      return []
    }

    return attemptFire(at: region, now: time)
  }

  private mutating func attemptFire(at region: CGPoint, now: TimeInterval) -> [TriggerEffect] {
    guard blinkRate(at: now) <= blinkRateCeiling else { return [] }

    state = .firing(region: region)
    pendingCooldownUntil = now + cooldownDuration
    return [.capture(at: region)]
  }

  private func blinkRate(at now: TimeInterval) -> Double {
    Double(blinkTimestamps.filter { now - $0 <= 60 }.count)
  }

  private func timestamp(of input: TriggerInput) -> TimeInterval {
    switch input {
    case .gaze(_, let time): time
    case .fixation(let fixation): fixation.startedAt + fixation.duration
    case .modifierDown(let time): time
    case .modifierUp(let time): time
    case .blink(_, let time): time
    case .faceLost(let time): time
    case .dismissed(let time): time
    }
  }
}
