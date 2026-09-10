import Foundation

enum MenuBarState: Equatable, Sendable {
  case off
  case on
  case cameraLive
  case captureBusy

  var symbolName: String {
    switch self {
    case .off: "eye.slash"
    case .on: "eye"
    case .cameraLive: "video.fill"
    case .captureBusy: "camera.viewfinder"
    }
  }

  var accessibilityDescription: String {
    switch self {
    case .off: "SmartGaze is off"
    case .on: "SmartGaze is starting the camera"
    case .cameraLive: "SmartGaze camera is live"
    case .captureBusy: "SmartGaze is capturing"
    }
  }
}
