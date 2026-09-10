import AppKit
import OverlayUI

private let explanation = """
  The highlighted region is a Swift closure. It captures `count` by reference, so each call updates the same value.

  ```swift
  var counter = 0
  let bump = { counter += 1 }
  bump()
  ```

  Copy, Expand, and Pin are on the bar below. Pin suppresses both Escape and gaze dismissal.
  """

@MainActor
final class DemoDelegate: NSObject, NSApplicationDelegate {
  private lazy var controller = BubbleController(appearance: appearance)
  private var streamTask: Task<Void, Never>?
  private var metadataTimer: Timer?
  private var scriptTask: Task<Void, Never>?
  private var handle: PresentationHandle?
  private var dismissCount = 0
  private var streamStopCount = 0

  private let flags = Set(CommandLine.arguments.dropFirst())
  private var bounds = CGRect.zero
  private var region = CGRect.zero
  private let bubbleSize = CGSize(width: 380, height: 250)

  private var appearance: OverlayAppearance {
    OverlayAppearance(
      colorScheme: flags.contains("--dark") ? .dark : (flags.contains("--light") ? .light : nil),
      reduceTransparency: flags.contains("--reduce-transparency"),
      increaseContrast: flags.contains("--increase-contrast"),
      reduceMotion: flags.contains("--reduce-motion")
    )
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    controller.onDismiss = { [weak self] in
      guard let self else { return }
      self.dismissCount += 1
      let streamWasActive = self.streamTask != nil
      self.streamTask?.cancel()
      self.handle = nil
      print(
        "[demo] onDismiss count=\(self.dismissCount) streamWasActive=\(streamWasActive) "
          + "streamStopped=\(self.streamStopCount)"
      )
    }

    let screen = NSScreen.main ?? NSScreen.screens[0]
    bounds =
      flags.contains("--small-bounds")
      ? CGRect(
        x: screen.visibleFrame.midX - 180, y: screen.visibleFrame.midY - 120, width: 360,
        height: 240)
      : screen.visibleFrame
    region = CGRect(
      x: bounds.midX - 100,
      y: bounds.midY - 50,
      width: 200,
      height: 100
    )

    print("[demo] bounds=\(bounds) anchor=\(region) appActive=\(NSApp.isActive)")
    print("[demo] appearance colorScheme=\(String(describing: appearance.colorScheme)) "
      + "reduceTransparency=\(appearance.reduceTransparency) "
      + "increaseContrast=\(appearance.increaseContrast) reduceMotion=\(appearance.reduceMotion)")
    show()
    startStream()
    startMetadata()
    runScriptedSequence()
  }

  private func show() {
    handle = controller.show(anchoredTo: region, within: bounds, size: bubbleSize)
    log("after show")
  }

  private func startStream() {
    guard let handle else { return }
    streamTask = Task { @MainActor in
      for token in explanation.map(String.init) {
        do {
          try await Task.sleep(nanoseconds: 18_000_000)
        } catch {
          finishStream()
          return
        }
        if Task.isCancelled {
          finishStream()
          return
        }
        controller.append(token, for: handle)
      }
      controller.finish(for: handle)
      streamTask = nil
      print("[demo] stream finished")
    }
  }

  private func finishStream() {
    streamStopCount += 1
    streamTask = nil
    print("[demo] stream stopped by cancellation count=\(streamStopCount)")
  }

  private func startMetadata() {
    let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
      MainActor.assumeIsolated {
        self.log("tick")
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    metadataTimer = timer
  }

  private func runScriptedSequence() {
    if flags.contains("--stale") {
      scriptTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        print("[demo] stale: dismiss then immediately show again")
        controller.dismiss()
        show()
        try? await Task.sleep(nanoseconds: 600_000_000)
        let panel = NSApp.windows.first { $0 is GlassPanel }
        let visible = panel?.isVisible ?? false
        let alpha = panel?.alphaValue ?? 0
        print(
          "[demo] stale: panel.isVisible=\(visible) panel.alphaValue=\(alpha) "
            + "alphaOK=\(alpha > 0.99) expected=true"
        )
        controller.dismiss()
        try? await Task.sleep(nanoseconds: 400_000_000)
        print("[demo] stale: exit dismiss count=\(dismissCount) expected=2")
        NSApp.terminate(nil)
      }
    } else if flags.contains("--auto") {
      scriptTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        print("[demo] auto: pin on")
        controller.setPinned(true)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        print("[demo] auto: pin off (dismissal re-armed)")
        controller.setPinned(false)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        print("[demo] auto: explicit dismiss")
        controller.dismiss()
        try? await Task.sleep(nanoseconds: 500_000_000)
        print("[demo] auto: exit dismiss count=\(dismissCount) expected=1")
        NSApp.terminate(nil)
      }
    }
  }

  private func log(_ label: String) {
    let panel = NSApp.windows.first { $0 is GlassPanel }
    let ignores = panel?.ignoresMouseEvents ?? true
    let frame = panel?.frame ?? .zero
    let visible = panel?.isVisible ?? false
    let alpha = panel?.alphaValue ?? 0
    let fits = bounds.contains(frame)
    print(
      "[demo] \(label) stateVisible=\(controller.state.isVisible) panelVisible=\(visible) "
        + "panelAlpha=\(alpha) stateStreaming=\(controller.state.isStreaming) "
        + "pinned=\(controller.state.isPinned) expanded=\(controller.state.isExpanded) "
        + "frameFitsBounds=\(fits) appActive=\(NSApp.isActive) keyWindow=\(NSApp.keyWindow != nil) "
        + "ignoresMouse=\(ignores) mouse=\(NSEvent.mouseLocation)"
    )
  }

  func applicationWillTerminate(_ notification: Notification) {
    streamTask?.cancel()
    scriptTask?.cancel()
    metadataTimer?.invalidate()
  }
}

@main
struct OverlayDemo {
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = DemoDelegate()
    app.delegate = delegate
    app.run()
  }
}
