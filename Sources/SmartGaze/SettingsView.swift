import GazeKit
import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: SettingsModel
  var preview: CalibrationPreviewModel
  @State private var selectedTab = Tab.general

  private enum Tab: Hashable {
    case general, preview, provider, privacy
  }

  var body: some View {
    VStack(spacing: 0) {
      if let error = model.persistenceError {
        GroupBox {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
      }
      TabView(selection: $selectedTab) {
        GeneralSettingsView(model: model)
          .tabItem { Label("General", systemImage: "gear") }
          .tag(Tab.general)
        CalibrationPreviewView(model: preview)
          .tabItem { Label("Calibration & Preview", systemImage: "eye") }
          .tag(Tab.preview)
        ProviderSettingsView(model: model)
          .tabItem { Label("Provider", systemImage: "brain") }
          .tag(Tab.provider)
        PrivacySettingsView(model: model)
          .tabItem { Label("Privacy", systemImage: "hand.raised") }
          .tag(Tab.privacy)
      }
    }
    .frame(minWidth: 760, minHeight: 400)
    .onChange(of: selectedTab) { _, tab in
      if tab == .preview {
        preview.prepareForPresentation(from: model)
      } else {
        preview.stop()
      }
    }
    .onAppear {
      if selectedTab == .preview {
        preview.prepareForPresentation(from: model)
      }
    }
    .onChange(of: model.settings) { _, settings in
      preview.applyConfiguration(from: settings)
    }
  }
}

private struct GeneralSettingsView: View {
  @ObservedObject var model: SettingsModel

  var body: some View {
    Form {
      Section("Activation") {
        Picker("Activation mode", selection: model.activationModeBinding()) {
          ForEach(ActivationMode.allCases, id: \.self) { mode in
            Text(activationLabel(mode)).tag(mode)
          }
        }
        Picker("Modifier key", selection: model.modifierKeyBinding()) {
          ForEach(ModifierKey.allCases, id: \.self) { key in
            Text(key.rawValue.capitalized).tag(key)
          }
        }
      }

      Section {
        VStack(alignment: .leading, spacing: 4) {
          Text("Smoothing")
          Slider(value: model.gazeSmoothingBinding(), in: GazeSmoothing.range) {
            Text("Smoothing")
          } minimumValueLabel: {
            Text("Responsive").font(.caption).foregroundStyle(.secondary)
          } maximumValueLabel: {
            Text("Calm").font(.caption).foregroundStyle(.secondary)
          }
          .labelsHidden()
        }
      } header: {
        Text("Tracking")
      } footer: {
        Text(
          "How steadily the on-screen outline follows your gaze. Calm removes almost all jitter but takes a moment longer to catch up after you look somewhere new."
        )
      }

      Section {
        boundedRow(
          "Dwell time", value: model.dwellSecondsBinding(), range: SettingsRange.dwellSeconds,
          step: 0.1, unit: "s", fractionDigits: 1)
        boundedRow(
          "Dispersion threshold", value: model.dispersionThresholdBinding(),
          range: SettingsRange.dispersionThreshold, step: 5, unit: "pt", fractionDigits: 0)
      } header: {
        Text("Dwell")
      } footer: {
        Text(
          "Dwell time is how long your gaze must hold still before an action triggers. Dispersion threshold is how far your gaze can wander, in screen points, and still count as holding still. Lower is stricter, higher tolerates more eye jitter."
        )
      }

      Section {
        boundedRow(
          "Width", value: model.bubbleWidthBinding(), range: SettingsRange.bubbleWidth, step: 10,
          unit: "pt", fractionDigits: 0)
        boundedRow(
          "Max height", value: model.bubbleMaxHeightBinding(), range: SettingsRange.bubbleMaxHeight,
          step: 10, unit: "pt", fractionDigits: 0)
      } header: {
        Text("Bubble")
      } footer: {
        Text("Controls how large the on-screen explanation bubble is allowed to grow, in points.")
      }
    }
    .formStyle(.grouped)
  }

