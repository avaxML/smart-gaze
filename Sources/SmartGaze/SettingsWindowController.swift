import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  private let model: SettingsModel
  private var window: NSWindow?

  init(model: SettingsModel) {
    self.model = model
    super.init()
  }

  func show() {
    model.prepareForPresentation()
    if window == nil {
      window = makeWindow()
    }
    window?.center()
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    model.settingsWindowWillClose()
  }

  private func makeWindow() -> NSWindow {
    let hosting = NSHostingController(rootView: SettingsView(model: model))
    let window = NSWindow(contentViewController: hosting)
    window.title = "SmartGaze Settings"
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.isReleasedWhenClosed = false
    window.delegate = self
    return window
  }
}
