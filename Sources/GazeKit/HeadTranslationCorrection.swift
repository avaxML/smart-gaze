import CoreGraphics
import Foundation

/// Moves the projected gaze point to undo the head's translation since
/// calibration.
///
/// The calibration map is fitted at one head position. When the head moves
/// sideways or vertically while the eyes hold a target, the eyes rotate to
/// compensate and the gaze model reports that rotation as a shifted gaze.
/// Geometrically 1 cm of head is 1 cm of screen. BlazeGaze receives the face
/// origin and cancels a measured 18 percent of the horizontal shift and 1
/// percent of the vertical one; the rest is applied here. Depth is not
/// corrected: the model's own origin term tracks it within a point per cm.
///
/// `referenceOriginCentimeters` is the mean face origin over the accepted
/// calibration bursts, camera frame, x image-right, y image-down, z away.
public struct HeadTranslationCorrection: Equatable, Sendable, Codable {
  public static let horizontalShareLeftToCorrect = 0.82
  public static let verticalShareLeftToCorrect = 0.99

  public let referenceOriginCentimeters: SIMD3<Double>
  public let pointsPerCentimeter: SIMD2<Double>

  public init(referenceOriginCentimeters: SIMD3<Double>, pointsPerCentimeter: SIMD2<Double>) {
    self.referenceOriginCentimeters = referenceOriginCentimeters
    self.pointsPerCentimeter = pointsPerCentimeter
  }

  /// The largest displacement the correction will act on, per axis. Posture
  /// drift within a session is a few centimetres. Beyond that the camera
  /// frame stops being a proxy for the screen plane: a laptop lid is tilted,
  /// so leaning back 25 cm alone moves the face several centimetres down in
  /// the image with no change in where the eyes sit against the screen, and
  /// an uncapped correction then pushed the point hundreds of points off the
  /// display. Clamping bounds that error to about 150 pt until the lid angle
  /// is modelled.
  public static let maximumDisplacementCentimeters = 3.0

  public func correct(_ point: CGPoint, faceOriginCentimeters origin: SIMD3<Double>) -> CGPoint {
    let raw = origin - referenceOriginCentimeters
    guard raw.x.isFinite, raw.y.isFinite else { return point }
    let limit = Self.maximumDisplacementCentimeters
    let delta = SIMD3(max(-limit, min(limit, raw.x)), max(-limit, min(limit, raw.y)), raw.z)
    // The un-mirrored camera puts the user's right on the image left, and the
    // model reports gaze in the user's frame. A head that moves towards image
    // right (the user's left) makes the eyes turn to the user's right to hold
    // the target, which reads as a point further right: take it back.
    let dx = -Self.horizontalShareLeftToCorrect * pointsPerCentimeter.x * delta.x
    // Image y and screen y both grow downwards. A head that moves down makes
    // the eyes look up to hold the target, which reads as a higher point.
    let dy = Self.verticalShareLeftToCorrect * pointsPerCentimeter.y * delta.y
    return CGPoint(x: point.x + dx, y: point.y + dy)
  }

  /// Depth ratios outside this band are treated as estimator trouble or a
  /// posture the map was never meant for, and held at the edge.
  public static let depthRatioRange: ClosedRange<Double> = 0.7...1.4

  /// Scales the point's offset from the spot straight ahead of the eyes by
  /// the change in distance since calibration. The affine map was fitted at
  /// one depth; the same gaze angle lands proportionally further from that
  /// spot as the head moves back, which the model's own origin term does not
  /// cover away from the centre. `displayBounds` is the calibrated display in
  /// global points; the camera is taken to sit at its top centre.
  public func scaleForDepth(
    _ point: CGPoint, faceOriginCentimeters origin: SIMD3<Double>, displayBounds: CGRect
  ) -> CGPoint {
    guard origin.z.isFinite, origin.z > 0, referenceOriginCentimeters.z > 0 else { return point }
    let raw = origin.z / referenceOriginCentimeters.z
    let ratio = min(max(raw, Self.depthRatioRange.lowerBound), Self.depthRatioRange.upperBound)
    let foot = CGPoint(
      x: displayBounds.midX + origin.x * pointsPerCentimeter.x,
      y: displayBounds.minY + origin.y * pointsPerCentimeter.y)
    return CGPoint(
      x: foot.x + (point.x - foot.x) * ratio,
      y: foot.y + (point.y - foot.y) * ratio)
  }
}
