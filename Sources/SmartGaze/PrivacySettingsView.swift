import AppKit
import SwiftUI

struct PrivacySettingsView: View {
  @ObservedObject var model: SettingsModel
  @State private var newBundleID = ""

  var body: some View {
    Form {
      Section {
        Text("Capture never starts while one of these apps is frontmost.")
        if model.deniedAppIDs.isEmpty {
          Label("No denied apps. Capture runs in every app.", systemImage: "checkmark.shield")
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.deniedAppIDs, id: \.self) { bundleID in
            deniedAppRow(bundleID)
          }
        }
        HStack {
          TextField("com.example.app", text: $newBundleID)
            .onSubmit(addBundleID)
          Button("Add", action: addBundleID)
            .buttonStyle(.borderedProminent)
            .disabled(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      } header: {
        Text("Denied apps")
      } footer: {
        Text("Captures are processed in memory and are never written to disk.")
      }
    }
    .formStyle(.grouped)
  }

  private func deniedAppRow(_ bundleID: String) -> some View {
    HStack(spacing: 8) {
      if let app = installedApp(for: bundleID) {
        Image(nsImage: app.icon)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 20, height: 20)
        VStack(alignment: .leading, spacing: 1) {
          Text(app.name)
          Text(bundleID).font(.caption).foregroundStyle(.secondary)
        }
      } else {
        Text(bundleID).font(.system(.body, design: .monospaced))
      }
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

  private func installedApp(for bundleID: String) -> (name: String, icon: NSImage)? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      return nil
    }
    let bundle = Bundle(url: url)
    let name =
      (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
      ?? url.deletingPathExtension().lastPathComponent
    return (name, NSWorkspace.shared.icon(forFile: url.path))
  }

  private func addBundleID() {
    model.addDeniedApp(newBundleID)
    newBundleID = ""
  }
}
