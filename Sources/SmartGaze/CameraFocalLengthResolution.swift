import Foundation
import GazeKit

/// Which input supplied the vertical focal length a pipeline is using, for the
/// one launch-log line per pipeline start.
enum FocalLengthSource: String, Equatable {
  case intrinsics
  case measured
  case table
  case assumed
}

struct ResolvedFocalLength {
  let source: FocalLengthSource
  let verticalFocalLengthPixels: Double
  let verticalFieldOfViewDegrees: Double
}

enum CameraFocalLengthResolution {
  /// Preference order: the camera's own intrinsics, then a stored
  /// measurement, then the per-model table, then the hand-fitted fallback. A
  /// stored measurement outside the plausible field-of-view range is skipped
  /// rather than applied.
  ///
  /// - Returns: `nil` when `frameHeight` is not a positive finite number.
  static func resolve(
    measured: CameraFocalLength?,
    intrinsicFocalLengthPixels: Double?,
    cameraName: String?,
    frameHeight: Double
  ) -> ResolvedFocalLength? {
    guard frameHeight.isFinite, frameHeight > 0 else { return nil }

    if let intrinsicFocalLengthPixels, intrinsicFocalLengthPixels.isFinite,
      intrinsicFocalLengthPixels > 0,
      let fieldOfViewDegrees = FocalLengthCalibration.verticalFieldOfViewDegrees(
        focalLengthPixels: intrinsicFocalLengthPixels, frameHeight: frameHeight)
    {
      return ResolvedFocalLength(
        source: .intrinsics,
        verticalFocalLengthPixels: intrinsicFocalLengthPixels,
        verticalFieldOfViewDegrees: fieldOfViewDegrees)
    }

    if let measured, measured.isPlausible {
      let pixels = measured.verticalFocalLengthPixels(frameHeight: frameHeight)
      if let fieldOfViewDegrees = FocalLengthCalibration.verticalFieldOfViewDegrees(
        focalLengthPixels: pixels, frameHeight: frameHeight)
      {
        return ResolvedFocalLength(
          source: .measured,
          verticalFocalLengthPixels: pixels,
          verticalFieldOfViewDegrees: fieldOfViewDegrees)
      }
    }

    let source: FocalLengthSource
    let degrees: Double
    if let cameraName, let tableDegrees = CameraGeometry.knownCameras[cameraName] {
      source = .table
      degrees = tableDegrees
    } else {
      source = .assumed
      degrees = CameraGeometry.builtInVerticalFieldOfViewDegrees
    }
    return ResolvedFocalLength(
      source: source,
      verticalFocalLengthPixels: CameraGeometry.verticalFocalLengthPixels(
        verticalFieldOfViewDegrees: degrees, frameHeight: frameHeight),
      verticalFieldOfViewDegrees: degrees)
  }
}
