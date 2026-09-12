import GazeKit
import SwiftUI

struct ProviderSettingsView: View {
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
