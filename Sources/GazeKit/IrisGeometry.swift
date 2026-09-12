import CoreGraphics
import Foundation

/// Pure geometry for the MediaPipe iris landmark model: the square eye ROI it
/// reads, the horizontal flip used to feed the right eye as a left-eye-shaped
/// crop, and the person-independent iris depth ruler.
///
/// Iris diameter is nearly constant across adults (11.7 mm), unlike the assumed
/// interpupillary distance the mesh eye-baseline depth relies on, so this ruler
/// does not carry a per-person scale error.
public enum IrisGeometry {
  /// The model's square input side, in crop pixels.
  public static let cropPixelSize = 64

  /// MediaPipe's eye ROI expansion: a square whose side is this multiple of the
  /// distance between the eye corners.
  public static let eyeCropScale = 2.3

  public static let irisDiameterMillimetres = 11.7
  public static let contourPointCount = 71
  public static let irisPointCount = 5

  /// MediaPipe's eye ROI: a square centred on the midpoint of the two eye-corner
  /// landmarks (full-frame pixel space), `side = distance * eyeCropScale`,
  /// `rotation = atan2(right.y - left.y, right.x - left.x)` folded into
  /// `(-pi/2, pi/2]` exactly like `FaceCrop.tracking`.
  ///
  /// - Returns: `nil` when the corner distance is below 1 pixel or any
  ///   coordinate is non-finite.
  public static func eyeCrop(
    imageLeftCorner: SIMD3<Double>,
    imageRightCorner: SIMD3<Double>
  ) -> FaceCrop? {
    guard
      imageLeftCorner.x.isFinite, imageLeftCorner.y.isFinite, imageLeftCorner.z.isFinite,
      imageRightCorner.x.isFinite, imageRightCorner.y.isFinite, imageRightCorner.z.isFinite
    else { return nil }

    let deltaX = imageRightCorner.x - imageLeftCorner.x
    let deltaY = imageRightCorner.y - imageLeftCorner.y
    let distance = (deltaX * deltaX + deltaY * deltaY).squareRoot()
    guard distance >= 1 else { return nil }

    var rotation = atan2(deltaY, deltaX)
    if rotation > .pi / 2 {
      rotation -= .pi
    } else if rotation <= -(.pi / 2) {
      rotation += .pi
    }

    return FaceCrop(
      center: CGPoint(
        x: (imageLeftCorner.x + imageRightCorner.x) / 2,
        y: (imageLeftCorner.y + imageRightCorner.y) / 2),
      side: distance * eyeCropScale,
      rotationRadians: rotation)
  }

  /// Column-reversed copy of a `width` x `height` RGB float buffer
  /// (`i -> width - 1 - i`). Returns the input unchanged for a non-positive
  /// dimension or a buffer whose element count does not match.
  public static func horizontallyFlipped(rgb: [Float], width: Int, height: Int) -> [Float] {
    guard width > 0, height > 0, rgb.count == width * height * 3 else { return rgb }
    var output = [Float](repeating: 0, count: rgb.count)
    for row in 0..<height {
      for column in 0..<width {
        let source = (row * width + (width - 1 - column)) * 3
        let destination = (row * width + column) * 3
        output[destination] = rgb[source]
        output[destination + 1] = rgb[source + 1]
        output[destination + 2] = rgb[source + 2]
      }
    }
    return output
  }

  /// Undo the flip on model output in crop pixels: `x' = width - 1 - x`, `y`
  /// and `z` unchanged.
  public static func unflipped(_ point: SIMD3<Double>, width: Int) -> SIMD3<Double> {
    SIMD3<Double>(Double(width - 1) - point.x, point.y, point.z)
  }

  /// A crop-space `z` mapped through `scale` to frame pixels and divided by
  /// the frame width, the same units as `GazeEstimate.meshDepth`.
  public static func depthFraction(cropZ: Double, scale: Double, frameWidth: Double) -> Double {
    cropZ * scale / frameWidth
  }

  /// Distance between iris points 1 and 3, the horizontal extremes, in whatever
  /// space the points are in.
  ///
  /// - Returns: `nil` for fewer than `irisPointCount` points.
  public static func irisDiameter(_ irisPoints: [SIMD2<Double>]) -> Double? {
    guard irisPoints.count >= irisPointCount else { return nil }
    let delta = irisPoints[3] - irisPoints[1]
    return (delta.x * delta.x + delta.y * delta.y).squareRoot()
  }

  /// `focalLengthPixels * irisDiameterMillimetres / 10 / diameterPixels`,
  /// centimetres.
  ///
  /// - Returns: `nil` for a non-positive or non-finite input.
  public static func depthCentimetres(
    irisDiameterPixels: Double,
    focalLengthPixels: Double
  ) -> Double? {
    guard
      irisDiameterPixels.isFinite, irisDiameterPixels > 0,
      focalLengthPixels.isFinite, focalLengthPixels > 0
    else { return nil }
    return focalLengthPixels * irisDiameterMillimetres / 10 / irisDiameterPixels
  }
}
