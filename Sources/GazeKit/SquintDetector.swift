import Foundation

/// Recognises a deliberate squint from per-frame eye aspect ratios. Fires once
/// per squint; re-arms only after the eyes have been open again for
/// `releaseDuration`. The open baseline adapts slowly to the user so glasses,
/// lighting and eye shape do not need a threshold of their own.
public struct SquintDetector: Equatable, Sendable {
  public static let initialOpenBaseline = 0.30
  public static let baselineRange: ClosedRange<Double> = 0.22...0.45
  public static let baselineSmoothing = 0.02
  public static let squintRatio = 0.72
  public static let closedThreshold = 0.15
  public static let holdDuration: TimeInterval = 0.45
  public static let releaseDuration: TimeInterval = 0.25
  public static let gapTolerance: TimeInterval = 0.15

  public private(set) var openBaseline: Double
  private var runStart: TimeInterval?
  private var openRunStart: TimeInterval?
  private var isArmed = true

  public init() {
    openBaseline = SquintDetector.initialOpenBaseline
  }

  /// Returns true on the single frame a squint is recognised.
  public mutating func add(left: Double, right: Double, at timestamp: TimeInterval) -> Bool {
    guard left.isFinite, right.isFinite, timestamp.isFinite else { return false }
    let average = (left + right) / 2
    let narrowedBelow = SquintDetector.squintRatio * openBaseline

    if average < SquintDetector.closedThreshold {
      return false
    }

    guard average < narrowedBelow else {
      adaptBaseline(towards: average)
      if openRunStart == nil {
        openRunStart = timestamp
      }
      let openDuration = timestamp - (openRunStart ?? timestamp)
      if runStart != nil, openDuration >= SquintDetector.gapTolerance {
        runStart = nil
      }
      if !isArmed, openDuration >= SquintDetector.releaseDuration {
        isArmed = true
      }
      return false
    }

    openRunStart = nil
    if runStart == nil {
      runStart = timestamp
    }
    guard isArmed, let start = runStart, timestamp - start >= SquintDetector.holdDuration else {
      return false
    }
    isArmed = false
    return true
  }

  public mutating func reset() {
    openBaseline = SquintDetector.initialOpenBaseline
    runStart = nil
    openRunStart = nil
    isArmed = true
  }

  private mutating func adaptBaseline(towards average: Double) {
    let adapted = openBaseline + (average - openBaseline) * SquintDetector.baselineSmoothing
    openBaseline = min(
      max(adapted, SquintDetector.baselineRange.lowerBound),
      SquintDetector.baselineRange.upperBound)
  }
}
