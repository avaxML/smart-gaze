import Foundation
import GazeKit
import Providers
import Testing

@testable import SmartGaze

@MainActor
private func makeModel(
  settings: Settings = .default,
  store: SettingsStore = FakeSettingsStore(),
  secrets: FakeSecrets = FakeSecrets(),
  tester: SettingsModel.ConnectionTester? = nil
) -> SettingsModel {
  SettingsModel(store: store, secrets: secrets, settings: settings, connectionTester: tester)
}

@MainActor
@Test func modelClampsLoadedValuesAtInit() {
  var settings = Settings.default
  settings.dwellSeconds = 99
  settings.dispersionThreshold = 1
  settings.bubbleWidth = 10
  settings.bubbleMaxHeight = 99999

  let model = makeModel(settings: settings)

  #expect(model.settings.dwellSeconds == 5.0)
  #expect(model.settings.dispersionThreshold == 10)
  #expect(model.settings.bubbleWidth == 220)
  #expect(model.settings.bubbleMaxHeight == 1200)
}

@MainActor
@Test func nonFiniteLoadedValuesFallBackToFiniteDefaults() {
  var settings = Settings.default
  settings.dwellSeconds = .nan
  settings.bubbleWidth = .infinity

  let model = makeModel(settings: settings)

  #expect(model.settings.dwellSeconds == Settings.default.dwellSeconds)
  #expect(model.settings.bubbleWidth == Settings.default.bubbleWidth)
}

@MainActor
@Test func nonFiniteNumericEditsFallBackToTheCurrentValue() {
  let model = makeModel()
  let before = model.settings.dwellSeconds

  model.dwellSecondsBinding().wrappedValue = .nan
  #expect(model.settings.dwellSeconds == before)
  model.dwellSecondsBinding().wrappedValue = .infinity
  #expect(model.settings.dwellSeconds == before)
  model.dwellSecondsBinding().wrappedValue = 99
  #expect(model.settings.dwellSeconds == 5.0)
}

@MainActor
@Test func invalidBaseURLDraftKeepsTextAndDoesNotMutateSettings() {
  let model = makeModel()
  let stored = model.settings.providers[.opencode]?.baseURL

  model.updateBaseURLDraft("htp://nope")
  #expect(model.baseURLDraft == "htp://nope")
  #expect(model.baseURLError != nil)

  model.commitBaseURL()
  #expect(model.settings.providers[.opencode]?.baseURL == stored)
}

@MainActor
@Test func applyingAValidBaseURLPersistsIt() {
  let store = FakeSettingsStore()
  let model = makeModel(store: store)

  model.updateBaseURLDraft("https://example.test/v1")
  #expect(model.baseURLError == nil)
  model.commitBaseURL()

  #expect(model.settings.providers[.opencode]?.baseURL.absoluteString == "https://example.test/v1")
  #expect(store.savedCount >= 1)
}

@Test func baseURLValidationRejectsUserinfoQueryAndFragment() {
  #expect(SettingsModel.validatedBaseURL("https://user:pass@api.openai.com/v1") == nil)
  #expect(SettingsModel.validatedBaseURL("https://api.openai.com/v1?x=1") == nil)
  #expect(SettingsModel.validatedBaseURL("https://api.openai.com/v1#frag") == nil)
  #expect(SettingsModel.validatedBaseURL("https://api.openai.com/v1") != nil)
}

@Test func plaintextHTTPIsRejectedExceptForLoopback() {
  #expect(SettingsModel.validatedBaseURL("http://api.openai.com/v1") == nil)
  #expect(SettingsModel.validatedBaseURL("http://localhost:8080/v1") != nil)
  #expect(SettingsModel.validatedBaseURL("http://127.0.0.1:8080/v1") != nil)
  #expect(SettingsModel.validatedBaseURL("http://[::1]:8080/v1") != nil)
}

@MainActor
@Test func loopbackPlaintextHTTPCanBeSavedForTheProxyProvider() {
  var settings = Settings.default
  settings.activeProvider = .proxy
  let model = makeModel(settings: settings)

  model.updateBaseURLDraft("http://127.0.0.1:8080/v1")
  #expect(model.baseURLError == nil)
  model.commitBaseURL()

  #expect(model.settings.providers[.proxy]?.baseURL.absoluteString == "http://127.0.0.1:8080/v1")
}

@MainActor
@Test func providerSwitchResetsTheDraftToTheStoredValue() {
  let model = makeModel()
  model.updateBaseURLDraft("https://example.test/v1")

  model.selectProvider(.google)

  #expect(model.baseURLDraft == model.settings.providers[.google]?.baseURL.absoluteString)
  #expect(model.baseURLError == nil)
}

@MainActor
@Test func testConnectionNeverClearsAnUnsavedKey() {
  let secrets = FakeSecrets()
  let probe = SuspendingConnectionProbe()
  let model = makeModel(secrets: secrets, tester: { _, _ in try await probe.test() })

  model.keyEntry = "sk-unsaved"
  #expect(model.canTestConnection == false)

  model.testConnection()

  #expect(model.keyEntry == "sk-unsaved")
  #expect(probe.calls == 0)
}

