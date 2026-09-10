/// Turns a run of per-frame detection failures into one "tracking lost"
/// decision. A single missed frame (motion blur, a blink, a dropped Vision
/// call) is normal at camera frame rate and must not reset an in-progress
/// dwell or modifier arm; only a sustained run should.
public struct FaceLossDebounce: Sendable {
  private let consecutiveFailureThreshold: Int
  private var consecutiveFailures = 0
  private var hasReportedLoss = false

  public init(consecutiveFailureThreshold: Int = 10) {
    self.consecutiveFailureThreshold = max(1, consecutiveFailureThreshold)
  }

  /// Records a frame that produced no gaze sample. Returns `true` the moment
  /// the run first crosses the threshold, so the caller reports loss exactly
  /// once per sustained gap rather than on every failure after it.
  public mutating func recordFailure() -> Bool {
    consecutiveFailures += 1
    guard consecutiveFailures >= consecutiveFailureThreshold, !hasReportedLoss else {
      return false
    }
    hasReportedLoss = true
    return true
  }

  public mutating func recordSuccess() {
    consecutiveFailures = 0
    hasReportedLoss = false
  }
}
