import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import GazeKit
import OverlayUI
import Perception
import ScreenCapture

// `FaceObservation.leftEye` and `.rightEye` are Vision's own landmarks, built
// in `VisionMapping.imagePoint` relative to `VNFaceObservation.boundingBox`.
// That is the same full-image normalized space `FaceObservation.boundingBox`
// itself lives in, and it comes from a request Vision runs independently of
// `GazePipeline`'s face-mesh crop. `eyeAspectRatio` only needs both eyes in
// one consistent space, which this already is, so blink detection reads
// straight off `FaceObservation` and never touches `GazePipeline`'s
// crop-to-frame landmark mapping.

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
  /// Parameters come from `GazeSmoothing`, tuned on a 30 s live trace in
  /// screen points rather than the paper's normalised defaults, whose beta of
  /// 0.007 let ordinary jitter open the cutoff to several hertz.
  private var gazeFilter: OneEuroPointFilter
  private var reportedSessionOrigin = false
  private var traceSamplesLeft =
    ProcessInfo.processInfo.environment["SMART_GAZE_TRACE_GAZE"] == nil ? 0 : 900
  private var faceLoss = FaceLossDebounce()
  private var blinkDetector = BlinkDetector()
  private var squintDetector = SquintDetector()
  private var observationCount = 0
  private var headPose = HeadPoseGate()
  private let calibration: CalibrationMap?
  private let headTranslation: HeadTranslationCorrection?
  private let headRotation: HeadRotationCorrection?

  private let gazePipeline: GazePipeline?
  private let capturer: any RegionCapturing
  private let captureSize: CGSize
  private let bubbleSize: CGSize
  private let makeExplanationStream: @Sendable (Data) async -> AsyncThrowingStream<String, Error>?

  private let bubble: any BubblePresenting
  private let reticle: (any ReticlePresenting)?

  private var activeCaptureTask: Task<Void, Never>?
  private(set) var completedCaptureCount = 0
  private(set) var cancelledCaptureCount = 0
  private(set) var providerErrorCount = 0

  init(
    settings: Settings,
    gazePipeline: GazePipeline?,
    capturer: any RegionCapturing,
    bubble: any BubblePresenting,
    reticle: (any ReticlePresenting)? = nil,
    captureSize: CGSize = CGSize(width: 600, height: 400),
    makeExplanationStream:
      @escaping @Sendable (Data) async -> AsyncThrowingStream<
        String, Error
      >?
  ) {
    self.tracking = TrackingPreview(
      mode: settings.activationMode,
      cooldown: 3.0,
      bounds: GazeCoordinator.trackingBounds(
        calibrated: settings.calibratedBounds, fallback: GazeCoordinator.unionOfActiveDisplays()),
      dwellWindow: settings.dwellSeconds,
      dispersionThreshold: settings.dispersionThreshold)
    self.calibration = settings.calibrationMap
    self.gazeFilter = OneEuroPointFilter(smoothing: settings.gazeSmoothing)
    self.headTranslation = settings.headTranslationCorrection
    self.headRotation = settings.headRotationCorrection
    self.gazePipeline = gazePipeline
    self.capturer = capturer
    self.bubble = bubble
    self.reticle = reticle
    self.captureSize = captureSize
    self.bubbleSize = CGSize(width: settings.bubbleWidth, height: settings.bubbleMaxHeight)
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

  func updateSmoothing(level: Double) {
    gazeFilter = OneEuroPointFilter(smoothing: level)
  }

  func updateVerticalFocalLength(pixels: Double) async {
    await gazePipeline?.updateVerticalFocalLength(pixels: pixels)
  }

  // MARK: - Camera queue input

  func handleFrame(_ pixelBuffer: sending CVPixelBuffer, at timestamp: TimeInterval) async {
    guard let gazePipeline, let calibration else { return }
    do {
      let estimate = try await gazePipeline.gazePoint(from: pixelBuffer)
      faceLoss.recordSuccess()
      handleHeadYaw(estimate.headYawRadians)
      let projected = calibration.project(estimate.gaze)
      var screenPoint =
        headTranslation?.correct(projected, faceOriginCentimeters: estimate.faceOriginCentimeters)
        ?? projected
      if let headRotation {
        screenPoint = headRotation.correct(
          screenPoint, yawRadians: estimate.headYawRadians,
          pitchRadians: estimate.headPitchRadians)
      }
      let filtered = gazeFilter.apply(screenPoint, at: timestamp)
      if !reportedSessionOrigin {
        reportedSessionOrigin = true
        let reference = headTranslation?.referenceOriginCentimeters
        let offset = reference.map { estimate.faceOriginCentimeters - $0 }
        LaunchDiagnostics.record(
          .gaze,
          "session origin=\(estimate.faceOriginCentimeters) reference=\(String(describing: reference)) "
            + "offset cm=\(String(describing: offset))")
      }
      if traceSamplesLeft > 0 {
        traceSamplesLeft -= 1
        LaunchDiagnostics.record(
          .gaze,
          "t=\(timestamp) raw=(\(projected.x),\(projected.y)) corrected=(\(screenPoint.x),\(screenPoint.y)) "
            + "filtered=(\(filtered.x),\(filtered.y)) origin=(\(estimate.faceOriginCentimeters.x),\(estimate.faceOriginCentimeters.y),\(estimate.faceOriginCentimeters.z)) "
            + "yaw=\(estimate.headYawRadians) pitch=\(estimate.headPitchRadians)"
        )
      }
      await handleGazeSample(filtered, at: timestamp)
    } catch is CancellationError {
      return
    } catch {
      if faceLoss.recordFailure() {
        gazeFilter.reset()
        await apply(tracking.handle(.trackingLost(timestamp)))
      }
    }
  }

  /// Head yaw comes from the same landmarks the gaze estimate does, not from
  /// Vision's face yaw, which is quantised to 45 degree steps and would make
  /// the gate flip on one bucket boundary. Internal so a test can turn the
  /// head without a live pipeline.
  func handleHeadYaw(_ yawRadians: Double) {
    let wasBlocked = headPose.isBlocked
    headPose.update(yawRadians: yawRadians)
    if headPose.isBlocked != wasBlocked {
      onFaceTurnedChanged?(headPose.isBlocked)
    }
  }

  /// Fires when the head pose gate opens or closes, so the menu can say why
  /// a hold produces nothing. Set once from `AppDelegate`.
  private var onFaceTurnedChanged: (@Sendable (Bool) -> Void)?

  func setFaceTurnedHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
    onFaceTurnedChanged = handler
  }

  /// Feeds a resolved screen-space gaze point straight into tracking.
  /// Internal rather than private so a test can arm `TrackingPreview` (set
  /// `isTracking` and `lastGazePoint`) without a live `GazePipeline`, the
  /// way `apply` is exposed for driving capture behavior directly.
  func handleGazeSample(_ point: CGPoint, at timestamp: TimeInterval) async {
    // A turned head is treated like a lost face: the estimate the model
    // produces is off the calibrated display, and often off any display.
    if headPose.isBlocked {
      gazeFilter.reset()
      await apply(tracking.handle(.trackingLost(timestamp)))
      return
    }
    await apply(tracking.handle(.sample(point, timestamp)))
  }

  /// Turns a camera-queue face observation into a blink signal. Both eyes'
  /// landmarks come from `FaceObservation`, not `GazePipeline` (see the note
  /// at the top of this file), so this runs independently of whether the
  /// gaze pipeline itself produced an estimate this frame.
  func handleObservation(_ observation: FaceObservation?, at timestamp: TimeInterval) async {
    guard let observation else { return }
    observationCount += 1
    let left = eyeAspectRatio(observation.leftEye)
    let right = eyeAspectRatio(observation.rightEye)
    if let event = blinkDetector.add(left: left, right: right, at: timestamp) {
      await apply(tracking.handle(.blink(event, timestamp)))
    }
    if let event = squintDetector.add(left: left, right: right, at: timestamp) {
      switch event {
      case .started: LaunchDiagnostics.record(.gaze, "squint started")
      case .ended: LaunchDiagnostics.record(.gaze, "squint ended")
      }
      await apply(tracking.handle(.squint(event, timestamp)))
    }
    if observationCount % 30 == 0 {
      let baseline = squintDetector.openBaseline
      let narrowedBelow = SquintDetector.squintRatio * baseline
      LaunchDiagnostics.record(
        .gaze,
        "ear left=\(String(format: "%.3f", left)) right=\(String(format: "%.3f", right)) "
          + "baseline=\(String(format: "%.3f", baseline)) "
          + "narrowedBelow=\(String(format: "%.3f", narrowedBelow))")
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
      case .showReticle(let point):
        let size = captureSize
        await MainActor.run { [weak self] in self?.reticle?.show(centredOn: point, size: size) }
      case .hideReticle:
        await MainActor.run { [weak self] in self?.reticle?.hide() }
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
    tracking.handle(.presentationEnded(ProcessInfo.processInfo.systemUptime))
    guard activeCaptureTask != nil else { return }
    activeCaptureTask?.cancel()
    activeCaptureTask = nil
    cancelledCaptureCount += 1
  }

  private func runCapture(at point: CGPoint) async {
    LaunchDiagnostics.record(.capture, "fired at=(\(point.x),\(point.y))")
    let (displayID, localCenter) = GazeCoordinator.displayLocalPoint(for: point)
    let request = CaptureRequest(center: localCenter, size: captureSize, displayID: displayID)

    do {
      try Task.checkCancellation()
      let region = try await capturer.capture(request)
      try Task.checkCancellation()

      let capturedGlobal = region.rect.offsetBy(
        dx: CGDisplayBounds(displayID).minX, dy: CGDisplayBounds(displayID).minY)
      await MainActor.run { [weak self] in self?.reticle?.flash(capturedRect: capturedGlobal) }

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
      LaunchDiagnostics.record(.capture, "completed")
    } catch is CancellationError {
      LaunchDiagnostics.record(.capture, "cancelled")
      return
    } catch let error as CaptureError {
      LaunchDiagnostics.record(.capture, "failed \(error)")
      providerErrorCount += 1
      await presentError(GazeCoordinator.message(for: error), anchoredTo: point)
    } catch {
      LaunchDiagnostics.record(.capture, "failed \(error)")
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
    return bubble.show(anchoredTo: region, within: bounds, size: bubbleSize)
  }

  @MainActor
  private func presentError(_ message: String, anchoredTo globalQuartzPoint: CGPoint) {
    let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
    let point = QuartzCocoaConversion.cocoaPoint(
      fromQuartz: globalQuartzPoint, mainDisplayHeight: mainHeight)
    let region = CGRect(origin: point, size: .zero)
    let bounds = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
    // An error is one short sentence, so it takes the configured width but only
    // as much height as it needs rather than the full reading height.
    let handle = bubble.show(
      anchoredTo: region, within: bounds,
      size: CGSize(width: bubbleSize.width, height: min(bubbleSize.height, 160)))
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
  /// The calibration map is only valid on the display it was fitted on. A
  /// glance at another monitor projects outside that display and is rejected
  /// as out of bounds instead of dwelling somewhere the map never covered.
  /// The margin absorbs the map's edge error without letting the other
  /// display's centre through.
  nonisolated static func trackingBounds(
    calibrated: CGRect?, fallback: CGRect, margin: CGFloat = 150
  ) -> CGRect {
    guard let calibrated, !calibrated.isNull, !calibrated.isEmpty else { return fallback }
    return calibrated.insetBy(dx: -margin, dy: -margin)
  }

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
  /// Maps a global point onto the display that contains it, in that display's
  /// own coordinates. Split from the hardware query so the mapping can be
  /// tested against displays this machine does not have; on a single display
  /// at the origin, global and local coordinates are identical and the
  /// arithmetic is untestable.
  nonisolated static func displayLocalPoint(
    for globalPoint: CGPoint, displays: [(id: CGDirectDisplayID, bounds: CGRect)],
    fallback: (id: CGDirectDisplayID, bounds: CGRect)
  ) -> (displayID: CGDirectDisplayID, localPoint: CGPoint) {
    for display in displays where display.bounds.contains(globalPoint) {
      return (
        display.id,
        CGPoint(
          x: globalPoint.x - display.bounds.minX, y: globalPoint.y - display.bounds.minY)
      )
    }
    let clamped = CGPoint(
      x: min(max(globalPoint.x, fallback.bounds.minX), fallback.bounds.maxX),
      y: min(max(globalPoint.y, fallback.bounds.minY), fallback.bounds.maxY))
    return (
      fallback.id,
      CGPoint(x: clamped.x - fallback.bounds.minX, y: clamped.y - fallback.bounds.minY)
    )
  }

  nonisolated static func displayLocalPoint(for globalPoint: CGPoint) -> (
    displayID: CGDirectDisplayID, localPoint: CGPoint
  ) {
    var displays: [(id: CGDirectDisplayID, bounds: CGRect)] = []
    var displayCount: UInt32 = 0
    if CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 {
      var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
      if CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount) == .success {
        displays = displayIDs.map { ($0, CGDisplayBounds($0)) }
      }
    }
    let mainID = CGMainDisplayID()
    return displayLocalPoint(
      for: globalPoint, displays: displays, fallback: (mainID, CGDisplayBounds(mainID)))
  }
}
