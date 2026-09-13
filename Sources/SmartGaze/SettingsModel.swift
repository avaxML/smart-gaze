import Combine
import Foundation
import GazeKit
import Providers

import struct SwiftUI.Binding

@MainActor
final class SettingsModel: ObservableObject {
  enum ConnectionStatus: Equatable {
    case idle
    case testing
    case success
    case failure(String)
  }

  typealias ConnectionTester = @Sendable (ProviderKind, ProviderSettings) async throws -> Void
  typealias ExplanationStreamFactory =
    @Sendable (ProviderKind, ProviderSettings, Data) ->
    AsyncThrowingStream<String, Error>

  @Published private(set) var settings: Settings
  @Published var keyEntry = "" {
    didSet {
      guard keyEntry != oldValue else { return }
      invalidateConnectionResult()
    }
  }
  @Published private(set) var hasStoredKey = false
  @Published private(set) var connectionStatus: ConnectionStatus = .idle
  @Published private(set) var baseURLDraft = ""
  @Published private(set) var baseURLError: String?
  @Published private(set) var persistenceError: String?

  private let store: SettingsStore
  private let secrets: any SecretStore & SecretPresence
  private let connectionTester: ConnectionTester?
  private let explanationStreamFactory: ExplanationStreamFactory?

  private(set) var connectionTask: Task<Void, Never>?

  init(
    store: SettingsStore,
    secrets: any SecretStore & SecretPresence,
    settings: Settings,
    connectionTester: ConnectionTester? = nil,
    explanationStreamFactory: ExplanationStreamFactory? = nil
  ) {
    self.store = store
    self.secrets = secrets
    self.connectionTester = connectionTester
    self.explanationStreamFactory = explanationStreamFactory
    self.settings = settings.clamped()
    refreshStoredKey()
    refreshBaseURLDraft()
  }

  var activeProvider: ProviderKind { settings.activeProvider }

  var deniedAppIDs: [String] { settings.deniedApps.bundleIDs.sorted() }

  /// The same configuration contract as `Test Connection`: a stored key, a
  /// committed valid base URL, no unsaved key text and no in-flight probe.
  var isProviderReady: Bool {
    hasStoredKey
      && baseURLError == nil
      && baseURLDraft == storedBaseURLString
      && keyEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var canTestConnection: Bool {
    isProviderReady && connectionStatus != .testing
  }

  private var storedBaseURLString: String {
    activeProviderSettings?.baseURL.absoluteString ?? ""
  }

  func selectProvider(_ kind: ProviderKind) {
    guard settings.activeProvider != kind else { return }
    settings.activeProvider = kind
    keyEntry = ""
    invalidateConnectionResult()
    refreshStoredKey()
    refreshBaseURLDraft()
    persist()
  }

  var onActivationChanged: (() -> Void)?

  func setActivationMode(_ mode: ActivationMode) {
    guard settings.activationMode != mode else { return }
    settings.activationMode = mode
    persist()
    onActivationChanged?()
  }

  func setModifierKey(_ key: ModifierKey) {
    guard settings.modifierKey != key else { return }
    settings.modifierKey = key
    persist()
    onActivationChanged?()
  }

  func activationModeBinding() -> Binding<ActivationMode> {
    Binding(
      get: { self.settings.activationMode },
      set: { self.setActivationMode($0) }
    )
  }

  func modifierKeyBinding() -> Binding<ModifierKey> {
    Binding(
      get: { self.settings.modifierKey },
      set: { self.setModifierKey($0) }
    )
  }

  func providerSelectionBinding() -> Binding<ProviderKind> {
    Binding(
      get: { self.settings.activeProvider },
      set: { self.selectProvider($0) }
    )
  }

  func binding(
    for keyPath: WritableKeyPath<ProviderSettings, String>, kind: ProviderKind
  ) -> Binding<String> {
    Binding(
      get: { self.settings.providers[kind]?[keyPath: keyPath] ?? "" },
      set: { newValue in
        guard var provider = self.settings.providers[kind],
          provider[keyPath: keyPath] != newValue
        else { return }
        provider[keyPath: keyPath] = newValue
        self.settings.providers[kind] = provider
        self.invalidateConnectionResult()
        self.persist()
      }
    )
  }

  func baseURLBinding() -> Binding<String> {
    Binding(
      get: { self.baseURLDraft },
      set: { self.updateBaseURLDraft($0) }
    )
  }

  /// Keeps the typed text and reports why it is not usable yet. It never
  /// mutates the saved settings, so an invalid edit cannot silently revert.
  func updateBaseURLDraft(_ value: String) {
    baseURLDraft = value
    baseURLError = SettingsModel.baseURLValidationMessage(value)
    invalidateConnectionResult()
  }

  func commitBaseURL() {
    guard baseURLError == nil,
      let url = SettingsModel.validatedBaseURL(baseURLDraft),
      var provider = activeProviderSettings
    else { return }
    guard provider.baseURL != url else {
      baseURLDraft = url.absoluteString
      return
    }
    provider.baseURL = url
    settings.providers[settings.activeProvider] = provider
    baseURLDraft = url.absoluteString
    invalidateConnectionResult()
    persist()
  }

  nonisolated static func validatedBaseURL(_ draft: String) -> URL? {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed),
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil
    else { return nil }
    if scheme == "http" && !isLoopbackHost(host) { return nil }
    return url
  }

