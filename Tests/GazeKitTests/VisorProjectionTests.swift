import Foundation
import Testing

@testable import GazeKit

private let cloudPoints = [
  SIMD2(0.25, 0.5), SIMD2(0.75, 0.5), SIMD2(0.75, 0.5), SIMD2(0.25, 0.5), SIMD2(0.5, 0.5),
]
private let cloudDepths = [0.0, -0.1, 0.1, 0.0, 0.0]

@Test func aCentroidPointAtMeanDepthIsAProjectionFixedPoint() {
  let projected = VisorProjection.project(
    points: cloudPoints, depths: cloudDepths, yawRadians: 0, pitchRadians: 0)

  #expect(projected.count == cloudPoints.count)
  #expect(abs(projected[4].x - 0.5) <= 1e-12)
  #expect(abs(projected[4].y - 0.5) <= 1e-12)
  #expect(abs(projected[4].depth - 0.5) <= 1e-12)

  // Rotating the virtual camera about the centroid cannot move the centroid.
  let turned = VisorProjection.project(
    points: cloudPoints, depths: cloudDepths, yawRadians: 0.2, pitchRadians: 0.1)
  #expect(abs(turned[4].x - 0.5) <= 1e-12)
  #expect(abs(turned[4].y - 0.5) <= 1e-12)
}

@Test func aNearerPointProjectsFartherFromTheCentroidThanAFartherOne() {
  let projected = VisorProjection.project(
    points: cloudPoints, depths: cloudDepths, yawRadians: 0, pitchRadians: 0)

  // Both points sit at (0.75, 0.5); index 1 is nearer (z = -0.1) and index 2
  // is farther (z = 0.1). The cloud's centroid is (0.5, 0.5).
  #expect(abs(projected[1].x - 0.7597402597402597) <= 1e-12)
  #expect(abs(projected[2].x - 0.7409638554216867) <= 1e-12)
  #expect(abs(projected[1].depth - 0.0) <= 1e-12)
  #expect(abs(projected[2].depth - 1.0) <= 1e-12)
  #expect(abs(projected[1].x - 0.5) > abs(projected[2].x - 0.5))
}

@Test func yawMovesACentroidPointWithDepthOffsetByTheStatedAmount() {
  let points = [SIMD2(0.5, 0.5), SIMD2(0.5, 0.5)]
  let depths = [0.1, -0.1]
  let projected = VisorProjection.project(
    points: points, depths: depths, yawRadians: 0.2, pitchRadians: 0)

  // depthScale 0.9 * 0.1 = 0.09 at yaw 0.2 * parallaxGain 0.35, projected
  // through cameraDistance 2.4, moves the point by -0.006067868451266709.
  #expect(abs(projected[0].x - 0.4939321315487333) <= 1e-12)
  #expect(abs(projected[0].x - 0.5 - (-0.006067868451266709)) <= 1e-12)
  #expect(abs(projected[0].y - 0.5) <= 1e-12)
  #expect(abs(projected[0].depth - 1.0) <= 1e-12)
}

@Test func nonFiniteDepthPassesThroughAtDepthOne() {
  let points = [SIMD2(0.25, 0.5), SIMD2(0.75, 0.5)]
  let depths = [Double.nan, 0.2]
  let projected = VisorProjection.project(
    points: points, depths: depths, yawRadians: 0.2, pitchRadians: 0.1)

  #expect(projected.count == 2)
  #expect(projected[0].x == 0.25)
  #expect(projected[0].y == 0.5)
  #expect(projected[0].depth == 1)
}

@Test func aNonFiniteRotationKeepsEveryProjectionFinite() {
  let projected = VisorProjection.project(
    points: [SIMD2(0.5, 0.5), SIMD2(0.6, 0.5)], depths: [0, 0.05],
    yawRadians: .nan, pitchRadians: .infinity)

  #expect(projected.count == 2)
  #expect(projected.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.depth.isFinite })
}

@Test func aPointOnTheCameraPlanePassesThroughFinitely() {
  let depths = [0.0, 2 * VisorProjection.cameraDistance / VisorProjection.depthScale]
  let projected = VisorProjection.project(
    points: [SIMD2(0.5, 0.5), SIMD2(0.5, 0.5)], depths: depths,
    yawRadians: 0, pitchRadians: 0)

  #expect(projected.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.depth.isFinite })
}
