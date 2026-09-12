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
    let displayID = CGMainDisplayID()
    let bounds = CGDisplayBounds(displayID)
    let pointsPerCentimeter = SettingsWindowController.pointsPerCentimeter(
      bounds: bounds, physicalMillimetres: CGDisplayScreenSize(displayID))
    let coordinator = CalibrationCoordinator(bounds: bounds)
    let controller = CalibrationWindowController(coordinator: coordinator)
    calibrationWindowController = controller
    controller.present { [weak self] result in
      self?.calibrationWindowController = nil
      guard let result else { return }
      self?.model.applyCalibrationResult(result, pointsPerCentimeter: pointsPerCentimeter)
    }
  }

  /// Points per centimetre of the calibrated display. `CGDisplayScreenSize`
  /// returns zero for a display with no EDID size, which yields nil here and
  /// switches the head translation correction off instead of scaling by zero.
  nonisolated static func pointsPerCentimeter(bounds: CGRect, physicalMillimetres: CGSize)
    -> SIMD2<Double>?
  {
    guard physicalMillimetres.width > 0, physicalMillimetres.height > 0,
      bounds.width > 0, bounds.height > 0
    else { return nil }
    return SIMD2(
      bounds.width / (physicalMillimetres.width / 10),
      bounds.height / (physicalMillimetres.height / 10))
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

  var screenshotWindow: NSWindow? { window }

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
