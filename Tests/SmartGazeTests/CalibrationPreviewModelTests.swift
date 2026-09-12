import CoreGraphics
import Foundation
import GazeKit
import Providers
import Testing

@testable import SmartGaze

private final class TestClock: @unchecked Sendable {
  var now: TimeInterval = 0
  func advance(_ delta: TimeInterval) { now += delta }
}

/// A provider stream factory that counts requests and lets a test drive output.
private final class ControlledExplanation: @unchecked Sendable {
  private let lock = NSLock()
  private var callsStorage = 0
  private var continuationStorage: AsyncThrowingStream<String, Error>.Continuation?

  var calls: Int { lock.withLock { callsStorage } }

  func factory() -> SettingsModel.ExplanationStreamFactory {
    { [self] _, _, _ in
      self.lock.withLock { self.callsStorage += 1 }
      return AsyncThrowingStream { continuation in
        self.lock.withLock { self.continuationStorage = continuation }
      }
    }
  }

  func yield(_ text: String) {
    lock.withLock { continuationStorage }?.yield(text)
  }

  func finish() {
    lock.withLock { continuationStorage }?.finish()
  }
}

@MainActor
private func makePreview(
  settings: Settings = .default,
  secrets: FakeSecrets = FakeSecrets(),
  factory: SettingsModel.ExplanationStreamFactory?,
  clock: TestClock
) -> (CalibrationPreviewModel, SettingsModel) {
  let settingsModel = SettingsModel(
    store: FakeSettingsStore(), secrets: secrets, settings: settings,
    explanationStreamFactory: factory)
  let model = CalibrationPreviewModel(
    settings: settingsModel,
    renderSampleCode: { _ in Data([0xFF, 0xD8, 0xFF]) },
    clock: { clock.now },
    automaticallySamplesPointer: false)
  model.applyConfiguration(from: settingsModel.settings, forceReset: true)
  model.updateTargetSize(CGSize(width: 400, height: 300))
  return (model, settingsModel)
}

private func readySecrets() -> FakeSecrets {
  let secrets = FakeSecrets()
  secrets.storage[KeychainAccount.openCodeKey.rawValue] = "sk-stored"
  return secrets
}

/// Yields to the MainActor scheduler until `condition` holds. This observes a
/// real state change rather than sleeping a fixed amount.
@MainActor
private func waitUntil(
  _ condition: @MainActor () -> Bool, attempts: Int = 10_000
) async {
  var remaining = attempts
  while !condition() && remaining > 0 {
    await Task.yield()
    remaining -= 1
  }
}

@MainActor
@Test func localPointerTriggerNeverRequestsTheProvider() async {
  var settings = Settings.default
  settings.activationMode = .passiveDwell
  settings.dwellSeconds = 0.3
  settings.dispersionThreshold = 100
  let controlled = ControlledExplanation()
  let clock = TestClock()
  let (model, _) = makePreview(
    settings: settings, secrets: readySecrets(), factory: controlled.factory(), clock: clock)

  model.setPointerSimulationEnabled(true)
  model.pointerHovered(at: CGPoint(x: 200, y: 150))
  for _ in 0..<10 {
    model.advancePointerSimulation()
    clock.advance(0.05)
  }

  #expect(model.tracking.localTriggerCount == 1)
  #expect(controlled.calls == 0)
  #expect(model.explanation == .idle)
}

@MainActor
@Test func testExplanationMakesExactlyOneRequestAndStreamsOutput() async {
  let controlled = ControlledExplanation()
  let clock = TestClock()
  let (model, _) = makePreview(
    secrets: readySecrets(), factory: controlled.factory(), clock: clock)

  model.requestTestExplanation()
  #expect(model.isExplanationLoading)
  #expect(controlled.calls == 1)

  controlled.yield("hello")
  controlled.finish()
  await model.explanationTask?.value

  #expect(model.explanation == .loaded("hello"))
}

@MainActor
@Test func repeatedClicksWhileLoadingDoNotMakeASecondRequest() async {
  let controlled = ControlledExplanation()
  let clock = TestClock()
  let (model, _) = makePreview(
    secrets: readySecrets(), factory: controlled.factory(), clock: clock)

  model.requestTestExplanation()
  model.requestTestExplanation()
  #expect(controlled.calls == 1)

  controlled.yield("once")
  controlled.finish()
  await model.explanationTask?.value

  #expect(model.explanation == .loaded("once"))
}

