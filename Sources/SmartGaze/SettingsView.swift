import Combine
import GazeKit
import SwiftUI

enum SettingsTab: Int, CaseIterable {
  case general, preview, provider, privacy

  var title: String {
    switch self {
    case .general: "General"
    case .preview: "Calibration & Preview"
    case .provider: "Provider"
    case .privacy: "Privacy"
    }
  }

  var symbolName: String {
    switch self {
    case .general: "gear"
    case .preview: "eye"
    case .provider: "brain"
    case .privacy: "hand.raised"
    }
  }
}

@MainActor
final class SettingsTabSelection: ObservableObject {
  @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
  @ObservedObject var model: SettingsModel
  var preview: CalibrationPreviewModel
  @ObservedObject var selection: SettingsTabSelection

  var body: some View {
    VStack(spacing: 0) {
      if let error = model.persistenceError {
        Label {
          Text(error)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(.orange.opacity(0.35))
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
      }

      content
    }
    .frame(minWidth: 760, minHeight: 520)
    .onChange(of: selection.tab) { _, tab in
      if tab == .preview {
        preview.prepareForPresentation(from: model)
      } else {
        preview.stop()
      }
    }
    .onAppear {
      if selection.tab == .preview {
        preview.prepareForPresentation(from: model)
      }
    }
    .onChange(of: model.settings) { _, settings in
      preview.applyConfiguration(from: settings)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch selection.tab {
    case .general:
      GeneralSettingsView(model: model)
    case .preview:
      CalibrationPreviewView(model: preview, settings: model)
    case .provider:
      ProviderSettingsView(model: model)
    case .privacy:
      PrivacySettingsView(model: model)
    }
  }
}