  private func boundedRow(
    _ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double.Stride,
    unit: String, fractionDigits: Int
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        Text(
          "\(value.wrappedValue.formatted(.number.precision(.fractionLength(fractionDigits)))) \(unit)"
        )
        .monospacedDigit()
        .foregroundStyle(.secondary)
      }
      Slider(value: value, in: range, step: step)
    }
  }

  private func activationLabel(_ mode: ActivationMode) -> String {
    switch mode {
    case .modifierHeld: "Modifier held"
    case .passiveDwell: "Passive dwell"
    case .doubleBlink: "Double blink"
    }
  }
}

private struct ProviderSettingsView: View {
  @ObservedObject var model: SettingsModel
  @FocusState private var baseURLFocused: Bool

  var body: some View {
    Form {
      Section("Active provider") {
        Picker("Provider", selection: model.providerSelectionBinding()) {
          ForEach(ProviderKind.allCases, id: \.self) { kind in
            Text(providerLabel(kind)).tag(kind)
          }
        }
      }

      Section("Configuration") {
        TextField("Model", text: model.binding(for: \.model, kind: model.activeProvider))
      }

      Section("Base URL") {
        HStack {
          TextField("Base URL", text: model.baseURLBinding())
            .focused($baseURLFocused)
            .onSubmit { model.commitBaseURL() }
          Button("Apply") { model.commitBaseURL() }
            .disabled(model.baseURLError != nil)
        }
        .onChange(of: baseURLFocused) { _, focused in
          if !focused { model.commitBaseURL() }
        }
        if let error = model.baseURLError {
          Text(error).font(.callout).foregroundStyle(.red)
        }
      }

      Section("API key") {
        SecureField("API key", text: $model.keyEntry)
          .onSubmit { model.saveKey() }
        HStack {
          Button("Save Key") { model.saveKey() }
            .disabled(model.keyEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          if model.hasStoredKey {
            Text("A key is stored").foregroundStyle(.secondary)
          } else {
            Text("No key stored").foregroundStyle(.secondary)
          }
        }
      }

      Section {
        Button("Test Connection") { model.testConnection() }
          .disabled(!model.canTestConnection)
        if !model.canTestConnection, model.connectionStatus != .testing {
          Text("Save the key and apply the base URL before testing.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        connectionStatus
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder private var connectionStatus: some View {
    switch model.connectionStatus {
    case .idle:
      EmptyView()
    case .testing:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Testing the connection...")
      }
    case .success:
      Label("Connection succeeded", systemImage: "checkmark.circle")
        .foregroundStyle(.green)
    case .failure(let message):
      Label(message, systemImage: "xmark.circle")
        .foregroundStyle(.red)
    }
  }

  private func providerLabel(_ kind: ProviderKind) -> String {
    switch kind {
    case .google: "Google"
    case .openai: "OpenAI"
    case .anthropic: "Anthropic"
    case .opencode: "OpenCode Go"
    case .proxy: "Custom proxy"
    }
  }
}

private struct PrivacySettingsView: View {
  @ObservedObject var model: SettingsModel
  @State private var newBundleID = ""

  var body: some View {
    Form {
      Section("Denied apps") {
        Text("Capture never starts while one of these apps is frontmost.")
        ForEach(model.deniedAppIDs, id: \.self) { bundleID in
          HStack {
            Text(bundleID).font(.system(.body, design: .monospaced))
            Spacer()
            Button {
              model.removeDeniedApp(bundleID)
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(bundleID)")
          }
        }
        HStack {
          TextField("com.example.app", text: $newBundleID)
            .onSubmit(addBundleID)
          Button("Add", action: addBundleID)
            .disabled(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }

      Section {
        Text("Captures are processed in memory and are never written to disk.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private func addBundleID() {
    model.addDeniedApp(newBundleID)
    newBundleID = ""
  }
}
