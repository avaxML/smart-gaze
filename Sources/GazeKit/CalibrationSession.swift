import CoreGraphics
import Foundation

/// The nine fit targets and four held-out validation targets for one calibration
/// run, as normalized positions in the unit square (0...1 on each axis, y down).
/// Validation targets sit at the midpoints between the grid rows and columns, so
/// they exercise the fit away from every point that shaped it.
public struct CalibrationTargetPlan: Equatable, Sendable {
  public let fitTargets: [NormalizedGazePoint]
  public let validationTargets: [NormalizedGazePoint]
  /// The centre target held during the head sweep. Kept after the fit grid
  /// because the map is valid at the centre, so a rotation fitted there
  /// measures the residual without an offset from a corner.
  public let sweepTarget = NormalizedGazePoint(x: 0.5, y: 0.5)

  public init(inset: Double = 0.12) {
    let low = inset
    let mid = 0.5
    let high = 1 - inset
    let coordinates = [low, mid, high]
    // Column by column, and within each column top, bottom, then middle. A
    // posture that drifts over the run then lands on every row in turn instead
    // of aliasing into the vertical gain the way a top to bottom sweep does.
    fitTargets = coordinates.flatMap { x in
      [low, high, mid].map { y in NormalizedGazePoint(x: x, y: y) }
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
  case accepted(
    centroid: NormalizedGazePoint, horizontalSpan: Double, verticalSpan: Double)
  case dispersed(dispersion: Double)
}

public enum BurstEvaluator {
  public static func evaluate(
    _ samples: [NormalizedGazePoint], dispersionThreshold: Double
  ) -> BurstQuality {
    guard let first = samples.first else { return .dispersed(dispersion: .infinity) }
    guard samples.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
      return .dispersed(dispersion: .infinity)
    }

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
    return .accepted(
      centroid: NormalizedGazePoint(x: sumX / count, y: sumY / count),
      horizontalSpan: maxX - minX, verticalSpan: maxY - minY)
  }
}

/// One accepted burst on each axis, reported separately because vertical and
/// horizontal accuracy are not the same axis (see `CalibrationRun`).
public struct CalibrationResult: Equatable, Sendable {
  public let map: CalibrationMap
  public let horizontalErrorPoints: Double
  public let verticalErrorPoints: Double
  public let distanceCentimeters: Double
  /// Median spread of the accepted fixation bursts, in screen points, measured
  /// while the user held a known target. `dispersion` is the sum of the two
  /// axes, matching `FixationDetector`.
  public let observedHorizontalSpanPoints: Double
  public let observedVerticalSpanPoints: Double
  public let observedDispersionPoints: Double
  public let acceptedBurstCount: Int
  /// Mean face origin over the accepted fit bursts, camera frame in cm. The
  /// pose the map is valid at; `HeadTranslationCorrection` measures from it.
  public let faceOriginCentimeters: SIMD3<Double>?
  /// The fitted rotation correction from the calibration head sweep, or nil
  /// when the sweep produced too few samples or too little pose range.
  public let headRotationCorrection: HeadRotationCorrection?
  /// The per-user interpupillary distance fitted from the accepted bursts'
  /// iris-ruler and eye-baseline depths. `nil` when too few values were
  /// recorded or their median was implausible.
  public let interpupillaryCentimetres: Double?
  /// The display the targets were shown on. The map is only meaningful there,
  /// so tracking must be bounded by it rather than by every attached display.
  public let bounds: CGRect

