import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Hashable, Sendable {
  case google, openai, anthropic, opencode, proxy
}

public enum KeychainAccount: String, Codable, CaseIterable, Sendable {
  case googleKey = "llm_key_google"
  case openAIKey = "llm_key_openai"
  case anthropicKey = "llm_key_anthropic"
  case openCodeKey = "llm_key_opencode"
  case proxyKey = "llm_key_proxy"
}

public enum ModifierKey: String, Codable, CaseIterable, Sendable {
  case option, control, command, shift
}

public struct ProviderSettings: Codable, Equatable, Sendable {
  public var model: String
  public var baseURL: URL
  public var keychainAccount: KeychainAccount

  public init(model: String, baseURL: URL, keychainAccount: KeychainAccount) {
    self.model = model
    self.baseURL = baseURL
    self.keychainAccount = keychainAccount
  }
}

public struct Settings: Codable, Equatable, Sendable {
  public var dwellSeconds: TimeInterval
  public var dispersionThreshold: Double
  public var activationMode: ActivationMode
  public var modifierKey: ModifierKey
  public var bubbleWidth: Double
  public var bubbleMaxHeight: Double
  public var activeProvider: ProviderKind
  public var providers: [ProviderKind: ProviderSettings]
  public var calibrationMap: CalibrationMap?

  private enum CodingKeys: String, CodingKey {
    case dwellSeconds
    case dispersionThreshold
    case activationMode
    case modifierKey
    case bubbleWidth
    case bubbleMaxHeight
    case activeProvider
    case providers
    case calibrationMap
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    dwellSeconds = try container.decode(TimeInterval.self, forKey: .dwellSeconds)
    dispersionThreshold = try container.decode(Double.self, forKey: .dispersionThreshold)
    activationMode = try container.decode(ActivationMode.self, forKey: .activationMode)
    modifierKey = try container.decode(ModifierKey.self, forKey: .modifierKey)
    bubbleWidth = try container.decode(Double.self, forKey: .bubbleWidth)
    bubbleMaxHeight = try container.decode(Double.self, forKey: .bubbleMaxHeight)
    activeProvider = try container.decode(ProviderKind.self, forKey: .activeProvider)
    providers = try container.decode([ProviderKind: ProviderSettings].self, forKey: .providers)
    // A legacy or corrupted calibration must drop only itself, never the user's other saved settings.
    calibrationMap = try? container.decode(CalibrationMap.self, forKey: .calibrationMap)
  }

  public init(
    dwellSeconds: TimeInterval,
    dispersionThreshold: Double,
    activationMode: ActivationMode,
    modifierKey: ModifierKey,
    bubbleWidth: Double,
    bubbleMaxHeight: Double,
    activeProvider: ProviderKind,
    providers: [ProviderKind: ProviderSettings],
    calibrationMap: CalibrationMap? = nil
  ) {
    self.dwellSeconds = dwellSeconds
    self.dispersionThreshold = dispersionThreshold
    self.activationMode = activationMode
    self.modifierKey = modifierKey
    self.bubbleWidth = bubbleWidth
    self.bubbleMaxHeight = bubbleMaxHeight
    self.activeProvider = activeProvider
    self.providers = providers
    self.calibrationMap = calibrationMap
  }

  public static let `default` = Settings(
    dwellSeconds: 0.6,
    dispersionThreshold: 160,
    activationMode: .modifierHeld,
    modifierKey: .option,
    bubbleWidth: 360,
    bubbleMaxHeight: 480,
    activeProvider: .opencode,
    providers: [
      .google: ProviderSettings(
        model: "gemini-2.5-flash",
        baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        keychainAccount: .googleKey
      ),
      .openai: ProviderSettings(
        model: "gpt-4o-mini",
        baseURL: URL(string: "https://api.openai.com/v1")!,
        keychainAccount: .openAIKey
      ),
      .anthropic: ProviderSettings(
        model: "claude-3-5-sonnet",
        baseURL: URL(string: "https://api.anthropic.com/v1")!,
        keychainAccount: .anthropicKey
      ),
      .opencode: ProviderSettings(
        model: "deepseek-v4-flash-vision-exp",
        baseURL: URL(string: "https://opencode.ai/zen/v1")!,
        keychainAccount: .openCodeKey
      ),
      .proxy: ProviderSettings(
        model: "",
        baseURL: URL(string: "http://localhost:8080/v1")!,
        keychainAccount: .proxyKey
      ),
    ]
  )
}
