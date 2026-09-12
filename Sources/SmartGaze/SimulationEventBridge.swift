import AppKit
import GazeKit
import SwiftUI

/// Bridges real keyboard input into the pointer simulation while the Settings
/// preview is active. It installs AppKit *local* monitors, so no Accessibility
/// permission or global event tap is needed, and it is filtered to the window
/// that hosts this view.
///
/// The model decides whether a key is relevant. Unrelated keys (and every key
/// outside an active simulation) are returned untouched, so normal editing is
/// preserved.
struct SimulationEventBridge: NSViewRepresentable {
  var isActive: Bool
  var modifierKey: ModifierKey
  var onModifierChange: @MainActor (Bool) -> Bool
  var onCommand: @MainActor (SimulationCommand) -> Bool

  func makeNSView(context: Context) -> BridgeView {
    BridgeView()
  }

  func updateNSView(_ view: BridgeView, context: Context) {
    view.update(
      isActive: isActive,
      modifierFlag: SimulationEventBridge.flag(for: modifierKey),
      onModifierChange: onModifierChange,
      onCommand: onCommand)
  }

  static func dismantleNSView(_ view: BridgeView, coordinator: ()) {
    view.removeMonitors()
  }

  static func flag(for key: ModifierKey) -> NSEvent.ModifierFlags {
    switch key {
    case .option: .option
    case .control: .control
    case .command: .command
    case .shift: .shift
    }
  }

  @MainActor
  final class BridgeView: NSView {
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var windowCloseObserver: NSObjectProtocol?
    private var isActive = false
    private var modifierFlag: NSEvent.ModifierFlags = .option
    private var onModifierChange: (@MainActor (Bool) -> Bool)?
    private var onCommand: (@MainActor (SimulationCommand) -> Bool)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let windowCloseObserver {
        NotificationCenter.default.removeObserver(windowCloseObserver)
        self.windowCloseObserver = nil
      }
      refreshMonitors()
    }

    func update(
      isActive: Bool,
      modifierFlag: NSEvent.ModifierFlags,
      onModifierChange: @escaping @MainActor (Bool) -> Bool,
      onCommand: @escaping @MainActor (SimulationCommand) -> Bool
    ) {
      self.isActive = isActive
      self.modifierFlag = modifierFlag
      self.onModifierChange = onModifierChange
      self.onCommand = onCommand
      refreshMonitors()
    }

    func removeMonitors() {
      if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
      if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
      flagsMonitor = nil
      keyMonitor = nil
      if let windowCloseObserver {
        NotificationCenter.default.removeObserver(windowCloseObserver)
        self.windowCloseObserver = nil
      }
    }

    private func refreshMonitors() {
      guard isActive, window != nil else {
        removeMonitors()
        return
      }
      if windowCloseObserver == nil, let window {
        // The window can close without SwiftUI re-running `update`; drop the
        // monitors directly so no key is ever captured after close.
        windowCloseObserver = NotificationCenter.default.addObserver(
          forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.removeMonitors() }
        }
      }
      if flagsMonitor == nil {
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
          [weak self] event in
          let window = event.window
          let pressedFlags = event.modifierFlags
          let consume = MainActor.assumeIsolated { () -> Bool in
            guard let self, self.isActive, self.window?.isKeyWindow == true,
              window == nil || window === self.window,
              let decide = self.onModifierChange
            else { return false }
            return decide(pressedFlags.contains(self.modifierFlag))
          }
          return consume ? nil : event
        }
      }
      if keyMonitor == nil {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
          let window = event.window
          guard !event.isARepeat,
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty
          else { return event }
          let key = event.charactersIgnoringModifiers?.lowercased()
          let consume = MainActor.assumeIsolated { () -> Bool in
            guard let self, self.isActive, self.window?.isKeyWindow == true,
              window == nil || window === self.window,
              let decide = self.onCommand,
              let command = SimulationEventBridge.command(for: key)
            else { return false }
            return decide(command)
          }
          return consume ? nil : event
        }
      }
    }

    deinit {
      MainActor.assumeIsolated { removeMonitors() }
    }
  }

  static func command(for key: String?) -> SimulationCommand? {
    switch key {
    case "b": return .singleBlink
    case "d": return .doubleBlink
    case "s": return .squint
    default: return nil
    }
  }
}
