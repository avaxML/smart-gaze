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

/// One frame's gaze reading alongside the face distance the same frame
/// implied, so a caller can record the distance a calibration was performed
/// at without a second pass over the landmarks.
public struct GazeEstimate: Equatable, Sendable {
  public let gaze: NormalizedGazePoint
  public let faceDistanceCentimeters: Double
  public let headYawRadians: Double
  public let headPitchRadians: Double
  /// Camera frame, centimetres: x image-right, y image-down, z away.
  public let faceOriginCentimeters: SIMD3<Double>
  /// The crop's rotation about the image normal, radians.
  public let cropRotationRadians: Double
  /// Whether the face-mesh input came from the previous frame's landmarks
  /// rather than a fresh Vision rectangle.
  public let usedTrackedCrop: Bool

  public init(
    gaze: NormalizedGazePoint, faceDistanceCentimeters: Double, headYawRadians: Double = 0,
    headPitchRadians: Double = 0, faceOriginCentimeters: SIMD3<Double> = .zero,
    cropRotationRadians: Double = 0, usedTrackedCrop: Bool = false
  ) {
    self.gaze = gaze
    self.faceDistanceCentimeters = faceDistanceCentimeters
    self.headYawRadians = headYawRadians
    self.headPitchRadians = headPitchRadians
    self.faceOriginCentimeters = faceOriginCentimeters
    self.cropRotationRadians = cropRotationRadians
    self.usedTrackedCrop = usedTrackedCrop
  }
}

