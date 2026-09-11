import Testing

@testable import SmartGaze

@Test func captureBusyOverridesEveryCameraState() {
  for camera: CameraController.State in [
    .off, .waitingForPermission, .permissionDenied, .starting, .timedOut, .live,
  ] {
    #expect(
      MenuBarState.presenting(camera: camera, calibrationNeeded: false, isCaptureBusy: true)
        == .captureBusy)
    #expect(
      MenuBarState.presenting(camera: camera, calibrationNeeded: true, isCaptureBusy: true)
        == .captureBusy)
  }
}

@Test func eachCameraStateMapsToItsOwnMenuStateWhenNotBusy() {
  #expect(
    MenuBarState.presenting(camera: .off, calibrationNeeded: false, isCaptureBusy: false) == .off)
  #expect(
    MenuBarState.presenting(
      camera: .waitingForPermission, calibrationNeeded: false, isCaptureBusy: false)
      == .waitingForPermission)
  #expect(
    MenuBarState.presenting(
      camera: .permissionDenied, calibrationNeeded: false, isCaptureBusy: false)
      == .permissionDenied)
  #expect(
    MenuBarState.presenting(camera: .starting, calibrationNeeded: false, isCaptureBusy: false)
      == .starting)
  #expect(
    MenuBarState.presenting(camera: .timedOut, calibrationNeeded: false, isCaptureBusy: false)
      == .timedOut)
}

@Test func liveCameraSplitsOnCalibration() {
  #expect(
    MenuBarState.presenting(camera: .live, calibrationNeeded: false, isCaptureBusy: false)
      == .cameraLive)
  #expect(
    MenuBarState.presenting(camera: .live, calibrationNeeded: true, isCaptureBusy: false)
      == .uncalibrated)
}

@Test func calibrationNeededHasNoEffectOffTheLiveState() {
  for camera: CameraController.State in [
    .off, .waitingForPermission, .permissionDenied, .starting, .timedOut,
  ] {
    let withoutCalibration = MenuBarState.presenting(
      camera: camera, calibrationNeeded: false, isCaptureBusy: false)
    let withCalibrationNeeded = MenuBarState.presenting(
      camera: camera, calibrationNeeded: true, isCaptureBusy: false)
    #expect(withoutCalibration == withCalibrationNeeded)
  }
}

@Test func everyMenuStateHasADistinctSymbolAndDescription() {
  let allStates: [MenuBarState] = [
    .off, .waitingForPermission, .permissionDenied, .starting, .timedOut, .cameraLive,
    .uncalibrated, .captureBusy,
  ]
  #expect(Set(allStates.map(\.symbolName)).count == allStates.count)
  #expect(Set(allStates.map(\.accessibilityDescription)).count == allStates.count)
}

@Test func literalSymbolsAndDescriptionsForEachState() {
  #expect(MenuBarState.off.symbolName == "eye.slash")
  #expect(MenuBarState.off.accessibilityDescription == "SmartGaze is off")

  #expect(MenuBarState.waitingForPermission.symbolName == "questionmark.circle.fill")
  #expect(
    MenuBarState.waitingForPermission.accessibilityDescription
      == "SmartGaze is waiting for camera permission")

  #expect(MenuBarState.permissionDenied.symbolName == "video.slash.fill")
  #expect(
    MenuBarState.permissionDenied.accessibilityDescription
      == "SmartGaze camera access is denied")

  #expect(MenuBarState.starting.symbolName == "eye")
  #expect(MenuBarState.starting.accessibilityDescription == "SmartGaze is starting the camera")

  #expect(MenuBarState.timedOut.symbolName == "exclamationmark.triangle.fill")
  #expect(MenuBarState.timedOut.accessibilityDescription == "SmartGaze camera did not start")

  #expect(MenuBarState.cameraLive.symbolName == "video.fill")
  #expect(MenuBarState.cameraLive.accessibilityDescription == "SmartGaze camera is live")

  #expect(MenuBarState.uncalibrated.symbolName == "scope")
  #expect(MenuBarState.uncalibrated.accessibilityDescription == "SmartGaze needs calibration")

  #expect(MenuBarState.captureBusy.symbolName == "camera.viewfinder")
  #expect(MenuBarState.captureBusy.accessibilityDescription == "SmartGaze is capturing")
}
