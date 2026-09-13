import CoreGraphics
import Foundation

/// Reports the two edges of a deliberate squint from per-frame eye aspect
/// ratios. `.started` fires once when a narrowed run reaches `holdDuration`;
/// `.ended` fires once when, after that, the eyes have stayed open for
/// `releaseDuration`, which is also when the detector re-arms. The open
/// baseline adapts slowly to the user so glasses, lighting and eye shape do
/// not need a threshold of their own.
///
/// A downward glance narrows the measured ratio the same way a squint does,
/// so two independent signals separate them. The head pitch baseline adapts
/// like the open baseline and a narrowed frame is ignored while the head is
/// pitched away from it; the iris drop measures how low the iris sits in the
/// eye for callers that have an iris model.
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
  /// A closure no longer than this is a blink; a longer one is a squint whose
  /// eyes are shut tight and whose ratio sits below `closedThreshold`.
  public static let blinkMaximumDuration: TimeInterval = 0.30
  public static let holdDuration: TimeInterval = 0.45
  public static let releaseDuration: TimeInterval = 0.25
  public static let gapTolerance: TimeInterval = 0.15
  public static let pitchTolerance = 0.12
  public static let pitchBaselineRange: ClosedRange<Double> = -0.6...0.6
  public static let irisDropTolerance = 0.18

  public private(set) var openBaseline: Double
  public private(set) var pitchBaseline: Double
  /// True from the frame a squint starts until the frame it ends.
  public private(set) var isSquinting = false
  /// True while narrowed eyes are being tracked towards a squint: from the
  /// frame the run begins, through `.started`, until the release opens it.
  public var isNarrowedRunActive: Bool { isSquinting || runStart != nil }
  /// True when the most recent `add` saw narrowed eyes that a gate rejected.
  public private(set) var suppressedNarrowedFrame = false
  private var runStart: TimeInterval?
  private var openRunStart: TimeInterval?
  private var closureStart: TimeInterval?

  public init() {
    openBaseline = SquintDetector.initialOpenBaseline
    pitchBaseline = 0
  }

  /// The vertical iris offset inside one eye, normalised by the contour's
  /// height: zero when the iris sits at the contour's mean, positive when it
  /// rests towards the lower lid. `nil` when the contour carries no height.
  public static func irisDrop(irisCenter: CGPoint, contour: [CGPoint]) -> Double? {
    guard !contour.isEmpty else { return nil }
    let ys = contour.map(\.y)
    guard let minY = ys.min(), let maxY = ys.max() else { return nil }
    let height = maxY - minY
    guard height >= 1e-6 else { return nil }
    let centre = ys.reduce(0, +) / CGFloat(ys.count)
    return Double(irisCenter.y - centre) / Double(height)
  }

  /// Returns `.started` on the single frame a squint is recognised and `.ended`
  /// on the single frame the eyes have been open long enough to release it.
  public mutating func add(
    left: Double, right: Double, pitchRadians: Double, irisDrop: Double?,
    at timestamp: TimeInterval
  ) -> SquintEvent? {
    suppressedNarrowedFrame = false
    guard left.isFinite, right.isFinite, timestamp.isFinite else { return nil }
    let average = (left + right) / 2
    let narrowedBelow = SquintDetector.squintRatio * openBaseline

    let isClosed = average < SquintDetector.closedThreshold
    if isClosed {
      if closureStart == nil {
        closureStart = timestamp
      }
    } else {
      closureStart = nil
    }
    let closureExceededBlink =
      isClosed && timestamp - (closureStart ?? timestamp) > SquintDetector.blinkMaximumDuration
    let isNarrowed = isClosed ? closureExceededBlink : average < narrowedBelow

    guard isNarrowed else {
      // The first `blinkMaximumDuration` of a closure is a blink candidate, not
      // a squint, so it neither adapts the baseline nor opens the run.
      guard !isClosed else { return nil }
      adaptBaseline(towards: average)
      if pitchRadians.isFinite {
        adaptPitchBaseline(towards: pitchRadians)
      }
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

    let pitchOutOfBand =
      pitchRadians.isFinite
      && abs(pitchRadians - pitchBaseline) > SquintDetector.pitchTolerance
    let drop = irisDrop.flatMap { $0.isFinite ? $0 : nil }
    let irisTooLow = drop.map { $0 > SquintDetector.irisDropTolerance } ?? false

    if isSquinting, pitchOutOfBand {
      isSquinting = false
      runStart = nil
      openRunStart = nil
      return .ended
    }

    if pitchOutOfBand || irisTooLow {
      suppressedNarrowedFrame = true
      return nil
    }

    openRunStart = nil
    if runStart == nil {
      if isClosed, let closureStart {
        runStart = closureStart + SquintDetector.blinkMaximumDuration
      } else {
        runStart = timestamp
      }
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
    pitchBaseline = 0
    isSquinting = false
    suppressedNarrowedFrame = false
    runStart = nil
    openRunStart = nil
    closureStart = nil
  }

  private mutating func adaptBaseline(towards average: Double) {
    let adapted = openBaseline + (average - openBaseline) * SquintDetector.baselineSmoothing
    openBaseline = min(
      max(adapted, SquintDetector.baselineRange.lowerBound),
      SquintDetector.baselineRange.upperBound)
  }

  private mutating func adaptPitchBaseline(towards pitch: Double) {
    let adapted = pitchBaseline + (pitch - pitchBaseline) * SquintDetector.baselineSmoothing
    pitchBaseline = min(
      max(adapted, SquintDetector.pitchBaselineRange.lowerBound),
      SquintDetector.pitchBaselineRange.upperBound)
  }
}
