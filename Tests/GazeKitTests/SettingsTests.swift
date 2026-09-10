import Foundation
import GazeKit
import Testing

// CalibrationMap has no public memberwise initializer; build one the way a real
// caller would, by decoding it, matching its own Codable contract.
private func fullyPopulatedSettings() throws -> Settings {
  let json = """
    {"inputSpace":"normalized-screen-point-v1","xCoefficients":[1,2,3,4,5,6],
    "yCoefficients":[6,5,4,3,2,1]}
    """
  var settings = Settings.default
  settings.calibrationMap = try JSONDecoder().decode(CalibrationMap.self, from: Data(json.utf8))
  return settings
}

private func loadSettings(withStoredCalibration calibration: [String: Any]) throws -> Settings {
  var settings = Settings.default
  settings.dwellSeconds = 1.25
  settings.activationMode = .passiveDwell
  settings.activeProvider = .anthropic

  let data = try JSONEncoder().encode(settings)
  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  object["calibrationMap"] = calibration
  let stored = try JSONSerialization.data(withJSONObject: object)

  let suiteName = "u41-settings-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defer { defaults.removePersistentDomain(forName: suiteName) }

  let key = "u41-settings-key"
  let store = UserDefaultsSettingsStore(defaults: defaults, key: key)
  defaults.set(stored, forKey: key)
  return store.load()
}

@Test func defaultSettingsEncodeToTheAgreedLiterals() throws {
  let data = try JSONEncoder().encode(Settings.default)
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

  #expect(object["dwellSeconds"] as? Double == 0.6)
  #expect(object["dispersionThreshold"] as? Double == 160)
  #expect(object["activationMode"] as? String == "modifierHeld")
  #expect(object["modifierKey"] as? String == "option")
  #expect(object["bubbleWidth"] as? Double == 360)
  #expect(object["bubbleMaxHeight"] as? Double == 480)
  #expect(object["activeProvider"] as? String == "opencode")

  let denied = try #require(object["deniedApps"] as? [String])
  #expect(Set(denied) == AppDenylist().bundleIDs)
  #expect(denied.contains("com.apple.mobilesms"))
  #expect(denied == denied.sorted())
}

@Test func oldSettingsWithoutDeniedAppsFallBackToSeedDenylist() throws {
  let data = try JSONEncoder().encode(Settings.default)
  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  object.removeValue(forKey: "deniedApps")
  let stripped = try JSONSerialization.data(withJSONObject: object)

  let decoded = try JSONDecoder().decode(Settings.self, from: stripped)
  #expect(decoded.deniedApps == AppDenylist())
  #expect(decoded.deniedApps.allowsCapture(frontmostBundleID: "com.1password.1password") == false)
  #expect(decoded.dwellSeconds == 0.6)
  #expect(decoded.activationMode == .modifierHeld)
  #expect(decoded.dispersionThreshold == 160)
}

@Test func settingsRoundTripACustomDenylist() throws {
  var settings = Settings.default
  settings.deniedApps = AppDenylist(bundleIDs: ["com.example.Secret", "com.example.notes"])

  let data = try JSONEncoder().encode(settings)
  let decoded = try JSONDecoder().decode(Settings.self, from: data)

  #expect(decoded.deniedApps == settings.deniedApps)
  #expect(decoded.deniedApps.allowsCapture(frontmostBundleID: "com.example.secret") == false)
  #expect(decoded.deniedApps.allowsCapture(frontmostBundleID: "com.example.notes") == false)
}

@Test func outOfRangeSettingsClampToTheAdvertisedBounds() {
  var settings = Settings.default
  settings.dwellSeconds = 99
  settings.dispersionThreshold = 1
  settings.bubbleWidth = 10
  settings.bubbleMaxHeight = 99999

  let clamped = settings.clamped()
  #expect(clamped.dwellSeconds == 5.0)
  #expect(clamped.dispersionThreshold == 10)
  #expect(clamped.bubbleWidth == 220)
  #expect(clamped.bubbleMaxHeight == 1200)
}

@Test func inRangeSettingsAreUnchangedByClamping() {
  #expect(Settings.default.clamped() == Settings.default)
}

@Test func settingsRoundTripsThroughJSONLosslessly() throws {
  let original = try fullyPopulatedSettings()
  let data = try JSONEncoder().encode(original)
  let decoded = try JSONDecoder().decode(Settings.self, from: data)
  #expect(decoded == original)
}

@Test func startupDefaultsUseModifierHeldActivationWithOption() {
  let settings = Settings.default
  #expect(settings.activationMode == .modifierHeld)
  #expect(settings.modifierKey == .option)
}

@Test func startupDefaultDispersionIsTheUncalibratedPlaceholder() {
  #expect(Settings.default.dispersionThreshold == 160)
}

