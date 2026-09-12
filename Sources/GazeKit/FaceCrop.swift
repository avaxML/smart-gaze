import CoreGraphics
import Foundation

/// A square region of the camera frame, possibly rotated, that the face-mesh
/// model reads. Frame pixels, top-left origin, y down.
public struct FaceCrop: Equatable, Sendable {
  /// `Tools/Conversion/facemesh_parity.py` swept candidate expansion factors
  /// against the pinned face-mesh model and this is the value it selected.
  /// It is not a published constant (u08 plan §3.1, §9.5).
  public static let expansionFactor = 1.5

  public let center: CGPoint
  public let side: Double
  /// Angle of the crop's x axis in the image frame, radians, positive from +x
  /// toward +y (clockwise on screen). 0 is axis aligned.
  public let rotationRadians: Double

  /// `nil` for a non-finite value or `side <= 0`.
  public init?(center: CGPoint, side: Double, rotationRadians: Double) {
    guard
      center.x.isFinite, center.y.isFinite,
      side.isFinite, rotationRadians.isFinite,
      side > 0
    else { return nil }
    self.center = center
    self.side = side
    self.rotationRadians = rotationRadians
  }

  /// The original axis-aligned seed behaviour: Vision's normalized
  /// bottom-left box flipped to top-left pixels, expanded by
  /// `expansionFactor`, square, clamped into the frame with
  /// `clampedCaptureRect`, rotation 0.
  ///
  /// - Returns: `nil` for a non-finite or non-positive box or frame size. The
  ///   returned square may be smaller than `expansionFactor` times the box
  ///   when the box sits near an edge of a frame smaller than the expanded
  ///   side.
  public static func seed(visionBoundingBox: CGRect, frameSize: CGSize) -> FaceCrop? {
    guard
      frameSize.width.isFinite, frameSize.height.isFinite,
      frameSize.width > 0, frameSize.height > 0
    else { return nil }
    guard
      visionBoundingBox.origin.x.isFinite, visionBoundingBox.origin.y.isFinite,
      visionBoundingBox.width.isFinite, visionBoundingBox.height.isFinite,
      visionBoundingBox.width > 0, visionBoundingBox.height > 0
    else { return nil }

    let width = Double(frameSize.width)
    let height = Double(frameSize.height)

    let widthPx = Double(visionBoundingBox.width) * width
    let heightPx = Double(visionBoundingBox.height) * height
    let originXPx = Double(visionBoundingBox.origin.x) * width
    // Vision's origin is the box's bottom-left corner in a bottom-left-origin
    // normalized space; the top-left frame-pixel y of that same corner is
    // measured from the top down.
    let topLeftYPx = height - Double(visionBoundingBox.origin.y) * height - heightPx

    let center = CGPoint(x: originXPx + widthPx / 2, y: topLeftYPx + heightPx / 2)
    let side = min(max(widthPx, heightPx) * expansionFactor, width, height)
    guard side.isFinite, side > 0 else { return nil }

    let rect = clampedCaptureRect(
      center: center,
      size: CGSize(width: side, height: side),
      within: CGRect(origin: .zero, size: frameSize)
    )
    return FaceCrop(
      center: CGPoint(x: rect.midX, y: rect.midY),
      side: Double(rect.width),
      rotationRadians: 0)
  }

  /// MediaPipe's landmarks-to-ROI from the previous frame's full-frame
  /// pixel-space landmarks (the `pixelSpace` array of `FullFrameLandmarks`,
  /// 468 entries).
  ///
  /// The rotation is folded into `(-pi/2, pi/2]` so a mirrored frame still
  /// yields a near-level crop. There is no clamping to the frame; out-of-frame
  /// samples replicate the edge.
  ///
  /// - Returns: `nil` when `landmarks.count != 468`, any `x` or `y` is
  ///   non-finite, the box has zero width and height, or `side < 1`.
  public static func tracking(landmarks: [SIMD3<Double>], frameSize: CGSize) -> FaceCrop? {
    guard landmarks.count == 468 else { return nil }

    var minX = Double.infinity
    var minY = Double.infinity
    var maxX = -Double.infinity
    var maxY = -Double.infinity
    for landmark in landmarks {
      guard landmark.x.isFinite, landmark.y.isFinite else { return nil }
      minX = min(minX, landmark.x)
      minY = min(minY, landmark.y)
      maxX = max(maxX, landmark.x)
      maxY = max(maxY, landmark.y)
    }

    let boxWidth = maxX - minX
    let boxHeight = maxY - minY
    guard boxWidth > 0 || boxHeight > 0 else { return nil }

    let side = max(boxWidth, boxHeight) * expansionFactor
    guard side >= 1 else { return nil }

    let eyeA = landmarks[33]
    let eyeB = landmarks[263]
    var rotation = atan2(eyeB.y - eyeA.y, eyeB.x - eyeA.x)
    if rotation > .pi / 2 {
      rotation -= .pi
    } else if rotation <= -(.pi / 2) {
      rotation += .pi
    }

    return FaceCrop(
      center: CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2),
      side: side,
      rotationRadians: rotation)
  }

  /// Frame pixels per crop pixel: `side / cropPixelSize`.
  public func scale(cropPixelSize: Double) -> Double {
    side / cropPixelSize
  }

  /// Affine map from crop-pixel space (`0...cropPixelSize`, top-left) to frame
  /// pixels: `frame = center + R(rotation) * (p * scale - side / 2)`, with
  /// `R = [[cos, -sin], [sin, cos]]`. For rotation 0 this is exactly the
  /// sampling grid `resampledRGB` uses over the rect (`center - side/2`,
  /// `side`).
  ///
  /// - Returns: `nil` only for a non-finite or non-positive `cropPixelSize`.
  public func cropToFrame(cropPixelSize: Double) -> ProjectiveTransform? {
    guard cropPixelSize.isFinite, cropPixelSize > 0 else { return nil }
    let pixelsPerCropPixel = scale(cropPixelSize: cropPixelSize)
    let cosR = cos(rotationRadians)
    let sinR = sin(rotationRadians)
    let centerX = Double(center.x)
    let centerY = Double(center.y)
    let offset = -side / 2
    let tx = centerX + cosR * offset - sinR * offset
    let ty = centerY + sinR * offset + cosR * offset

    return ProjectiveTransform(matrix: [
      pixelsPerCropPixel * cosR, -pixelsPerCropPixel * sinR, tx,
      pixelsPerCropPixel * sinR, pixelsPerCropPixel * cosR, ty,
      0, 0, 1,
    ])
  }

  /// Inverse of `cropToFrame`. This is what `warpedRGB` takes as its
  /// `transform` (it maps destination pixels through `transform.inverse` to
  /// find the sample).
  ///
  /// - Returns: `nil` only for a non-finite or non-positive `cropPixelSize`.
  public func frameToCrop(cropPixelSize: Double) -> ProjectiveTransform? {
    cropToFrame(cropPixelSize: cropPixelSize)?.inverse
  }
}
