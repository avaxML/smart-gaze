import AppKit
import CoreGraphics
import Foundation
import GazeKit
import Observation
import Providers

/// A local key command that simulates a trigger gesture while the preview is
/// active.
enum SimulationCommand: Equatable, Sendable {
  case singleBlink
  case doubleBlink
  case squint
}

/// Everything the preview needs that does not live in `Settings`.
struct CalibrationPreviewConfiguration {
  var activationMode: ActivationMode = .modifierHeld
  var dwellSeconds: TimeInterval = 0.6
  var dispersionThreshold: Double = 160
  var cooldown: TimeInterval = 3.0
  var bounds: CGRect = CGRect(x: 0, y: 0, width: 640, height: 400)
  var liveSampleSourceAvailable: Bool = false
  var sampleTitle: String = "Sample code"
  var sampleCode: String = """
    let values = [1, 2, 3]
    let total = values.reduce(0, +)
    """
}

/// Renders only the visible sample code to an in-memory JPEG. No desktop
/// capture, nothing written to disk.
enum SampleCodeRenderer {
  @MainActor
  static func renderJPEG(
    code: String, size: CGSize = CGSize(width: 720, height: 420)
  ) -> Data? {
    guard size.width > 0, size.height > 0,
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width),
        pixelsHigh: Int(size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
      .foregroundColor: NSColor.black,
    ]
    let inset = NSRect(
      x: 20, y: 20, width: size.width - 40, height: size.height - 40)
    (code as NSString).draw(in: inset, withAttributes: attributes)
    return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
  }
}

@MainActor
@Observable
final class CalibrationPreviewModel {
  enum Source: String, CaseIterable, Identifiable, Hashable {
    case live
    case pointerSimulation

    var id: String { rawValue }

    var title: String {
      switch self {
      case .live: "Live tracking"
      case .pointerSimulation: "Pointer simulation"
      }
    }
  }

  enum ExplanationState: Equatable {
    case idle
    case loading
    case loaded(String)
    case failed(String)
  }

  private(set) var configuration: CalibrationPreviewConfiguration
  private(set) var tracking: TrackingPreview

  private(set) var selectedSource: Source = .pointerSimulation
  var liveSampleSourceAvailable: Bool
  private(set) var isPointerSimulationEnabled = false
  private(set) var simulatedModifierHeld = false
  private(set) var isPreviewPresented = false

  var explanation: ExplanationState = .idle
  private(set) var targetCenter: CGPoint?

  /// Set by `SettingsWindowController`, which owns the window-level plumbing
  /// a calibration run needs (its own non-activating windows and screens).
  var onStartCalibration: (() -> Void)?

  func startCalibration() { onStartCalibration?() }

  let sampleTitle: String
  let sampleCode: String

  private var settings: SettingsModel?
  private let renderSampleCode: (String) -> Data?
  private let clock: () -> TimeInterval
  private let automaticallySamplesPointer: Bool

  private var pointerTask: Task<Void, Never>?
  private(set) var explanationTask: Task<Void, Never>?
  private var explanationGeneration = 0
  private var latestHoverPoint: CGPoint?
  private var isHoveringTarget = false

  init(
    configuration: CalibrationPreviewConfiguration = CalibrationPreviewConfiguration(),
    settings: SettingsModel? = nil,
    renderSampleCode: @escaping (String) -> Data? = { SampleCodeRenderer.renderJPEG(code: $0) },
    clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    automaticallySamplesPointer: Bool = true
  ) {
    self.configuration = configuration
    self.tracking = TrackingPreview(
      mode: configuration.activationMode,
      cooldown: configuration.cooldown,
      bounds: configuration.bounds,
      dwellWindow: configuration.dwellSeconds,
      dispersionThreshold: configuration.dispersionThreshold
    )
    self.liveSampleSourceAvailable = configuration.liveSampleSourceAvailable
    self.sampleTitle = configuration.sampleTitle
    self.sampleCode = configuration.sampleCode
    self.settings = settings
    self.renderSampleCode = renderSampleCode
    self.clock = clock
    self.automaticallySamplesPointer = automaticallySamplesPointer
  }

  var mode: ActivationMode { tracking.mode }
  var dwellSeconds: TimeInterval { tracking.dwellWindow }
  var dispersionThreshold: Double { tracking.dispersionThreshold }

  /// Called on tab open and relevant `Settings` changes. It always cancels an
  /// in-flight explanation and rebuilds when the pipeline config moved.
  func applyConfiguration(from settings: Settings, forceReset: Bool = false) {
    cancelExplanation()
    let modeChanged =
      settings.activationMode != configuration.activationMode
      || settings.dwellSeconds != configuration.dwellSeconds
      || settings.dispersionThreshold != configuration.dispersionThreshold
    guard forceReset || modeChanged else { return }
    configuration.activationMode = settings.activationMode
    configuration.dwellSeconds = settings.dwellSeconds
    configuration.dispersionThreshold = settings.dispersionThreshold
    simulatedModifierHeld = false
    isHoveringTarget = false
    latestHoverPoint = nil
    rebuildTracking()
  }

