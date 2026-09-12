import CoreGraphics
import Foundation
import Testing

@testable import GazeKit

@Test func ellipseThroughAxisAlignedRimHasTheStatedAxes() throws {
  let rim = [
    CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 6),
    CGPoint(x: -10, y: 0), CGPoint(x: 0, y: -6),
  ]

  let ellipse = try #require(IrisRingGeometry.ellipse(throughRim: rim))

  #expect(ellipse.center == CGPoint(x: 0, y: 0))
  #expect(abs(ellipse.semiMajor - 10) <= 1e-12)
  #expect(abs(ellipse.semiMinor - 6) <= 1e-12)
  #expect(abs(ellipse.angleRadians) <= 1e-12)
}

@Test func ellipseThroughRotatedRimKeepsTheRotationAngle() throws {
  let angle = Double.pi / 6
  let cosA = cos(angle)
  let sinA = sin(angle)
  func rotate(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: point.x * cosA - point.y * sinA,
      y: point.x * sinA + point.y * cosA)
  }
  let rim = [
    CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 6),
    CGPoint(x: -10, y: 0), CGPoint(x: 0, y: -6),
  ].map(rotate)

  let ellipse = try #require(IrisRingGeometry.ellipse(throughRim: rim))

  #expect(abs(ellipse.center.x) <= 1e-12)
  #expect(abs(ellipse.center.y) <= 1e-12)
  #expect(abs(ellipse.semiMajor - 10) <= 1e-12)
  #expect(abs(ellipse.semiMinor - 6) <= 1e-12)
  #expect(abs(ellipse.angleRadians - Double.pi / 6) <= 1e-9)
}

@Test func ellipseRejectsFewerThanFourRimPoints() {
  let rim = [CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 6), CGPoint(x: -10, y: 0)]
  #expect(IrisRingGeometry.ellipse(throughRim: rim) == nil)
}

@Test func ellipseRejectsAZeroAreaRim() {
  let rim = [
    CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 0),
    CGPoint(x: -10, y: 0), CGPoint(x: 0, y: 0),
  ]
  #expect(IrisRingGeometry.ellipse(throughRim: rim) == nil)
}
