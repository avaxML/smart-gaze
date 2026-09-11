import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import GazeKit
import OverlayUI
import Perception
import ScreenCapture

/// Owns the trigger state the camera queue and the main thread both feed, so
/// no external synchronization is needed between a modifier-key event and a
/// camera frame landing at the same moment.
///
/// This type performs effects. Every decision (when a dwell completes, when
/// a capture should fire, where the bubble goes) is made by the `GazeKit`
/// types it calls into; a policy question with no such owner belongs
/// upstream, not here.
///
/// Every point this actor produces or consumes for tracking, capture and
/// display lookup is in Quartz global display space (origin at the main
/// display's top-left, y increasing downward), matching `CGEvent`,
/// `CGDisplayBounds` and `ScreenCaptureKit`. `OverlayUI.BubbleController`
/// is AppKit, whose screen space is the same layout flipped about the main
/// display's height (origin bottom-left, y increasing upward); the boundary
/// between the two spaces is `GazeKit.QuartzCocoaConversion`, crossed only
/// right before a `BubblePresenting` call.
actor GazeCoordinator {
  private var tracking: TrackingPreview
  private var gazeFilter = OneEuroPointFilter()
  private var faceLoss = FaceLossDebounce()
  private let calibration: CalibrationMap?

  private let gazePipeline: GazePipeline?
  private let capturer: any RegionCapturing
  private let captureSize: CGSize
  private let makeExplanationStream: @Sendable (Data) async -> AsyncThrowingStream<String, Error>?

  private let bubble: any BubblePresenting

  private var activeCaptureTask: Task<Void, Never>?
  private(set) var completedCaptureCount = 0
  private(set) var cancelledCaptureCount = 0
  private(set) var providerErrorCount = 0

  init(
    settings: Settings,
    gazePipeline: GazePipeline?,
    capturer: any RegionCapturing,
    bubble: any BubblePresenting,
    captureSize: CGSize = CGSize(width: 600, height: 400),
    makeExplanationStream:
      @escaping @Sendable (Data) async -> AsyncThrowingStream<
        String, Error
      >?
  ) {
    self.tracking = TrackingPreview(
      mode: settings.activationMode,
      cooldown: 3.0,
      bounds: GazeCoordinator.unionOfActiveDisplays(),
      dwellWindow: settings.dwellSeconds,
      dispersionThreshold: settings.dispersionThreshold)
    self.calibration = settings.calibrationMap
    self.gazePipeline = gazePipeline
    self.capturer = capturer
    self.bubble = bubble
    self.captureSize = captureSize
    self.makeExplanationStream = makeExplanationStream
  }

  /// Wires the bubble's dismiss callback to this coordinator. Split out of
  /// `init` because assigning into a `@MainActor` stored property is itself
  /// an isolated operation.
  func start() async {
    await MainActor.run { [weak self] in
      self?.bubble.onDismiss = { [weak self] in
        Task { await self?.handleDismiss() }
      }
    }
  }

  func stop() async {
    activeCaptureTask?.cancel()
    activeCaptureTask = nil
    tracking.handle(.reset)
    await MainActor.run { [weak self] in
      self?.bubble.onDismiss = nil
      self?.bubble.dismiss()
    }
  }

  // MARK: - Camera queue input

  func handleFrame(_ pixelBuffer: sending CVPixelBuffer, at timestamp: TimeInterval) async {
    guard let gazePipeline, let calibration else { return }
    do {
      let gaze = try await gazePipeline.gazePoint(from: pixelBuffer)
      faceLoss.recordSuccess()
      let screenPoint = calibration.project(gaze)
      let filtered = gazeFilter.apply(screenPoint, at: timestamp)
      await apply(tracking.handle(.sample(filtered, timestamp)))
    } catch is CancellationError {
      return
    } catch {
      if faceLoss.recordFailure() {
        gazeFilter.reset()
        await apply(tracking.handle(.trackingLost(timestamp)))
      }
    }
  }

  // MARK: - Global modifier input

  func handleModifierDown(at timestamp: TimeInterval) async {
    await apply(tracking.handle(.modifierDown(timestamp)))
  }

  func handleModifierUp(at timestamp: TimeInterval) async {
    await apply(tracking.handle(.modifierUp(timestamp)))
  }

  // MARK: - Effects

  /// Internal rather than private so a test can drive capture suppression,
  /// dismiss-cancellation and provider-error surfacing directly, without a
  /// live camera or Core ML models.
  func apply(_ effects: [TriggerEffect]) async {
    for effect in effects {
      switch effect {
      case .capture(let point):
        beginCapture(at: point)
      case .dismissBubble:
        await MainActor.run { [weak self] in self?.bubble.dismiss() }
      case .showReticle, .hideReticle:
        // No reticle view exists yet in `OverlayUI`; nothing to render.
        continue
      }
    }
  }

  private func beginCapture(at point: CGPoint) {
    guard activeCaptureTask == nil else { return }

    activeCaptureTask = Task { [weak self] in
      guard let self else { return }
      await self.runCapture(at: point)
      await self.captureFinished()
    }
  }

  private func captureFinished() {
    activeCaptureTask = nil
  }

  /// Test-only: waits for a capture kicked off by `apply` to finish, since
  /// production code never blocks on it.
  func waitUntilCaptureSettled() async {
    await activeCaptureTask?.value
  }

  private func handleDismiss() {
    guard activeCaptureTask != nil else { return }
    activeCaptureTask?.cancel()
    activeCaptureTask = nil
    cancelledCaptureCount += 1
  }

  private func runCapture(at point: CGPoint) async {
    let (displayID, localCenter) = GazeCoordinator.displayLocalPoint(for: point)
    let request = CaptureRequest(center: localCenter, size: captureSize, displayID: displayID)

    do {
      try Task.checkCancellation()
      let region = try await capturer.capture(request)
      try Task.checkCancellation()

      let handle = await presentBubble(anchoredToDisplayLocal: region.rect, displayID: displayID)

      guard let stream = await makeExplanationStream(region.jpeg) else {
        await MainActor.run { [weak self] in
          self?.bubble.showError(
            "No provider is configured. Add an API key in Settings.", for: handle)
        }
        return
      }
      for try await token in stream {
        try Task.checkCancellation()
        await MainActor.run { [weak self] in self?.bubble.append(token, for: handle) }
      }
      // The stream can terminate normally as a consequence of cancellation, so
      // reaching the end of the loop is not by itself proof the capture completed.
      try Task.checkCancellation()
      await MainActor.run { [weak self] in self?.bubble.finish(for: handle) }
      completedCaptureCount += 1
    } catch is CancellationError {
      return
    } catch let error as CaptureError {
      providerErrorCount += 1
      await presentError(GazeCoordinator.message(for: error), anchoredTo: point)
    } catch {
      providerErrorCount += 1
      let message =
        (error as? LocalizedError)?.errorDescription ?? "The explanation could not be completed."
      await presentError(message, anchoredTo: point)
    }
  }

  @MainActor
  private func presentBubble(
    anchoredToDisplayLocal displayLocalRect: CGRect, displayID: CGDirectDisplayID
  ) -> PresentationHandle {
    let globalQuartzRect = displayLocalRect.offsetBy(
      dx: CGDisplayBounds(displayID).minX, dy: CGDisplayBounds(displayID).minY)
    let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
    let region = QuartzCocoaConversion.cocoaRect(
      fromQuartz: globalQuartzRect, mainDisplayHeight: mainHeight)
    let bounds = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
    return bubble.show(anchoredTo: region, within: bounds, size: CGSize(width: 360, height: 240))
  }

  @MainActor
  private func presentError(_ message: String, anchoredTo globalQuartzPoint: CGPoint) {
    let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
    let point = QuartzCocoaConversion.cocoaPoint(
      fromQuartz: globalQuartzPoint, mainDisplayHeight: mainHeight)
    let region = CGRect(origin: point, size: .zero)
    let bounds = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
    let handle = bubble.show(
      anchoredTo: region, within: bounds, size: CGSize(width: 360, height: 160))
    bubble.showError(message, for: handle)
  }

  private static func message(for error: CaptureError) -> String {
    switch error {
    case .suppressedApp: "Screen capture is disabled for the app in front."
    case .displayNotFound: "The display to capture could not be found."
    case .encodingFailed: "The captured region could not be encoded."
    }
  }

  // MARK: - Display geometry

  /// The union, in Quartz global display space, of every active display.
  /// Used as the tracking bounds so a gaze sample on a secondary display is
  /// not rejected as out of bounds.
  nonisolated static func unionOfActiveDisplays() -> CGRect {
    var displayCount: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
      return CGDisplayBounds(CGMainDisplayID())
    }
    var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    guard CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount) == .success else {
      return CGDisplayBounds(CGMainDisplayID())
    }
    return displayIDs.reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
  }

  /// Which active display contains `globalPoint`, and that point converted
  /// to the display's own local origin, as `ScreenCaptureKitCapturer`
  /// requires. Falls back to the main display, clamped to its bounds, for a
  /// point that lands in no display's bounds (e.g. rounding at a seam) or
  /// when the active display list cannot be enumerated at all.
  nonisolated static func displayLocalPoint(for globalPoint: CGPoint) -> (
    displayID: CGDirectDisplayID, localPoint: CGPoint
  ) {
    var displayCount: UInt32 = 0
    if CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 {
      var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
      if CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount) == .success {
        for displayID in displayIDs {
          let bounds = CGDisplayBounds(displayID)
          if bounds.contains(globalPoint) {
            return (
              displayID, CGPoint(x: globalPoint.x - bounds.minX, y: globalPoint.y - bounds.minY)
            )
          }
        }
      }
    }
    let mainID = CGMainDisplayID()
    let bounds = CGDisplayBounds(mainID)
    let clamped = CGPoint(
      x: min(max(globalPoint.x, bounds.minX), bounds.maxX),
      y: min(max(globalPoint.y, bounds.minY), bounds.maxY))
    return (mainID, CGPoint(x: clamped.x - bounds.minX, y: clamped.y - bounds.minY))
  }
}
