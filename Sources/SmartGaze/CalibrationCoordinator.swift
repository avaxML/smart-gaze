import AppKit
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import GazeKit
import Perception
import QuartzCore

/// What the calibration window shows right now. `CalibrationRun` decides the
/// target sequence and whether a burst is good enough; this only tracks the
/// timing state a real camera and a human eye need that the pure run does not:
/// settling before a burst starts, and collecting the burst itself.
@MainActor
@Observable
final class CalibrationCoordinator {
  enum Phase: Equatable {
    case preparing
    case setup(CalibrationSetupGuidance)
    case unavailable(String)
    case settling(target: CGPoint)
    case collecting(target: CGPoint)
    case retrying(target: CGPoint)
    case completed(CalibrationResult)
    case failed(String)
    case aborted
  }

  private(set) var phase: Phase = .preparing
  private(set) var progress: (completed: Int, total: Int) = (0, 0)
  private(set) var setupFace: CalibrationSetupFace?
  private(set) var setupImage: CGImage?
  private(set) var frameSize: CGSize = .zero

  var onFinished: ((CalibrationResult?) -> Void)?

  private let bounds: CGRect
  private let makePipeline: () throws -> GazePipeline
  private let camera: CameraController
  let settleDuration: Duration
  let burstDuration: Duration
  private let dispersionThreshold: Double
  private let maxErrorPoints: Double

  private var pipeline: GazePipeline?
  private var run: CalibrationRun?
  private var runTask: Task<Void, Never>?
  private var bufferedGaze: [NormalizedGazePoint] = []
  private var frameCount = 0
  private var gazeCount = 0
  private var gazeErrorCount = 0
  private var latestDistanceCentimeters: Double?
  private var latestFaceOrigin: SIMD3<Double>?
  private var latestHeadPose: (yaw: Double, pitch: Double)?
  private var latestImpliedInterpupillary: Double?
  private var setupReducer = CalibrationSetupReducer()
  private let ciContext = CIContext()

  init(
    bounds: CGRect,
    interpupillaryCentimetres: Double? = nil,
    makePipeline: (() throws -> GazePipeline)? = nil,
    camera: CameraController = CameraController(),
    settleDuration: Duration = .milliseconds(700),
    burstDuration: Duration = .milliseconds(500),
    // Measured on the first live run: held-gaze bursts spread 0.11 to 0.22
    // normalized, and the saccade to find a new dot spread 0.57. The gate must
    // sit between those. 0.08 rejected every real fixation and retried forever.
    dispersionThreshold: Double = 0.25,
    maxErrorPoints: Double = 120
  ) {
    self.bounds = bounds
    self.makePipeline =
      makePipeline ?? {
        try GazePipeline(
          faceMeshModelURL: ModelLocator.faceMeshModelURL(),
          blazeGazeModelURL: ModelLocator.blazeGazeModelURL(),
          irisModelURL: ModelLocator.irisModelURLIfPresent(),
          verticalFieldOfViewDegrees: CameraGeometry.builtInVerticalFieldOfViewDegrees,
          interpupillaryCentimetres: interpupillaryCentimetres ?? defaultInterpupillaryCentimetres)
      }
    self.camera = camera
    self.settleDuration = settleDuration
    self.burstDuration = burstDuration
    self.dispersionThreshold = dispersionThreshold
    self.maxErrorPoints = maxErrorPoints
  }

  var exceedsAcceptableError: Bool {
    guard case .completed(let result) = phase else { return false }
    return result.horizontalErrorPoints > maxErrorPoints
      || result.verticalErrorPoints > maxErrorPoints
  }

  /// Maps one pipeline reading onto the setup visor's face. Pure so a test can
  /// exercise the mapping without a camera or an actor hop.
  nonisolated static func setupFace(from estimate: GazeEstimate) -> CalibrationSetupFace {
    CalibrationSetupFace(
      mesh: estimate.meshLandmarks,
      imageLeftEyeContour: estimate.iris?.imageLeftEye.contour ?? [],
      imageRightEyeContour: estimate.iris?.imageRightEye.contour ?? [],
      imageLeftIris: estimate.iris?.imageLeftEye.irisPoints ?? [],
      imageRightIris: estimate.iris?.imageRightEye.irisPoints ?? [],
      depthCentimetres: estimate.iris?.depthCentimetres ?? estimate.faceDistanceCentimeters)
  }

  func start() {
    guard runTask == nil else { return }
    phase = .preparing
    do {
      pipeline = try makePipeline()
    } catch {
      phase = .unavailable("The gaze model could not be loaded.")
      return
    }

    camera.onFrame = { [weak self] frame in self?.handleFrame(frame) }
    camera.onError = { [weak self] _ in
      self?.phase = .unavailable("The camera could not be started.")
    }

    let plan = CalibrationTargetPlan()
    run = CalibrationRun(
      plan: plan, bounds: bounds, dispersionThreshold: dispersionThreshold,
      distanceCentimeters: 0)
    progress = (0, plan.fitTargets.count + plan.validationTargets.count)

    runTask = Task { [weak self] in
      await self?.camera.start()
      await self?.runLoop()
    }
  }

  func abort() {
    runTask?.cancel()
    runTask = nil
    run?.abort()
    stopCamera()
    phase = .aborted
    onFinished?(nil)
  }

