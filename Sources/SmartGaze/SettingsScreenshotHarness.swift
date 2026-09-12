import AppKit
import Foundation
import GazeKit
import Providers

/// Drives the Settings window through every tab in both appearances and writes
/// one PNG per tab. `Scripts/screenshot-settings.sh` runs it so a reviewer can
/// see the panel after a change. The mode never reads or writes the real
/// Keychain or UserDefaults.
@MainActor
enum SettingsScreenshotHarness {
  private static let environmentKey = "SMART_GAZE_SETTINGS_SCREENSHOT_DIR"

  static var outputDirectory: URL? {
    guard let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty
    else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  static var isEnabled: Bool { outputDirectory != nil }

  static func makeSettingsStore() -> SettingsStore {
    ScreenshotSettingsStore(settings: previewSettings)
  }

  static func makeSecrets() -> any SecretStore & SecretPresence {
    ScreenshotSecrets()
  }

  static var previewSettings: Settings {
    var settings = Settings.default
    settings.deniedApps = AppDenylist(bundleIDs: [
      "com.1password.1password",
      "com.apple.keychainaccess",
      "com.apple.MobileSMS",
      "com.apple.mail",
      "com.tinyspeck.slackmacgap",
    ])
    return settings
  }

  private struct ScreenshotSettingsStore: SettingsStore {
    let settings: Settings

    func load() -> Settings { settings }
    func save(_ settings: Settings) throws {}
  }

  private struct ScreenshotSecrets: SecretStore, SecretPresence {
    func read(account: String) throws -> String? { "screenshot-placeholder" }
    func write(_ secret: String, account: String) throws {}
    func delete(account: String) throws {}
    func contains(account: String) throws -> Bool { true }
  }

  private static let tabs = ["general", "calibration-preview", "provider", "privacy"]

  static func capture(windowController: SettingsWindowController) async {
    guard let outputDirectory else { return }
    try? FileManager.default.createDirectory(
      at: outputDirectory, withIntermediateDirectories: true)
    windowController.show()
    guard let window = windowController.screenshotWindow else { exit(1) }

    for (index, slug) in tabs.enumerated() {
      for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
        window.appearance = NSAppearance(named: appearanceName)
        try? await Task.sleep(for: .milliseconds(400))
        selectTab(at: index, in: windowController)
        try? await Task.sleep(for: .milliseconds(600))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        guard let png = pngData(of: window) else { continue }
        let suffix = appearanceName == .darkAqua ? "dark" : "light"
        let url = outputDirectory.appendingPathComponent("\(slug)-\(suffix).png")
        try? png.write(to: url)
      }
    }
    exit(0)
  }

  /// `SettingsView` renders its tabs through the window toolbar rather than a
  /// SwiftUI `TabView`, so the harness asks the controller to select a tab.
  private static func selectTab(at index: Int, in windowController: SettingsWindowController) {
    windowController.selectTab(at: index)
  }

  /// In-process drawing of the whole window, toolbar included, so a reviewer
  /// sees the tab bar as well as the content and the harness needs no Screen
  /// Recording permission.
  private static func pngData(of window: NSWindow) -> Data? {
    guard let view = window.contentView?.superview ?? window.contentView,
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep.representation(using: .png, properties: [:])
  }
}
