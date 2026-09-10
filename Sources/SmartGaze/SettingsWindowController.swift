import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  private let model: SettingsModel
  private let preview: CalibrationPreviewModel
  private var window: NSWindow?

  init(model: SettingsModel) {
    self.model = model
    self.preview = CalibrationPreviewModel(settings: model)
    super.init()
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
    window.contentMinSize = NSSize(width: 760, height: 620)
    window.isReleasedWhenClosed = false
    window.delegate = self
    return window
  }
}
