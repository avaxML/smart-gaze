import CoreVideo
import Foundation
import GazeKit
import Observation
import Perception

/// The one-frame-at-a-time view of the gaze pipeline the measurement needs.
/// `GazePipeline` conforms; a test substitutes a fake.
protocol FocalMeasurementPipeline: Sendable {
  func estimate(for frame: CameraFrame) async throws -> GazeEstimate
}

extension GazePipeline: FocalMeasurementPipeline {
  func estimate(for frame: CameraFrame) async throws -> GazeEstimate {
    try await gazePoint(from: frame.pixelBuffer)
  }
}

/// Measures one camera's focal length from the iris ruler at a known distance.
///
/// Modelled on `CalibrationCoordinator`: it owns a `CameraController` and a
/// pipeline for the single task, runs for up to four seconds, and finishes
/// with a `CameraFocalLength` or a reason it could not.
@MainActor
@Observable
final class FocalMeasurementCoordinator {
  enum Phase: Equatable {
    case idle
    case measuring(progress: Double)
    case done(CameraFocalLength, verticalFieldOfViewDegrees: Double)
    case failed(String)
  }

  static let measurementDuration: Duration = .seconds(4)

  private(set) var phase: Phase = .idle

  /// Called once when the measurement ends: the stored measurement, or `nil`
  /// when it failed.
  var onFinished: ((CameraFocalLength?) -> Void)?

  private let distanceCentimetres: Double
  private let camera: CameraController
  private let makePipeline: () throws -> any FocalMeasurementPipeline
  private let duration: Duration
  private let durationSeconds: TimeInterval
  private let sleep: @Sendable (Duration) async throws -> Void
  private let clock: () -> TimeInterval

  private var pipeline: (any FocalMeasurementPipeline)?
  private var timeoutTask: Task<Void, Never>?
  private var startedAt: TimeInterval = 0
  private var focalLengthsPixels: [Double] = []
  private var frameHeight: Double = 0
  private var isFinished = false

  init(
    distanceCentimetres: Double,
    camera: CameraController = CameraController(),
    makePipeline: (() throws -> any FocalMeasurementPipeline)? = nil,
    duration: Duration = FocalMeasurementCoordinator.measurementDuration,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.distanceCentimetres = SettingsRange.clampFinite(
      distanceCentimetres, to: SettingsRange.measurementDistanceCentimetres, fallback: 60)
    self.camera = camera
    self.makePipeline =
      makePipeline ?? {
        try GazePipeline(
          faceMeshModelURL: ModelLocator.faceMeshModelURL(),
          blazeGazeModelURL: ModelLocator.blazeGazeModelURL(),
          irisModelURL: ModelLocator.irisModelURLIfPresent(),
          verticalFieldOfViewDegrees: CameraGeometry.builtInVerticalFieldOfViewDegrees,
          interpupillaryCentimetres: defaultInterpupillaryCentimetres)
      }
    self.duration = duration
    self.durationSeconds = FocalMeasurementCoordinator.seconds(duration)
    self.sleep = sleep
    self.clock = clock
  }

  func start() async {
    guard !isFinished, timeoutTask == nil else { return }
    do {
      pipeline = try makePipeline()
    } catch {
      fail("The gaze model could not be loaded.")
      return
    }
    phase = .measuring(progress: 0)
    camera.onFrame = { [weak self] frame in self?.handleFrame(frame) }
    camera.onError = { [weak self] _ in self?.fail("The camera could not be started.") }
    startedAt = clock()
    await camera.start()
    guard !isFinished else { return }
    timeoutTask = Task { [weak self] in
      guard let self else { return }
      try? await self.sleep(self.duration)
      guard !Task.isCancelled else { return }
      self.finish()
    }
  }

  func cancel() {
    timeoutTask?.cancel()
    timeoutTask = nil
    isFinished = true
    camera.onFrame = nil
    camera.onError = nil
    camera.pause()
    phase = .idle
  }

  /// Appends one frame's iris reading. Internal so a test can drive the
  /// collector without a camera.
  func record(estimate: GazeEstimate, frameHeight: Double) {
    guard !isFinished, case .measuring = phase, let iris = estimate.iris else { return }
    guard frameHeight.isFinite, frameHeight > 0 else { return }
    if self.frameHeight == 0 {
      self.frameHeight = frameHeight
    }
    let meanDiameter =
      (iris.imageLeftEye.irisDiameterPixels + iris.imageRightEye.irisDiameterPixels) / 2
    guard
      let focalLength = FocalLengthCalibration.focalLengthPixels(
        irisDiameterPixels: meanDiameter, distanceCentimetres: distanceCentimetres)
    else { return }
    focalLengthsPixels.append(focalLength)
    let elapsed = clock() - startedAt
    let progress = durationSeconds > 0 ? min(1, max(0, elapsed / durationSeconds)) : 1
    phase = .measuring(progress: progress)
  }

  /// Ends collection and fits. Internal so a test can end the window without
  /// waiting out the timer.
  func finish() {
    guard !isFinished, case .measuring = phase else { return }
    let cameraID = camera.cameraID
    let cameraName = camera.cameraName
    stopCamera()
    let height = frameHeight
    guard height > 0 else {
      fail("No camera frames arrived.")
      return
    }
    guard
      let focalLength = FocalLengthCalibration.fit(
        focalLengthsPixels: focalLengthsPixels, frameHeight: height)
    else {
      fail("The measurement was not consistent. Try again in even light.")
      return
    }
    guard let cameraID, let cameraName else {
      fail("The camera could not be identified.")
      return
    }
    guard
      let fieldOfViewDegrees = FocalLengthCalibration.verticalFieldOfViewDegrees(
        focalLengthPixels: focalLength, frameHeight: height)
    else {
      fail("The measurement was not consistent. Try again in even light.")
      return
    }
    let measurement = CameraFocalLength(
      cameraID: cameraID, cameraName: cameraName,
      focalLengthPerFrameHeight: focalLength / height)
    isFinished = true
    phase = .done(measurement, verticalFieldOfViewDegrees: fieldOfViewDegrees)
    onFinished?(measurement)
  }

  private func handleFrame(_ frame: CameraFrame) {
    guard let pipeline, !isFinished, case .measuring = phase else { return }
    let height = Double(CVPixelBufferGetHeight(frame.pixelBuffer))
    Task { [weak self] in
      guard let self else { return }
      guard let estimate = try? await pipeline.estimate(for: frame) else { return }
      self.record(estimate: estimate, frameHeight: height)
    }
  }

  private func stopCamera() {
    timeoutTask?.cancel()
    timeoutTask = nil
    camera.onFrame = nil
    camera.onError = nil
    camera.pause()
  }

  private func fail(_ message: String) {
    guard !isFinished else { return }
    isFinished = true
    stopCamera()
    phase = .failed(message)
    onFinished?(nil)
  }

  private static func seconds(_ duration: Duration) -> TimeInterval {
    let components = duration.components
    return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
  }
}
