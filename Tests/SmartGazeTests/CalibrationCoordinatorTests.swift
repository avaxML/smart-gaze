import CoreGraphics
import Foundation
import GazeKit
import Perception
import Testing

@testable import SmartGaze

private let testBounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

@MainActor
@Test func aMissingModelDegradesToUnavailableWithoutTouchingTheCamera() async {
  let observer = FakeFaceObserver()
  let coordinator = CalibrationCoordinator(
    bounds: testBounds,
    makePipeline: { throw TestFailure() },
    camera: CameraController(makeObserver: { observer }))

  coordinator.start()

  guard case .unavailable = coordinator.phase else {
    Issue.record("expected .unavailable, got \(coordinator.phase)")
    return
  }
  #expect(observer.startCount == 0)
}

@MainActor
@Test func abortingBeforeThePipelineLoadsStillReachesAbortedWithNoResult() async {
  let observer = FakeFaceObserver()
  let coordinator = CalibrationCoordinator(
    bounds: testBounds,
    makePipeline: { throw TestFailure() },
    camera: CameraController(makeObserver: { observer }))

  var finishedResults: [CalibrationResult?] = []
  coordinator.onFinished = { finishedResults.append($0) }

  coordinator.start()
  coordinator.abort()

  #expect(coordinator.phase == .aborted)
  #expect(finishedResults == [nil])
}

/// Mirrors exactly how `SettingsWindowController.startCalibration()` wires a
/// run's completion into persistence: only a non-nil result is ever applied.
/// This is the contract issue #14 calls out explicitly: an aborted run must
/// leave the user no worse off than before they started.
@MainActor
@Test func aNilCompletionResultLeavesThePreviousCalibrationUntouched() {
  let previousMap = try! solveCalibrationFixture()
  var settings = Settings.default
  settings.calibrationMap = previousMap
  settings.calibrationDistanceCentimeters = 52
  let store = FakeSettingsStore(current: settings)
  let model = SettingsModel(store: store, secrets: FakeSecrets(), settings: settings)

  func handleCalibrationCompletion(_ result: CalibrationResult?) {
    guard let result else { return }
    model.applyCalibrationResult(result)
  }

  handleCalibrationCompletion(nil)

  #expect(model.settings.calibrationMap == previousMap)
  #expect(model.settings.calibrationDistanceCentimeters == 52)
  #expect(store.savedCount == 0)
}

@MainActor
@Test func aCompletedResultReplacesThePreviousCalibrationAndPersists() {
  let previousMap = try! solveCalibrationFixture()
  var settings = Settings.default
  settings.calibrationMap = previousMap
  let store = FakeSettingsStore(current: settings)
  let model = SettingsModel(store: store, secrets: FakeSecrets(), settings: settings)

  let newMap = try! solveCalibrationFixture(scale: 2)
  let result = CalibrationResult(
    map: newMap, horizontalErrorPoints: 4, verticalErrorPoints: 9, distanceCentimeters: 61)

  func handleCalibrationCompletion(_ result: CalibrationResult?) {
    guard let result else { return }
    model.applyCalibrationResult(result)
  }
  handleCalibrationCompletion(result)

  #expect(model.settings.calibrationMap == newMap)
  #expect(model.settings.calibrationDistanceCentimeters == 61)
  #expect(store.savedCount == 1)
}

private func solveCalibrationFixture(scale: Double = 1) throws -> CalibrationMap {
  let gridPoints: [NormalizedGazePoint] = [
    NormalizedGazePoint(x: -0.4, y: -0.3), NormalizedGazePoint(x: 0.0, y: -0.3),
    NormalizedGazePoint(x: 0.4, y: -0.3), NormalizedGazePoint(x: -0.4, y: 0.0),
    NormalizedGazePoint(x: 0.0, y: 0.0), NormalizedGazePoint(x: 0.4, y: 0.0),
    NormalizedGazePoint(x: -0.4, y: 0.3), NormalizedGazePoint(x: 0.0, y: 0.3),
    NormalizedGazePoint(x: 0.4, y: 0.3),
  ]
  let samples = gridPoints.map { point in
    CalibrationSample(
      gaze: point, screenPoint: CGPoint(x: 100 * scale + 800 * point.x, y: 50 + 600 * point.y))
  }
  return try solveCalibration(samples)
}
