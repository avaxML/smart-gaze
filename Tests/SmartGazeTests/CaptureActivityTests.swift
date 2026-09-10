import Testing

@testable import SmartGaze

@MainActor
@Test func captureCountIncrementsOnlyOnSuccess() {
  let activity = CaptureActivity()

  activity.captureDidBegin()
  #expect(activity.isBusy)
  activity.captureDidEnd()
  #expect(!activity.isBusy)
  #expect(activity.captureCount == 0)

  activity.captureDidBegin()
  activity.captureDidSucceed()
  #expect(activity.captureCount == 1)
  #expect(!activity.isBusy)

  activity.captureDidSucceed()
  #expect(activity.captureCount == 2)
}

@MainActor
@Test func captureActivityNotifiesOnEveryVisibleChange() {
  let activity = CaptureActivity()
  var changes = 0
  activity.onChange = { changes += 1 }

  activity.captureDidBegin()
  activity.captureDidEnd()
  activity.captureDidSucceed()

  #expect(changes == 3)
}
