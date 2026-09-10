import GazeKit
import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: SettingsModel

  var body: some View {
    VStack(spacing: 0) {
      if let error = model.persistenceError {
        Text(error)
          .font(.callout)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
          .padding(.top, 8)
      }
      TabView {
        GeneralSettingsView(model: model)
          .tabItem { Label("General", systemImage: "gear") }
        ProviderSettingsView(model: model)
          .tabItem { Label("Provider", systemImage: "brain") }
        PrivacySettingsView(model: model)
          .tabItem { Label("Privacy", systemImage: "hand.raised") }
      }
    }
    .frame(width: 560, height: 440)
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

      Section("Dwell") {
        TextField(
          "Dwell seconds",
          value: model.dwellSecondsBinding(),
          format: .number.precision(.fractionLength(1))
        )
        TextField(
          "Dispersion threshold", value: model.dispersionThresholdBinding(), format: .number)
      }

      Section("Bubble") {
        TextField("Width", value: model.bubbleWidthBinding(), format: .number)
        TextField("Max height", value: model.bubbleMaxHeightBinding(), format: .number)
      }
    }
    .formStyle(.grouped)
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
        .pickerStyle(.segmented)
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
