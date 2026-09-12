import GazeKit
import SwiftUI

struct GeneralSettingsView: View {
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
