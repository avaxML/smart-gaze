import AppKit
import SwiftUI

@MainActor
public final class GlassPanel: NSPanel {
  public init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect,
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered,
      defer: false
    )
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    ignoresMouseEvents = true
    isMovable = false
    isMovableByWindowBackground = false
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = true
    animationBehavior = .none
  }

  public override var canBecomeKey: Bool { false }
  public override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
