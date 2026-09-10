import Foundation
import GazeKit
import Testing

// CalibrationMap has no public memberwise initializer; build one the way a real
// caller would, by decoding it, matching its own Codable contract.
private func fullyPopulatedSettings() throws -> Settings {
  let json = """
    {"xCoefficients":[1,2,3,4,5,6],"yCoefficients":[6,5,4,3,2,1]}
    """
  var settings = Settings.default
  settings.calibrationMap = try JSONDecoder().decode(CalibrationMap.self, from: Data(json.utf8))
  return settings
}

@Test func settingsRoundTripsThroughJSONLosslessly() throws {
  let original = try fullyPopulatedSettings()
  let data = try JSONEncoder().encode(original)
  let decoded = try JSONDecoder().decode(Settings.self, from: data)
  #expect(decoded == original)
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
  settings.modifierKey = .control
  settings.activeProvider = .anthropic

  try store.save(settings)
  #expect(store.load() == settings)
}
