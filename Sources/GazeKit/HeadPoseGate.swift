import Foundation

/// Decides whether the head is turned too far for the gaze map to mean
/// anything. The map is fitted with the face roughly square to the camera; a
/// look at a second monitor is a head turn of tens of degrees and the model
/// then reports a direction it was never trained on. Hysteresis keeps a head
/// hovering at the edge from toggling tracking on and off every frame.
public struct HeadPoseGate: Equatable, Sendable {
  public let blockAboveRadians: Double
  public let releaseBelowRadians: Double
  public private(set) var isBlocked = false

  /// Defaults are about 23 degrees to block and 17 to release, the band
  /// between a natural glance across one display and a turn to the next.
  public init(blockAboveRadians: Double = 0.40, releaseBelowRadians: Double = 0.30) {
    self.blockAboveRadians = blockAboveRadians
    self.releaseBelowRadians = releaseBelowRadians
  }

  /// Feeds one head yaw in radians. Returns the gate's state afterwards.
  @discardableResult
  public mutating func update(yawRadians: Double) -> Bool {
    guard yawRadians.isFinite else { return isBlocked }
    let magnitude = abs(yawRadians)
    if isBlocked {
      if magnitude < releaseBelowRadians { isBlocked = false }
    } else if magnitude > blockAboveRadians {
      isBlocked = true
    }
    return isBlocked
  }

  public mutating func reset() {
    isBlocked = false
  }
}
