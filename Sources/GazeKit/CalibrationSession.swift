import CoreGraphics
import Foundation

/// The nine fit targets and four held-out validation targets for one calibration
/// run, as normalized positions in the unit square (0...1 on each axis, y down).
/// Validation targets sit at the midpoints between the grid rows and columns, so
/// they exercise the fit away from every point that shaped it.
public struct CalibrationTargetPlan: Equatable, Sendable {
  public let fitTargets: [NormalizedGazePoint]
  public let validationTargets: [NormalizedGazePoint]

  public init(inset: Double = 0.12) {
    let low = inset
    let mid = 0.5
    let high = 1 - inset
    let coordinates = [low, mid, high]
    fitTargets = coordinates.flatMap { y in coordinates.map { x in NormalizedGazePoint(x: x, y: y) }
    }

    let validationLow = low + (mid - low) / 2
    let validationHigh = mid + (high - mid) / 2
    validationTargets = [
      NormalizedGazePoint(x: validationLow, y: validationLow),
      NormalizedGazePoint(x: validationHigh, y: validationLow),
      NormalizedGazePoint(x: validationLow, y: validationHigh),
      NormalizedGazePoint(x: validationHigh, y: validationHigh),
    ]
  }

  public static func screenPoint(for normalized: NormalizedGazePoint, in bounds: CGRect) -> CGPoint
  {
    CGPoint(
      x: bounds.minX + normalized.x * bounds.width,
      y: bounds.minY + normalized.y * bounds.height)
  }
}

/// Whether a burst of gaze samples collected at a held target is tight enough
/// to trust. Dispersion is the sum of the horizontal and vertical span of the
/// burst, the same bounding-box measure `FixationDetector` already uses.
public enum BurstQuality: Equatable, Sendable {
  case accepted(centroid: NormalizedGazePoint)
  case dispersed(dispersion: Double)
}

public enum BurstEvaluator {
  public static func evaluate(
    _ samples: [NormalizedGazePoint], dispersionThreshold: Double
  ) -> BurstQuality {
    guard let first = samples.first else { return .dispersed(dispersion: .infinity) }

    var minX = first.x
    var maxX = first.x
    var minY = first.y
    var maxY = first.y
    var sumX = 0.0
    var sumY = 0.0
    for sample in samples {
      minX = min(minX, sample.x)
      maxX = max(maxX, sample.x)
      minY = min(minY, sample.y)
      maxY = max(maxY, sample.y)
      sumX += sample.x
      sumY += sample.y
    }

    let dispersion = (maxX - minX) + (maxY - minY)
    guard dispersion < dispersionThreshold else { return .dispersed(dispersion: dispersion) }

    let count = Double(samples.count)
    return .accepted(centroid: NormalizedGazePoint(x: sumX / count, y: sumY / count))
  }
}

/// One accepted burst on each axis, reported separately because vertical and
/// horizontal accuracy are not the same axis (see `CalibrationRun`).
public struct CalibrationResult: Equatable, Sendable {
  public let map: CalibrationMap
  public let horizontalErrorPoints: Double
  public let verticalErrorPoints: Double
  public let distanceCentimeters: Double

  public init(
    map: CalibrationMap, horizontalErrorPoints: Double, verticalErrorPoints: Double,
    distanceCentimeters: Double
  ) {
    self.map = map
    self.horizontalErrorPoints = horizontalErrorPoints
    self.verticalErrorPoints = verticalErrorPoints
    self.distanceCentimeters = distanceCentimeters
  }
}

public enum CalibrationStage: Equatable, Sendable {
  case fitting(targetIndex: Int)
  case validating(targetIndex: Int)
  case finished(CalibrationResult)
  case aborted
  case failed(CalibrationError)
}

public enum CalibrationSubmitOutcome: Equatable, Sendable {
  case retryTarget(dispersion: Double)
  case advancedToNextFitTarget
  case advancedToNextValidationTarget
  case completed(CalibrationResult)
  case solveFailed(CalibrationError)
}

/// Drives one calibration attempt through its fit targets, then its held-out
/// validation targets, one burst at a time. Never bakes a dispersed burst into
/// the fit: `submitBurst` reports `.retryTarget` and leaves the stage exactly
/// where it was, so the caller can show the same target again.
///
/// Vertical and horizontal residuals are computed and reported separately
/// because the two axes have measured different noise: a single averaged
/// error would hide whichever axis is actually failing.
public struct CalibrationRun: Sendable {
  public let plan: CalibrationTargetPlan
  public let bounds: CGRect
  public let dispersionThreshold: Double