@Test func defaultProviderConfigurationMatchesTheAgreedSchema() {
  let settings = Settings.default
  #expect(settings.activeProvider == .opencode)
  #expect(settings.providers[.opencode]?.baseURL.absoluteString == "https://opencode.ai/zen/v1")
  #expect(settings.providers[.opencode]?.model == "deepseek-v4-flash-vision-exp")
  #expect(settings.providers[.opencode]?.keychainAccount == .openCodeKey)
  #expect(settings.providers[.google]?.model == "gemini-2.5-flash")
  #expect(settings.providers[.openai]?.model == "gpt-4o-mini")
  #expect(settings.providers[.anthropic]?.model == "claude-3-5-sonnet")
  #expect(settings.providers[.proxy]?.baseURL.absoluteString == "http://localhost:8080/v1")
}

@Test func encodedSettingsContainNoKeychainAccountOutsideTheKnownFiveNames() throws {
  let settings = try fullyPopulatedSettings()
  let data = try JSONEncoder().encode(settings)
  let json = try #require(String(data: data, encoding: .utf8))

  let knownAccounts = Set(KeychainAccount.allCases.map(\.rawValue))
  for match in json.matches(of: /llm_key_[A-Za-z0-9_]+/) {
    #expect(knownAccounts.contains(String(json[match.range])))
  }
}

@Test func encodedSettingsContainNoKeyShapedString() throws {
  let settings = try fullyPopulatedSettings()
  let data = try JSONEncoder().encode(settings)
  let json = try #require(String(data: data, encoding: .utf8))

  let keyShapedPatterns: [Regex<Substring>] = [
    /sk-[A-Za-z0-9]{16,}/,
    /AIza[A-Za-z0-9_-]{20,}/,
    /Bearer [A-Za-z0-9._-]{16,}/,
  ]
  for pattern in keyShapedPatterns {
    #expect(json.firstMatch(of: pattern) == nil)
  }

  #expect(!json.contains("apiKey"))
  #expect(!json.contains("secret"))
}

@Test func storeLoadsDefaultsWhenNothingWasSavedYet() throws {
  let suiteName = "u11-settings-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defer { defaults.removePersistentDomain(forName: suiteName) }

  let store = UserDefaultsSettingsStore(defaults: defaults)
  #expect(store.load() == Settings.default)
}

@Test func storeRoundTripsASavedValue() throws {
  let suiteName = "u11-settings-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defer { defaults.removePersistentDomain(forName: suiteName) }

  let store = UserDefaultsSettingsStore(defaults: defaults)
  var settings = Settings.default
  settings.dwellSeconds = 1.25
  settings.dispersionThreshold = 73
  settings.activationMode = .passiveDwell
  settings.modifierKey = .control
  settings.activeProvider = .anthropic

  try store.save(settings)

  let loaded = store.load()
  #expect(loaded == settings)
  #expect(loaded.dwellSeconds == 1.25)
  #expect(loaded.dispersionThreshold == 73)
  #expect(loaded.activationMode == .passiveDwell)
}

@Test func legacyUntaggedCalibrationIsDroppedWhileOtherSettingsSurviveLoad() throws {
  let loaded = try loadSettings(withStoredCalibration: [
    "xCoefficients": [1, 2, 3, 4, 5, 6],
    "yCoefficients": [6, 5, 4, 3, 2, 1],
  ])

  #expect(loaded.calibrationMap == nil)
  #expect(loaded.dwellSeconds == 1.25)
  #expect(loaded.activationMode == .passiveDwell)
  #expect(loaded.activeProvider == .anthropic)
}

@Test func wrongMarkerCalibrationIsDroppedWhileOtherSettingsSurviveLoad() throws {
  let loaded = try loadSettings(withStoredCalibration: [
    "inputSpace": "gaze-angles-v1",
    "xCoefficients": [1, 2, 3, 4, 5, 6],
    "yCoefficients": [6, 5, 4, 3, 2, 1],
  ])

  #expect(loaded.calibrationMap == nil)
  #expect(loaded.dwellSeconds == 1.25)
  #expect(loaded.activationMode == .passiveDwell)
  #expect(loaded.activeProvider == .anthropic)
}

@Test func badCoefficientCountIsDroppedWhileOtherSettingsSurviveLoad() throws {
  let loaded = try loadSettings(withStoredCalibration: [
    "inputSpace": "normalized-screen-point-v1",
    "xCoefficients": [1, 2, 3, 4, 5],
    "yCoefficients": [6, 5, 4, 3, 2, 1],
  ])

  #expect(loaded.calibrationMap == nil)
  #expect(loaded.dwellSeconds == 1.25)
  #expect(loaded.activationMode == .passiveDwell)
  #expect(loaded.activeProvider == .anthropic)
}
