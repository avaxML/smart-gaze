import Foundation

/// One-time per-camera focal length from the iris ruler.
///
/// The iris is a near-constant 11.7 mm across adults, so at a known distance
/// its pixel diameter gives the camera's focal length directly. The fitted
/// value is stored as a fraction of the frame height so it survives a
/// resolution change.
public enum FocalLengthCalibration {
  public static let minimumSamples = 15

  /// A median outside this range means a wrong distance or a broken iris
  /// reading, not a camera.
  public static let plausibleVerticalFieldOfViewDegrees: ClosedRange<Double> = 20...90

  /// `irisDiameterPixels * distanceCentimetres * 10 / IrisGeometry.irisDiameterMillimetres`.
  ///
  /// - Returns: `nil` when either input is non-finite or non-positive.
  public static func focalLengthPixels(
    irisDiameterPixels: Double, distanceCentimetres: Double
  ) -> Double? {
    guard
      irisDiameterPixels.isFinite, irisDiameterPixels > 0,
      distanceCentimetres.isFinite, distanceCentimetres > 0
    else { return nil }
    return irisDiameterPixels * distanceCentimetres * 10 / IrisGeometry.irisDiameterMillimetres
  }

  /// Median of the per-frame focal lengths, in pixels.
  ///
  /// - Returns: `nil` for fewer than `minimumSamples` values, or when the
  ///   vertical field of view the median implies for `frameHeight`
  ///   (`2 * atan(frameHeight / (2 * focal))`) is outside
  ///   `plausibleVerticalFieldOfViewDegrees`.
  public static func fit(focalLengthsPixels: [Double], frameHeight: Double) -> Double? {
    guard focalLengthsPixels.count >= minimumSamples else { return nil }
    let sorted = focalLengthsPixels.sorted()
    let median = sorted[sorted.count / 2]
    guard
      let fieldOfViewDegrees = verticalFieldOfViewDegrees(
        focalLengthPixels: median, frameHeight: frameHeight),
      plausibleVerticalFieldOfViewDegrees.contains(fieldOfViewDegrees)
    else { return nil }
    return median
  }

  /// `2 * atan(frameHeight / (2 * focalLengthPixels))`, degrees.
  ///
  /// - Returns: `nil` for a non-finite or non-positive input.
  public static func verticalFieldOfViewDegrees(
    focalLengthPixels: Double, frameHeight: Double
  ) -> Double? {
    guard
      focalLengthPixels.isFinite, focalLengthPixels > 0,
      frameHeight.isFinite, frameHeight > 0
    else { return nil }
    return 2 * atan(frameHeight / (2 * focalLengthPixels)) * 180 / .pi
  }
}

/// A measured camera: the focal length stored as a fraction of the frame
/// height, so it survives a resolution change.
public struct CameraFocalLength: Equatable, Sendable, Codable {
  /// `AVCaptureDevice.uniqueID`.
  public let cameraID: String
  public let cameraName: String
  public let focalLengthPerFrameHeight: Double

  public init(
    cameraID: String = "", cameraName: String = "", focalLengthPerFrameHeight: Double
  ) {
    self.cameraID = cameraID
    self.cameraName = cameraName
    self.focalLengthPerFrameHeight = focalLengthPerFrameHeight
  }

  public func verticalFocalLengthPixels(frameHeight: Double) -> Double {
    focalLengthPerFrameHeight * frameHeight
  }
}