  public init(
    map: CalibrationMap, horizontalErrorPoints: Double, verticalErrorPoints: Double,
    distanceCentimeters: Double, observedHorizontalSpanPoints: Double = 0,
    observedVerticalSpanPoints: Double = 0, observedDispersionPoints: Double = 0,
    acceptedBurstCount: Int = 0, bounds: CGRect = .null,
    faceOriginCentimeters: SIMD3<Double>? = nil,
    headRotationCorrection: HeadRotationCorrection? = nil,
    interpupillaryCentimetres: Double? = nil
  ) {
    self.bounds = bounds
    self.faceOriginCentimeters = faceOriginCentimeters
    self.headRotationCorrection = headRotationCorrection
    self.interpupillaryCentimetres = interpupillaryCentimetres
    self.map = map
    self.horizontalErrorPoints = horizontalErrorPoints
    self.verticalErrorPoints = verticalErrorPoints
    self.distanceCentimeters = distanceCentimeters
    self.observedHorizontalSpanPoints = observedHorizontalSpanPoints
    self.observedVerticalSpanPoints = observedVerticalSpanPoints
    self.observedDispersionPoints = observedDispersionPoints
    self.acceptedBurstCount = acceptedBurstCount
  }
}

public enum CalibrationStage: Equatable, Sendable {
  case fitting(targetIndex: Int)
  case sweeping
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
  /// Spans of every burst accepted while the user was provably holding a known
  /// target, which is the only condition under which observed spread is jitter
  /// rather than the user looking somewhere else. This is the measurement #21
  /// needs to replace a guessed dispersion threshold.
  private var acceptedSpans: [(horizontal: Double, vertical: Double)] = []
  private var latestFaceOrigin: SIMD3<Double>?
  private var fitOrigins: [SIMD3<Double>] = []
  /// The head pose recorded since the last accepted burst, consumed when that
  /// burst is accepted so the sweep's reference is the mean over the fit
  /// bursts the user actually held, not over retries.
  private var latestHeadPose: (yaw: Double, pitch: Double)?
  private var fitHeadPoses: [(yaw: Double, pitch: Double)] = []
  /// The rotation correction fitted from the calibration sweep, stored until
  /// validation finishes and the result is built.
  private var headRotationCorrection: HeadRotationCorrection?
  /// The implied interpupillary distance recorded since the last accepted
  /// burst, consumed when that burst is accepted so a dispersed retry cannot
  /// count the same reading twice.
  private var pendingImpliedInterpupillary: Double?
  /// The implied distance each accepted fit or validation burst carried.
  private var acceptedImpliedInterpupillary: [Double] = []

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
    case .sweeping:
      return CalibrationTargetPlan.screenPoint(for: plan.sweepTarget, in: bounds)
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
    case .sweeping:
      return .solveFailed(.degenerate)
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

  public mutating func recordFaceOrigin(_ centimeters: SIMD3<Double>) {
    latestFaceOrigin = centimeters
  }

  /// Records the head pose for the burst being collected. Accepted fit bursts
  /// keep it as the sweep's reference; validation reads it as the burst mean.
  public mutating func recordHeadPose(yawRadians: Double, pitchRadians: Double) {
    latestHeadPose = (yawRadians, pitchRadians)
  }

  /// Records the latest implied interpupillary distance. It is consumed by the
  /// next accepted burst, so a dispersed retry cannot count it twice.
  public mutating func recordImpliedInterpupillary(_ centimetres: Double) {
    pendingImpliedInterpupillary = centimetres
  }

  /// Face origins captured with each accepted fit burst, in order. Exposed so
  /// a run can be checked for posture drift across the target sequence.
  public var acceptedFitOrigins: [SIMD3<Double>] { fitOrigins }

  /// The map solved from the accepted fit bursts, available while the run is
  /// sweeping and validating. The sweep pairs each frame's projection through
  /// it with the head pose on that frame.
  public var solvedMap: CalibrationMap? { map }

  /// The rotation correction fitted by the sweep, or nil when the sweep had
  /// too few samples or too little pose range.
  public var solvedHeadRotationCorrection: HeadRotationCorrection? { headRotationCorrection }

  /// Fits the rotation correction from the sweep samples and advances to
  /// validation. The reference is the mean pose recorded with the accepted fit
  /// bursts. A nil fit stores no correction and is not an error.
  public mutating func submitSweep(
    _ samples: [HeadRotationFit.Sample]
  ) -> CalibrationSubmitOutcome {
    guard case .sweeping = stage else { return .solveFailed(.degenerate) }
    let reference =
      fitHeadPoses.isEmpty
      ? (yaw: 0.0, pitch: 0.0)
      : (
        yaw: fitHeadPoses.map(\.yaw).reduce(0, +) / Double(fitHeadPoses.count),
        pitch: fitHeadPoses.map(\.pitch).reduce(0, +) / Double(fitHeadPoses.count)
      )
    let target = CalibrationTargetPlan.screenPoint(for: plan.sweepTarget, in: bounds)
    headRotationCorrection = HeadRotationFit.fit(
      samples: samples, target: target, referenceYawRadians: reference.yaw,
      referencePitchRadians: reference.pitch)
    stage = .validating(targetIndex: 0)
    return .advancedToNextValidationTarget
  }