  private func runLoop() async {
    phase = .setup(.findingFace)
    while !Task.isCancelled {
      if case .setup(.ready) = phase { break }
      try? await Task.sleep(for: .milliseconds(50))
    }
    if Task.isCancelled { return }
    try? await Task.sleep(for: .milliseconds(600))
    if Task.isCancelled { return }
    setupFace = nil
    setupImage = nil

    while !Task.isCancelled {
      guard var currentRun = run, let target = currentRun.currentTargetScreenPoint else { break }

      phase = .settling(target: target)
      LaunchDiagnostics.record(.calibration, "settling frames=\(frameCount) gaze=\(gazeCount)")
      try? await Task.sleep(for: settleDuration)
      if Task.isCancelled { return }

      phase = .collecting(target: target)
      bufferedGaze = []
      try? await Task.sleep(for: burstDuration)
      if Task.isCancelled { return }

      let samples = bufferedGaze
      LaunchDiagnostics.record(
        .calibration, "burst samples=\(samples.count) frames=\(frameCount) gaze=\(gazeCount)")
      if let latestDistanceCentimeters {
        currentRun.recordDistance(latestDistanceCentimeters)
      }
      if let latestFaceOrigin {
        currentRun.recordFaceOrigin(latestFaceOrigin)
        LaunchDiagnostics.record(
          .calibration,
          "origin cm=(\(latestFaceOrigin.x),\(latestFaceOrigin.y),\(latestFaceOrigin.z)) "
            + "yaw=\(latestHeadPose?.yaw ?? .nan) pitch=\(latestHeadPose?.pitch ?? .nan)")
      }
      if let latestImpliedInterpupillary {
        currentRun.recordImpliedInterpupillary(latestImpliedInterpupillary)
      }
      let outcome = currentRun.submitBurst(samples)
      if !samples.isEmpty {
        let cx = samples.map(\.x).reduce(0, +) / Double(samples.count)
        let cy = samples.map(\.y).reduce(0, +) / Double(samples.count)
        LaunchDiagnostics.record(
          .calibration,
          "sample target=(\(target.x),\(target.y)) gaze=(\(cx),\(cy)) n=\(samples.count)")
      }
      run = currentRun

      switch outcome {
      case .retryTarget(let dispersion):
        LaunchDiagnostics.record(.calibration, "retry dispersion=\(dispersion)")
        phase = .retrying(target: target)
        try? await Task.sleep(for: .milliseconds(400))
      case .advancedToNextFitTarget, .advancedToNextValidationTarget:
        progress.completed += 1
      case .completed(let result):
        LaunchDiagnostics.record(
          .calibration,
          "completed hErr=\(result.horizontalErrorPoints) vErr=\(result.verticalErrorPoints) dispersion=\(result.observedDispersionPoints) bursts=\(result.acceptedBurstCount) x=\(result.map.xCoefficients) y=\(result.map.yCoefficients)"
        )
        LaunchDiagnostics.record(
          .calibration,
          "interpupillary cm=\(result.interpupillaryCentimetres.map { String($0) } ?? "nil")")
        progress.completed = progress.total
        finish(with: result)
        return
      case .solveFailed:
        phase = .failed(
          "Calibration could not be solved from these points. Try again with a steadier gaze.")
        stopCamera()
        onFinished?(nil)
        return
      }
    }
  }

  private func finish(with result: CalibrationResult) {
    stopCamera()
    phase = .completed(result)
    onFinished?(result)
  }

  private func stopCamera() {
    camera.onFrame = nil
    camera.onError = nil
    camera.pause()
    runTask = nil
  }

  private func handleFrame(_ frame: CameraFrame) {
    guard let pipeline else { return }
    frameCount += 1
    if frameSize == .zero {
      frameSize = CGSize(
        width: CVPixelBufferGetWidth(frame.pixelBuffer),
        height: CVPixelBufferGetHeight(frame.pixelBuffer))
    }
    var captureSetupImage = false
    if case .setup = phase, frameCount % 3 == 0 {
      captureSetupImage = true
    }
    Task { [weak self] in
      guard let self else { return }
      if captureSetupImage, let image = self.setupPreviewImage(from: frame.pixelBuffer) {
        self.setupImage = image
      }
      do {
        let estimate = try await pipeline.gazePoint(from: frame.pixelBuffer)
        self.gazeCount += 1
        self.bufferedGaze.append(estimate.gaze)
        self.latestDistanceCentimeters = estimate.faceDistanceCentimeters
        self.latestFaceOrigin = estimate.faceOriginCentimeters
        self.latestHeadPose = (estimate.headYawRadians, estimate.headPitchRadians)
        if let iris = estimate.iris,
          let implied = InterpupillaryFit.impliedCentimetres(
            irisDepthCentimetres: iris.depthCentimetres,
            baselineDepthCentimetres: estimate.faceDistanceCentimeters,
            assumedCentimetres: estimate.assumedInterpupillaryCentimetres)
        {
          self.latestImpliedInterpupillary = implied
        }
        if case .setup = self.phase {
          let face = Self.setupFace(from: estimate)
          self.setupFace = face
          self.phase = .setup(
            self.setupReducer.update(face: face, at: CACurrentMediaTime()))
        }
      } catch {
        self.gazeErrorCount += 1
        if self.gazeErrorCount <= 5 {
          LaunchDiagnostics.record(.calibration, "gaze error \(self.gazeErrorCount): \(error)")
        }
        if case .setup = self.phase {
          self.setupFace = nil
          self.phase = .setup(
            self.setupReducer.update(face: nil, at: CACurrentMediaTime()))
        }
      }
    }
  }

  /// A downscaled still of the current frame for the setup visor. The view only
  /// needs a preview, so the longer side is capped and the still is refreshed
  /// on a fraction of frames rather than every frame the pipeline reads.
  private func setupPreviewImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
    let source = CIImage(cvPixelBuffer: pixelBuffer)
    let extent = source.extent
    guard extent.width > 0, extent.height > 0 else { return nil }
    let scale = min(1, 960 / max(extent.width, extent.height))
    let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    return ciContext.createCGImage(scaled, from: scaled.extent)
  }
}
