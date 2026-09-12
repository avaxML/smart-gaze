import GazeKit
import SwiftUI

struct ProviderSettingsView: View {
  @ObservedObject var model: SettingsModel
  @FocusState private var baseURLFocused: Bool

  var body: some View {
    Form {
      Section("Provider") {
        Picker("Provider", selection: model.providerSelectionBinding()) {
          ForEach(ProviderKind.allCases, id: \.self) { kind in
            Text(providerLabel(kind)).tag(kind)
          }
        }
      }

      Section("Configuration") {
        TextField("Model", text: model.binding(for: \.model, kind: model.activeProvider))

        LabeledContent("Base URL") {
          HStack(spacing: 8) {
            TextField("Base URL", text: model.baseURLBinding())
              .labelsHidden()
              .focused($baseURLFocused)
              .onSubmit { model.commitBaseURL() }
            Button("Apply") { model.commitBaseURL() }
              .disabled(model.baseURLError != nil)
              .help("Apply the base URL to this provider.")
          }
        }
        .onChange(of: baseURLFocused) { _, focused in
          if !focused { model.commitBaseURL() }
        }

        if let error = model.baseURLError {
          statusRow(error, systemImage: "exclamationmark.triangle", tint: .red)
        }

        LabeledContent("API key") {
          HStack(spacing: 8) {
            SecureField("API key", text: $model.keyEntry)
              .labelsHidden()
              .onSubmit { model.saveKey() }
            Button("Save") { model.saveKey() }
              .disabled(model.keyEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              .help("Save the API key to the Keychain.")
          }
        }

        if model.hasStoredKey {
          statusRow("A key is stored", systemImage: "key.fill")
        } else {
          statusRow("No key stored", systemImage: "key")
        }
      }

      Section("Connection") {
        Button("Test Connection") { model.testConnection() }
          .disabled(!model.canTestConnection)
          .help("Send a small request to verify the provider responds.")

        if model.connectionStatus == .idle, !model.canTestConnection {
          statusRow(
            "Save the key and apply the base URL before testing.", systemImage: "info.circle")
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
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
    case .success:
      statusRow("Connection succeeded", systemImage: "checkmark.circle", tint: .green)
    case .failure(let message):
      statusRow(message, systemImage: "xmark.circle", tint: .red)
    }
  }

  private func statusRow(_ text: String, systemImage: String, tint: Color? = nil) -> some View {
    Label(text, systemImage: systemImage)
      .font(.callout)
      .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
      .frame(maxWidth: .infinity, alignment: .leading)
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
