import Foundation

/// What the app assumes about the camera it runs on, because macOS reports
/// neither a field of view nor an intrinsic matrix for the built-in camera.
enum CameraGeometry {
  /// Fitted, not measured. At the 60 degree default the first live calibration
  /// recorded a face distance of 27.8 cm against a real sitting distance near
  /// 55 cm, and horizontal gaze barely moved across the screen. At 32 degrees
  /// the depth landed where it should and horizontal error fell from 188,235
  /// points to 33.
  static let builtInVerticalFieldOfViewDegrees = 32.0

  /// Seed field of view per camera model, degrees, used when no measured
  /// focal length is stored for the camera. Deliberately tiny: a measurement
  /// from the Camera distance section is the real source, and this only keeps
  /// a known model on its fitted value until then.
  static let knownCameras: [String: Double] = [
    "MacBook Pro Camera": 32.0
  ]

  static func verticalFocalLengthPixels(
    verticalFieldOfViewDegrees degrees: Double, frameHeight: Double
  ) -> Double {
    frameHeight / (2 * tan(degrees / 2 * .pi / 180))
  }
}
