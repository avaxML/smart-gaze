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

@MainActor
@Test func aResultWithAFaceOriginAndADisplayDensityStoresTheHeadCorrection() {
  let store = FakeSettingsStore(current: .default)
  let model = SettingsModel(store: store, secrets: FakeSecrets(), settings: .default)
  let result = CalibrationResult(
    map: try! solveCalibrationFixture(), horizontalErrorPoints: 4, verticalErrorPoints: 9,
    distanceCentimeters: 61, faceOriginCentimeters: SIMD3(1.5, 4.0, 61.0))

  model.applyCalibrationResult(result, pointsPerCentimeter: SIMD2(50.2, 50.1))

  #expect(
    model.settings.headTranslationCorrection
      == HeadTranslationCorrection(
        referenceOriginCentimeters: SIMD3(1.5, 4.0, 61.0), pointsPerCentimeter: SIMD2(50.2, 50.1)))

  // Without a density there is no scale to correct by; the previous correction goes too.
  model.applyCalibrationResult(result)
  #expect(model.settings.headTranslationCorrection == nil)
}

@Test func theDisplayDensityComesFromItsPhysicalSize() {
  let density = SettingsWindowController.pointsPerCentimeter(
    bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117),
    physicalMillimetres: CGSize(width: 344, height: 223))
  #expect(density != nil)
  #expect(abs((density?.x ?? 0) - 50.23) <= 0.01)
  #expect(abs((density?.y ?? 0) - 50.09) <= 0.01)
  #expect(
    SettingsWindowController.pointsPerCentimeter(
      bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117), physicalMillimetres: .zero) == nil)
}

@Test func setupFaceMapsMeshIrisContoursAndTheIrisDepth() {
  let mesh = (0..<468).map { index in
    CGPoint(x: Double(index) / 468, y: Double(index % 3) / 3)
  }
  let contour = (0..<71).map { index in
    CGPoint(x: Double(index) / 71, y: 0.5)
  }
  let irisPoints = [
    CGPoint(x: 0.4, y: 0.5),
    CGPoint(x: 0.45, y: 0.5),
    CGPoint(x: 0.4, y: 0.55),
    CGPoint(x: 0.35, y: 0.5),
    CGPoint(x: 0.4, y: 0.45),
  ]
  let leftEye = EyeIrisEstimate(
    irisCenter: irisPoints[0], irisDiameterPixels: 12, contour: contour, irisPoints: irisPoints)
  let rightEye = EyeIrisEstimate(
    irisCenter: irisPoints[0], irisDiameterPixels: 12, contour: contour, irisPoints: irisPoints)
  let estimate = GazeEstimate(
    gaze: NormalizedGazePoint(x: 0, y: 0),
    faceDistanceCentimeters: 50,
    iris: IrisEstimate(imageLeftEye: leftEye, imageRightEye: rightEye, depthCentimetres: 61.5),
    meshLandmarks: mesh)

  let face = CalibrationCoordinator.setupFace(from: estimate)

  #expect(face.mesh.count == 468)
  #expect(face.imageLeftEyeContour.count == 71)
  #expect(face.imageRightEyeContour.count == 71)
  #expect(face.imageLeftIris.count == 5)
  #expect(face.imageRightIris.count == 5)
  #expect(face.depthCentimetres == 61.5)
}

@Test func setupFaceUsesEmptyContoursAndTheBaselineDepthWithoutIris() {
  let estimate = GazeEstimate(
    gaze: NormalizedGazePoint(x: 0, y: 0),
    faceDistanceCentimeters: 52.5,
    meshLandmarks: [CGPoint(x: 0.5, y: 0.5)])

  let face = CalibrationCoordinator.setupFace(from: estimate)

  #expect(face.mesh.count == 1)
  #expect(face.imageLeftEyeContour.isEmpty)
  #expect(face.imageRightEyeContour.isEmpty)
  #expect(face.imageLeftIris.isEmpty)
  #expect(face.imageRightIris.isEmpty)
  #expect(face.depthCentimetres == 52.5)
}