@MainActor
@Test func testConnectionSucceedsWhenTheKeyIsStoredAndTheDraftIsClean() async {
  let secrets = FakeSecrets()
  secrets.storage[KeychainAccount.openCodeKey.rawValue] = "sk-stored"
  let model = makeModel(secrets: secrets, tester: { _, _ in })

  #expect(model.canTestConnection)
  model.testConnection()
  await model.connectionTask?.value

  #expect(model.connectionStatus == .success)
}

@MainActor
@Test func cannotTestConnectionWhenTheStoredBaseURLIsInvalid() async {
  var settings = Settings.default
  settings.providers[.opencode] = ProviderSettings(
    model: "m",
    baseURL: URL(string: "http://remote.example.com/v1")!,
    keychainAccount: .openCodeKey
  )

  let secrets = FakeSecrets()
  secrets.storage[KeychainAccount.openCodeKey.rawValue] = "sk-stored"
  let probe = SuspendingConnectionProbe()
  let model = makeModel(
    settings: settings, secrets: secrets, tester: { _, _ in try await probe.test() })

  #expect(model.baseURLError != nil)
  #expect(model.canTestConnection == false)

  model.testConnection()

  #expect(probe.calls == 0)
  #expect(model.connectionStatus == .idle)
}

@MainActor
@Test func editingTheBaseURLDraftCancelsAnInFlightConnectionResult() async {
  let secrets = FakeSecrets()
  secrets.storage[KeychainAccount.openCodeKey.rawValue] = "sk-stored"
  let probe = SuspendingConnectionProbe()
  let model = makeModel(secrets: secrets, tester: { _, _ in try await probe.test() })

  model.testConnection()
  await probe.waitUntilCalled()
  #expect(model.connectionStatus == .testing)
  let task = model.connectionTask

  model.updateBaseURLDraft("https://example.test/v1")
  #expect(model.connectionStatus == .idle)

  probe.resume()
  await task?.value
  #expect(model.connectionStatus == .idle)
}

@MainActor
@Test func typingAKeyCancelsAnInFlightConnectionResult() async {
  let secrets = FakeSecrets()
  secrets.storage[KeychainAccount.openCodeKey.rawValue] = "sk-stored"
  let probe = SuspendingConnectionProbe()
  let model = makeModel(secrets: secrets, tester: { _, _ in try await probe.test() })

  model.testConnection()
  await probe.waitUntilCalled()
  #expect(model.connectionStatus == .testing)
  let task = model.connectionTask

  model.keyEntry = "sk-typing"
  #expect(model.connectionStatus == .idle)

  probe.resume()
  await task?.value
  #expect(model.connectionStatus == .idle)
}

@MainActor
@Test func editingTheModelCancelsAnInFlightConnectionResult() async {
  let secrets = FakeSecrets()
  secrets.storage[KeychainAccount.openCodeKey.rawValue] = "sk-stored"
  let probe = SuspendingConnectionProbe()
  let model = makeModel(secrets: secrets, tester: { _, _ in try await probe.test() })

  model.testConnection()
  await probe.waitUntilCalled()
  let task = model.connectionTask

  model.binding(for: \.model, kind: model.activeProvider).wrappedValue = "another-model"
  #expect(model.connectionStatus == .idle)

  probe.resume()
  await task?.value
  #expect(model.connectionStatus == .idle)
}

@MainActor
@Test func saveKeyStoresTheSecretClearsTheEntryAndMarksPresence() {
  let secrets = FakeSecrets()
  let model = makeModel(secrets: secrets)

  model.keyEntry = "sk-new"
  model.saveKey()

  #expect(model.keyEntry == "")
  #expect(model.hasStoredKey)
  #expect(secrets.storage[KeychainAccount.openCodeKey.rawValue] == "sk-new")
}

@MainActor
@Test func persistenceFailureIsSurfaced() {
  let store = FakeSettingsStore()
  store.saveError = TestFailure()
  let model = makeModel(store: store)

  model.addDeniedApp("com.example.private")

  #expect(model.persistenceError != nil)
}

@MainActor
@Test func storingAFocalLengthReplacesTheEntryForTheSameCameraAndPersists() {
  let store = FakeSettingsStore()
  let model = makeModel(store: store)
  let first = CameraFocalLength(
    cameraID: "camera-one", cameraName: "Camera One", focalLengthPerFrameHeight: 1.4)
  let other = CameraFocalLength(
    cameraID: "camera-two", cameraName: "Camera Two", focalLengthPerFrameHeight: 1.2)
  let replacement = CameraFocalLength(
    cameraID: "camera-one", cameraName: "Camera One", focalLengthPerFrameHeight: 1.5)

  model.applyCameraFocalLength(first)
  model.applyCameraFocalLength(other)
  model.applyCameraFocalLength(replacement)

  #expect(model.settings.cameraFocalLengths == [other, replacement])
  #expect(model.settings.focalLength(forCameraID: "camera-one") == replacement)
  #expect(store.savedCount == 3)
}
