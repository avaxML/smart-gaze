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
  private var actionItem: NSMenuItem!
  private var statusLineItem: NSMenuItem!

  private let settingsStore: SettingsStore =
    SettingsScreenshotHarness.isEnabled
    ? SettingsScreenshotHarness.makeSettingsStore() : UserDefaultsSettingsStore()
  private let secrets: any SecretStore & SecretPresence =
    SettingsScreenshotHarness.isEnabled
    ? SettingsScreenshotHarness.makeSecrets() : KeychainStore()
  private let camera = CameraController()
  private let captureActivity = CaptureActivity()
  private let bubble = BubbleController()
  private let reticle = ReticleController()
  private var settingsModel: SettingsModel!

  private var coordinator: GazeCoordinator?
  /// Bumped by every start and stop so a model load that finishes after a
  /// later stop does not wire a coordinator into a stopped session.
  private var pipelineGeneration = 0
  private var modifierMonitor: ModifierMonitor?
  private var accessibilityDegraded = false
  private var faceTurned = false
  private var accessibilityWatch: Timer?
  private var modelsMissing = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    let settings = settingsStore.load()
    let model = SettingsModel(store: settingsStore, secrets: secrets, settings: settings)
    settingsModel = model
    settingsWindowController = SettingsWindowController(model: model)
    LaunchDiagnostics.record(
      .providerKey,
      "\(settings.activeProvider.rawValue) \(model.hasStoredKey ? "present" : "absent")")

    configureMainMenu()
    configureStatusItem()

    captureActivity.onChange = { [weak self] in self?.refreshMenu() }
    camera.onChange = { [weak self] in
      LaunchDiagnostics.record(.cameraState, "\(String(describing: self?.camera.state))")
      self?.refreshMenu()
    }
    camera.onError = { [weak self] error in self?.presentCameraError(error) }
    settingsModel.onCalibrationChanged = { [weak self] in self?.calibrationDidChange() }
    settingsModel.onGazeSmoothingChanged = { [weak self] level in
      guard let coordinator = self?.coordinator else { return }
      Task { await coordinator.updateSmoothing(level: level) }
    }
    camera.onFrame = { [weak self] frame in self?.handleFrame(frame) }
    camera.onObservation = { [weak self] observation in self?.handleObservation(observation) }
    camera.onFocalLength = { [weak self] pixels in
      let detail = pixels.map { "present \($0)" } ?? "absent"
      LaunchDiagnostics.record(.intrinsicMatrix, detail)
      guard let pixels else { return }
      Task { await self?.coordinator?.updateVerticalFocalLength(pixels: pixels) }
    }
    refreshMenu()
    LaunchDiagnostics.record(.launchCompleted)
    if SettingsScreenshotHarness.isEnabled {
      Task { await SettingsScreenshotHarness.capture(windowController: settingsWindowController) }
    } else if LaunchDiagnostics.isEnabled {
      toggleCamera()
    }
  }

  private func handleFrame(_ frame: CameraFrame) {
    guard let coordinator else { return }
    let timestamp = ProcessInfo.processInfo.systemUptime
    Task { await coordinator.handleFrame(frame.pixelBuffer, at: timestamp) }
  }

  /// `camera.onFrame` and `camera.onObservation` both fire once per delivered
  /// video frame, from the same `AVCaptureVideoDataOutput` callback, so both
  /// are timestamped off the same clock the gaze samples already use rather
  /// than the sample buffer's own presentation time, keeping every input
  /// `TrackingPreview` sees on one monotonic timeline.
  private func handleObservation(_ observation: FaceObservation?) {
    guard let coordinator else { return }
    let timestamp = ProcessInfo.processInfo.systemUptime
    Task { await coordinator.handleObservation(observation, at: timestamp) }
  }

  /// Builds the coordinator and the modifier tap for this session. A missing
  /// Core ML model, or missing Accessibility permission, degrades rather
  /// than crashing: the reported condition still starts the camera, just
  /// without the leg that needs the missing piece.
  private func startGazePipeline() {
    // The two Core ML loads take the better part of a second. Done on the
    // main thread they stall the event tap past its deadline and macOS
    // switches it off, so they run detached and the wiring resumes here.
    pipelineGeneration += 1
    let generation = pipelineGeneration
    Task { [weak self] in
      let loaded = await Task.detached(priority: .userInitiated) {
        () -> Result<GazePipeline, Error> in
        Result {
          try GazePipeline(
            faceMeshModelURL: ModelLocator.faceMeshModelURL(),
            blazeGazeModelURL: ModelLocator.blazeGazeModelURL(),
            verticalFieldOfViewDegrees: CameraGeometry.builtInVerticalFieldOfViewDegrees)
        }
      }.value
      guard let self, self.pipelineGeneration == generation else { return }
      switch loaded {
      case .success(let pipeline):
        self.modelsMissing = false
        LaunchDiagnostics.record(.pipelineReady, "ok")
        self.finishStartingGazePipeline(pipeline)
      case .failure(let error):
        self.modelsMissing = true
        LaunchDiagnostics.record(.pipelineReady, "failed \(error)")
        self.finishStartingGazePipeline(nil)
      }
    }
  }

  private func finishStartingGazePipeline(_ pipeline: GazePipeline?) {
    let settings = settingsModel.settings

    // Without Accessibility the modifier is never seen, so the app stays in
    // the mode the user chose and fires nothing. Silently switching to dwell
    // here once turned a hold-to-ask app into one that captured on every
    // glance, and the user never knew why. The menu says what is missing.
    let needsAccessibility = settings.activationMode == .modifierHeld
    let accessibilityGranted = AXIsProcessTrusted()
    accessibilityDegraded = needsAccessibility && !accessibilityGranted
    if accessibilityDegraded {
      refreshMenu()
      watchForAccessibilityGrant()
    }

    let coordinator = GazeCoordinator(
      settings: settings,
      gazePipeline: pipeline,
      capturer: ScreenCaptureKitCapturer(denylist: settings.deniedApps),
      bubble: bubble,
      reticle: reticle,
      makeExplanationStream: { [weak settingsModel] jpeg in
        await MainActor.run { settingsModel?.makeExplanationStream(imageJPEG: jpeg) }
      })
    self.coordinator = coordinator
    faceTurned = false
    Task {
      await coordinator.setFaceTurnedHandler { [weak self] turned in
        Task { @MainActor in
          guard let self, self.faceTurned != turned else { return }
          self.faceTurned = turned
          self.refreshMenu()
        }
      }
      await coordinator.start()
    }

    LaunchDiagnostics.record(
      .modifier,
      "mode=\(settings.activationMode.rawValue) accessibility=\(accessibilityGranted ? "granted" : "denied")"
    )
    guard needsAccessibility, accessibilityGranted else { return }
    let monitor = ModifierMonitor(modifierKey: settings.modifierKey) { [weak self] down, time in
      guard let self else { return }
      LaunchDiagnostics.record(.modifier, down ? "down" : "up")
      Task {
        if down {
          await self.coordinator?.handleModifierDown(at: time)
        } else {
          await self.coordinator?.handleModifierUp(at: time)
        }
      }
    }
    if monitor.start() == .started {
      LaunchDiagnostics.record(.modifier, "tap started key=\(settings.modifierKey.rawValue)")
      modifierMonitor = monitor
    } else {
      LaunchDiagnostics.record(.modifier, "tap failed")
      accessibilityDegraded = true
      refreshMenu()
    }
  }

  /// The coordinator holds the calibration it was built with. A calibration
  /// finished while the camera is live must replace it, or the app keeps
  /// tracking on the old map, or on none at all when it started uncalibrated,
  /// and the modifier appears dead.
  private func calibrationDidChange() {
    if coordinator != nil {
      stopGazePipeline()
      startGazePipeline()
    }
    refreshMenu()
  }

  /// A grant made in System Settings does not notify the app. Poll the trust
  /// flag while degraded and rebuild the pipeline when it flips, so the user
  /// does not have to quit and relaunch after clicking the switch.
  private func watchForAccessibilityGrant() {
    accessibilityWatch?.invalidate()
    accessibilityWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, AXIsProcessTrusted() else { return }
        self.accessibilityWatch?.invalidate()
        self.accessibilityWatch = nil
        LaunchDiagnostics.record(.modifier, "accessibility granted while running")
        if self.coordinator != nil {
          self.stopGazePipeline()
          self.startGazePipeline()
        }
        self.refreshMenu()
      }
    }
  }

  private func stopGazePipeline() {
    pipelineGeneration += 1
    accessibilityWatch?.invalidate()
    accessibilityWatch = nil
    modifierMonitor?.stop()
    modifierMonitor = nil
    if let coordinator {
      Task { await coordinator.stop() }
    }
    coordinator = nil
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

    statusLineItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    statusLineItem.isEnabled = false
    menu.addItem(statusLineItem)

    captureCountItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    captureCountItem.isEnabled = false
    menu.addItem(captureCountItem)
    menu.addItem(.separator())

    startPauseItem = NSMenuItem(title: "Start", action: #selector(toggleCamera), keyEquivalent: "")
    startPauseItem.target = self
    menu.addItem(startPauseItem)

    actionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    actionItem.target = self
    actionItem.isHidden = true
    menu.addItem(actionItem)

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
    MenuBarState.presenting(
      camera: camera.state,
      calibrationNeeded: !settingsModel.hasCalibration,
      isCaptureBusy: captureActivity.isBusy,
      accessibilityDegraded: accessibilityDegraded, modelsMissing: modelsMissing,
      faceTurned: faceTurned)
  }

  private func refreshMenu() {
    let state = menuState
    let image = NSImage(
      systemSymbolName: state.symbolName,
      accessibilityDescription: state.accessibilityDescription)
    image?.isTemplate = true
    statusItem.button?.image = image

    statusLineItem.title = state.menuStatus
    captureCountItem.title = "Session captures: \(captureActivity.captureCount)"
    startPauseItem.title = camera.state == .off ? "Start" : "Pause"

    switch state {
    case .permissionDenied:
      actionItem.title = "Open Privacy Settings…"
      actionItem.action = #selector(openPrivacySettings)
      actionItem.isHidden = false
    case .uncalibrated:
      actionItem.title = "Calibrate Now"
      actionItem.action = #selector(calibrateNow)
      actionItem.isHidden = false
    case .timedOut:
      actionItem.title = "Open Privacy Settings…"
      actionItem.action = #selector(openPrivacySettings)
      actionItem.isHidden = false
    case .modelsMissing:
      actionItem.title = "Open Settings…"
      actionItem.action = #selector(openSettings)
      actionItem.isHidden = false
    case .cameraLive:
      actionItem.title = "Recalibrate…"
      actionItem.action = #selector(calibrateNow)
      actionItem.isHidden = false
    case .accessibilityDegraded:
      actionItem.title = "Open Accessibility Settings…"
      actionItem.action = #selector(openAccessibilitySettings)
      actionItem.isHidden = false
    default:
      actionItem.action = nil
      actionItem.isHidden = true
    }
  }

  @objc private func toggleCamera() {
    switch camera.state {
    case .off, .permissionDenied:
      startGazePipeline()
      Task { await camera.start() }
    case .waitingForPermission, .starting, .timedOut, .live:
      camera.pause()
      stopGazePipeline()
    }
  }

  @objc private func openSettings() {
    settingsWindowController.show()
  }

  @objc private func openPrivacySettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    else { return }
    NSWorkspace.shared.open(url)
  }

  @objc private func calibrateNow() {
    settingsWindowController.startCalibration()
  }

  @objc private func openAccessibilitySettings() {
    // The prompting variant registers the app in the Accessibility list so the
    // user only has to flip the switch, instead of finding the bundle by hand.
    // The key is the C constant `kAXTrustedCheckOptionPrompt`, spelled out
    // because the imported global is not concurrency-safe under Swift 6.
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    else { return }
    NSWorkspace.shared.open(url)
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
