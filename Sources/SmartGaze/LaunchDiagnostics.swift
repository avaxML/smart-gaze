import Foundation

/// Milestones the app reports during startup when `SMART_GAZE_LAUNCH_LOG` names
/// a writable path.
///
/// Three shipped defects lived in the launch path and every one passed the test
/// suite: models resolved relative to a working directory an app launched from
/// Finder does not have, a camera state that waited forever with no timeout, and
/// modal alerts that blocked before the camera started. None of it is reachable
/// from a unit test, because none of it happens until the bundle is launched.
/// `Scripts/launch-smoke.sh` asserts against these milestones.
enum LaunchDiagnostics {
  enum Milestone: String {
    case launchCompleted = "launch-completed"
    case cameraState = "camera-state"
    case pipelineReady = "pipeline-ready"
    case calibration = "calibration"
    case intrinsicMatrix = "intrinsic-matrix"
    /// Whether the active provider's key was readable from the Keychain at
    /// launch. Never the key itself, only "present" or "absent".
    case providerKey = "provider-key"
    /// Whether the modifier tap could be installed, and each modifier edge it
    /// sees. The only way to tell "no Accessibility" from "no gaze" from
    /// "no capture" without a debugger.
    case modifier = "modifier"
    /// Raw and filtered screen points, only while `SMART_GAZE_TRACE_GAZE` is
    /// set, and only for the first few hundred samples. The evidence a filter
    /// change has to be tuned against.
    case gaze = "gaze"
    /// Every capture the trigger fires and how it ended, so a live session
    /// can be checked from the log alone.
    case capture = "capture"
  }

  private static let path = ProcessInfo.processInfo.environment["SMART_GAZE_LAUNCH_LOG"]

  static var isEnabled: Bool { path != nil }

  static func record(_ milestone: Milestone, _ detail: String = "") {
    guard let path else { return }
    let line = detail.isEmpty ? milestone.rawValue : "\(milestone.rawValue) \(detail)"
    let data = (line + "\n").data(using: .utf8)!
    let url = URL(fileURLWithPath: path)
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(data)
      try? handle.close()
    } else {
      try? data.write(to: url)
    }
  }
}