  /// Enters the preview tab. Sampling only starts here, never from a plain
  /// window show, so a previously enabled simulation cannot resume while the
  /// General tab is in front.
  func prepareForPresentation(from settings: SettingsModel) {
    self.settings = settings
    isPreviewPresented = true
    applyConfiguration(from: settings.settings, forceReset: true)
    reconcilePointerSampling()
  }

  /// Tab exit / window close: stop all work and drop stale state.
  func stop() {
    isPreviewPresented = false
    stopPointerSampling()
    cancelExplanation()
    simulatedModifierHeld = false
    isHoveringTarget = false
    latestHoverPoint = nil
    tracking.handle(.reset)
  }

  /// The rendered target area drives the bounds used to reject samples.
  func updateTargetSize(_ size: CGSize) {
    guard size.width > 0, size.height > 0 else { return }
    targetCenter = CGPoint(x: size.width / 2, y: size.height / 2)
    let rect = CGRect(origin: .zero, size: size)
    guard rect != configuration.bounds else { return }
    configuration.bounds = rect
    cancelExplanation()
    rebuildTracking()
  }

  func selectSource(_ source: Source) {
    guard selectedSource != source else { return }
    selectedSource = source
    cancelExplanation()
    simulatedModifierHeld = false
    isHoveringTarget = false
    latestHoverPoint = nil
    if source == .live {
      isPointerSimulationEnabled = false
    }
    tracking.handle(.reset)
    reconcilePointerSampling()
  }

  func setPointerSimulationEnabled(_ enabled: Bool) {
    if enabled {
      selectedSource = .pointerSimulation
      isPointerSimulationEnabled = true
      cancelExplanation()
      tracking.handle(.reset)
    } else {
      isPointerSimulationEnabled = false
      simulatedModifierHeld = false
      isHoveringTarget = false
      latestHoverPoint = nil
      cancelExplanation()
      tracking.handle(.reset)
    }
    reconcilePointerSampling()
  }

  /// Live camera samples. A no-op until a real source is connected.
  func ingest(_ input: TrackingPreviewInput) {
    guard selectedSource == .live, liveSampleSourceAvailable else { return }
    tracking.handle(input)
  }

  /// The latest actual hovered position, sampled on a bounded 30 Hz task while
  /// the pointer stays over the target. No synthetic motion.
  func pointerHovered(at point: CGPoint) {
    guard isPointerSimulationEnabled else { return }
    latestHoverPoint = point
    isHoveringTarget = true
  }

  func pointerExited() {
    guard isPointerSimulationEnabled else { return }
    isHoveringTarget = false
    latestHoverPoint = nil
    tracking.handle(.trackingLost(clock()))
    // An explicit simulated hold survives the pointer leaving; it only becomes
    // a capture when a later fresh sample is on the target.
    if simulatedModifierHeld { tracking.handle(.modifierDown(clock())) }
  }

  func advancePointerSimulation() {
    guard isPointerSimulationEnabled, isHoveringTarget, let point = latestHoverPoint else { return }
    tracking.handle(.sample(point, clock()))
  }

  func beginSimulatedModifierHold() {
    guard isPointerSimulationEnabled else { return }
    simulatedModifierHeld = true
    tracking.handle(.modifierDown(clock()))
  }

  func endSimulatedModifierHold() {
    guard isPointerSimulationEnabled else { return }
    simulatedModifierHeld = false
    tracking.handle(.modifierUp(clock()))
  }

  func simulateBlink(_ event: BlinkEvent) {
    guard isPointerSimulationEnabled else { return }
    tracking.handle(.blink(event, clock()))
  }

  func simulateSquint() {
    guard isPointerSimulationEnabled else { return }
    tracking.handle(.squint(clock()))
  }

  func resetPreview() {
    simulatedModifierHeld = false
    isHoveringTarget = false
    latestHoverPoint = nil
    cancelExplanation()
    tracking.handle(.reset)
  }

  /// The selected modifier key from `Settings`, Option until one is available.
  var modifierKey: ModifierKey { settings?.settings.modifierKey ?? .option }

  var modifierKeyName: String { modifierKey.rawValue.capitalized }

  /// True only while the preview tab is in front and pointer simulation is on.
  /// The local event monitor is installed from this, so it never eats keys on
  /// any other tab.
  var isSimulationInputActive: Bool {
    isPreviewPresented && selectedSource == .pointerSimulation && isPointerSimulationEnabled
  }

  /// Local key-bridge entry point. Returns whether the event should be
  /// swallowed. It only acts in an active simulation, so normal editing and
  /// other tabs keep receiving their keys.
  func handleModifierStateChange(pressed: Bool) -> Bool {
    guard isSimulationInputActive, mode == .modifierHeld else { return false }
    if pressed {
      guard isHoveringTarget, !simulatedModifierHeld else { return false }
      beginSimulatedModifierHold()
      return true
    }
    guard simulatedModifierHeld else { return false }
    endSimulatedModifierHold()
    return true
  }

