import Foundation

/// Reports the two edges of a deliberate squint from per-frame eye aspect
/// ratios. `.started` fires once when a narrowed run reaches `holdDuration`;
/// `.ended` fires once when, after that, the eyes have stayed open for
/// `releaseDuration`, which is also when the detector re-arms. The open
/// baseline adapts slowly to the user so glasses, lighting and eye shape do
/// not need a threshold of their own.
public enum SquintEvent: Equatable, Sendable {
  case started
  case ended
}

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
  /// True from the frame a squint starts until the frame it ends.
  public private(set) var isSquinting = false
  private var runStart: TimeInterval?
  private var openRunStart: TimeInterval?

  public init() {
    openBaseline = SquintDetector.initialOpenBaseline
  }

  /// Returns `.started` on the single frame a squint is recognised and `.ended`
  /// on the single frame the eyes have been open long enough to release it.
  public mutating func add(
    left: Double, right: Double, at timestamp: TimeInterval
  ) -> SquintEvent? {
    guard left.isFinite, right.isFinite, timestamp.isFinite else { return nil }
    let average = (left + right) / 2
    let narrowedBelow = SquintDetector.squintRatio * openBaseline

    if average < SquintDetector.closedThreshold {
      return nil
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
      if isSquinting, openDuration >= SquintDetector.releaseDuration {
        isSquinting = false
        return .ended
      }
      return nil
    }

    openRunStart = nil
    if runStart == nil {
      runStart = timestamp
    }
    guard !isSquinting, let start = runStart, timestamp - start >= SquintDetector.holdDuration
    else {
      return nil
    }
    isSquinting = true
    return .started
  }

  public mutating func reset() {
    openBaseline = SquintDetector.initialOpenBaseline
    isSquinting = false
    runStart = nil
    openRunStart = nil
  }

  private mutating func adaptBaseline(towards average: Double) {
    let adapted = openBaseline + (average - openBaseline) * SquintDetector.baselineSmoothing
    openBaseline = min(
      max(adapted, SquintDetector.baselineRange.lowerBound),
      SquintDetector.baselineRange.upperBound)
  }
}
