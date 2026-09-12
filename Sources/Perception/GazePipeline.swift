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
  /// The iris-landmark reading for this frame: `nil` when the iris model is not
  /// configured or either eye crop was unavailable.
  public let iris: IrisEstimate?
  /// The face-mesh landmarks, 468 top-left normalized frame points, for a
  /// consumer that draws the mesh itself.
  public let meshLandmarks: [CGPoint]
  /// Each mesh landmark's `z` divided by the frame width, one per landmark.
  public let meshDepth: [Double]
  /// The rigid head rotation the pipeline fitted this frame, `nil` only when
  /// a caller constructs an estimate without one.
  public let headRotation: RigidRotation?
  /// The interpupillary distance the eye-baseline depth was scaled by, so a
  /// consumer can compute the user's implied value with `InterpupillaryFit`.
  public let assumedInterpupillaryCentimetres: Double

  public init(
    gaze: NormalizedGazePoint, faceDistanceCentimeters: Double, headYawRadians: Double = 0,
    headPitchRadians: Double = 0, faceOriginCentimeters: SIMD3<Double> = .zero,
    cropRotationRadians: Double = 0, usedTrackedCrop: Bool = false,
    iris: IrisEstimate? = nil, meshLandmarks: [CGPoint] = [],
    meshDepth: [Double] = [], headRotation: RigidRotation? = nil,
    assumedInterpupillaryCentimetres: Double = defaultInterpupillaryCentimetres
  ) {
    self.gaze = gaze
    self.faceDistanceCentimeters = faceDistanceCentimeters
    self.headYawRadians = headYawRadians
    self.headPitchRadians = headPitchRadians
    self.faceOriginCentimeters = faceOriginCentimeters
    self.cropRotationRadians = cropRotationRadians
    self.usedTrackedCrop = usedTrackedCrop
    self.iris = iris
    self.meshLandmarks = meshLandmarks
    self.meshDepth = meshDepth
    self.headRotation = headRotation
    self.assumedInterpupillaryCentimetres = assumedInterpupillaryCentimetres
  }
}

/// One eye's iris-landmark reading. Points are top-left normalized frame
/// coordinates.
public struct EyeIrisEstimate: Equatable, Sendable {
  public let irisCenter: CGPoint
  public let irisDiameterPixels: Double
  /// The 71 eye-contour and brow points.
  public let contour: [CGPoint]
  /// The 5 iris points: centre, horizontal extremes, vertical extremes.
  public let irisPoints: [CGPoint]
  /// Each contour point's crop `z` scaled to frame pixels and divided by the
  /// frame width, one per contour point.
  public let contourDepth: [Double]
  /// Each iris point's depth, scaled like `contourDepth`, one per iris point.
  public let irisDepth: [Double]

  public init(
    irisCenter: CGPoint, irisDiameterPixels: Double, contour: [CGPoint], irisPoints: [CGPoint],
    contourDepth: [Double] = [], irisDepth: [Double] = []
  ) {
    self.irisCenter = irisCenter
    self.irisDiameterPixels = irisDiameterPixels
    self.contour = contour
    self.irisPoints = irisPoints
    self.contourDepth = contourDepth
    self.irisDepth = irisDepth
  }
}

/// Both eyes' iris readings plus the depth their iris rulers agree on.
public struct IrisEstimate: Equatable, Sendable {
  public let imageLeftEye: EyeIrisEstimate
  public let imageRightEye: EyeIrisEstimate
  /// Mean of the two eyes' depths from the iris ruler, centimetres.
  public let depthCentimetres: Double

  public init(
    imageLeftEye: EyeIrisEstimate, imageRightEye: EyeIrisEstimate, depthCentimetres: Double
  ) {
    self.imageLeftEye = imageLeftEye
    self.imageRightEye = imageRightEye
    self.depthCentimetres = depthCentimetres
  }
}

