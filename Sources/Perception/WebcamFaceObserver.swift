import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import GazeKit
import Vision

public enum PerceptionError: Error, Equatable, Sendable {
  case cameraAccessDenied
  case noCameraAvailable
  case cannotConfigureSession
}

public final class WebcamFaceObserver: NSObject, FaceObserving, FrameProviding,
  FieldOfViewProviding, @unchecked Sendable
{
  public let faces: AsyncStream<FaceObservation?>
  public let frames: AsyncStream<CameraFrame>
  public private(set) var verticalFieldOfViewDegrees: Double?

  private let continuation: AsyncStream<FaceObservation?>.Continuation
  private let frameContinuation: AsyncStream<CameraFrame>.Continuation
  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "com.avaxml.smartgaze.perception.session")
  private let videoQueue = DispatchQueue(label: "com.avaxml.smartgaze.perception.video")
  private let landmarksRequest: VNDetectFaceLandmarksRequest

  public override init() {
    var streamContinuation: AsyncStream<FaceObservation?>.Continuation!
    self.faces = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { streamContinuation = $0 }
    self.continuation = streamContinuation

    var frameStreamContinuation: AsyncStream<CameraFrame>.Continuation!
    self.frames = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
      frameStreamContinuation = $0
    }
    self.frameContinuation = frameStreamContinuation

    let request = VNDetectFaceLandmarksRequest()
    request.revision = VNDetectFaceLandmarksRequestRevision3
    self.landmarksRequest = request

    super.init()
  }

  public var authorizationStatus: CameraAuthorization {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      return .authorized
    case .notDetermined:
      return .notDetermined
    case .denied, .restricted:
      return .denied
    @unknown default:
      return .denied
    }
  }

  public func start() async throws {
    guard await requestCameraAccess() else { throw PerceptionError.cameraAccessDenied }
    try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
      sessionQueue.async { [weak self] in
        guard let self else {
          resume.resume()
          return
        }
        do {
          try self.configureAndStart()
          resume.resume()
        } catch {
          resume.resume(throwing: error)
        }
      }
    }
  }

  public func stop() {
    sessionQueue.sync {
      self.session.stopRunning()
    }
    continuation.finish()
    frameContinuation.finish()
  }

  private func requestCameraAccess() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      return true
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .video)
    case .denied, .restricted:
      return false
    @unknown default:
      return false
    }
  }

  private func configureAndStart() throws {
    session.beginConfiguration()
    session.sessionPreset = .hd1920x1080

    guard let device = AVCaptureDevice.default(for: .video) else {
      session.commitConfiguration()
      throw PerceptionError.noCameraAvailable
    }

    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else {
      session.commitConfiguration()
      throw PerceptionError.cannotConfigureSession
    }
    session.addInput(input)
    verticalFieldOfViewDegrees = Self.verticalFieldOfViewDegrees(
      horizontalDegrees: Self.horizontalFieldOfViewDegrees(for: device),
      format: device.activeFormat)

    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: videoQueue)
    guard session.canAddOutput(output) else {
      session.commitConfiguration()
      throw PerceptionError.cannotConfigureSession
    }
    session.addOutput(output)

    session.commitConfiguration()
    session.startRunning()
  }

  /// `AVCaptureDevice.Format.videoFieldOfView` reports the HORIZONTAL field of view in
  /// degrees on iOS, but Apple marks it `API_UNAVAILABLE(macos)`, confirmed by a build
  /// failure against the macOS 26 SDK when this was called directly. There is currently
  /// no public AVFoundation replacement on macOS, so this always returns `nil` here.
  /// `configureAndStart` still routes the (currently absent) reading through the same
  /// derivation and validation `metricFaceOrigin`'s caller needs, so the day AVFoundation
  /// exposes one on macOS, wiring it in is a one-line change at this call site.
  private static func horizontalFieldOfViewDegrees(for device: AVCaptureDevice) -> Double? {
    nil
  }

  /// Derives the vertical field of view from a horizontal reading and the active
  /// format's frame aspect ratio, returned as a plain `Double` so `GazeKit` never has
  /// to import AVFoundation to consume it.
  ///
  /// Returns `nil` when there is no horizontal reading, or it is zero, negative, or at
  /// least 180 degrees: values a real lens cannot produce, so the caller keeps its own
  /// default rather than deriving an angle from a nonsensical one.
  static func verticalFieldOfViewDegrees(
    horizontalDegrees: Double?, format: AVCaptureDevice.Format
  ) -> Double? {
    guard let horizontalDegrees, horizontalDegrees > 0, horizontalDegrees < 180 else {
      return nil
    }

    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    guard dimensions.width > 0, dimensions.height > 0 else { return nil }

    let halfHorizontal = horizontalDegrees / 2 * .pi / 180
    let aspect = Double(dimensions.height) / Double(dimensions.width)
    let halfVertical = atan(tan(halfHorizontal) * aspect)
    return halfVertical * 2 * 180 / .pi
  }
}

extension WebcamFaceObserver: AVCaptureVideoDataOutputSampleBufferDelegate {
  public func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
    do {
      try handler.perform([landmarksRequest])
    } catch {
      frameContinuation.yield(CameraFrame(pixelBuffer: pixelBuffer))
      continuation.yield(nil)
      return
    }

    // Vision only reads the buffer above; the frame stream's consumer is the
    // last owner, so the yield comes after every local use of `pixelBuffer`.
    frameContinuation.yield(CameraFrame(pixelBuffer: pixelBuffer))

    guard
      let face = (landmarksRequest.results ?? []).first,
      let observation = FaceObservation(visionFace: face, timestamp: timestamp)
    else {
      continuation.yield(nil)
      return
    }
    continuation.yield(observation)
  }
}
