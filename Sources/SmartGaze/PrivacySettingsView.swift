import SwiftUI

struct PrivacySettingsView: View {
  @ObservedObject var model: SettingsModel
  @State private var newBundleID = ""

  var body: some View {
    Form {
      Section {
        deniedApps
        addAppRow
      } header: {
        Text("Denied apps")
      } footer: {
        Text("Capture never starts while one of these apps is frontmost.")
      }

      Section {
        Text("Captures are processed in memory and are never written to disk.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder private var deniedApps: some View {
    if model.deniedAppIDs.isEmpty {
      Label("No apps are denied", systemImage: "hand.raised.slash")
        .foregroundStyle(.secondary)
    } else {
      ForEach(model.deniedAppIDs, id: \.self) { bundleID in
        deniedAppRow(bundleID)
      }
    }
  }

  private func deniedAppRow(_ bundleID: String) -> some View {
    HStack {
      Text(bundleID).font(.system(.body, design: .monospaced))
      Spacer()
      Button {
        model.removeDeniedApp(bundleID)
      } label: {
        Image(systemName: "minus.circle.fill")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .help("Allow capture while \(bundleID) is frontmost")
      .accessibilityLabel("Remove \(bundleID)")
    }
  }

  private var addAppRow: some View {
    HStack(spacing: 8) {
      Image(systemName: "plus.circle")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField("Add a bundle identifier", text: $newBundleID)
        .font(.system(.body, design: .monospaced))
        .onSubmit(addBundleID)
      Button("Add", action: addBundleID)
        .disabled(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  private func addBundleID() {
    model.addDeniedApp(newBundleID)
    newBundleID = ""
  }
}
