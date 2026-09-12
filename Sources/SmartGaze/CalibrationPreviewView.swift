import GazeKit
import SwiftUI

/// Native, readable preview of the production gaze-to-trigger pipeline.
///
/// Pointer simulation samples the real pointer while it is over the target.
/// It is never presented as camera tracking.
struct CalibrationPreviewView: View {
  var model: CalibrationPreviewModel

  var body: some View {
    Form {
      calibrationSection
      targetTelemetrySection
      explanationSection
    }
    .formStyle(.grouped)
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

  private var pointerSimulationBinding: Binding<Bool> {
    Binding(
      get: { model.isPointerSimulationEnabled },
      set: { model.setPointerSimulationEnabled($0) })
  }

  /// One card holds the primary action, the source picker and every source
  /// detail, so the target and its live telemetry start high enough to fit the
  /// default 800x600 window without scrolling.
  private var calibrationSection: some View {
    Section {
      HStack(spacing: 12) {
        Button("Start Calibration") { model.startCalibration() }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .help("Run the calibration overlay to measure your gaze.")
        Spacer(minLength: 12)
        if model.isExplanationLoading {
          Button("Cancel") { model.cancelExplanation() }
            .controlSize(.large)
            .help("Stop the in-flight explanation request.")
        }
        Button("Test Explanation") { model.requestTestExplanation() }
          .controlSize(.large)
          .disabled(!model.isExplanationAvailable || model.isExplanationLoading)
          .help("Send the visible sample code to the provider and show the returned explanation.")
      }

      LabeledContent("Preview source") {
        Picker("Preview source", selection: sourceBinding) {
          ForEach(CalibrationPreviewModel.Source.allCases) { source in
            Text(source.title).tag(source)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 280)
        .help("Choose live tracking or a pointer-driven simulation.")
      }

      sourceDetails

      Label(model.calibrationStatusMessage, systemImage: "target")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if let message = model.explanationAvailabilityMessage {
        Label(message, systemImage: "info.circle")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    } header: {
      Text("Calibration")
    } footer: {
      sourceFooter
    }
  }

  @ViewBuilder
  private var sourceDetails: some View {
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
      Toggle(
        "Enable pointer simulation (real pointer, not camera gaze)", isOn: pointerSimulationBinding
      )
      .help("Feed the trigger pipeline from the real pointer instead of camera gaze.")
      if model.isPointerSimulationEnabled {
        HStack(spacing: 12) {
          LabeledContent("Activation mode", value: modeLabel)
          Button("Reset") { model.resetPreview() }
            .help("Clear the sample history and return the trigger to idle.")
        }
      }
    }
  }

  @ViewBuilder
  private var sourceFooter: some View {
    if model.selectedSource == .pointerSimulation, model.isPointerSimulationEnabled {
      VStack(alignment: .leading, spacing: 4) {
        Text(modifierInstruction)
        Text(
          "Samples come from the latest real pointer position while it is over the target, at about 30 Hz."
        )
      }
    }
  }

  private var modifierInstruction: String {
    switch model.mode {
    case .modifierHeld:
      "Keep the pointer over the sample, hold the \(model.modifierKeyName) key, then release it to capture. Moving the pointer off the target cancels the hold."
    case .doubleBlink:
      "Keep the pointer over the sample. Press B for a single blink, or D for a double blink to capture."
    case .squint:
      "Keep the pointer over the sample and press S to simulate a squint."
    case .passiveDwell:
      "Hold the pointer still over the target until the dwell completes."
    }
  }

  /// Target and telemetry sit side by side so the reader can hover the reticle
  /// and watch the trigger pipeline react in the same glance.
  private var targetTelemetrySection: some View {
    Section {
      HStack(alignment: .top, spacing: 16) {
        targetArea
        telemetryPanel
          .frame(width: 300, alignment: .topLeading)
      }
    } header: {
      Text("Target")
    }
  }

  private var targetArea: some View {
    GeometryReader { proxy in
      ZStack(alignment: .topLeading) {
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(model.sampleTitle).font(.headline)
            Spacer(minLength: 8)
            Label("Hover or look at the reticle to sample", systemImage: "scope")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          ScrollView {
            Text(verbatim: model.sampleCode)
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

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
    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 280, maxHeight: 280)
  }

  private var targetReticle: some View {
    ZStack {
      Circle().stroke(.tint, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(width: 28)
      Circle().fill(.tint).frame(width: 4)
    }
    .accessibilityLabel("Target to look at")
  }

  private var telemetryPanel: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Why it triggers")
        .font(.subheadline.weight(.semibold))
      telemetryRow("Mode", modeLabel)
      telemetryRow("Source", model.selectedSource.title)
      telemetryRow("Tracking", trackingDescription)
      telemetryRow("Dwell", String(format: "%.1f s", model.dwellSeconds))
      telemetryRow(
        "Dispersion",
        String(format: "%.0f / %.0f", model.tracking.dispersion, model.dispersionThreshold))
      telemetryRow("Trigger state", model.triggerStateDescription)
      telemetryRow("Local captures", "\(model.tracking.localTriggerCount) (no provider request)")
      telemetryRow("Input", issueDescription(model.tracking.lastIssue))
      if let error = model.measuredTargetError {
        telemetryRow("Measured error", String(format: "%.0f pt", error))
      }

      ProgressView(value: model.tracking.dwellProgress)
        .progressViewStyle(.linear)
      Text(dwellLabel)
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }

  private func telemetryRow(_ label: String, _ value: String) -> some View {
    LabeledContent {
      Text(value)
        .monospacedDigit()
        .textSelection(.enabled)
    } label: {
      Text(label)
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

  private var explanationSection: some View {
    Section {
      explanationContent
    } header: {
      Text("Explanation")
    } footer: {
      Text(
        "Local preview triggers never call the provider. Only Test Explanation sends the visible sample code as an image."
      )
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
