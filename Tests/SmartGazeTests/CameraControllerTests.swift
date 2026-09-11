import Perception
import Testing

@testable import SmartGaze

@MainActor
@Test func pauseDuringSuspendedStartKeepsCameraOffAndReportsNoError() async {
  let observer = FakeFaceObserver()
  observer.suspendsStart = true
  let controller = CameraController(makeObserver: { observer })
  var errors = 0
  controller.onError = { _ in errors += 1 }

  let start = Task { await controller.start() }
  await observer.waitUntilSuspended()
  #expect(controller.state == .starting)

  controller.pause()
  #expect(controller.state == .off)

  observer.resumeStart()
  await start.value

  #expect(controller.state == .off)
  #expect(observer.stopCount >= 1)
  #expect(errors == 0)
}

@MainActor
@Test func lateStartErrorAfterPauseIsIgnored() async {
  let observer = FakeFaceObserver()
  observer.suspendsStart = true
  let controller = CameraController(makeObserver: { observer })
  var errors = 0
  controller.onError = { _ in errors += 1 }

  let start = Task { await controller.start() }
  await observer.waitUntilSuspended()
  controller.pause()
  observer.failStart(TestFailure())
  await start.value

  #expect(controller.state == .off)
  #expect(errors == 0)
}

@MainActor
@Test func startErrorWhileCurrentReportsOnError() async {
  let observer = FakeFaceObserver()
  observer.startError = TestFailure()
  let controller = CameraController(makeObserver: { observer })
  var reported: Error?
  controller.onError = { reported = $0 }

  await controller.start()

  #expect(controller.state == .off)
  #expect(reported is TestFailure)
}

@MainActor
@Test func eachResumeCreatesAFreshObserver() async {
  let observers = [FakeFaceObserver(), FakeFaceObserver()]
  var index = 0
  let controller = CameraController(makeObserver: {
    defer { index += 1 }
    return observers[index]
  })

  await controller.start()
  #expect(controller.state == .starting)
  await controller.reportFirstObservation(from: observers[0])
  #expect(observers[0].startCount == 1)

  controller.pause()
  #expect(controller.state == .off)

  await controller.start()
  #expect(controller.state == .starting)
  await controller.reportFirstObservation(from: observers[1])
  #expect(index == 2)
  #expect(observers[0].stopCount >= 1)
  #expect(observers[1].startCount == 1)
}

@MainActor
@Test func repeatedStartStopsThePreviousObserver() async {
  let observers = [FakeFaceObserver(), FakeFaceObserver()]
  var index = 0
  let controller = CameraController(makeObserver: {
    defer { index += 1 }
    return observers[index]
  })

  await controller.start()
  await controller.start()
  await controller.reportFirstObservation(from: observers[1])

  #expect(observers[0].stopCount >= 1)
  #expect(observers[1].startCount == 1)
}

@MainActor
@Test func observationsQueuedAfterTheSubscriptionIsCancelledAreNotDelivered() async {
  let observers = [FakeFaceObserver(), FakeFaceObserver()]
  observers[0].finishesOnStop = false
  var index = 0
  let controller = CameraController(makeObserver: {
    defer { index += 1 }
    return observers[index]
  })
  var received = 0
  var delivered = Signal()
  controller.onObservation = { _ in
    received += 1
    delivered.signal()
  }

  await controller.start()
  observers[0].emit(nil)
  await delivered.wait()
  #expect(received == 1)

  controller.pause()
  await observers[0].waitUntilTerminated()

  observers[0].emit(nil)
  delivered = Signal()
  await controller.start()
  observers[0].emit(nil)
  observers[1].emit(nil)
  await delivered.wait()

  #expect(received == 2)
  #expect(controller.state == .live)
}

@MainActor
@Test func notDeterminedAuthorizationWaitsForPermissionInsteadOfStarting() async {
  let observer = FakeFaceObserver()
  observer.authorizationStatus = .notDetermined
  observer.suspendsStart = true
  let controller = CameraController(makeObserver: { observer })

  let start = Task { await controller.start() }
  await observer.waitUntilSuspended()
  #expect(controller.state == .waitingForPermission)
  #expect(observer.startCount == 1)

  observer.resumeStart()
  await start.value
}

@MainActor
@Test func deniedAuthorizationReportsDeniedWithoutStarting() async {
  let observer = FakeFaceObserver()
  observer.authorizationStatus = .denied
  let controller = CameraController(makeObserver: { observer })

  await controller.start()

  #expect(controller.state == .permissionDenied)
  #expect(observer.startCount == 0)
}

@MainActor
@Test func startingTimesOutWhenNoFrameArrives() async {
  let observer = FakeFaceObserver()
  let elapsed = Signal()
  let controller = CameraController(
    makeObserver: { observer },
    sleep: { _ in await elapsed.wait() })

  var timedOut = false
  let becameTimedOut = Signal()
  controller.onChange = {
    if controller.state == .timedOut {
      timedOut = true
      becameTimedOut.signal()
    }
  }

  await controller.start()
  #expect(controller.state == .starting)

  elapsed.signal()
  await becameTimedOut.wait()
  #expect(timedOut)
  #expect(controller.state == .timedOut)
}

@MainActor
@Test func aLateFrameRecoversFromTimedOut() async {
  let observer = FakeFaceObserver()
  let elapsed = Signal()
  let controller = CameraController(
    makeObserver: { observer },
    sleep: { _ in await elapsed.wait() })

  let becameTimedOut = Signal()
  controller.onChange = {
    if controller.state == .timedOut { becameTimedOut.signal() }
  }

  await controller.start()
  elapsed.signal()
  await becameTimedOut.wait()
  #expect(controller.state == .timedOut)

  let becameLive = Signal()
  controller.onObservation = { _ in becameLive.signal() }
  observer.emit(nil)
  await becameLive.wait()

  #expect(controller.state == .live)
}

extension CameraController {
  /// Emits one observation from `observer` and waits for the controller to
  /// finish processing it, so a test can assert on the resulting state
  /// without racing the `AsyncStream` drain task.
  fileprivate func reportFirstObservation(from observer: FakeFaceObserver) async {
    let delivered = Signal()
    onObservation = { _ in delivered.signal() }
    observer.emit(nil)
    await delivered.wait()
  }
}