  /// Local key-bridge entry point for `B`/`D` in double-blink mode and `S` in
  /// squint mode.
  func handleSimulationCommand(_ command: SimulationCommand) -> Bool {
    guard isSimulationInputActive, isHoveringTarget else { return false }
    switch (mode, command) {
    case (.doubleBlink, .singleBlink): simulateBlink(.blink)
    case (.doubleBlink, .doubleBlink): simulateBlink(.doubleBlink)
    case (.squint, .squint): simulateSquint()
    default: return false
    }
    return true
  }

  private func reconcilePointerSampling() {
    guard isPreviewPresented, isPointerSimulationEnabled, selectedSource == .pointerSimulation
    else {
      stopPointerSampling()
      return
    }
    startPointerSampling()
  }

  private func startPointerSampling() {
    stopPointerSampling()
    guard automaticallySamplesPointer else { return }
    pointerTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(33))
        guard let self, !Task.isCancelled else { return }
        self.advancePointerSimulation()
      }
    }
  }

  private func stopPointerSampling() {
    pointerTask?.cancel()
    pointerTask = nil
  }

  private func rebuildTracking() {
    tracking = TrackingPreview(
      mode: configuration.activationMode,
      cooldown: configuration.cooldown,
      bounds: configuration.bounds,
      dwellWindow: configuration.dwellSeconds,
      dispersionThreshold: configuration.dispersionThreshold
    )
  }

  var isExplanationAvailable: Bool { settings?.isProviderReady ?? false }

  var explanationAvailabilityMessage: String? {
    isExplanationAvailable
      ? nil : "Configure a provider in the Provider tab to test an explanation."
  }

  /// True from the first request until the stream terminates or is cancelled.
  /// It deliberately does not depend on `explanation`, which becomes `.loaded`
  /// at the first delta: Cancel and the duplicate-request guard depend on this.
  var isExplanationLoading: Bool { explanationTask != nil }

  /// Exactly one provider request per explicit activation. Local preview
  /// triggers never call this path.
  func requestTestExplanation() {
    guard explanationTask == nil else { return }
    cancelExplanation()
    guard let settings, settings.isProviderReady else {
      explanation = .failed("Configure a provider in the Provider tab first.")
      return
    }
    guard let jpeg = renderSampleCode(sampleCode) else {
      explanation = .failed("The sample code could not be rendered.")
      return
    }
    guard let stream = settings.makeExplanationStream(imageJPEG: jpeg) else {
      explanation = .failed("Configure a provider in the Provider tab first.")
      return
    }
    explanationGeneration += 1
    let token = explanationGeneration
    explanation = .loading
    explanationTask = Task { [weak self] in
      var text = ""
      defer {
        // Only the stream that still owns the generation may clear the task,
        // so a cancelled stream cannot reopen the guard for a newer one.
        if let self, token == self.explanationGeneration {
          self.explanationTask = nil
        }
      }
      do {
        for try await delta in stream {
          guard let self, !Task.isCancelled, token == self.explanationGeneration else { return }
          text += delta
          self.explanation = .loaded(text)
        }
      } catch is CancellationError {
        return
      } catch let error as ProviderError {
        guard let self, token == self.explanationGeneration else { return }
        self.explanation = .failed(error.localizedDescription)
        return
      } catch {
        guard let self, token == self.explanationGeneration else { return }
        self.explanation = .failed("The provider could not be reached.")
        return
      }
      guard let self, token == self.explanationGeneration else { return }
      if text.isEmpty { self.explanation = .failed("The provider returned no text.") }
    }
  }

  func cancelExplanation() {
    explanationGeneration += 1
    explanationTask?.cancel()
    explanationTask = nil
    if explanation != .idle { explanation = .idle }
  }

  var measuredTargetError: Double? {
    guard selectedSource == .live, tracking.isTracking,
      let gaze = tracking.lastGazePoint, let target = targetCenter
    else { return nil }
    return ((gaze.x - target.x) * (gaze.x - target.x) + (gaze.y - target.y) * (gaze.y - target.y))
      .squareRoot()
  }

  var markerPoint: CGPoint? {
    switch selectedSource {
    case .live:
      return (liveSampleSourceAvailable && tracking.isTracking) ? tracking.lastGazePoint : nil
    case .pointerSimulation:
      return (isPointerSimulationEnabled && tracking.isTracking) ? tracking.lastGazePoint : nil
    }
  }

  var triggerStateDescription: String {
    switch tracking.state {
    case .idle: "idle"
    case .settling: "waiting for a valid gaze sample"
    case .armed: "armed - release to capture"
    case .firing: "captured"
    case .cooldown: "cooldown"
    }
  }

  var isLiveTrackingAvailable: Bool { liveSampleSourceAvailable }

  var calibrationStatusMessage: String {
    guard let settings, settings.hasCalibration else {
      return "No calibration is saved yet. Live gaze tracking is uncalibrated until you run one."
    }
    if let distance = settings.settings.calibrationDistanceCentimeters {
      return String(
        format:
          "Calibrated at %.0f cm from the screen. Recalibrate if you move, add glasses, or switch monitors.",
        distance)
    }
    return "A calibration is saved. Recalibrate if you move, add glasses, or switch monitors."
  }
}
