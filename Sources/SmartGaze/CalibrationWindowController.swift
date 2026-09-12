import AppKit
import CoreGraphics
import GazeKit
import SwiftUI

/// Presents one full-screen, non-activating window per active display for a
/// calibration run, driven by `CalibrationCoordinator`. Targets are placed in
/// Quartz global display space, the same space `GazeCoordinator` already uses
/// for the live pipeline, so a target that lands on a secondary display shows
/// up in that display's window rather than the main one.
@MainActor
final class CalibrationWindowController {
  private var windows: [NSWindow] = []
  private var escapeMonitor: Any?
  private let coordinator: CalibrationCoordinator
  private var mainDisplayWindow: NSWindow?

  init(coordinator: CalibrationCoordinator) {
    self.coordinator = coordinator
  }

  static func unionOfActiveDisplays() -> CGRect {
    GazeCoordinator.unionOfActiveDisplays()
  }

  /// The main display's window, for an in-process screenshot harness.
  var screenshotWindow: NSWindow? { mainDisplayWindow }

  /// True while the setup visor is on screen with both a mesh and an iris
  /// reading, which is the state a screenshot lever needs to capture.
  var isShowingSetupWithFace: Bool {
    guard case .setup = coordinator.phase, let face = coordinator.setupFace else { return false }
    return !face.mesh.isEmpty && !face.imageLeftIris.isEmpty
  }

  func present(onCompletion: @escaping (CalibrationResult?) -> Void) {
    let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
    let mainScreen = NSScreen.main ?? NSScreen.screens.first
    windows = NSScreen.screens.map { screen in
      makeWindow(
        for: screen, mainDisplayHeight: mainHeight, showsSetup: screen == mainScreen)
    }
    mainDisplayWindow = windows.first { $0.screen == mainScreen } ?? windows.first
    for window in windows { window.orderFrontRegardless() }

    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard event.keyCode == 53 else { return event }
      self?.coordinator.abort()
      return nil
    }

    coordinator.onFinished = { [weak self] result in
      self?.tearDown()
      onCompletion(result)
    }
    coordinator.start()
  }

  func abort() {
    coordinator.abort()
  }

  private func tearDown() {
    if let escapeMonitor {
      NSEvent.removeMonitor(escapeMonitor)
      self.escapeMonitor = nil
    }
    for window in windows { window.orderOut(nil) }
    windows = []
  }

  private func makeWindow(
    for screen: NSScreen, mainDisplayHeight: CGFloat, showsSetup: Bool
  ) -> NSWindow {
    let window = NSPanel(
      contentRect: screen.frame,
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered,
      defer: false,
      screen: screen)
    window.isOpaque = false
    window.backgroundColor = NSColor.black.withAlphaComponent(0.92)
    window.level = .screenSaver
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

    let localTargetPoint: (CGPoint) -> CGPoint? = { quartzPoint in
      let cocoaGlobal = QuartzCocoaConversion.cocoaPoint(
        fromQuartz: quartzPoint, mainDisplayHeight: mainDisplayHeight)
      let local = CGPoint(
        x: cocoaGlobal.x - screen.frame.minX, y: cocoaGlobal.y - screen.frame.minY)
      guard screen.frame.width > 0, screen.frame.height > 0,
        local.x >= 0, local.x <= screen.frame.width,
        local.y >= 0, local.y <= screen.frame.height
      else { return nil }
      return CGPoint(x: local.x, y: screen.frame.height - local.y)
    }

    let hosting = NSHostingView(
      rootView: CalibrationOverlayView(
        coordinator: coordinator, localTargetPoint: localTargetPoint, showsSetup: showsSetup)
    )
    hosting.frame = CGRect(origin: .zero, size: screen.frame.size)
    window.contentView = hosting
    return window
  }
}
