import CoreGraphics
import Foundation
import Testing

@testable import GazeKit

@Test func eyeCropCentersAndScalesBetweenTheCorners() throws {
  let crop = try #require(
    IrisGeometry.eyeCrop(
      imageLeftCorner: SIMD3(100, 200, 0),
      imageRightCorner: SIMD3(140, 230, 0)))

  #expect(crop.center == CGPoint(x: 120, y: 215))
  #expect(abs(crop.side - 115) < 1e-9)
  #expect(abs(crop.rotationRadians - atan2(30, 40)) < 1e-12)
}

@Test func eyeCropMirroredCornerOrderFoldsToTheSameAngle() throws {
  let crop = try #require(
    IrisGeometry.eyeCrop(
      imageLeftCorner: SIMD3(140, 230, 0),
      imageRightCorner: SIMD3(100, 200, 0)))

  #expect(abs(crop.rotationRadians - atan2(30, 40)) < 1e-12)
}

@Test func eyeCropRejectsDegenerateAndNonFiniteCorners() {
  #expect(
    IrisGeometry.eyeCrop(
      imageLeftCorner: SIMD3(10, 10, 0),
      imageRightCorner: SIMD3(10.5, 10, 0)) == nil)
  #expect(
    IrisGeometry.eyeCrop(
      imageLeftCorner: SIMD3(.nan, 10, 0),
      imageRightCorner: SIMD3(40, 10, 0)) == nil)
}

@Test func horizontalFlipReversesColumns() {
  let rgb = (1...18).map { Float($0) }
  let flipped = IrisGeometry.horizontallyFlipped(rgb: rgb, width: 3, height: 2)
  #expect(flipped == [7, 8, 9, 4, 5, 6, 1, 2, 3, 16, 17, 18, 13, 14, 15, 10, 11, 12])
}

@Test func unflippedMirrorsXOnly() {
  #expect(IrisGeometry.unflipped(SIMD3(63, 5, 1), width: 64) == SIMD3(0, 5, 1))
}

@Test func irisDiameterUsesTheHorizontalExtremes() throws {
  let points = [
    SIMD2<Double>(0, 0),
    SIMD2<Double>(10, 0),
    SIMD2<Double>(0, 7),
    SIMD2<Double>(2, 0),
    SIMD2<Double>(0, -7),
  ]
  let diameter = try #require(IrisGeometry.irisDiameter(points))
  #expect(abs(diameter - 8) < 1e-12)
  #expect(IrisGeometry.irisDiameter([SIMD2(0, 0), SIMD2(1, 1)]) == nil)
}

@Test func depthRulerUsesFocalLengthAndDiameter() throws {
  let depth = try #require(
    IrisGeometry.depthCentimetres(irisDiameterPixels: 20, focalLengthPixels: 1000))
  #expect(abs(depth - 58.5) < 1e-9)

  #expect(IrisGeometry.depthCentimetres(irisDiameterPixels: 0, focalLengthPixels: 1000) == nil)
  #expect(IrisGeometry.depthCentimetres(irisDiameterPixels: 20, focalLengthPixels: 0) == nil)
  #expect(IrisGeometry.depthCentimetres(irisDiameterPixels: .nan, focalLengthPixels: 1000) == nil)
  #expect(
    IrisGeometry.depthCentimetres(irisDiameterPixels: 20, focalLengthPixels: .infinity) == nil)
}
