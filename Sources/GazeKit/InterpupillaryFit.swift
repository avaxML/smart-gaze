import Foundation

/// The per-user interpupillary distance the eye-baseline depth ruler assumes.
///
/// The eye-baseline depth is exactly proportional to that assumption, so one
/// constant measured during calibration corrects it from then on. The iris
/// ruler is person-independent, which is what makes the ratio of the two
/// rulers a reading of the user rather than of the camera.
public enum InterpupillaryFit {
  /// Adult interpupillary distance, centimetres. A median outside this range
  /// means a wrong focal length or a broken iris ruler, not a user.
  public static let plausibleRange: ClosedRange<Double> = 5.0...7.5

  public static let minimumSamples = 5

  /// `assumed * irisDepth / baselineDepth`. The eye-baseline depth is exactly
  /// proportional to `assumedCentimetres`, so the ratio recovers the user's own
  /// distance.
  ///
  /// - Returns: `nil` when any input is non-finite or non-positive.
  public static func impliedCentimetres(
    irisDepthCentimetres: Double,
    baselineDepthCentimetres: Double,
    assumedCentimetres: Double
  ) -> Double? {
    guard
      irisDepthCentimetres.isFinite, irisDepthCentimetres > 0,
      baselineDepthCentimetres.isFinite, baselineDepthCentimetres > 0,
      assumedCentimetres.isFinite, assumedCentimetres > 0
    else { return nil }
    return assumedCentimetres * irisDepthCentimetres / baselineDepthCentimetres
  }

  /// Median of the implied values, which rejects the iris ruler's per-frame
  /// noise without dropping good frames.
  ///
  /// - Returns: `nil` for fewer than `minimumSamples` values, or a median
  ///   outside `plausibleRange` so a single bad run cannot set the scale.
  public static func fit(impliedCentimetres: [Double]) -> Double? {
    guard impliedCentimetres.count >= minimumSamples else { return nil }
    let sorted = impliedCentimetres.sorted()
    let median = sorted[sorted.count / 2]
    guard plausibleRange.contains(median) else { return nil }
    return median
  }
}
