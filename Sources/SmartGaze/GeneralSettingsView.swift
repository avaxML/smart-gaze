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
        .help("How a capture starts: hold a key, dwell on a region, or blink twice.")

        Picker("Modifier key", selection: model.modifierKeyBinding()) {
          ForEach(ModifierKey.allCases, id: \.self) { key in
            Text(key.rawValue.capitalized).tag(key)
          }
        }
        .help("The key to hold while aiming, in Modifier held mode.")
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
          "Dwell time is how long your gaze must hold still before triggering. Dispersion threshold is how far it may wander, in screen points, and still count as still."
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
        Text("Controls how large the on-screen explanation bubble may grow, in points.")
      }
    }
    .formStyle(.grouped)
  }

  private func boundedRow(
    _ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double.Stride,
    unit: String, fractionDigits: Int
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 12) {
        Text(title)
        Spacer(minLength: 12)
        Text(measurement(value.wrappedValue, digits: fractionDigits, unit: unit))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      Slider(value: value, in: range, step: step)
        .labelsHidden()
      HStack(spacing: 12) {
        Text(measurement(range.lowerBound, digits: fractionDigits, unit: unit))
        Spacer(minLength: 12)
        Text(measurement(range.upperBound, digits: fractionDigits, unit: unit))
      }
      .font(.caption)
      .foregroundStyle(.tertiary)
    }
  }

  private func measurement(_ value: Double, digits: Int, unit: String) -> String {
    "\(value.formatted(.number.precision(.fractionLength(digits)))) \(unit)"
  }

  private func activationLabel(_ mode: ActivationMode) -> String {
    switch mode {
    case .modifierHeld: "Modifier held"
    case .passiveDwell: "Passive dwell"
    case .doubleBlink: "Double blink"
    }
  }
}