  public private(set) var stage: CalibrationStage
  /// The distance the calibration was performed at, in centimeters. Set at
  /// construction from whatever is known then and refined by `recordDistance`
  /// as later, more representative readings arrive; the value in place when
  /// the run finishes is the one carried into `CalibrationResult`.
  public private(set) var distanceCentimeters: Double

  private var fitSamples: [CalibrationSample] = []
  private var map: CalibrationMap?
  private var validationErrors: [(horizontal: Double, vertical: Double)] = []

  public init(
    plan: CalibrationTargetPlan,
    bounds: CGRect,
    dispersionThreshold: Double,
    distanceCentimeters: Double
  ) {
    self.plan = plan
    self.bounds = bounds
    self.dispersionThreshold = dispersionThreshold
    self.distanceCentimeters = distanceCentimeters
    self.stage = plan.fitTargets.isEmpty ? .aborted : .fitting(targetIndex: 0)
  }

  public var currentTargetScreenPoint: CGPoint? {
    switch stage {
    case .fitting(let index):
      guard plan.fitTargets.indices.contains(index) else { return nil }
      return CalibrationTargetPlan.screenPoint(for: plan.fitTargets[index], in: bounds)
    case .validating(let index):
      guard plan.validationTargets.indices.contains(index) else { return nil }
      return CalibrationTargetPlan.screenPoint(for: plan.validationTargets[index], in: bounds)
    case .finished, .aborted, .failed:
      return nil
    }
  }

  public mutating func submitBurst(_ samples: [NormalizedGazePoint]) -> CalibrationSubmitOutcome {
    switch stage {
    case .fitting(let index):
      return submitFitBurst(samples, at: index)
    case .validating(let index):
      return submitValidationBurst(samples, at: index)
    case .finished, .aborted, .failed:
      return .solveFailed(.degenerate)
    }
  }

  public mutating func abort() {
    stage = .aborted
  }

  public mutating func recordDistance(_ centimeters: Double) {
    distanceCentimeters = centimeters
  }

  private mutating func submitFitBurst(
    _ samples: [NormalizedGazePoint], at index: Int
  ) -> CalibrationSubmitOutcome {
    guard plan.fitTargets.indices.contains(index) else { return .solveFailed(.degenerate) }
    switch BurstEvaluator.evaluate(samples, dispersionThreshold: dispersionThreshold) {
    case .dispersed(let dispersion):
      return .retryTarget(dispersion: dispersion)
    case .accepted(let centroid):
      let screenPoint = CalibrationTargetPlan.screenPoint(for: plan.fitTargets[index], in: bounds)
      fitSamples.append(CalibrationSample(gaze: centroid, screenPoint: screenPoint))

      let nextIndex = index + 1
      guard nextIndex < plan.fitTargets.count else { return solveFit() }
      stage = .fitting(targetIndex: nextIndex)
      return .advancedToNextFitTarget
    }
  }

  private mutating func solveFit() -> CalibrationSubmitOutcome {
    do {
      let solved = try solveCalibration(fitSamples)
      map = solved
      stage = .validating(targetIndex: 0)
      return .advancedToNextFitTarget
    } catch let error as CalibrationError {
      stage = .failed(error)
      return .solveFailed(error)
    } catch {
      stage = .failed(.degenerate)
      return .solveFailed(.degenerate)
    }
  }

  private mutating func submitValidationBurst(
    _ samples: [NormalizedGazePoint], at index: Int
  ) -> CalibrationSubmitOutcome {
    guard let map, plan.validationTargets.indices.contains(index) else {
      return .solveFailed(.degenerate)
    }
    switch BurstEvaluator.evaluate(samples, dispersionThreshold: dispersionThreshold) {
    case .dispersed(let dispersion):
      return .retryTarget(dispersion: dispersion)
    case .accepted(let centroid):
      let actual = CalibrationTargetPlan.screenPoint(for: plan.validationTargets[index], in: bounds)
      let predicted = map.project(centroid)
      validationErrors.append(
        (horizontal: abs(predicted.x - actual.x), vertical: abs(predicted.y - actual.y)))

      let nextIndex = index + 1
      guard nextIndex < plan.validationTargets.count else { return finishValidation(map: map) }
      stage = .validating(targetIndex: nextIndex)
      return .advancedToNextValidationTarget
    }
  }

  private mutating func finishValidation(map: CalibrationMap) -> CalibrationSubmitOutcome {
    let count = Double(validationErrors.count)
    let horizontalMean = validationErrors.map(\.horizontal).reduce(0, +) / count
    let verticalMean = validationErrors.map(\.vertical).reduce(0, +) / count
    let result = CalibrationResult(
      map: map,
      horizontalErrorPoints: horizontalMean,
      verticalErrorPoints: verticalMean,
      distanceCentimeters: distanceCentimeters)
    stage = .finished(result)
    return .completed(result)
  }
}
