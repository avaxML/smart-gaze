import AppKit
import CoreGraphics
import Foundation
import GazeKit
import Perception

/// What the calibration window shows right now. `CalibrationRun` decides the
/// target sequence and whether a burst is good enough; this only tracks the
/// timing state a real camera and a human eye need that the pure run does not:
/// settling before a burst starts, and collecting the burst itself.
@MainActor
@Observable
final class CalibrationCoordinator {
  enum Phase: Equatable {
    case preparing
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

  var onFinished: ((CalibrationResult?) -> Void)?

  private let bounds: CGRect
  private let makePipeline: () throws -> GazePipeline
  private let camera: CameraController
  private let settleDuration: Duration
  private let burstDuration: Duration
  private let dispersionThreshold: Double
  private let maxErrorPoints: Double

  private var pipeline: GazePipeline?
  private var run: CalibrationRun?
  private var runTask: Task<Void, Never>?
  private var bufferedGaze: [NormalizedGazePoint] = []
  private var latestDistanceCentimeters: Double?

  init(
    bounds: CGRect,
    makePipeline: @escaping () throws -> GazePipeline = {
      try GazePipeline(
        faceMeshModelURL: ModelLocator.faceMeshModelURL(),
        blazeGazeModelURL: ModelLocator.blazeGazeModelURL())
    },
    camera: CameraController = CameraController(),
    settleDuration: Duration = .milliseconds(700),
    burstDuration: Duration = .milliseconds(500),
    dispersionThreshold: Double = 0.08,
    maxErrorPoints: Double = 120
  ) {
    self.bounds = bounds
    self.makePipeline = makePipeline
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
    while !Task.isCancelled {
      guard var currentRun = run, let target = currentRun.currentTargetScreenPoint else { break }

      phase = .settling(target: target)
      try? await Task.sleep(for: settleDuration)
      if Task.isCancelled { return }

      phase = .collecting(target: target)
      bufferedGaze = []
      try? await Task.sleep(for: burstDuration)
      if Task.isCancelled { return }

      let samples = bufferedGaze
      if let latestDistanceCentimeters {
        currentRun.recordDistance(latestDistanceCentimeters)
      }
      let outcome = currentRun.submitBurst(samples)
      run = currentRun

      switch outcome {
      case .retryTarget:
        phase = .retrying(target: target)
        try? await Task.sleep(for: .milliseconds(400))
      case .advancedToNextFitTarget, .advancedToNextValidationTarget:
        progress.completed += 1
      case .completed(let result):
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
    Task { [weak self] in
      guard let self, let estimate = try? await pipeline.gazePoint(from: frame.pixelBuffer) else {
        return
      }
      self.bufferedGaze.append(estimate.gaze)
      self.latestDistanceCentimeters = estimate.faceDistanceCentimeters
    }
  }
}
