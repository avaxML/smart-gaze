import Foundation

enum MenuBarState: Equatable, Sendable {
  case off
  case waitingForPermission
  case permissionDenied
  case starting
  case timedOut
  case cameraLive
  case uncalibrated
  case accessibilityDegraded
  case captureBusy

  var symbolName: String {
    switch self {
    case .off: "eye.slash"
    case .waitingForPermission: "questionmark.circle.fill"
    case .permissionDenied: "video.slash.fill"
    case .starting: "eye"
    case .timedOut: "exclamationmark.triangle.fill"
    case .cameraLive: "video.fill"
    case .uncalibrated: "scope"
    case .accessibilityDegraded: "accessibility"
    case .captureBusy: "camera.viewfinder"
    }
  }

  var accessibilityDescription: String {
    switch self {
    case .off: "SmartGaze is off"
    case .waitingForPermission: "SmartGaze is waiting for camera permission"
    case .permissionDenied: "SmartGaze camera access is denied"
    case .starting: "SmartGaze is starting the camera"
    case .timedOut: "SmartGaze camera did not start"
    case .cameraLive: "SmartGaze camera is live"
    case .uncalibrated: "SmartGaze needs calibration"
    case .accessibilityDegraded: "SmartGaze is running in dwell mode"
    case .captureBusy: "SmartGaze is capturing"
    }
  }

  /// The single place that folds camera state, whether calibration exists,
  /// whether the modifier-held activation mode fell back to passive dwell,
  /// and whether an explanation capture is in flight into one presentation.
  /// Pure and AVFoundation-free, so it is testable with literal camera
  /// states and no real camera.
  ///
  /// When the camera is live, an outstanding calibration takes priority
  /// over reporting the dwell fallback: tracking is unusable without
  /// calibration regardless of activation mode, so that is the more urgent
  /// thing to surface.
  static func presenting(
    camera: CameraController.State, calibrationNeeded: Bool, isCaptureBusy: Bool,
    accessibilityDegraded: Bool = false
  ) -> MenuBarState {
    if isCaptureBusy { return .captureBusy }
    switch camera {
    case .off: return .off
    case .waitingForPermission: return .waitingForPermission
    case .permissionDenied: return .permissionDenied
    case .starting: return .starting
    case .timedOut: return .timedOut
    case .live:
      if calibrationNeeded { return .uncalibrated }
      if accessibilityDegraded { return .accessibilityDegraded }
      return .cameraLive
    }
  }
}
