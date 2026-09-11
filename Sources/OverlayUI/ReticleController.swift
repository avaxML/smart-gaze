import AppKit
import SwiftUI

/// Draws the outline of the region that would be captured, centred on the
/// current gaze point, while the trigger is armed, and locks onto the exact
/// rect that was captured when one fires. It answers two questions the user
/// otherwise cannot: is the calibration landing where I am looking, and what
/// just left this machine.
///
/// The window is owned by this bundle, so the capturer's own-window exclusion
/// keeps the outline out of the crop it outlines.
@MainActor
public final class ReticleController {
  private var panel: NSPanel?
  private var isFlashing = false

  public init() {}

  /// Shows the outline centred on `point` in global top-left screen
  /// coordinates, as the gaze pipeline reports them, for a capture of `size`.
  public func show(centredOn point: CGPoint, size: CGSize) {
    guard !isFlashing else { return }
    let panel = panel ?? makePanel()
    self.panel = panel
    let origin = Self.appKitOrigin(for: point, size: size)
    let frame = CGRect(origin: origin, size: size)
    if !panel.isVisible {
      panel.setFrame(frame, display: true)
      panel.orderFrontRegardless()
      return
    }
    // Residual jitter after filtering is a few points per frame. Ignoring
    // moves under the dead band and easing the rest keeps the outline from
    // twitching at 30 Hz while it still follows a real shift of gaze.
    let current = panel.frame
    guard
      abs(frame.minX - current.minX) > Self.deadBandPoints
        || abs(frame.minY - current.minY) > Self.deadBandPoints || frame.size != current.size
    else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      context.allowsImplicitAnimation = true
      panel.animator().setFrame(frame, display: true)
    }
  }

  private static let deadBandPoints: CGFloat = 6

  public func hide() {
    guard !isFlashing else { return }
    panel?.orderOut(nil)
  }

  /// Locks the outline on exactly the rect that was captured and animates it,
  /// so the user sees what was sent rather than where their gaze happened to be
  /// a frame later. Hides itself when the animation ends.
  public func flash(capturedRect rect: CGRect) {
    let panel = panel ?? makePanel()
    self.panel = panel
    isFlashing = true
    let origin = Self.appKitOrigin(for: CGPoint(x: rect.midX, y: rect.midY), size: rect.size)
    panel.setFrame(CGRect(origin: origin, size: rect.size), display: true)
    panel.contentView = NSHostingView(rootView: ReticleView(mode: .captured))
    panel.alphaValue = 1
    if !panel.isVisible { panel.orderFrontRegardless() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
      guard let self, let panel = self.panel else { return }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.35
        panel.animator().alphaValue = 0
      } completionHandler: {
        panel.orderOut(nil)
        panel.alphaValue = 1
        panel.contentView = NSHostingView(rootView: ReticleView(mode: .armed))
        self.isFlashing = false
      }
    }
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered,
      defer: false)
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.contentView = NSHostingView(rootView: ReticleView(mode: .armed))
    return panel
  }

  /// Gaze points arrive with a top-left origin. AppKit frames use a bottom-left
  /// origin measured against the main display's height, on every display.
  private static func appKitOrigin(for topLeftCentre: CGPoint, size: CGSize) -> CGPoint {
    let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
    let x = topLeftCentre.x - size.width / 2
    let topLeftY = topLeftCentre.y - size.height / 2
    return CGPoint(x: x, y: mainHeight - topLeftY - size.height)
  }
}

private struct ReticleView: View {
  enum Mode { case armed, captured }
  var mode: Mode

  @State private var dashPhase: CGFloat = 0

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    ZStack {
      shape.fill(.tint.opacity(mode == .captured ? 0.10 : 0.06))
      switch mode {
      case .armed:
        shape.strokeBorder(.tint, lineWidth: 2)
      case .captured:
        shape
          .strokeBorder(
            .tint,
            style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [14, 10], dashPhase: dashPhase)
          )
          .onAppear {
            withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: false)) {
              dashPhase = -24
            }
          }
      }
    }
    .padding(1)
    .allowsHitTesting(false)
  }
}
