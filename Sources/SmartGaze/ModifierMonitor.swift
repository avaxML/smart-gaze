import ApplicationServices
import CoreGraphics
import Foundation
import GazeKit

/// A global `flagsChanged` `CGEvent` tap for the configured modifier key.
///
/// Needs Accessibility permission (`AXIsProcessTrusted`); without it macOS
/// refuses to create the tap. The caller is responsible for telling the user
/// when `start()` reports that rather than pretending the modifier will
/// ever fire.
///
/// macOS disables a tap whose callback misses its deadline, and a Core ML
/// model load on the main thread is enough to do that; the tap then goes
/// silent with no error, and if the key was down at the time the release is
/// never seen and the outline hangs. Two guards: the disable events re-enable
/// the tap, and a 250 ms timer reads the real modifier state from the event
/// source and reports any edge the tap missed.
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
  private var healthTimer: Timer?

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
        callback: { _, type, event, refcon in
          guard let refcon else { return Unmanaged.passUnretained(event) }
          let monitor = Unmanaged<ModifierMonitor>.fromOpaque(refcon).takeUnretainedValue()
          if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            monitor.reenableTap()
          } else {
            monitor.handle(event)
          }
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
    healthTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkHealth() }
    }
    return .started
  }

  private func reenableTap() {
    guard let eventTap else { return }
    CGEvent.tapEnable(tap: eventTap, enable: true)
  }

  /// Compares the modifier state the system reports against the last edge the
  /// tap delivered and synthesises the missing one.
  private func checkHealth() {
    if let eventTap, !CGEvent.tapIsEnabled(tap: eventTap) {
      CGEvent.tapEnable(tap: eventTap, enable: true)
    }
    let flags = CGEventSource.flagsState(.combinedSessionState)
    apply(down: flags.contains(ModifierMonitor.cgFlag(for: modifierKey)))
  }

  func stop() {
    healthTimer?.invalidate()
    healthTimer = nil
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
    apply(down: event.flags.contains(ModifierMonitor.cgFlag(for: modifierKey)))
  }

  private func apply(down: Bool) {
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
    healthTimer?.invalidate()
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
    }
  }
}
