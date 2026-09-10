import AppKit
import CoreGraphics
import GazeKit
import SwiftUI

@MainActor
public final class BubbleController {
  public let state = BubbleState()
  public var onDismiss: (() -> Void)?
  public let appearance: OverlayAppearance

  private let panel: GlassPanel
  private var anchorRegion: CGRect = .zero
  private var anchorBounds: CGRect = .zero
  private var baseSize: CGSize = CGSize(width: 380, height: 250)
  private var presentationID = 0
  private var dismissalLatch = DismissalLatch()
  private var eventMonitors: [Any] = []
  private var mouseTimer: Timer?

  private let expandedScale: CGFloat = 1.6
  private let escapeKeyCode: UInt16 = 53

  public init(appearance: OverlayAppearance = OverlayAppearance()) {
    self.appearance = appearance
    let panel = GlassPanel(contentRect: CGRect(x: 0, y: 0, width: 380, height: 250))
    self.panel = panel
    panel.appearance = appearance.panelAppearance
    panel.contentView = FirstMouseHostingView(
      rootView: BubbleView(
        state: state,
        onCopy: { [weak self] in self?.copyToPasteboard() },
        onTogglePin: { [weak self] in self?.state.togglePinned() },
        onToggleExpand: { [weak self] in self?.toggleExpanded() },
        onClose: { [weak self] in self?.dismiss() }
      )
    )
  }

  @discardableResult
  public func show(anchoredTo region: CGRect, within bounds: CGRect, size: CGSize)
    -> PresentationHandle
  {
    if state.isVisible {
      dismiss()
    }
    presentationID += 1
    dismissalLatch.arm()
    anchorRegion = region
    anchorBounds = bounds
    baseSize = clampedSize(size, within: bounds)

    let handle = state.begin()
    let frame = bubbleFrame(anchoredTo: region, size: baseSize, within: bounds)
    panel.setFrame(frame, display: true)
    panel.ignoresMouseEvents = true
    panel.orderFrontRegardless()
    if reduceMotion {
      panel.alphaValue = 1
    } else {
      // Animating to 1 retargets a fade-out still in flight from a replaced presentation.
      panel.animator().alphaValue = 1
    }

    installEventMonitors()
    startMouseTracking()
    return handle
  }

  public func append(_ token: String, for handle: PresentationHandle) {
    state.append(token, for: handle)
  }

  public func finish(for handle: PresentationHandle) {
    state.finish(for: handle)
  }

  public func showError(_ message: String, for handle: PresentationHandle) {
    state.fail(message, for: handle)
  }

  public func setPinned(_ pinned: Bool) {
    state.setPinned(pinned)
  }

  public func updateGaze(_ point: CGPoint, at timestamp: TimeInterval) {
    guard state.isVisible else { return }
    let inside = panel.frame.contains(point)
    if state.updateGaze(inside: inside, at: timestamp) {
      dismiss()
    }
  }

  public func dismiss() {
    guard state.isVisible else { return }
    state.end()
    removeEventMonitors()
    stopMouseTracking()

    let id = presentationID
    if reduceMotion {
      panel.orderOut(nil)
    } else {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        panel.animator().alphaValue = 0
      } completionHandler: { [weak self] in
        MainActor.assumeIsolated {
          guard let self, self.presentationID == id else { return }
          self.panel.orderOut(nil)
        }
      }
    }

    notifyDismissOnce()
  }

  private func notifyDismissOnce() {
    guard dismissalLatch.fireOnce() else { return }
    onDismiss?()
  }

  private func toggleExpanded() {
    let expanded = !state.isExpanded
    state.setExpanded(expanded)
    let requested =
      expanded
      ? CGSize(width: baseSize.width * expandedScale, height: baseSize.height * expandedScale)
      : baseSize
    let size = clampedSize(requested, within: anchorBounds)
    let frame = bubbleFrame(anchoredTo: anchorRegion, size: size, within: anchorBounds)
    panel.setFrame(frame, display: true, animate: !reduceMotion)
  }

  private func clampedSize(_ size: CGSize, within bounds: CGRect) -> CGSize {
    CGSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
  }

  private func copyToPasteboard() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(state.text, forType: .string)
  }

  private var reduceMotion: Bool {
    appearance.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  private func installEventMonitors() {
    removeEventMonitors()

    let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      MainActor.assumeIsolated { self?.handleKey(event) }
      return event
    }
    let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      MainActor.assumeIsolated { self?.handleKey(event) }
    }
    if let local { eventMonitors.append(local) }
    if let global { eventMonitors.append(global) }
  }

  private func removeEventMonitors() {
    for monitor in eventMonitors {
      NSEvent.removeMonitor(monitor)
    }
    eventMonitors.removeAll()
  }

  private func handleKey(_ event: NSEvent) {
    guard event.keyCode == escapeKeyCode, !state.isPinned else { return }
    dismiss()
  }

  private func startMouseTracking() {
    stopMouseTracking()
    synchronizeMousePassthrough()
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.synchronizeMousePassthrough() }
    }
    RunLoop.main.add(timer, forMode: .common)
    mouseTimer = timer
  }

  private func stopMouseTracking() {
    mouseTimer?.invalidate()
    mouseTimer = nil
  }

  private func synchronizeMousePassthrough() {
    guard state.isVisible else { return }
    panel.ignoresMouseEvents = !panel.frame.contains(NSEvent.mouseLocation)
  }

  isolated deinit {
    removeEventMonitors()
    stopMouseTracking()
  }
}