/// Maps one eye's crop-space iris landmarks onto a frame-normalized
/// `EyeIrisEstimate`, with each point's `z` scaled to a frame-width depth
/// fraction. Pure so the mapping is testable without a model.
func makeEyeIrisEstimate(
  contour: [SIMD3<Float>],
  iris: [SIMD3<Float>],
  transform: ProjectiveTransform,
  flip: Bool,
  cropPixelSize: Int,
  scale: Double,
  frameSize: CGSize
) -> EyeIrisEstimate? {
  let width = Double(frameSize.width)
  let height = Double(frameSize.height)
  guard width > 0, height > 0 else { return nil }

  func framePoint(_ point: SIMD3<Float>) -> (pixel: CGPoint, depth: Double)? {
    var cropPoint = SIMD3<Double>(Double(point.x), Double(point.y), Double(point.z))
    if flip {
      cropPoint = IrisGeometry.unflipped(cropPoint, width: cropPixelSize)
    }
    guard let mapped = transform.map(CGPoint(x: cropPoint.x, y: cropPoint.y)) else {
      return nil
    }
    return (
      CGPoint(x: Double(mapped.x), y: Double(mapped.y)),
      IrisGeometry.depthFraction(cropZ: cropPoint.z, scale: scale, frameWidth: width)
    )
  }

  var contourPoints: [CGPoint] = []
  var contourDepth: [Double] = []
  contourPoints.reserveCapacity(contour.count)
  contourDepth.reserveCapacity(contour.count)
  for point in contour {
    guard let mapped = framePoint(point) else { return nil }
    contourPoints.append(CGPoint(x: mapped.pixel.x / width, y: mapped.pixel.y / height))
    contourDepth.append(mapped.depth)
  }

  var irisPoints: [CGPoint] = []
  var irisDepth: [Double] = []
  var irisPixels: [SIMD2<Double>] = []
  irisPoints.reserveCapacity(iris.count)
  irisDepth.reserveCapacity(iris.count)
  irisPixels.reserveCapacity(iris.count)
  for point in iris {
    guard let mapped = framePoint(point) else { return nil }
    irisPoints.append(CGPoint(x: mapped.pixel.x / width, y: mapped.pixel.y / height))
    irisDepth.append(mapped.depth)
    irisPixels.append(SIMD2(Double(mapped.pixel.x), Double(mapped.pixel.y)))
  }
  guard let irisCenter = irisPoints.first,
    let diameterPixels = IrisGeometry.irisDiameter(irisPixels)
  else { return nil }

  return EyeIrisEstimate(
    irisCenter: irisCenter,
    irisDiameterPixels: diameterPixels,
    contour: contourPoints,
    irisPoints: irisPoints,
    contourDepth: contourDepth,
    irisDepth: irisDepth)
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
  private let irisEstimator: IrisLandmarkEstimator?
  private var verticalFocalLengthPixels: Double?
  private var verticalFieldOfViewOverrideDegrees: Double?
  private let interpupillaryCentimetres: Double
  private var trackedLandmarks: [SIMD3<Double>]?
  private var trackedFrameSize: CGSize?

  public init(
    faceMeshModelURL: URL,
    blazeGazeModelURL: URL,
    irisModelURL: URL? = nil,
    computeUnits: MLComputeUnits = .all,
    verticalFocalLengthPixels: Double? = nil,
    verticalFieldOfViewDegrees: Double? = nil,
    interpupillaryCentimetres: Double = defaultInterpupillaryCentimetres
  ) throws {
    self.faceMesh = try FaceMeshEstimator(modelURL: faceMeshModelURL, computeUnits: computeUnits)
    self.blazeGaze = try BlazeGazeEstimator(modelURL: blazeGazeModelURL, computeUnits: computeUnits)
    if let irisModelURL {
      self.irisEstimator = try IrisLandmarkEstimator(
        modelURL: irisModelURL, computeUnits: computeUnits)
    } else {
      self.irisEstimator = nil
    }
    self.interpupillaryCentimetres = interpupillaryCentimetres
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

    let iris: IrisEstimate?
    if irisEstimator != nil {
      let focalLengthPixels = resolvedVerticalFocalLengthPixels(
        measured: effectiveVerticalFocalLengthPixels(frameHeight: frameSize.height),
        imageHeight: Double(frameSize.height))
      iris = try await irisEstimate(
        from: source, fullFrame: fullFrame, frameSize: frameSize,
        focalLengthPixels: focalLengthPixels)
    } else {
      iris = nil
    }

    let eyeBand = try eyeBandRGB(
      from: source, landmarks: fullFrame.normalized, frameSize: frameSize)

    let headPose = try headPoseInputs(
      landmarks: fullFrame.pixelSpace,
      imageSize: SIMD2(Double(frameSize.width), Double(frameSize.height)),
      verticalFocalLengthPixels: effectiveVerticalFocalLengthPixels(frameHeight: frameSize.height),
      interpupillaryCentimetres: interpupillaryCentimetres)

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
      cropRotationRadians: crop.rotationRadians, usedTrackedCrop: usedTrackedCrop,
      iris: iris, meshLandmarks: fullFrame.normalized,
      meshDepth: fullFrame.pixelSpace.map { $0.z / Double(frameSize.width) },
      headRotation: headPose.rotation,
      assumedInterpupillaryCentimetres: interpupillaryCentimetres)
  }

  /// Runs the iris model on both eye crops. The image-right eye's landmarks
  /// (362/263) feed a horizontally flipped crop, and its output is unflipped,
  /// because the model was trained on left-eye-shaped crops and MediaPipe
  /// mirrors the other eye rather than running a second model.
  private func irisEstimate(
    from source: some PixelSource,
    fullFrame: FullFrameLandmarks,
    frameSize: CGSize,
    focalLengthPixels: Double
  ) async throws -> IrisEstimate? {
    guard let irisEstimator else { return nil }
    guard
      let imageLeftCrop = IrisGeometry.eyeCrop(
        imageLeftCorner: fullFrame.pixelSpace[33],
        imageRightCorner: fullFrame.pixelSpace[133]),
      let imageRightCrop = IrisGeometry.eyeCrop(
        imageLeftCorner: fullFrame.pixelSpace[362],
        imageRightCorner: fullFrame.pixelSpace[263])
    else { return nil }

    guard
      let imageLeft = try await eyeIrisEstimate(
        from: source, crop: imageLeftCrop, flip: false, estimator: irisEstimator,
        frameSize: frameSize, focalLengthPixels: focalLengthPixels),
      let imageRight = try await eyeIrisEstimate(
        from: source, crop: imageRightCrop, flip: true, estimator: irisEstimator,
        frameSize: frameSize, focalLengthPixels: focalLengthPixels)
    else { return nil }

    return IrisEstimate(
      imageLeftEye: imageLeft.estimate, imageRightEye: imageRight.estimate,
      depthCentimetres: (imageLeft.depth + imageRight.depth) / 2)
  }

  private func eyeIrisEstimate(
    from source: some PixelSource,
    crop: FaceCrop,
    flip: Bool,
    estimator: IrisLandmarkEstimator,
    frameSize: CGSize,
    focalLengthPixels: Double
  ) async throws -> (estimate: EyeIrisEstimate, depth: Double)? {
    let cropPixelSize = IrisGeometry.cropPixelSize
    let cropRGB = try croppedRGB(source, crop: crop, cropPixelSize: cropPixelSize)
    let input =
      flip
      ? IrisGeometry.horizontallyFlipped(rgb: cropRGB, width: cropPixelSize, height: cropPixelSize)
      : cropRGB
    let result = try await estimator.landmarks(rgb: input)
    guard let transform = crop.cropToFrame(cropPixelSize: Double(cropPixelSize)) else {
      return nil
    }
    guard
      let estimate = makeEyeIrisEstimate(
        contour: result.contour, iris: result.iris, transform: transform, flip: flip,
        cropPixelSize: cropPixelSize, scale: crop.scale(cropPixelSize: Double(cropPixelSize)),
        frameSize: frameSize),
      let depth = IrisGeometry.depthCentimetres(
        irisDiameterPixels: estimate.irisDiameterPixels, focalLengthPixels: focalLengthPixels)
    else { return nil }
    return (estimate, depth)
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
