import GazeKit
import SwiftUI

/// Native, readable preview of the production gaze-to-trigger pipeline.
///
/// Pointer simulation samples the real pointer while it is over the target.
/// It is never presented as camera tracking.
struct CalibrationPreviewView: View {
  var model: CalibrationPreviewModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Picker("Preview source", selection: sourceBinding) {
          ForEach(CalibrationPreviewModel.Source.allCases) { source in
            Text(source.title).tag(source)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        sourceSection

        HStack(alignment: .top, spacing: 12) {
          targetArea
          telemetryPanel.frame(width: 300, alignment: .topLeading)
        }

        explanationPanel
      }
      .padding(16)
      .frame(minWidth: 760, alignment: .topLeading)
    }
    .background {
      SimulationEventBridge(
        isActive: model.isSimulationInputActive,
        modifierKey: model.modifierKey,
        onModifierChange: { model.handleModifierStateChange(pressed: $0) },
        onCommand: { model.handleSimulationCommand($0) }
      )
      .frame(width: 0, height: 0)
    }
    .onDisappear { model.stop() }
  }

  private var sourceBinding: Binding<CalibrationPreviewModel.Source> {
    Binding(get: { model.selectedSource }, set: { model.selectSource($0) })
  }

  @ViewBuilder
  private var sourceSection: some View {
    switch model.selectedSource {
    case .live:
      if model.isLiveTrackingAvailable {
        Label("Live gaze samples are connected.", systemImage: "camera.fill")
          .foregroundStyle(.secondary)
      } else {
        Label(
          "Live camera gaze is not connected in this build. Pointer simulation can still show how triggers behave.",
          systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(.secondary)
      }
    case .pointerSimulation:
      VStack(alignment: .leading, spacing: 8) {
        Toggle(
          "Enable pointer simulation (real pointer, not camera gaze)",
          isOn: pointerSimulationBinding)
        if model.isPointerSimulationEnabled {
          Text("Activation mode: \(modeLabel)")
            .font(.callout)
          modifierControls
          HStack(spacing: 8) {
            Button("Reset") { model.resetPreview() }
            Spacer()
          }
          Text(
            "Samples come from the latest real pointer position while it is over the target, at about 30 Hz."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder
  private var modifierControls: some View {
    switch model.mode {
    case .modifierHeld:
      Text(
        "Keep the pointer over the sample, hold the \(model.modifierKeyName) key, then release it to capture. Moving the pointer off the target cancels the hold."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    case .doubleBlink:
      Text(
        "Keep the pointer over the sample. Press B for a single blink, or D for a double blink to capture."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    case .squint:
      Text("Keep the pointer over the sample and press S to simulate a squint.")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .passiveDwell:
      Text("Hold the pointer still over the target until the dwell completes.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var pointerSimulationBinding: Binding<Bool> {
    Binding(
      get: { model.isPointerSimulationEnabled },
      set: { model.setPointerSimulationEnabled($0) })
  }

  private var targetArea: some View {
    GeometryReader { proxy in
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 10)
          .fill(.background)
          .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))

        VStack(alignment: .leading, spacing: 8) {
          Text(model.sampleTitle).font(.callout.weight(.semibold))
          ScrollView {
            Text(verbatim: model.sampleCode)
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(12)

        if let target = model.targetCenter {
          targetReticle.position(target)
        }

        if let marker = model.markerPoint {
          Circle()
            .fill(.red)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .frame(width: 12, height: 12)
            .position(marker)
        }
      }
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        switch phase {
        case .active(let location): model.pointerHovered(at: location)
        case .ended: model.pointerExited()
        }
      }
      .onAppear { model.updateTargetSize(proxy.size) }
      .onChange(of: proxy.size) { _, size in model.updateTargetSize(size) }
    }
    .frame(minWidth: 420, minHeight: 300)
  }

  private var targetReticle: some View {
    ZStack {
      Circle().stroke(.tint, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(width: 28)
      Circle().fill(.tint).frame(width: 4)
    }
    .accessibilityLabel("Target to look at")
  }

  private var telemetryPanel: some View {
    GroupBox("Why it triggers") {
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
        row("Mode", modeLabel)
        row("Source", model.selectedSource.title)
        row("Tracking", trackingDescription)
        row("Dwell", String(format: "%.1f s", model.dwellSeconds))
        row(
          "Dispersion",
          String(format: "%.0f / %.0f", model.tracking.dispersion, model.dispersionThreshold))
        row("Trigger state", model.triggerStateDescription)
        row("Local captures", "\(model.tracking.localTriggerCount) (no provider request)")
        row("Input", issueDescription(model.tracking.lastIssue))
        if let error = model.measuredTargetError {
          row("Measured error", String(format: "%.0f pt", error))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      ProgressView(value: model.tracking.dwellProgress)
        .progressViewStyle(.linear)
      Text(dwellLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var dwellLabel: String {
    if let fixation = model.tracking.currentFixation, model.tracking.dwellProgress >= 1 {
      return String(
        format: "Last fixation: %.2f s across %d samples", fixation.duration, fixation.sampleCount)
    }
    return String(format: "Dwell progress: %.0f%%", model.tracking.dwellProgress * 100)
  }

  private func row(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary)
      Text(value).textSelection(.enabled)
    }
  }

  private var modeLabel: String {
    switch model.mode {
    case .modifierHeld: "Modifier held"
    case .passiveDwell: "Passive dwell"
    case .doubleBlink: "Double blink"
    case .squint: "Squint"
    }
  }

  private var trackingDescription: String {
    switch model.selectedSource {
    case .live:
      guard model.isLiveTrackingAvailable else { return "unavailable" }
      return model.tracking.isTracking ? "receiving samples" : "waiting for samples"
    case .pointerSimulation:
      guard model.isPointerSimulationEnabled else { return "not enabled" }
      return model.tracking.isTracking ? "pointer over target" : "move pointer over target"
    }
  }

  private func issueDescription(_ issue: TrackingPreviewIssue?) -> String {
    switch issue {
    case .none: "none"
    case .nonFiniteSample: "non-finite sample rejected"
    case .outOfBoundsSample(let point, _):
      String(format: "out of bounds (%.0f, %.0f) rejected", point.x, point.y)
    case .nonMonotonicTimestamp: "non-monotonic timestamp rejected"
    case .blinkWhileUntracked: "blink ignored without tracking"
    case .squintWhileUntracked: "squint ignored without tracking"
    }
  }

  private var explanationPanel: some View {
    GroupBox("Explanation") {
      VStack(alignment: .leading, spacing: 8) {
        Text(
          "Local preview triggers never call the provider. Only Test Explanation sends the visible sample code as an image."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        explanationContent

        HStack(spacing: 8) {
          Button("Test Explanation") { model.requestTestExplanation() }
            .disabled(!model.isExplanationAvailable || model.isExplanationLoading)
          if model.isExplanationLoading {
            Button("Cancel") { model.cancelExplanation() }
          }
          Spacer()
          Button("Start Calibration") { model.startCalibration() }
        }

        if let message = model.explanationAvailabilityMessage {
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text(model.calibrationStatusMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private var explanationContent: some View {
    switch model.explanation {
    case .idle:
      Text("No explanation requested yet.")
        .foregroundStyle(.secondary)
    case .loading:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Requesting explanation...")
      }
    case .loaded(let markdown):
      ScrollView {
        Text(LocalizedStringKey(markdown))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(minHeight: 72, maxHeight: 140)
    case .failed(let message):
      Text(message)
        .foregroundStyle(.red)
        .textSelection(.enabled)
    }
  }
}

#Preview {
  CalibrationPreviewView(model: CalibrationPreviewModel())
}
