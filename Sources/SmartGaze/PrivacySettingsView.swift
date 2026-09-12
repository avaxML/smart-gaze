import SwiftUI

struct PrivacySettingsView: View {
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