/// Turns a camera frame into a normalized gaze point.
///
/// Owns both Core ML estimators and does the Core Video, Core ML and Vision
/// work; every arithmetic step (the crop, the map-back, the eye band) is a
/// pure `GazeKit` call. The first frame's crop is seeded from Vision's face
/// rectangle; following frames re-crop from the previous frame's mesh
/// landmarks, so the mesh reads the level, rotated crop it was trained on.
/// Vision runs again only when the tracked crop's presence drops. A missing
/// face or a face-mesh score below `facePresenceThreshold` throws rather than
/// returning a fabricated sample, because a neutral head vector or a
/// Vision-landmark stand-in would look like a real reading downstream.
public actor GazePipeline {
  /// The face-mesh model's own presence gate (u08 plan §1.3: `sigmoid`,
  /// gate `>= 0.5`).
  public static let facePresenceThreshold: Float = 0.5

  private let faceMesh: FaceMeshEstimator
  private let blazeGaze: BlazeGazeEstimator
  private var verticalFocalLengthPixels: Double?
  private var verticalFieldOfViewOverrideDegrees: Double?
  private var trackedLandmarks: [SIMD3<Double>]?
  private var trackedFrameSize: CGSize?

  public init(
    faceMeshModelURL: URL,
    blazeGazeModelURL: URL,
    computeUnits: MLComputeUnits = .all,
    verticalFocalLengthPixels: Double? = nil,
    verticalFieldOfViewDegrees: Double? = nil
  ) throws {
    self.faceMesh = try FaceMeshEstimator(modelURL: faceMeshModelURL, computeUnits: computeUnits)
    self.blazeGaze = try BlazeGazeEstimator(modelURL: blazeGazeModelURL, computeUnits: computeUnits)
    // SMART_GAZE_VERTICAL_FOV_DEGREES lets the depth scale be corrected for a
    // camera whose field of view macOS will not report. The first live run
    // recorded 27.8 cm at the 60 degree default against a real distance near
    // 55 cm, which halves the model's horizontal sensitivity.
    if let override = ProcessInfo.processInfo.environment["SMART_GAZE_VERTICAL_FOV_DEGREES"],
      let degrees = Double(override), degrees > 1, degrees < 179
    {
      self.verticalFieldOfViewOverrideDegrees = degrees
    } else if let verticalFieldOfViewDegrees, verticalFieldOfViewDegrees > 1,
      verticalFieldOfViewDegrees < 179
    {
      self.verticalFieldOfViewOverrideDegrees = verticalFieldOfViewDegrees
    }
    self.verticalFocalLengthPixels = verticalFocalLengthPixels
  }

  /// Called once the camera reports a real focal length, read from its capture
  /// buffer's own intrinsic matrix attachment, which is only known after the
  /// first frame has arrived and is not available at `init` time. A malformed
  /// reading is ignored, leaving the pipeline on the assumed field of view
  /// `metricFaceOrigin` falls back to.
  private func effectiveVerticalFocalLengthPixels(frameHeight: CGFloat) -> Double? {
    if let verticalFocalLengthPixels { return verticalFocalLengthPixels }
    guard let degrees = verticalFieldOfViewOverrideDegrees else { return nil }
    return Double(frameHeight) / (2 * tan(degrees / 2 * .pi / 180))
  }

  public func updateVerticalFocalLength(pixels: Double) {
    guard pixels.isFinite, pixels > 0 else { return }
    verticalFocalLengthPixels = pixels
  }

  public func gazePoint(from pixelBuffer: sending CVPixelBuffer) async throws -> GazeEstimate {
    try Task.checkCancellation()

    let frameSize = CGSize(
      width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
    let source = try CVPixelBufferSource(pixelBuffer: pixelBuffer)

    var trackedResult: (crop: FaceCrop, mesh: FaceMeshResult)?
    if let landmarks = trackedLandmarks, trackedFrameSize == frameSize,
      let trackedCrop = FaceCrop.tracking(landmarks: landmarks, frameSize: frameSize)
    {
      let cropRGB = try croppedRGB(
        source, crop: trackedCrop, cropPixelSize: FaceMeshInput.width)
      let mesh = try await faceMesh.landmarks(rgb: cropRGB)
      if mesh.facePresence >= Self.facePresenceThreshold {
        trackedResult = (trackedCrop, mesh)
      }
    }

    let crop: FaceCrop
    let meshResult: FaceMeshResult
    if let trackedResult {
      crop = trackedResult.crop
      meshResult = trackedResult.mesh
    } else {
      trackedLandmarks = nil
      guard let boundingBox = try Self.detectFaceBoundingBox(in: pixelBuffer) else {
        throw GazePipelineError.noFaceDetected
      }
      guard let seeded = FaceCrop.seed(visionBoundingBox: boundingBox, frameSize: frameSize) else {
        throw GazePipelineError.cropUnavailable
      }
      let cropRGB = try croppedRGB(source, crop: seeded, cropPixelSize: FaceMeshInput.width)
      let mesh = try await faceMesh.landmarks(rgb: cropRGB)
      guard mesh.facePresence >= Self.facePresenceThreshold else {
        throw GazePipelineError.facePresenceTooLow(mesh.facePresence)
      }
      crop = seeded
      meshResult = mesh
    }
    let usedTrackedCrop = trackedResult != nil

    let fullFrame = try mapCropLandmarksToFrame(
      cropLandmarks: meshResult.landmarks,
      cropPixelSize: Double(FaceMeshInput.width),
      crop: crop,
      frameSize: frameSize)

    trackedLandmarks = fullFrame.pixelSpace
    trackedFrameSize = frameSize

    let eyeBand = try eyeBandRGB(
      from: source, landmarks: fullFrame.normalized, frameSize: frameSize)

    let headPose = try headPoseInputs(
      landmarks: fullFrame.pixelSpace,
      imageSize: SIMD2(Double(frameSize.width), Double(frameSize.height)),
      verticalFocalLengthPixels: effectiveVerticalFocalLengthPixels(frameHeight: frameSize.height))

    let blazeInput = try BlazeGazeInput(
      eyeBandRGB: eyeBand,
      headVector: headPose.modelVectors.headVector,
      faceOriginCentimeters: headPose.modelVectors.faceOriginCentimeters)

    let gaze = try await blazeGaze.estimate(blazeInput)
    return GazeEstimate(
      gaze: gaze, faceDistanceCentimeters: headPose.faceOrigin.centimetres.z,
      headYawRadians: headYawRadians(from: headPose.headVector),
      headPitchRadians: headPitchRadians(from: headPose.headVector),
      faceOriginCentimeters: headPose.faceOrigin.centimetres,
      cropRotationRadians: crop.rotationRadians, usedTrackedCrop: usedTrackedCrop)
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
