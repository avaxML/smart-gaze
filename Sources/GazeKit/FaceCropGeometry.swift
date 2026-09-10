import CoreGraphics
import Foundation

/// Turns a Vision face rectangle into the square crop the dense face-mesh
/// model reads. Vision reports bottom-left normalized boxes; this flips to
/// top-left frame pixels before expanding and clamping.
public enum FaceCropGeometry {
  /// `Tools/Conversion/facemesh_parity.py` swept candidate expansion factors
  /// against the pinned face-mesh model and this is the value it selected.
  /// It is not a published constant (u08 plan §3.1, §9.5).
  public static let expansionFactor = 1.5

  /// Computes the square, frame-clamped crop rectangle in full-frame pixel
  /// space, top-left origin.
  ///
  /// - Parameters:
  ///   - visionBoundingBox: Vision's normalized, bottom-left-origin face
  ///     rectangle.
  ///   - frameSize: Positive frame dimensions in pixels.
  /// - Returns: `nil` for a non-finite or non-positive box or frame size.
  ///   The returned square may be smaller than `expansionFactor` times the
  ///   box when the box sits near an edge of a frame smaller than the
  ///   expanded side.
  public static func expandedFaceCrop(
    visionBoundingBox: CGRect,
    frameSize: CGSize
  ) -> CGRect? {
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
    let side = max(widthPx, heightPx) * expansionFactor
    guard side.isFinite, side > 0 else { return nil }

    return clampedCaptureRect(
      center: center,
      size: CGSize(width: side, height: side),
      within: CGRect(origin: .zero, size: frameSize)
    )
  }
}
