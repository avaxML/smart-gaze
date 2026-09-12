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

@Test func liveCameraReportsAccessibilityDegradedOnlyWhenCalibrated() {
  #expect(
    MenuBarState.presenting(
      camera: .live, calibrationNeeded: false, isCaptureBusy: false,
      accessibilityDegraded: true)
      == .accessibilityDegraded)
  #expect(
    MenuBarState.presenting(
      camera: .live, calibrationNeeded: false, isCaptureBusy: false,
      accessibilityDegraded: false)
      == .cameraLive)
}

@Test func uncalibratedTakesPriorityOverAccessibilityDegraded() {
  #expect(
    MenuBarState.presenting(
      camera: .live, calibrationNeeded: true, isCaptureBusy: false,
      accessibilityDegraded: true)
      == .uncalibrated)
}

@Test func captureBusyOverridesAccessibilityDegraded() {
  #expect(
    MenuBarState.presenting(
      camera: .live, calibrationNeeded: false, isCaptureBusy: true,
      accessibilityDegraded: true)
      == .captureBusy)
}

@Test func accessibilityDegradedHasNoEffectOffTheLiveState() {
  for camera: CameraController.State in [
    .off, .waitingForPermission, .permissionDenied, .starting, .timedOut,
  ] {
    let withoutDegradation = MenuBarState.presenting(
      camera: camera, calibrationNeeded: false, isCaptureBusy: false,
      accessibilityDegraded: false)
    let withDegradation = MenuBarState.presenting(
      camera: camera, calibrationNeeded: false, isCaptureBusy: false,
      accessibilityDegraded: true)
    #expect(withoutDegradation == withDegradation)
  }
}

@Test func everyMenuStateHasADistinctSymbolAndDescription() {
  let allStates: [MenuBarState] = [
    .off, .waitingForPermission, .permissionDenied, .starting, .timedOut, .cameraLive,
    .uncalibrated, .accessibilityDegraded, .modelsMissing, .captureBusy,
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

  #expect(MenuBarState.accessibilityDegraded.symbolName == "accessibility")
  #expect(
    MenuBarState.accessibilityDegraded.accessibilityDescription
      == "SmartGaze cannot see the modifier key until Accessibility is granted")

  #expect(MenuBarState.captureBusy.symbolName == "camera.viewfinder")
  #expect(MenuBarState.captureBusy.accessibilityDescription == "SmartGaze is capturing")
}

@Test func everyStateHasAMenuStatusThatDoesNotRepeatTheAppName() {
  let states: [MenuBarState] = [
    .off, .waitingForPermission, .permissionDenied, .starting, .timedOut, .cameraLive,
    .uncalibrated, .accessibilityDegraded, .captureBusy,
  ]
  for state in states {
    #expect(!state.menuStatus.isEmpty)
    #expect(!state.menuStatus.contains("SmartGaze"))
  }
}

@Test func theStatesThatCanBlockAUserSayWhatIsWrong() {
  #expect(MenuBarState.waitingForPermission.menuStatus == "Waiting for camera permission")
  #expect(MenuBarState.permissionDenied.menuStatus == "Camera access denied")
  #expect(MenuBarState.timedOut.menuStatus == "The camera did not start")
  #expect(MenuBarState.uncalibrated.menuStatus == "Calibration needed")
}

@Test func missingModelsOutrankALiveCamera() {
  let state = MenuBarState.presenting(
    camera: .live, calibrationNeeded: false, isCaptureBusy: false, modelsMissing: true)
  #expect(state == .modelsMissing)
  #expect(state.menuStatus == "Gaze models not found")
}

@Test func missingModelsOutrankAnOutstandingCalibration() {
  let state = MenuBarState.presenting(
    camera: .live, calibrationNeeded: true, isCaptureBusy: false, modelsMissing: true)
  #expect(state == .modelsMissing)
}

@Test func anInFlightCaptureStillOutranksMissingModels() {
  let state = MenuBarState.presenting(
    camera: .live, calibrationNeeded: false, isCaptureBusy: true, modelsMissing: true)
  #expect(state == .captureBusy)
}

@Test func aCalibratedLiveCameraStillOffersRecalibration() {
  // Once a map exists the state is cameraLive, and the menu must not lose the
  // only path back to calibration. The first live run saved an unusable map and
  // the action vanished with it.
  let state = MenuBarState.presenting(camera: .live, calibrationNeeded: false, isCaptureBusy: false)
  #expect(state == .cameraLive)
}

@Test func accessibilityDegradedSaysPausedNotDwell() {
  // The app never switches modes on the user's behalf; the status must not
  // claim a mode the user did not pick.
  #expect(MenuBarState.accessibilityDegraded.menuStatus == "Paused, Accessibility not granted")
  #expect(!MenuBarState.accessibilityDegraded.menuStatus.lowercased().contains("dwell"))
}

@Test func aTurnedFaceIsReportedOnlyWhenEverythingElseIsHealthy() {
  #expect(
    MenuBarState.presenting(
      camera: .live, calibrationNeeded: false, isCaptureBusy: false, faceTurned: true)
      == .faceTurned)
  #expect(
    MenuBarState.presenting(
      camera: .live, calibrationNeeded: true, isCaptureBusy: false, faceTurned: true)
      == .uncalibrated)
  #expect(
    MenuBarState.presenting(
      camera: .live, calibrationNeeded: false, isCaptureBusy: false,
      accessibilityDegraded: true, faceTurned: true)
      == .accessibilityDegraded)
  #expect(
    MenuBarState.presenting(
      camera: .off, calibrationNeeded: false, isCaptureBusy: false, faceTurned: true)
      == .off)
  #expect(MenuBarState.faceTurned.menuStatus == "Paused, face turned from the camera")
}
