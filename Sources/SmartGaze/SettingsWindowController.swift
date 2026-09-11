import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  private let model: SettingsModel
  private let preview: CalibrationPreviewModel
  private var window: NSWindow?
  private var calibrationWindowController: CalibrationWindowController?

  init(model: SettingsModel) {
    self.model = model
    self.preview = CalibrationPreviewModel(settings: model)
    super.init()
    preview.onStartCalibration = { [weak self] in self?.startCalibration() }
  }

  /// The single entry point for both re-entry points in issue #14: the
  /// Settings button calls this directly, and `AppDelegate`'s first-run
  /// prompt calls it too, so a completed run always lands the same way.
  func startCalibration() {
    guard calibrationWindowController == nil else { return }
    // One display, not the union. Looking between monitors is a head turn of
    // tens of degrees, outside anything the model was trained on, and the first
    // live run's cross-display row was the one with no horizontal signal.
    let bounds = CGDisplayBounds(CGMainDisplayID())
    let coordinator = CalibrationCoordinator(bounds: bounds)
    let controller = CalibrationWindowController(coordinator: coordinator)
    calibrationWindowController = controller
    controller.present { [weak self] result in
      self?.calibrationWindowController = nil
      guard let result else { return }
      self?.model.applyCalibrationResult(result)
    }
  }

  func show() {
    // Only prepare the settings form here. The preview starts only when its
    // tab is actually shown, so a previously enabled simulation cannot resume
    // while the General tab is in front.
    model.prepareForPresentation()
    if window == nil {
      window = makeWindow()
    }
    window?.center()
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    preview.stop()
    model.settingsWindowWillClose()
  }

  private func makeWindow() -> NSWindow {
    let hosting = NSHostingController(rootView: SettingsView(model: model, preview: preview))
    let window = NSWindow(contentViewController: hosting)
    window.title = "SmartGaze Settings"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.contentMinSize = NSSize(width: 760, height: 400)
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.toolbarStyle = .preference
    window.toolbar = NSToolbar()
    return window
  }
}