@MainActor
@Test func secondClickAfterFirstDeltaDoesNotMakeASecondRequest() async {
  let controlled = ControlledExplanation()
  let clock = TestClock()
  let (model, _) = makePreview(
    secrets: readySecrets(), factory: controlled.factory(), clock: clock)

  model.requestTestExplanation()
  #expect(controlled.calls == 1)

  controlled.yield("first token")
  await waitUntil { model.explanation == .loaded("first token") }

  // The stream is still open, so the guard and Cancel must both stay active.
  #expect(model.isExplanationLoading)
  model.requestTestExplanation()
  #expect(controlled.calls == 1)

  controlled.finish()
  await model.explanationTask?.value

  #expect(model.explanation == .loaded("first token"))
  #expect(model.isExplanationLoading == false)
}

@MainActor
@Test func cancelAfterFirstDeltaIgnoresLateOutput() async {
  let controlled = ControlledExplanation()
  let clock = TestClock()
  let (model, _) = makePreview(
    secrets: readySecrets(), factory: controlled.factory(), clock: clock)

  model.requestTestExplanation()
  controlled.yield("first token")
  await waitUntil { model.explanation == .loaded("first token") }
  #expect(model.isExplanationLoading)

  let task = model.explanationTask
  model.cancelExplanation()
  #expect(model.isExplanationLoading == false)
  #expect(model.explanation == .idle)

  controlled.yield("late")
  controlled.finish()
  await task?.value

  #expect(model.explanation == .idle)
}

@MainActor
@Test func modifierKeyHandlerCapturesWhileThePointerStaysOnTarget() {
  var settings = Settings.default
  settings.activationMode = .modifierHeld
  settings.modifierKey = .option
  let (model, settingsModel) = makePreview(
    settings: settings, secrets: readySecrets(), factory: nil, clock: TestClock())
  model.prepareForPresentation(from: settingsModel)
  model.setPointerSimulationEnabled(true)
  model.pointerHovered(at: CGPoint(x: 200, y: 150))

  #expect(model.handleModifierStateChange(pressed: true))
  model.advancePointerSimulation()
  #expect(model.tracking.state == .armed(region: CGPoint(x: 200, y: 150), since: 0.0))

  #expect(model.handleModifierStateChange(pressed: false))
  #expect(model.tracking.localTriggerCount == 1)
  #expect(model.simulatedModifierHeld == false)
}

@MainActor
@Test func modifierKeyHandlerIgnoresInputWithoutHoverOrPresentation() {
  var settings = Settings.default
  settings.activationMode = .modifierHeld
  let (model, settingsModel) = makePreview(
    settings: settings, secrets: readySecrets(), factory: nil, clock: TestClock())

  model.setPointerSimulationEnabled(true)
  model.pointerHovered(at: CGPoint(x: 200, y: 150))
  // Not presented: the preview tab is not in front.
  #expect(model.handleModifierStateChange(pressed: true) == false)

  model.prepareForPresentation(from: settingsModel)
  model.setPointerSimulationEnabled(true)
  // Presented but pointer still off the target.
  #expect(model.handleModifierStateChange(pressed: true) == false)
  #expect(model.simulatedModifierHeld == false)
}

@MainActor
@Test func doubleBlinkCommandCapturesOnlyWhileHovered() {
  var settings = Settings.default
  settings.activationMode = .doubleBlink
  let (model, settingsModel) = makePreview(
    settings: settings, secrets: readySecrets(), factory: nil, clock: TestClock())
  model.prepareForPresentation(from: settingsModel)
  model.setPointerSimulationEnabled(true)

  #expect(model.handleSimulationCommand(.doubleBlink) == false)

  model.pointerHovered(at: CGPoint(x: 200, y: 150))
  model.advancePointerSimulation()
  #expect(model.handleSimulationCommand(.doubleBlink))
  #expect(model.tracking.localTriggerCount == 1)
}

@MainActor
@Test func squintCommandTogglesStartAndEnd() {
  var settings = Settings.default
  settings.activationMode = .squint
  let (model, settingsModel) = makePreview(
    settings: settings, secrets: readySecrets(), factory: nil, clock: TestClock())
  model.prepareForPresentation(from: settingsModel)
  model.setPointerSimulationEnabled(true)
  model.pointerHovered(at: CGPoint(x: 200, y: 150))
  model.advancePointerSimulation()

  #expect(model.handleSimulationCommand(.squint))
  #expect(model.simulatedSquintActive)
  #expect(model.tracking.state == .settling(since: 0.0))

  model.advancePointerSimulation()
  #expect(model.tracking.state == .armed(region: CGPoint(x: 200, y: 150), since: 0.0))

  #expect(model.handleSimulationCommand(.squint))
  #expect(model.simulatedSquintActive == false)
  #expect(model.tracking.localTriggerCount == 1)
}