  private mutating func keepPendingImpliedInterpupillary() {
    guard let pendingImpliedInterpupillary else { return }
    acceptedImpliedInterpupillary.append(pendingImpliedInterpupillary)
    self.pendingImpliedInterpupillary = nil
  }

  private mutating func submitFitBurst(
    _ samples: [NormalizedGazePoint], at index: Int
  ) -> CalibrationSubmitOutcome {
    guard plan.fitTargets.indices.contains(index) else { return .solveFailed(.degenerate) }
    switch BurstEvaluator.evaluate(samples, dispersionThreshold: dispersionThreshold) {
    case .dispersed(let dispersion):
      return .retryTarget(dispersion: dispersion)
    case .accepted(let centroid, let horizontalSpan, let verticalSpan):
      acceptedSpans.append((horizontal: horizontalSpan, vertical: verticalSpan))
      if let latestFaceOrigin { fitOrigins.append(latestFaceOrigin) }
      if let latestHeadPose { fitHeadPoses.append(latestHeadPose) }
      keepPendingImpliedInterpupillary()
      let screenPoint = CalibrationTargetPlan.screenPoint(for: plan.fitTargets[index], in: bounds)
      fitSamples.append(CalibrationSample(gaze: centroid, screenPoint: screenPoint))

      let nextIndex = index + 1
      guard nextIndex < plan.fitTargets.count else { return solveFit() }
      stage = .fitting(targetIndex: nextIndex)
      return .advancedToNextFitTarget
    }
  }

  static func median(_ sorted: [Double]) -> Double {
    guard !sorted.isEmpty else { return 0 }
    return sorted[sorted.count / 2]
  }

  private mutating func solveFit() -> CalibrationSubmitOutcome {
    do {
      let solved = try solveCalibration(fitSamples)
      map = solved
      stage = .sweeping
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
    case .accepted(let centroid, _, _):
      keepPendingImpliedInterpupillary()
      let actual = CalibrationTargetPlan.screenPoint(for: plan.validationTargets[index], in: bounds)
      var predicted = map.project(centroid)
      if let headRotationCorrection, let latestHeadPose {
        predicted = headRotationCorrection.correct(
          predicted, yawRadians: latestHeadPose.yaw, pitchRadians: latestHeadPose.pitch)
      }
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
    let horizontalSpans = acceptedSpans.map { $0.horizontal * Double(bounds.width) }.sorted()
    let verticalSpans = acceptedSpans.map { $0.vertical * Double(bounds.height) }.sorted()
    let dispersions = zip(horizontalSpans, verticalSpans).map(+).sorted()
    let result = CalibrationResult(
      map: map,
      horizontalErrorPoints: horizontalMean,
      verticalErrorPoints: verticalMean,
      distanceCentimeters: distanceCentimeters,
      observedHorizontalSpanPoints: CalibrationRun.median(horizontalSpans),
      observedVerticalSpanPoints: CalibrationRun.median(verticalSpans),
      observedDispersionPoints: CalibrationRun.median(dispersions),
      acceptedBurstCount: acceptedSpans.count,
      bounds: bounds,
      faceOriginCentimeters: fitOrigins.isEmpty
        ? nil : fitOrigins.reduce(SIMD3<Double>.zero, +) / Double(fitOrigins.count),
      headRotationCorrection: headRotationCorrection,
      interpupillaryCentimetres: InterpupillaryFit.fit(
        impliedCentimetres: acceptedImpliedInterpupillary))
    stage = .finished(result)
    return .completed(result)
  }
}
