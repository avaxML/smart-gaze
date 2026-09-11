import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import GazeKit
import Vision
import simd

public enum PerceptionError: Error, Equatable, Sendable {
  case cameraAccessDenied
  case noCameraAvailable
  case cannotConfigureSession
}

public final class WebcamFaceObserver: NSObject, FaceObserving, FrameProviding,
  FocalLengthProviding, @unchecked Sendable
{
  public let faces: AsyncStream<FaceObservation?>
  public let frames: AsyncStream<CameraFrame>
  public private(set) var verticalFocalLengthPixels: Double?

  private var checkedIntrinsics = false
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

  /// `AVCaptureConnection.isCameraIntrinsicMatrixDeliveryEnabled`, the switch that
  /// requests intrinsics, is `API_UNAVAILABLE(macos)`. But the attachment that
  /// carries them, `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`, has been
  /// available on macOS since 10.13, so some devices (Continuity Camera and newer
  /// built-ins, which already apply geometric distortion correction) attach it
  /// unsolicited. Element `[1][1]` of the `matrix_float3x3` is the vertical focal
  /// length in pixels, in the coordinate space of the buffer it arrived with.
  ///
  /// Returns `nil` when the attachment is absent, the wrong size, or the value it
  /// carries is zero, negative or non-finite, so a malformed reading falls back
  /// exactly like a device that never attaches one.
  static func verticalFocalLengthPixels(from sampleBuffer: CMSampleBuffer) -> Double? {
    guard
      let attachment = CMGetAttachment(
        sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
        attachmentModeOut: nil),
      let data = attachment as? Data,
      data.count == MemoryLayout<matrix_float3x3>.size
    else { return nil }

    let matrix = data.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }
    let vertical = Double(matrix[1][1])
    guard vertical.isFinite, vertical > 0 else { return nil }
    return vertical
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

    if !checkedIntrinsics {
      checkedIntrinsics = true
      verticalFocalLengthPixels = Self.verticalFocalLengthPixels(from: sampleBuffer)
    }

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
