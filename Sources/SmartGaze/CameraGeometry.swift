import Foundation

/// What the app assumes about the camera it runs on, because macOS reports
/// neither a field of view nor an intrinsic matrix for the built-in camera.
enum CameraGeometry {
  /// Fitted, not measured. At the 60 degree default the first live calibration
  /// recorded a face distance of 27.8 cm against a real sitting distance near
  /// 55 cm, and horizontal gaze barely moved across the screen. At 32 degrees
  /// the depth landed where it should and horizontal error fell from 188,235
  /// points to 33. The per-device table in #71 replaces this with a real value.
  static let builtInVerticalFieldOfViewDegrees = 32.0
}
