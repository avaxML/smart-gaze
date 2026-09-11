import Testing

@testable import GazeKit

@Test func firstFailuresBelowThresholdDoNotReportLoss() {
  var debounce = FaceLossDebounce(consecutiveFailureThreshold: 3)
  #expect(debounce.recordFailure() == false)
  #expect(debounce.recordFailure() == false)
}

@Test func thresholdFailureReportsLossExactlyOnce() {
  var debounce = FaceLossDebounce(consecutiveFailureThreshold: 3)
  #expect(debounce.recordFailure() == false)
  #expect(debounce.recordFailure() == false)
  #expect(debounce.recordFailure() == true)
  #expect(debounce.recordFailure() == false)
  #expect(debounce.recordFailure() == false)
}

@Test func successResetsTheRun() {
  var debounce = FaceLossDebounce(consecutiveFailureThreshold: 2)
  #expect(debounce.recordFailure() == false)
  debounce.recordSuccess()
  #expect(debounce.recordFailure() == false)
  #expect(debounce.recordFailure() == true)
}

@Test func lossReportsAgainAfterAnInterveningSuccess() {
  var debounce = FaceLossDebounce(consecutiveFailureThreshold: 1)
  #expect(debounce.recordFailure() == true)
  #expect(debounce.recordFailure() == false)
  debounce.recordSuccess()
  #expect(debounce.recordFailure() == true)
}

@Test func thresholdIsClampedToAtLeastOne() {
  var debounce = FaceLossDebounce(consecutiveFailureThreshold: 0)
  #expect(debounce.recordFailure() == true)
}
