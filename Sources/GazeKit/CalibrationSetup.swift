import CoreGraphics
import Foundation

/// What the setup stage knows about the face in the current frame. Every point
/// is a top-left normalized (0...1) coordinate in the unmirrored camera frame.
public struct CalibrationSetupFace: Equatable, Sendable {
  public let mesh: [CGPoint]
  public let imageLeftEyeContour: [CGPoint]
  public let imageRightEyeContour: [CGPoint]
  public let imageLeftIris: [CGPoint]
  public let imageRightIris: [CGPoint]
  public let depthCentimetres: Double?
  /// The mesh landmarks' `z` divided by the frame width, one per mesh point,
  /// in the mesh's own normalized units. Empty when the pipeline did not
  /// provide a depth.
  public let meshDepth: [Double]
  /// Each contour point's depth, one per contour point, in the same units as
  /// `meshDepth`. Empty when the pipeline did not provide one.
  public let imageLeftEyeContourDepth: [Double]
  public let imageRightEyeContourDepth: [Double]
  /// Each iris point's depth, one per iris point, in the same units as
  /// `meshDepth`. Empty when the pipeline did not provide one.
  public let imageLeftIrisDepth: [Double]
  public let imageRightIrisDepth: [Double]
  /// The head rotation the pipeline fitted this frame, `nil` without one.
  public let rotation: RigidRotation?
  /// Each eye's aspect ratio from `eyeAspectRatio`, image-left then
  /// image-right. `nil` when either eye's contour could not be read.
  public let eyeAspectRatios: (left: Double, right: Double)?

  public init(
    mesh: [CGPoint],
    imageLeftEyeContour: [CGPoint],
    imageRightEyeContour: [CGPoint],
    imageLeftIris: [CGPoint],
    imageRightIris: [CGPoint],
    depthCentimetres: Double?,
    meshDepth: [Double] = [],
    imageLeftEyeContourDepth: [Double] = [],
    imageRightEyeContourDepth: [Double] = [],
    imageLeftIrisDepth: [Double] = [],
    imageRightIrisDepth: [Double] = [],
    rotation: RigidRotation? = nil,
    eyeAspectRatios: (left: Double, right: Double)? = nil
  ) {
    self.mesh = mesh
    self.imageLeftEyeContour = imageLeftEyeContour
    self.imageRightEyeContour = imageRightEyeContour
    self.imageLeftIris = imageLeftIris
    self.imageRightIris = imageRightIris
    self.depthCentimetres = depthCentimetres
    self.meshDepth = meshDepth
    self.imageLeftEyeContourDepth = imageLeftEyeContourDepth
    self.imageRightEyeContourDepth = imageRightEyeContourDepth
    self.imageLeftIrisDepth = imageLeftIrisDepth
    self.imageRightIrisDepth = imageRightIrisDepth
    self.rotation = rotation
    self.eyeAspectRatios = eyeAspectRatios
  }

  /// The tuple's values cannot be synthesized, so equality is written out.
  public static func == (lhs: CalibrationSetupFace, rhs: CalibrationSetupFace) -> Bool {
    lhs.mesh == rhs.mesh
      && lhs.imageLeftEyeContour == rhs.imageLeftEyeContour
      && lhs.imageRightEyeContour == rhs.imageRightEyeContour
      && lhs.imageLeftIris == rhs.imageLeftIris
      && lhs.imageRightIris == rhs.imageRightIris
      && lhs.depthCentimetres == rhs.depthCentimetres
      && lhs.meshDepth == rhs.meshDepth
      && lhs.imageLeftEyeContourDepth == rhs.imageLeftEyeContourDepth
      && lhs.imageRightEyeContourDepth == rhs.imageRightEyeContourDepth
      && lhs.imageLeftIrisDepth == rhs.imageLeftIrisDepth
      && lhs.imageRightIrisDepth == rhs.imageRightIrisDepth
      && lhs.rotation == rhs.rotation
      && lhs.eyeAspectRatios?.left == rhs.eyeAspectRatios?.left
      && lhs.eyeAspectRatios?.right == rhs.eyeAspectRatios?.right
  }

  /// Mean of the mesh points. nil when mesh is empty or its mean is not finite.
  public var center: CGPoint? {
    guard !mesh.isEmpty else { return nil }
    let total = mesh.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
    let count = CGFloat(mesh.count)
    let center = CGPoint(x: total.x / count, y: total.y / count)
    guard center.x.isFinite, center.y.isFinite else { return nil }
    return center
  }

  /// The band the visor reveals: the bounding box of mesh points 33, 133, 362,
  /// 263, 70, 300 (eye corners and brow ends) padded by 0.6 of its own height
  /// above and below and 0.25 of its width on each side, clamped to 0...1. nil
  /// when mesh has fewer than 468 points.
  public var eyeBand: CGRect? {
    guard mesh.count >= CanonicalFaceModel.vertexCount else { return nil }

    let indices = [33, 133, 362, 263, 70, 300]
    var minX = CGFloat.greatestFiniteMagnitude
    var maxX = -CGFloat.greatestFiniteMagnitude
    var minY = CGFloat.greatestFiniteMagnitude
    var maxY = -CGFloat.greatestFiniteMagnitude
    for index in indices {
      let point = mesh[index]
      minX = min(minX, point.x)
      maxX = max(maxX, point.x)
      minY = min(minY, point.y)
      maxY = max(maxY, point.y)
    }

    let padX = 0.25 * (maxX - minX)
    let padY = 0.6 * (maxY - minY)
    let left = clamp(minX - padX)
    let right = clamp(maxX + padX)
    let top = clamp(minY - padY)
    let bottom = clamp(maxY + padY)
    return CGRect(x: left, y: top, width: right - left, height: bottom - top)
  }

  private func clamp(_ value: CGFloat) -> CGFloat {
    min(max(value, 0), 1)
  }
}

public enum CalibrationSetupGuidance: Equatable, Sendable {
  case findingFace
  case moveCloser
  case moveBack
  case centerFace(offsetX: Double, offsetY: Double)
  case holdStill(progress: Double)
  case ready
}

/// Decides what to tell the user from a stream of faces. Pure and clock-driven,
/// so tests pass explicit times.
public struct CalibrationSetupReducer: Equatable, Sendable {
  public static let depthRange: ClosedRange<Double> = 45...75
  public static let centerTolerance = 0.12
  public static let holdDuration: TimeInterval = 1.0

  private var holdStart: TimeInterval?

  public init() {}

  public mutating func update(face: CalibrationSetupFace?, at time: TimeInterval)
    -> CalibrationSetupGuidance
  {
    guard let face, !face.mesh.isEmpty else {
      holdStart = nil
      return .findingFace
    }

    if let depth = face.depthCentimetres {
      if depth < Self.depthRange.lowerBound {
        holdStart = nil
        return .moveBack
      }
      if depth > Self.depthRange.upperBound {
        holdStart = nil
        return .moveCloser
      }
    }

    guard let center = face.center else {
      holdStart = nil
      return .findingFace
    }
    let offsetX = Double(center.x) - 0.5
    let offsetY = Double(center.y) - 0.5
    guard abs(offsetX) <= Self.centerTolerance, abs(offsetY) <= Self.centerTolerance else {
      holdStart = nil
      return .centerFace(offsetX: offsetX, offsetY: offsetY)
    }

    guard let start = holdStart else {
      holdStart = time
      return .holdStill(progress: 0)
    }
    let progress = min(max((time - start) / Self.holdDuration, 0), 1)
    return progress >= 1 ? .ready : .holdStill(progress: progress)
  }
}
