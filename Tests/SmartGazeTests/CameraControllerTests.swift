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
  #expect(controller.state == .live)
  #expect(observers[0].startCount == 1)

  controller.pause()
  #expect(controller.state == .off)

  await controller.start()
  #expect(controller.state == .live)
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

  #expect(controller.state == .live)
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
  let delivered = Signal()
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
  await controller.start()
  observers[0].emit(nil)

  #expect(received == 1)
  #expect(controller.state == .live)
}
