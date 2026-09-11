import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import GazeKit
import Vision

public enum GazePipelineError: Error, Equatable, Sendable {
  case noFaceDetected
  case facePresenceTooLow(Float)
  case cropUnavailable
}

/// Turns a camera frame into a normalized gaze point.
///
/// Owns both Core ML estimators and does the Core Video, Core ML and Vision
/// work; every arithmetic step (the crop, the map-back, the eye band) is a
/// pure `GazeKit` call. A missing face or a face-mesh score below
/// `facePresenceThreshold` throws rather than returning a fabricated sample,
/// because a neutral head vector or a Vision-landmark stand-in would look
/// like a real reading downstream.
public actor GazePipeline {
  /// The face-mesh model's own presence gate (u08 plan §1.3: `sigmoid`,
  /// gate `>= 0.5`).
  public static let facePresenceThreshold: Float = 0.5

  private let faceMesh: FaceMeshEstimator
  private let blazeGaze: BlazeGazeEstimator
  private var verticalFieldOfViewDegrees: Double

  public init(
    faceMeshModelURL: URL,
    blazeGazeModelURL: URL,
    computeUnits: MLComputeUnits = .all,
    verticalFieldOfViewDegrees: Double = 60
  ) throws {
    self.faceMesh = try FaceMeshEstimator(modelURL: faceMeshModelURL, computeUnits: computeUnits)
    self.blazeGaze = try BlazeGazeEstimator(modelURL: blazeGazeModelURL, computeUnits: computeUnits)
    self.verticalFieldOfViewDegrees = verticalFieldOfViewDegrees
  }

  /// Called once the camera reports its actual field of view, which is only known
  /// after the capture session has configured its device and is not available at
  /// `init` time. Ignored if the pipeline already heard from the camera.
  public func updateVerticalFieldOfView(degrees: Double) {
    guard degrees.isFinite, degrees > 0 else { return }
    verticalFieldOfViewDegrees = degrees
  }

  public func gazePoint(from pixelBuffer: sending CVPixelBuffer) async throws -> NormalizedGazePoint
  {
    try Task.checkCancellation()

    let frameSize = CGSize(
      width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
    guard let boundingBox = try Self.detectFaceBoundingBox(in: pixelBuffer) else {
      throw GazePipelineError.noFaceDetected
    }
    guard
      let cropRect = FaceCropGeometry.expandedFaceCrop(
        visionBoundingBox: boundingBox, frameSize: frameSize)
    else {
      throw GazePipelineError.cropUnavailable
    }

    let source = try CVPixelBufferSource(pixelBuffer: pixelBuffer)
    let cropRGB = try resampledRGB(
      source, from: cropRect, width: FaceMeshInput.width, height: FaceMeshInput.height)
    let meshResult = try await faceMesh.landmarks(rgb: cropRGB)

    guard meshResult.facePresence >= Self.facePresenceThreshold else {
      throw GazePipelineError.facePresenceTooLow(meshResult.facePresence)
    }

    let fullFrame = try mapCropLandmarksToFrame(
      cropLandmarks: meshResult.landmarks,
      cropPixelSize: Double(FaceMeshInput.width),
      cropRect: cropRect,
      frameSize: frameSize)

    let eyeBand = try eyeBandRGB(
      from: source, landmarks: fullFrame.normalized, frameSize: frameSize)

    let headPose = try headPoseInputs(
      landmarks: fullFrame.pixelSpace,
      imageSize: SIMD2(Double(frameSize.width), Double(frameSize.height)),
      verticalFieldOfViewDegrees: verticalFieldOfViewDegrees)

    let blazeInput = try BlazeGazeInput(
      eyeBandRGB: eyeBand,
      headVector: headPose.modelVectors.headVector,
      faceOriginCentimeters: headPose.modelVectors.faceOriginCentimeters)

    return try await blazeGaze.estimate(blazeInput)
  }

  /// The only Vision call in the pipeline: bootstraps the crop from Vision's
  /// face rectangle. Vision's own dense landmarks are never substituted for
  /// the mesh model's output.
  private static func detectFaceBoundingBox(in pixelBuffer: CVPixelBuffer) throws -> CGRect? {
    let request = VNDetectFaceRectanglesRequest()
    request.revision = VNDetectFaceRectanglesRequestRevision3
    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
    try handler.perform([request])
    return request.results?.first?.boundingBox
  }
}
