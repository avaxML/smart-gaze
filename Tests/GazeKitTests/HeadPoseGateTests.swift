import Foundation
import GazeKit
import Testing

@Test func aSquareFaceIsNeverBlocked() {
  var gate = HeadPoseGate()
  for yaw in [0.0, 0.1, -0.2, 0.3, -0.39] {
    #expect(gate.update(yawRadians: yaw) == false)
  }
}

@Test func aTurnToTheNextMonitorBlocksAndOnlyASquareFaceReleases() {
  var gate = HeadPoseGate()
  #expect(gate.update(yawRadians: 0.45) == true)
  // Back inside the block band but not yet square: still blocked.
  #expect(gate.update(yawRadians: 0.35) == true)
  #expect(gate.update(yawRadians: -0.35) == true)
  #expect(gate.update(yawRadians: 0.25) == false)
  #expect(gate.update(yawRadians: 0.39) == false)
}

@Test func nonFiniteYawLeavesTheGateWhereItWas() {
  var gate = HeadPoseGate()
  #expect(gate.update(yawRadians: .nan) == false)
  gate.update(yawRadians: 0.6)
  #expect(gate.update(yawRadians: .infinity) == true)
  gate.reset()
  #expect(gate.isBlocked == false)
}
