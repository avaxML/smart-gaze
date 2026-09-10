import CoreGraphics
import Foundation

/// Pure geometry for the 512×128 eye band consumed by BlazeGaze.
///
/// Pads landmarks 103/150/379/332 radially away from centre 4 with anisotropic
/// coefficients `(0.4, 0.2)`, solves the projective map from that quad onto the
/// 512×512 face crop, then projects landmarks 151/195 to the clamped
/// `[top, bottom)` row band. Row cropping and resize are a separate raster
/// stage, so this unit does not claim pixel parity.
///
/// Formula sources and the parity caveat are in
/// `Docs/models/eye-band-geometry.md`.
public struct EyeBandGeometry: Equatable, Sendable {
  /// Side length of the square face crop the projective map targets.
  public static let faceCropSize = 512

  /// Minimum landmark count accepted. Every index used here is below 468.
  public static let minimumLandmarkCount = 468

  /// The padded source quad in full-frame pixel space, in the order
  /// `[103, 150, 379, 332]`.
  public let sourceQuad: [CGPoint]

  /// The projective map from `sourceQuad` onto the 512×512 face crop.
  public let transform: ProjectiveTransform

  /// Half-open rows `[top, bottom)` of the 512×512 face crop, before resize.
  public let bandRowRange: Range<Int>

  public init(sourceQuad: [CGPoint], transform: ProjectiveTransform, bandRowRange: Range<Int>) {
    self.sourceQuad = sourceQuad
    self.transform = transform
    self.bandRowRange = bandRowRange
  }

  /// Computes eye-band geometry from full-frame normalized top-left landmarks.
  ///
  /// - Parameters:
  ///   - landmarks: At least 468 normalized (`0...1`) landmarks.
  ///   - frameSize: Positive frame dimensions in pixels.
  /// - Returns: Geometry with a non-empty band, or `nil` for too few
  ///   landmarks, non-finite/negative frame dimensions, non-finite points, a
  ///   singular quad, or an empty or reversed row band. Source points are
  ///   never clamped to the frame; border padding may fall outside it.
  public static func compute(landmarks: [CGPoint], frameSize: CGSize) -> EyeBandGeometry? {
    guard landmarks.count >= minimumLandmarkCount else { return nil }

    let width = Double(frameSize.width)
    let height = Double(frameSize.height)
    guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }

    // Landmark order matches WebEyeTrack: lefttop, leftbottom, rightbottom, righttop.
    let cornerIndices = [103, 150, 379, 332]
    var corners: [CGPoint] = []
    corners.reserveCapacity(4)
    for index in cornerIndices {
      guard let pixel = pixelPoint(landmarks[index], width, height) else { return nil }
      corners.append(pixel)
    }
    guard let center = pixelPoint(landmarks[4], width, height) else { return nil }

    let sourceQuad = corners.map { corner in
      CGPoint(
        x: corner.x + 0.4 * (corner.x - center.x),
        y: corner.y + 0.2 * (corner.y - center.y)
      )
    }
    guard sourceQuad.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }

    let side = Double(faceCropSize)
    let destination = [
      CGPoint(x: 0, y: 0),
      CGPoint(x: 0, y: side),
      CGPoint(x: side, y: side),
      CGPoint(x: side, y: 0),
    ]
    guard let transform = ProjectiveTransform(source: sourceQuad, destination: destination) else {
      return nil
    }

    guard
      let topPoint = pixelPoint(landmarks[151], width, height),
      let bottomPoint = pixelPoint(landmarks[195], width, height),
      let warpedTop = transform.map(topPoint),
      let warpedBottom = transform.map(bottomPoint)
    else { return nil }

    let topRow = clampRow(warpedTop.y)
    let bottomRow = clampRow(warpedBottom.y)
    guard bottomRow > topRow else { return nil }

    return EyeBandGeometry(
      sourceQuad: sourceQuad,
      transform: transform,
      bandRowRange: topRow..<bottomRow
    )
  }

  private static func pixelPoint(_ landmark: CGPoint, _ width: Double, _ height: Double) -> CGPoint?
  {
    let x = Double(landmark.x) * width
    let y = Double(landmark.y) * height
    guard x.isFinite, y.isFinite else { return nil }
    return CGPoint(x: x, y: y)
  }

  /// Truncates toward zero, then clamps to `0...512` without risking an
  /// out-of-range `Int` conversion for very large finite coordinates.
  private static func clampRow(_ value: Double) -> Int {
    let truncated = value.rounded(.towardZero)
    if truncated <= 0 { return 0 }
    if truncated >= Double(faceCropSize) { return faceCropSize }
    return Int(truncated)
  }
}
