import Testing

@testable import OverlayUI

@MainActor
@Test func stateStartsHiddenAndIdle() {
  let state = BubbleState()

  #expect(state.isVisible == false)
  #expect(state.isStreaming == false)
  #expect(state.text == "")
  #expect(state.isPinned == false)
  #expect(state.isExpanded == false)
}

@MainActor
@Test func beginResetsPreviousContent() {
  let state = BubbleState()
  let first = state.begin()
  state.append("old", for: first)
  state.fail("boom", for: first)

  state.begin()

  #expect(state.isVisible == true)
  #expect(state.isStreaming == true)
  #expect(state.text == "")
  #expect(state.errorMessage == nil)
  #expect(state.isExpanded == false)
}

@MainActor
@Test func appendAccumulatesTokensInOrder() {
  let state = BubbleState()
  let handle = state.begin()

  state.append("The ", for: handle)
  state.append("answer ", for: handle)
  state.append("is 42.", for: handle)

  #expect(state.text == "The answer is 42.")
}

@MainActor
@Test func finishStopsStreamingButKeepsText() {
  let state = BubbleState()
  let handle = state.begin()
  state.append("done", for: handle)

  state.finish(for: handle)

  #expect(state.isStreaming == false)
  #expect(state.text == "done")
}

@MainActor
@Test func failRecordsErrorAndStopsStreaming() {
  let state = BubbleState()
  let handle = state.begin()

  state.fail("No API key", for: handle)

  #expect(state.errorMessage == "No API key")
  #expect(state.isStreaming == false)
}

@MainActor
@Test func tokenFromAnEarlierPresentationCannotModifyANewerOne() {
  let state = BubbleState()
  let first = state.begin()

  let second = state.begin()
  state.append("NEW", for: second)
  let accepted = state.append("STALE", for: first)

  #expect(accepted == false)
  #expect(state.text == "NEW")
}

@MainActor
@Test func tokenAfterFinishIsIgnored() {
  let state = BubbleState()
  let handle = state.begin()
  state.append("done", for: handle)

  #expect(state.finish(for: handle) == true)
  #expect(state.append("!", for: handle) == false)
  #expect(state.text == "done")
}

@MainActor
@Test func staleFailureCannotOverrideANewerPresentation() {
  let state = BubbleState()
  let first = state.begin()
  let second = state.begin()
  state.append("fresh", for: second)

  let accepted = state.fail("boom", for: first)

  #expect(accepted == false)
  #expect(state.errorMessage == nil)
  #expect(state.text == "fresh")
}

@Test func dismissalLatchFiresExactlyOncePerArm() {
  var latch = DismissalLatch()

  latch.arm()
  #expect(latch.fireOnce() == true)
  #expect(latch.fireOnce() == false)

  latch.arm()
  #expect(latch.fireOnce() == true)
  #expect(latch.fireOnce() == false)
}

@MainActor
@Test func escapingGazeFiresDismissalAfterGracePeriod() {
  let state = BubbleState()
  state.begin()

  #expect(state.updateGaze(inside: false, at: 0.0) == false)
  #expect(state.updateGaze(inside: false, at: 1.9) == false)
  #expect(state.updateGaze(inside: false, at: 2.1) == true)
}

@MainActor
@Test func pinnedStateSuppressesGazeDismissal() {
  let state = BubbleState()
  state.begin()
  state.setPinned(true)

  #expect(state.updateGaze(inside: false, at: 0.0) == false)
  #expect(state.updateGaze(inside: false, at: 5.0) == false)
  #expect(state.updateGaze(inside: false, at: 100.0) == false)
}

@MainActor
@Test func unpinningResetsTheDismissalCountdown() {
  let state = BubbleState()
  state.begin()
  state.setPinned(true)
  state.updateGaze(inside: false, at: 10.0)

  state.setPinned(false)

  #expect(state.updateGaze(inside: false, at: 20.0) == false)
  #expect(state.updateGaze(inside: false, at: 22.1) == true)
}

@MainActor
@Test func reEnteringTheBubbleResetsTheCountdown() {
  let state = BubbleState()
  state.begin()

  #expect(state.updateGaze(inside: false, at: 0.0) == false)
  #expect(state.updateGaze(inside: true, at: 1.0) == false)
  #expect(state.updateGaze(inside: false, at: 1.1) == false)
  #expect(state.updateGaze(inside: false, at: 2.5) == false)
}

@MainActor
@Test func endHidesTheBubbleAndDisablesGaze() {
  let state = BubbleState()
  state.begin()

  state.end()

  #expect(state.isVisible == false)
  #expect(state.isStreaming == false)
  #expect(state.updateGaze(inside: false, at: 0.0) == false)
}

@MainActor
@Test func expandedTogglesIndependently() {
  let state = BubbleState()
  state.begin()

  state.setExpanded(true)
  #expect(state.isExpanded == true)

  state.begin()
  #expect(state.isExpanded == false)
}

@MainActor
@Test func beginUnpinsForANewPresentation() {
  let state = BubbleState()
  state.begin()
  state.setPinned(true)

  state.begin()

  #expect(state.isPinned == false)
  #expect(state.updateGaze(inside: false, at: 0.0) == false)
  #expect(state.updateGaze(inside: false, at: 2.1) == true)
}
