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
  /// 0 responsive to 1 calm; see `GazeSmoothing`.
  public var gazeSmoothing: Double
  public var activationMode: ActivationMode
  public var modifierKey: ModifierKey
  public var bubbleWidth: Double
  public var bubbleMaxHeight: Double
  public var activeProvider: ProviderKind
  public var providers: [ProviderKind: ProviderSettings]
  public var deniedApps: AppDenylist
  public var calibrationMap: CalibrationMap?
  public var calibrationDistanceCentimeters: Double?
  public var calibratedBounds: CGRect?
  public var headTranslationCorrection: HeadTranslationCorrection?

  private enum CodingKeys: String, CodingKey {
    case dwellSeconds
    case dispersionThreshold
    case gazeSmoothing
    case activationMode
    case modifierKey
    case bubbleWidth
    case bubbleMaxHeight
    case activeProvider
    case providers
    case deniedApps
    case calibrationMap
    case calibrationDistanceCentimeters
    case calibratedBounds
    case headTranslationCorrection
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    dwellSeconds = try container.decode(TimeInterval.self, forKey: .dwellSeconds)
    dispersionThreshold = try container.decode(Double.self, forKey: .dispersionThreshold)
    gazeSmoothing =
      (try? container.decode(Double.self, forKey: .gazeSmoothing)) ?? Settings.defaultGazeSmoothing
    activationMode = try container.decode(ActivationMode.self, forKey: .activationMode)
    modifierKey = try container.decode(ModifierKey.self, forKey: .modifierKey)
    bubbleWidth = try container.decode(Double.self, forKey: .bubbleWidth)
    bubbleMaxHeight = try container.decode(Double.self, forKey: .bubbleMaxHeight)
    activeProvider = try container.decode(ProviderKind.self, forKey: .activeProvider)
    providers = try container.decode([ProviderKind: ProviderSettings].self, forKey: .providers)
    // Settings written before the denylist existed keep the seeded defaults.
    deniedApps = (try? container.decode(AppDenylist.self, forKey: .deniedApps)) ?? AppDenylist()
    // A legacy or corrupted calibration must drop only itself, never the user's other saved settings.
    calibrationMap = try? container.decode(CalibrationMap.self, forKey: .calibrationMap)
    calibrationDistanceCentimeters = try? container.decode(
      Double.self, forKey: .calibrationDistanceCentimeters)
    calibratedBounds = try? container.decode(CGRect.self, forKey: .calibratedBounds)
    headTranslationCorrection = try? container.decode(
      HeadTranslationCorrection.self, forKey: .headTranslationCorrection)
  }

  public init(
    dwellSeconds: TimeInterval,
    dispersionThreshold: Double,
    gazeSmoothing: Double = Settings.defaultGazeSmoothing,
    activationMode: ActivationMode,
    modifierKey: ModifierKey,
    bubbleWidth: Double,
    bubbleMaxHeight: Double,
    activeProvider: ProviderKind,
    providers: [ProviderKind: ProviderSettings],
    deniedApps: AppDenylist = AppDenylist(),
    calibrationMap: CalibrationMap? = nil,
    calibrationDistanceCentimeters: Double? = nil,
    calibratedBounds: CGRect? = nil,
    headTranslationCorrection: HeadTranslationCorrection? = nil
  ) {
    self.dwellSeconds = dwellSeconds
    self.dispersionThreshold = dispersionThreshold
    self.gazeSmoothing = gazeSmoothing
    self.activationMode = activationMode
    self.modifierKey = modifierKey
    self.bubbleWidth = bubbleWidth
    self.bubbleMaxHeight = bubbleMaxHeight
    self.activeProvider = activeProvider
    self.providers = providers
    self.deniedApps = deniedApps
    self.calibrationMap = calibrationMap
    self.calibrationDistanceCentimeters = calibrationDistanceCentimeters
    self.calibratedBounds = calibratedBounds
    self.headTranslationCorrection = headTranslationCorrection
  }

  /// Calm end of the range by default: the user asked for smooth motion and
  /// accepted the lag, about a third of a second to settle after a saccade.
  public static let defaultGazeSmoothing = 0.75

  public static let `default` = Settings(
    dwellSeconds: 1.2,
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
        model: "deepseek-v4.1-flash",
        baseURL: URL(string: "https://opencode.ai/zen/go/v1")!,
        keychainAccount: .openCodeKey
      ),
      .proxy: ProviderSettings(
        model: "",
        baseURL: URL(string: "http://localhost:8080/v1")!,
        keychainAccount: .proxyKey
      ),
    ]
  )

  public func clamped() -> Settings {
    var copy = self
    copy.dwellSeconds = SettingsRange.clampFinite(
      dwellSeconds, to: SettingsRange.dwellSeconds, fallback: Settings.default.dwellSeconds)
    copy.dispersionThreshold = SettingsRange.clampFinite(
      dispersionThreshold, to: SettingsRange.dispersionThreshold,
      fallback: Settings.default.dispersionThreshold)
    copy.gazeSmoothing = SettingsRange.clampFinite(
      gazeSmoothing, to: GazeSmoothing.range, fallback: Settings.defaultGazeSmoothing)
    copy.bubbleWidth = SettingsRange.clampFinite(
      bubbleWidth, to: SettingsRange.bubbleWidth, fallback: Settings.default.bubbleWidth)
    copy.bubbleMaxHeight = SettingsRange.clampFinite(
      bubbleMaxHeight, to: SettingsRange.bubbleMaxHeight,
      fallback: Settings.default.bubbleMaxHeight)
    return copy
  }
}

public enum SettingsRange {
  public static let dwellSeconds: ClosedRange<TimeInterval> = 0.2...5.0
  public static let dispersionThreshold: ClosedRange<Double> = 10...600
  public static let bubbleWidth: ClosedRange<Double> = 220...900
  public static let bubbleMaxHeight: ClosedRange<Double> = 160...1200

  public static func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
    min(max(value, range.lowerBound), range.upperBound)
  }

  /// Clamps a measurement, replacing NaN and infinities with a finite fallback
  /// so corrupt persisted values can never escape into the UI.
  public static func clampFinite(
    _ value: Double, to range: ClosedRange<Double>, fallback: Double
  ) -> Double {
    let finite = value.isFinite ? value : fallback
    return min(max(finite, range.lowerBound), range.upperBound)
  }
}
