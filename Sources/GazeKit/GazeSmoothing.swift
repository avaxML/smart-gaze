import Foundation

/// Maps the one user-facing smoothing level onto the One-Euro parameters.
///
/// Level 0 is responsive, level 1 is calm; the cutoff runs log-linearly from
/// 0.5 Hz to 0.05 Hz so each step of the slider feels like the same change.
/// Beta scales with the cutoff so a real saccade still opens the filter by
/// the same factor at every level. The derivative cutoff stays at 0.5 Hz,
/// which is what stops one-frame jitter spikes from opening it; that was the
/// lever a live-trace replay found, not the base cutoff.
public enum GazeSmoothing {
  public static let range: ClosedRange<Double> = 0...1
  public static let responsiveCutoffHertz = 0.5
  public static let calmCutoffHertz = 0.05
  public static let betaPerHertz = 0.0075
  public static let derivativeCutoffHertz = 0.5

  public struct Parameters: Equatable, Sendable {
    public let minCutoff: Double
    public let beta: Double
    public let derivativeCutoff: Double
  }

  public static func parameters(forLevel level: Double) -> Parameters {
    let clamped = level.isFinite ? min(max(level, range.lowerBound), range.upperBound) : 0.75
    let ratio = calmCutoffHertz / responsiveCutoffHertz
    let minCutoff = responsiveCutoffHertz * pow(ratio, clamped)
    return Parameters(
      minCutoff: minCutoff, beta: betaPerHertz * minCutoff,
      derivativeCutoff: derivativeCutoffHertz)
  }
}

extension OneEuroPointFilter {
  public init(smoothing level: Double) {
    let p = GazeSmoothing.parameters(forLevel: level)
    self.init(minCutoff: p.minCutoff, beta: p.beta, derivativeCutoff: p.derivativeCutoff)
  }
}