@MainActor
@Test func stopClearsSimulationStateAndInputActivation() {
  var settings = Settings.default
  settings.activationMode = .modifierHeld
  let (model, settingsModel) = makePreview(
    settings: settings, secrets: readySecrets(), factory: nil, clock: TestClock())
  model.prepareForPresentation(from: settingsModel)
  model.setPointerSimulationEnabled(true)
  model.pointerHovered(at: CGPoint(x: 200, y: 150))
  model.advancePointerSimulation()
  _ = model.handleModifierStateChange(pressed: true)
  #expect(model.isSimulationInputActive)
  #expect(model.simulatedModifierHeld)

  model.stop()

  #expect(model.isPreviewPresented == false)
  #expect(model.isSimulationInputActive == false)
  #expect(model.simulatedModifierHeld == false)
  #expect(model.markerPoint == nil)
  #expect(model.tracking.isTracking == false)
  #expect(model.handleModifierStateChange(pressed: true) == false)
}

@MainActor
@Test func selectingAnotherSourceClearsSimulationState() {
  let (model, settingsModel) = makePreview(
    settings: .default, secrets: readySecrets(), factory: nil, clock: TestClock())
  model.prepareForPresentation(from: settingsModel)
  model.setPointerSimulationEnabled(true)
  model.pointerHovered(at: CGPoint(x: 200, y: 150))
  model.advancePointerSimulation()
  _ = model.handleModifierStateChange(pressed: true)

  model.selectSource(.live)

  #expect(model.isPointerSimulationEnabled == false)
  #expect(model.simulatedModifierHeld == false)
  #expect(model.markerPoint == nil)
  #expect(model.tracking.isTracking == false)
  #expect(model.isSimulationInputActive == false)
}

@MainActor
@Test func cancelledExplanationIgnoresLateOutput() async {
  let controlled = ControlledExplanation()
  let clock = TestClock()
  let (model, _) = makePreview(
    secrets: readySecrets(), factory: controlled.factory(), clock: clock)

  model.requestTestExplanation()
  let task = model.explanationTask
  model.cancelExplanation()
  #expect(model.explanation == .idle)

  controlled.yield("late")
  controlled.finish()
  await task?.value

  #expect(model.explanation == .idle)
}

@MainActor
@Test func settingsChangeCancelsAnInFlightExplanation() async {
  let controlled = ControlledExplanation()
  let clock = TestClock()
  let (model, _) = makePreview(
    secrets: readySecrets(), factory: controlled.factory(), clock: clock)

  model.requestTestExplanation()
  let task = model.explanationTask
  #expect(model.isExplanationLoading)

  var changed = Settings.default
  changed.activationMode = .doubleBlink
  model.applyConfiguration(from: changed)
  #expect(model.explanation == .idle)

  controlled.yield("late")
  controlled.finish()
  await task?.value

  #expect(model.explanation == .idle)
}

@MainActor
@Test func testExplanationStaysOffUntilAProviderIsConfigured() {
  let controlled = ControlledExplanation()
  let clock = TestClock()
  let (model, _) = makePreview(secrets: FakeSecrets(), factory: controlled.factory(), clock: clock)

  #expect(model.isExplanationAvailable == false)
  model.requestTestExplanation()

  #expect(controlled.calls == 0)
  if case .failed(let message) = model.explanation {
    #expect(message.contains("Configure"))
  } else {
    Issue.record("expected a configure-provider failure, got \(model.explanation)")
  }
}

@MainActor
@Test func resizeRebuildsBoundsAndClearsStaleGaze() {
  let clock = TestClock()
  let (model, _) = makePreview(
    secrets: readySecrets(), factory: nil, clock: clock)

  model.setPointerSimulationEnabled(true)
  model.pointerHovered(at: CGPoint(x: 200, y: 150))
  model.advancePointerSimulation()
  #expect(model.tracking.isTracking)

  model.updateTargetSize(CGSize(width: 500, height: 400))

  #expect(model.tracking.bounds == CGRect(x: 0, y: 0, width: 500, height: 400))
  #expect(model.targetCenter == CGPoint(x: 250, y: 200))
  #expect(model.tracking.isTracking == false)
}