  nonisolated static func baseURLValidationMessage(_ draft: String) -> String? {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "Enter a base URL." }
    if validatedBaseURL(draft) != nil { return nil }
    return
      "Enter a full https:// URL. Plain http is allowed only for localhost, and credentials, query and fragment are not."
  }

  nonisolated static func isLoopbackHost(_ host: String) -> Bool {
    let unbracketed =
      host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    let lowered = unbracketed.lowercased()
    return lowered == "localhost" || lowered == "127.0.0.1" || lowered == "::1"
  }

  var onGazeSmoothingChanged: ((Double) -> Void)?

  func gazeSmoothingBinding() -> Binding<Double> {
    Binding(
      get: { self.settings.gazeSmoothing },
      set: {
        let safe = $0.isFinite ? $0 : self.settings.gazeSmoothing
        self.settings.gazeSmoothing = SettingsRange.clamp(safe, to: GazeSmoothing.range)
        self.persist()
        self.onGazeSmoothingChanged?(self.settings.gazeSmoothing)
      }
    )
  }

  func dwellSecondsBinding() -> Binding<Double> {
    Binding(
      get: { self.settings.dwellSeconds },
      set: {
        let safe = $0.isFinite ? $0 : self.settings.dwellSeconds
        self.settings.dwellSeconds = SettingsRange.clamp(safe, to: SettingsRange.dwellSeconds)
        self.persist()
      }
    )
  }

  func dispersionThresholdBinding() -> Binding<Double> {
    Binding(
      get: { self.settings.dispersionThreshold },
      set: {
        let safe = $0.isFinite ? $0 : self.settings.dispersionThreshold
        self.settings.dispersionThreshold = SettingsRange.clamp(
          safe, to: SettingsRange.dispersionThreshold)
        self.persist()
      }
    )
  }

  func bubbleWidthBinding() -> Binding<Double> {
    Binding(
      get: { self.settings.bubbleWidth },
      set: {
        let safe = $0.isFinite ? $0 : self.settings.bubbleWidth
        self.settings.bubbleWidth = SettingsRange.clamp(safe, to: SettingsRange.bubbleWidth)
        self.persist()
      }
    )
  }

  func bubbleMaxHeightBinding() -> Binding<Double> {
    Binding(
      get: { self.settings.bubbleMaxHeight },
      set: {
        let safe = $0.isFinite ? $0 : self.settings.bubbleMaxHeight
        self.settings.bubbleMaxHeight = SettingsRange.clamp(safe, to: SettingsRange.bubbleMaxHeight)
        self.persist()
      }
    )
  }

  func addDeniedApp(_ bundleID: String) {
    settings.deniedApps.add(bundleID)
    persist()
  }

  func removeDeniedApp(_ bundleID: String) {
    settings.deniedApps.remove(bundleID)
    persist()
  }

  func saveKey() {
    guard let account = activeProviderSettings?.keychainAccount.rawValue else { return }
    let trimmed = keyEntry.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      try secrets.write(trimmed, account: account)
      keyEntry = ""
      invalidateConnectionResult()
      refreshStoredKey()
    } catch {
      connectionStatus = .failure("The key could not be saved to the Keychain.")
    }
  }

  func testConnection() {
    guard canTestConnection, let providerSettings = activeProviderSettings else { return }
    let kind = settings.activeProvider
    cancelConnectionTest()
    connectionStatus = .testing

    connectionTask = Task { [weak self] in
      guard let self else { return }
      do {
        if let tester = self.connectionTester {
          try await tester(kind, providerSettings)
        } else {
          let provider = HTTPProvider(kind: kind, settings: providerSettings, secrets: self.secrets)
          try await provider.testConnection(timeout: Duration.seconds(15))
        }
        guard !Task.isCancelled else { return }
        self.connectionStatus = .success
      } catch is CancellationError {
        return
      } catch let error as ProviderError {
        guard !Task.isCancelled else { return }
        self.connectionStatus = .failure(error.localizedDescription)
      } catch {
        guard !Task.isCancelled else { return }
        self.connectionStatus = .failure("The provider could not be reached.")
      }
    }
  }

  /// Builds one streaming explanation request from the stored provider
  /// settings and Keychain, or `nil` when the configuration is not ready.
  func makeExplanationStream(imageJPEG: Data) -> AsyncThrowingStream<String, Error>? {
    guard isProviderReady, let providerSettings = activeProviderSettings else { return nil }
    if let factory = explanationStreamFactory {
      return factory(settings.activeProvider, providerSettings, imageJPEG)
    }
    let provider = HTTPProvider(
      kind: settings.activeProvider,
      settings: providerSettings,
      secrets: secrets,
      maximumOutputTokens: 512
    )
    return provider.explain(
      imageJPEG: imageJPEG,
      prompt: "Explain what this code does in a few sentences.",
      system: "You are a concise programming assistant."
    )
  }

  func prepareForPresentation() {
    keyEntry = ""
    invalidateConnectionResult()
    refreshStoredKey()
    refreshBaseURLDraft()
  }

  func settingsWindowWillClose() {
    keyEntry = ""
    invalidateConnectionResult()
  }

  var hasCalibration: Bool { settings.calibrationMap != nil }

  /// Session-only measurement distance, centimetres. Never persisted: it is
  /// the distance the user is sitting at today, not a saved preference.
  @Published var measurementDistanceCentimetres: Double = 60

  var onCalibrationChanged: (() -> Void)?

  func measurementDistanceBinding() -> Binding<Double> {
    Binding(
      get: { self.measurementDistanceCentimetres },
      set: {
        let safe = $0.isFinite ? $0 : self.measurementDistanceCentimetres
        self.measurementDistanceCentimetres = SettingsRange.clampFinite(
          safe, to: SettingsRange.measurementDistanceCentimetres, fallback: 60)
      })
  }

  /// Stores a measured camera focal length, replacing any earlier entry for
  /// the same camera, and persists.
  func applyCameraFocalLength(_ measurement: CameraFocalLength) {
    settings.cameraFocalLengths.removeAll { $0.cameraID == measurement.cameraID }
    settings.cameraFocalLengths.append(measurement)
    persist()
  }

  /// `pointsPerCentimeter` is the calibrated display's density, from its
  /// physical size; nil (an unknown display, or a test) disables the head
  /// translation correction rather than guessing a scale.
  func applyCalibrationResult(
    _ result: CalibrationResult, pointsPerCentimeter: SIMD2<Double>? = nil
  ) {
    settings.calibrationMap = result.map
    settings.calibrationDistanceCentimeters = result.distanceCentimeters
    settings.calibratedBounds = result.bounds.isNull ? nil : result.bounds
    if let origin = result.faceOriginCentimeters, let pointsPerCentimeter,
      pointsPerCentimeter.x > 0, pointsPerCentimeter.y > 0
    {
      settings.headTranslationCorrection = HeadTranslationCorrection(
        referenceOriginCentimeters: origin, pointsPerCentimeter: pointsPerCentimeter)
    } else {
      settings.headTranslationCorrection = nil
    }
    settings.headRotationCorrection = result.headRotationCorrection
    if let interpupillaryCentimetres = result.interpupillaryCentimetres {
      settings.interpupillaryCentimetres = interpupillaryCentimetres
    }
    persist()
    onCalibrationChanged?()
  }

  private var activeProviderSettings: ProviderSettings? {
    settings.providers[settings.activeProvider]
  }

  private func refreshStoredKey() {
    guard let account = activeProviderSettings?.keychainAccount.rawValue else {
      hasStoredKey = false
      return
    }
    hasStoredKey = (try? secrets.contains(account: account)) ?? false
  }

  private func refreshBaseURLDraft() {
    baseURLDraft = storedBaseURLString
    baseURLError = SettingsModel.baseURLValidationMessage(storedBaseURLString)
  }

  private func invalidateConnectionResult() {
    cancelConnectionTest()
    if connectionStatus != .idle {
      connectionStatus = .idle
    }
  }

  private func cancelConnectionTest() {
    connectionTask?.cancel()
    connectionTask = nil
  }

  private func persist() {
    do {
      try store.save(settings)
      persistenceError = nil
    } catch {
      persistenceError = "Settings could not be saved."
    }
  }
}
