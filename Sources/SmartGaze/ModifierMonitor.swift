import ApplicationServices
import CoreGraphics
import Foundation
import GazeKit

/// A global `flagsChanged` `CGEvent` tap for the configured modifier key.
///
/// Needs Accessibility permission (`AXIsProcessTrusted`); without it macOS
/// refuses to create the tap. The caller is responsible for degrading to
/// dwell mode when `start()` reports that rather than pretending the
/// modifier will ever fire.
@MainActor
final class ModifierMonitor {
  enum StartResult: Equatable {
    case started
    case accessibilityPermissionMissing
    case tapCreationFailed
  }

  private var modifierKey: ModifierKey
  private let onChange: (Bool, TimeInterval) -> Void
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var isDown = false

  init(modifierKey: ModifierKey, onChange: @escaping (Bool, TimeInterval) -> Void) {
    self.modifierKey = modifierKey
    self.onChange = onChange
  }

  func updateModifierKey(_ key: ModifierKey) {
    modifierKey = key
    isDown = false
  }

  func start() -> StartResult {
    stop()
    guard AXIsProcessTrusted() else { return .accessibilityPermissionMissing }

    let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: { _, _, event, refcon in
          guard let refcon else { return Unmanaged.passUnretained(event) }
          let monitor = Unmanaged<ModifierMonitor>.fromOpaque(refcon).takeUnretainedValue()
          monitor.handle(event)
          return Unmanaged.passUnretained(event)
        },
        userInfo: refcon)
    else {
      return .tapCreationFailed
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    eventTap = tap
    runLoopSource = source
    return .started
  }

  func stop() {
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
    }
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
    eventTap = nil
    runLoopSource = nil
    isDown = false
  }

  private func handle(_ event: CGEvent) {
    let flags = event.flags
    let down = flags.contains(ModifierMonitor.cgFlag(for: modifierKey))
    guard down != isDown else { return }
    isDown = down
    onChange(down, ProcessInfo.processInfo.systemUptime)
  }

  private static func cgFlag(for key: ModifierKey) -> CGEventFlags {
    switch key {
    case .option: .maskAlternate
    case .control: .maskControl
    case .command: .maskCommand
    case .shift: .maskShift
    }
  }

  isolated deinit {
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
    }
  }
}
