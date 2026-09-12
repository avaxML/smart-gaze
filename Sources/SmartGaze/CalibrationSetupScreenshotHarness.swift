import AppKit
import Foundation

/// Captures the calibration setup visor as a PNG so a reviewer can see it
/// without running a calibration by hand. `Scripts/screenshot-calibration-setup.sh`
/// runs it. The camera must be live for the visor to carry a real face.
@MainActor
enum CalibrationSetupScreenshotHarness {
  private static let environmentKey = "SMART_GAZE_CALIBRATION_SCREENSHOT_DIR"

  static var outputDirectory: URL? {
    guard let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty
    else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  static func capture(windowController: SettingsWindowController, outputDirectory: URL) async {
    try? FileManager.default.createDirectory(
      at: outputDirectory, withIntermediateDirectories: true)
    windowController.startCalibration()
    // The visor is gone the moment the reducer reports ready, which can happen
    // inside a fixed delay, so keep the newest visor frame seen over the
    // three-second capture window instead of trusting one fixed instant.
    var latest: Data?
    for _ in 0..<20 {
      try? await Task.sleep(for: .milliseconds(150))
      guard windowController.isCalibrationSetupVisible,
        let window = windowController.calibrationScreenshotWindow
      else { continue }
      window.layoutIfNeeded()
      window.displayIfNeeded()
      if let png = pngData(of: window) { latest = png }
    }
    guard let png = latest else { exit(1) }
    let url = outputDirectory.appendingPathComponent("setup.png")
    try? png.write(to: url)
    windowController.abortCalibration()
    exit(0)
  }

  /// In-process drawing of the whole window, so the harness needs no Screen
  /// Recording permission.
  private static func pngData(of window: NSWindow) -> Data? {
    guard let view = window.contentView?.superview ?? window.contentView,
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep.representation(using: .png, properties: [:])
  }
}
