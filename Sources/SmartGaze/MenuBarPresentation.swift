import Foundation

enum MenuBarState: Equatable, Sendable {
  case off
  case waitingForPermission
  case permissionDenied
  case starting
  case timedOut
  case cameraLive
  case uncalibrated
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
    case .captureBusy: "SmartGaze is capturing"
    }
  }

  /// The single place that folds camera state, whether calibration exists,
  /// and whether an explanation capture is in flight into one presentation.
  /// Pure and AVFoundation-free, so it is testable with literal camera
  /// states and no real camera.
  static func presenting(
    camera: CameraController.State, calibrationNeeded: Bool, isCaptureBusy: Bool
  ) -> MenuBarState {
    if isCaptureBusy { return .captureBusy }
    switch camera {
    case .off: return .off
    case .waitingForPermission: return .waitingForPermission
    case .permissionDenied: return .permissionDenied
    case .starting: return .starting
    case .timedOut: return .timedOut
    case .live: return calibrationNeeded ? .uncalibrated : .cameraLive
    }
  }
}
