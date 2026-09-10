import Foundation

public protocol SettingsStore: Sendable {
  func load() -> Settings
  func save(_ settings: Settings) throws
}

public struct UserDefaultsSettingsStore: SettingsStore {
  // UserDefaults is thread safe in practice; it predates Sendable and never adopted it.
  nonisolated(unsafe) private let defaults: UserDefaults
  private let key: String

  public init(defaults: UserDefaults = .standard, key: String = "com.avaxml.smartgaze.settings") {
    self.defaults = defaults
    self.key = key
  }

  public func load() -> Settings {
    guard let data = defaults.data(forKey: key),
      let decoded = try? JSONDecoder().decode(Settings.self, from: data)
    else {
      return .default
    }
    return decoded
  }

  public func save(_ settings: Settings) throws {
    let data = try JSONEncoder().encode(settings)
    defaults.set(data, forKey: key)
  }
}
