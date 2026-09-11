import AppKit
import ApplicationServices
import CoreVideo
import GazeKit
import OverlayUI
import Perception
import Providers
import ScreenCapture

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem!
  private var settingsWindowController: SettingsWindowController!
  private var startPauseItem: NSMenuItem!
  private var captureCountItem: NSMenuItem!

  private let settingsStore = UserDefaultsSettingsStore()
  private let secrets = KeychainStore()
  private let camera = CameraController()
  private let captureActivity = CaptureActivity()
  private let bubble = BubbleController()
  private var settingsModel: SettingsModel!

  private var coordinator: GazeCoordinator?
  private var modifierMonitor: ModifierMonitor?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    let settings = settingsStore.load()
    let model = SettingsModel(store: settingsStore, secrets: secrets, settings: settings)
    settingsModel = model
    settingsWindowController = SettingsWindowController(model: model)

    configureMainMenu()
    configureStatusItem()

    captureActivity.onChange = { [weak self] in self?.refreshMenu() }
    camera.onChange = { [weak self] in self?.refreshMenu() }
    camera.onError = { [weak self] error in self?.presentCameraError(error) }
    camera.onFrame = { [weak self] frame in self?.handleFrame(frame) }
    camera.onFieldOfView = { [weak self] degrees in
      Task { await self?.coordinator?.updateVerticalFieldOfView(degrees: degrees) }
    }
    refreshMenu()
  }

  private func handleFrame(_ frame: CameraFrame) {
    guard let coordinator else { return }
    let timestamp = ProcessInfo.processInfo.systemUptime
    Task { await coordinator.handleFrame(frame.pixelBuffer, at: timestamp) }
  }

  /// Builds the coordinator and the modifier tap for this session. A missing
  /// Core ML model, or missing Accessibility permission, degrades rather
  /// than crashing: the reported condition still starts the camera, just
  /// without the leg that needs the missing piece.
  private func startGazePipeline() {
    var settings = settingsModel.settings
    let pipeline: GazePipeline?
    do {
      pipeline = try GazePipeline(
        faceMeshModelURL: ModelLocator.faceMeshModelURL(),
        blazeGazeModelURL: ModelLocator.blazeGazeModelURL())
    } catch {
      pipeline = nil
    }

    // Checked before the coordinator is built so its `TrackingPreview` is
    // configured for the mode that will actually receive input, rather than
    // being built for `.modifierHeld` and then never hearing from it.
    let needsAccessibility = settings.activationMode == .modifierHeld
    let accessibilityGranted = AXIsProcessTrusted()
    if needsAccessibility && !accessibilityGranted {
      settings.activationMode = .passiveDwell
      presentAccessibilityDegradedAlert()
    }

    let coordinator = GazeCoordinator(
      settings: settings,
      gazePipeline: pipeline,
      capturer: ScreenCaptureKitCapturer(denylist: settings.deniedApps),
      bubble: bubble,
      makeExplanationStream: { [weak settingsModel] jpeg in
        await MainActor.run { settingsModel?.makeExplanationStream(imageJPEG: jpeg) }
      })
    self.coordinator = coordinator
    Task { await coordinator.start() }

    guard needsAccessibility, accessibilityGranted else { return }
    let monitor = ModifierMonitor(modifierKey: settings.modifierKey) { [weak self] down, time in
      guard let self else { return }
      Task {
        if down {
          await self.coordinator?.handleModifierDown(at: time)
        } else {
          await self.coordinator?.handleModifierUp(at: time)
        }
      }
    }
    if monitor.start() == .started {
      modifierMonitor = monitor
    } else {
      presentAccessibilityDegradedAlert()
    }
  }

  private func stopGazePipeline() {
    modifierMonitor?.stop()
    modifierMonitor = nil
    if let coordinator {
      Task { await coordinator.stop() }
    }
    coordinator = nil
  }

  private func presentAccessibilityDegradedAlert() {
    let alert = NSAlert()
    alert.messageText = "SmartGaze is running in dwell mode"
    alert.informativeText =
      "Accessibility permission is not granted, so the modifier key cannot be detected. Grant SmartGaze Accessibility access in System Settings › Privacy & Security to use hold-to-activate; until then, capture fires from a sustained gaze instead."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  private func configureMainMenu() {
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu()
    let settingsItem = NSMenuItem(
      title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    settingsItem.target = self
    appMenu.addItem(settingsItem)
    appMenu.addItem(.separator())
    let quitItem = NSMenuItem(title: "Quit SmartGaze", action: #selector(quit), keyEquivalent: "q")
    quitItem.target = self
    appMenu.addItem(quitItem)
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    // A standard Edit menu keeps copy/paste and select-all working in the
    // Settings text fields through the responder chain.
    let editMenuItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)

    NSApp.mainMenu = mainMenu
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    settingsWindowController.show()
    return false
  }

  private func configureStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    let menu = NSMenu()

    captureCountItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    captureCountItem.isEnabled = false
    menu.addItem(captureCountItem)
    menu.addItem(.separator())

    startPauseItem = NSMenuItem(title: "Start", action: #selector(toggleCamera), keyEquivalent: "")
    startPauseItem.target = self
    menu.addItem(startPauseItem)

    let settingsItem = NSMenuItem(
      title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
    settingsItem.target = self
    menu.addItem(settingsItem)

    menu.addItem(.separator())

    let quitItem = NSMenuItem(title: "Quit SmartGaze", action: #selector(quit), keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)

    statusItem.menu = menu
  }

  private var menuState: MenuBarState {
    if captureActivity.isBusy { return .captureBusy }
    switch camera.state {
    case .off: return .off
    case .starting: return .on
    case .live: return .cameraLive
    }
  }

  private func refreshMenu() {
    let state = menuState
    let image = NSImage(
      systemSymbolName: state.symbolName,
      accessibilityDescription: state.accessibilityDescription)
    image?.isTemplate = true
    statusItem.button?.image = image

    captureCountItem.title = "Session captures: \(captureActivity.captureCount)"
    startPauseItem.title = state == .off ? "Start" : "Pause"
  }

  @objc private func toggleCamera() {
    switch camera.state {
    case .off:
      startGazePipeline()
      Task { await camera.start() }
    case .starting, .live:
      camera.pause()
      stopGazePipeline()
    }
  }

  @objc private func openSettings() {
    settingsWindowController.show()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

  private func presentCameraError(_ error: Error) {
    let message: String
    switch error as? PerceptionError {
    case .cameraAccessDenied:
      message =
        "Camera access is denied. Grant SmartGaze camera access in System Settings, then try Start again."
    case .noCameraAvailable:
      message = "No camera is available on this Mac."
    case .cannotConfigureSession:
      message = "The camera session could not be configured."
    case nil:
      message = "The camera could not be started."
    }

    let alert = NSAlert()
    alert.messageText = "SmartGaze could not start the camera"
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}
