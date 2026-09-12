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
        VStack(alignment: .leading, spacing: 4) {
          valueRow(
            "Smoothing",
            value: model.settings.gazeSmoothing.formatted(
              .percent.precision(.fractionLength(0)))
          )
          Slider(value: model.gazeSmoothingBinding(), in: GazeSmoothing.range) {
            Text("Smoothing")
          } minimumValueLabel: {
            Text("Responsive").font(.caption).foregroundStyle(.secondary)
          } maximumValueLabel: {
            Text("Calm").font(.caption).foregroundStyle(.secondary)
          }
          .labelsHidden()
        }
      } header: {
        Text("Tracking")
      } footer: {
        Text(
          "How steadily the on-screen outline follows your gaze. Calm removes almost all jitter but takes a moment longer to catch up after you look somewhere new."
        )
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
    _ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
    unit: String, fractionDigits: Int
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      valueRow(
        title,
        value:
          "\(value.wrappedValue.formatted(.number.precision(.fractionLength(fractionDigits)))) \(unit)"
      )
      Slider(value: stepped(value, step: step, in: range), in: range)
    }
  }

  private func valueRow(_ title: String, value: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value).monospacedDigit().foregroundStyle(.secondary)
    }
  }

  /// Snaps the continuous slider to `step` so the track carries no tick marks;
  /// a stepped `Slider` draws one tick per step, which reads as noise here.
  private func stepped(
    _ value: Binding<Double>, step: Double, in range: ClosedRange<Double>
  ) -> Binding<Double> {
    Binding(
      get: { value.wrappedValue },
      set: { newValue in
        let snapped = (newValue / step).rounded() * step
        value.wrappedValue = min(max(snapped, range.lowerBound), range.upperBound)
      }
    )
  }

  private func activationLabel(_ mode: ActivationMode) -> String {
    switch mode {
    case .modifierHeld: "Modifier held"
    case .passiveDwell: "Passive dwell"
    case .doubleBlink: "Double blink"
    }
  }
}
