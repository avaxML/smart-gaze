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
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.orange)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
          .padding(.horizontal, 16)
          .padding(.top, 12)
      }
      TabView(selection: $selectedTab) {
        GeneralSettingsView(model: model)
          .tabItem { Label("General", systemImage: "gearshape") }
          .tag(Tab.general)
        CalibrationPreviewView(model: preview)
          .tabItem { Label("Calibration & Preview", systemImage: "eye") }
          .tag(Tab.preview)
        ProviderSettingsView(model: model)
          .tabItem { Label("Provider", systemImage: "sparkles") }
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
