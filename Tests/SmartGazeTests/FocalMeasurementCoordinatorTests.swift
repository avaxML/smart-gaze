import CoreGraphics
import CoreVideo
import Foundation
import GazeKit
import Perception
import Testing

@testable import SmartGaze

private actor FakeFocalPipeline: FocalMeasurementPipeline {
  private let meanIrisDiameterPixels: Double

  init(meanIrisDiameterPixels: Double) {
    self.meanIrisDiameterPixels = meanIrisDiameterPixels
  }

  func estimate(for frame: CameraFrame) async throws -> GazeEstimate {
    let eye = EyeIrisEstimate(
      irisCenter: .zero, irisDiameterPixels: meanIrisDiameterPixels, contour: [], irisPoints: [])
    return GazeEstimate(
      gaze: NormalizedGazePoint(x: 0, y: 0),
      faceDistanceCentimeters: 60,
      iris: IrisEstimate(imageLeftEye: eye, imageRightEye: eye, depthCentimetres: 60))
  }
}

private func makeCameraFrame(height: Int = 1080) -> CameraFrame {
  var buffer: CVPixelBuffer?
  let status = CVPixelBufferCreate(nil, 16, height, kCVPixelFormatType_32BGRA, nil, &buffer)
  precondition(status == kCVReturnSuccess && buffer != nil)
  return CameraFrame(pixelBuffer: buffer!)
}

@MainActor
@Test func twentyFramesOfThirtyPixelsProduceTheStoredFraction() async {
  let pipeline = FakeFocalPipeline(meanIrisDiameterPixels: 30)
  let observer = FakeFaceObserver()
  let coordinator = FocalMeasurementCoordinator(
    distanceCentimetres: 60,
    camera: CameraController(makeObserver: { observer }),
    makePipeline: { pipeline },
    sleep: { _ in try await Task.sleep(for: .seconds(3600)) })

  await coordinator.start()
  for _ in 0..<20 {
    let frame = makeCameraFrame(height: 1080)
    guard let estimate = try? await pipeline.estimate(for: frame) else {
      Issue.record("the fake pipeline produced no estimate")
      return
    }
    coordinator.record(estimate: estimate, frameHeight: 1080)
  }
  coordinator.finish()

  guard case .done(let measured, let fieldOfViewDegrees) = coordinator.phase else {
    Issue.record("expected .done, got \(coordinator.phase)")
    return
  }
  // 30 px at 60 cm: 30 * 60 * 10 / 11.7 = 1538.4615... pixels, over 1080.
  let focalLengthPixels = 30.0 * 600.0 / 11.7
  #expect(abs(measured.focalLengthPerFrameHeight - focalLengthPixels / 1080) <= 1e-12)
  #expect(measured.cameraID == "fake-camera")
  #expect(measured.cameraName == "Fake Camera")
  #expect(
    FocalLengthCalibration.plausibleVerticalFieldOfViewDegrees.contains(fieldOfViewDegrees))
}

@MainActor
@Test func tenFramesFailForTooFewSamples() async {
  let pipeline = FakeFocalPipeline(meanIrisDiameterPixels: 30)
  let coordinator = FocalMeasurementCoordinator(
    distanceCentimetres: 60,
    camera: CameraController(makeObserver: { FakeFaceObserver() }),
    makePipeline: { pipeline },
    sleep: { _ in try await Task.sleep(for: .seconds(3600)) })

  await coordinator.start()
  for _ in 0..<10 {
    let frame = makeCameraFrame(height: 1080)
    guard let estimate = try? await pipeline.estimate(for: frame) else {
      Issue.record("the fake pipeline produced no estimate")
      return
    }
    coordinator.record(estimate: estimate, frameHeight: 1080)
  }
  coordinator.finish()

  guard case .failed = coordinator.phase else {
    Issue.record("expected .failed, got \(coordinator.phase)")
    return
  }
}

@Test func focalResolutionPrefersIntrinsicsOverAMeasurement() throws {
  let measured = CameraFocalLength(
    cameraID: "id", cameraName: "Camera", focalLengthPerFrameHeight: 1.0)

  let resolved = try #require(
    CameraFocalLengthResolution.resolve(
      measured: measured, intrinsicFocalLengthPixels: 1000,
      cameraName: "MacBook Pro Camera", frameHeight: 1080))

  #expect(resolved.source == .intrinsics)
  #expect(resolved.verticalFocalLengthPixels == 1000)
}

@Test func focalResolutionUsesAMeasurementBeforeTheTable() throws {
  let measured = CameraFocalLength(
    cameraID: "id", cameraName: "Camera", focalLengthPerFrameHeight: 1.4)

  let resolved = try #require(
    CameraFocalLengthResolution.resolve(
      measured: measured, intrinsicFocalLengthPixels: nil,
      cameraName: "MacBook Pro Camera", frameHeight: 1080))

  #expect(resolved.source == .measured)
  #expect(resolved.verticalFocalLengthPixels == 1512)
}

@Test func focalResolutionFallsBackToTheTableThenTheFittedValue() throws {
  let table = try #require(
    CameraFocalLengthResolution.resolve(
      measured: nil, intrinsicFocalLengthPixels: nil,
      cameraName: "MacBook Pro Camera", frameHeight: 1080))
  #expect(table.source == .table)
  #expect(table.verticalFieldOfViewDegrees == 32)

  let assumed = try #require(
    CameraFocalLengthResolution.resolve(
      measured: nil, intrinsicFocalLengthPixels: nil,
      cameraName: "Unknown Camera", frameHeight: 1080))
  #expect(assumed.source == .assumed)
  #expect(assumed.verticalFieldOfViewDegrees == 32)
}

@Test func focalResolutionRejectsAnImplausibleMeasurementAndUsesTheTable() throws {
  let measured = CameraFocalLength(
    cameraID: "id", cameraName: "Camera", focalLengthPerFrameHeight: 20)

  let resolved = try #require(
    CameraFocalLengthResolution.resolve(
      measured: measured, intrinsicFocalLengthPixels: nil,
      cameraName: "MacBook Pro Camera", frameHeight: 1080))

  #expect(resolved.source == .table)
  #expect(resolved.verticalFieldOfViewDegrees == 32)
}

@Test func focalResolutionRejectsAnOverflowingStoredFraction() throws {
  let measured = CameraFocalLength(
    cameraID: "id", cameraName: "Camera", focalLengthPerFrameHeight: 1e300)

  let resolved = try #require(
    CameraFocalLengthResolution.resolve(
      measured: measured, intrinsicFocalLengthPixels: nil,
      cameraName: "Unknown Camera", frameHeight: 1080))

  #expect(resolved.source == .assumed)
}
