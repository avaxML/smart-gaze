import AVFoundation
import CoreGraphics
import Foundation
import GazeKit
import Vision

public enum PerceptionError: Error, Equatable, Sendable {
  case cameraAccessDenied
  case noCameraAvailable
  case cannotConfigureSession
}

public final class WebcamFaceObserver: NSObject, FaceObserving, @unchecked Sendable {
  public let faces: AsyncStream<FaceObservation?>

  private let continuation: AsyncStream<FaceObservation?>.Continuation
  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "com.avaxml.smartgaze.perception.session")
  private let videoQueue = DispatchQueue(label: "com.avaxml.smartgaze.perception.video")
  private let landmarksRequest: VNDetectFaceLandmarksRequest

  public override init() {
    var streamContinuation: AsyncStream<FaceObservation?>.Continuation!
    self.faces = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { streamContinuation = $0 }
    self.continuation = streamContinuation

    let request = VNDetectFaceLandmarksRequest()
    request.revision = VNDetectFaceLandmarksRequestRevision3
    self.landmarksRequest = request

    super.init()
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
      continuation.yield(nil)
      return
    }

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
