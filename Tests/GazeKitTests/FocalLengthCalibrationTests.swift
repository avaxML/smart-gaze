import Foundation
import GazeKit
import Testing

@Test func oneFramesFocalLengthUsesTheIrisRuler() throws {
  let focalLength = try #require(
    FocalLengthCalibration.focalLengthPixels(irisDiameterPixels: 30, distanceCentimetres: 60))

  // 30 * 60 cm * 10 / 11.7 mm = 1538.4615...
  #expect(abs(focalLength - 1538.4615) <= 1e-3)
}

@Test func nonFiniteOrNonPositiveFocalInputsReturnNil() {
  #expect(
    FocalLengthCalibration.focalLengthPixels(irisDiameterPixels: .nan, distanceCentimetres: 60)
      == nil)
  #expect(
    FocalLengthCalibration.focalLengthPixels(irisDiameterPixels: 30, distanceCentimetres: .infinity)
      == nil)
  #expect(
    FocalLengthCalibration.focalLengthPixels(irisDiameterPixels: 0, distanceCentimetres: 60) == nil)
  #expect(
    FocalLengthCalibration.focalLengthPixels(irisDiameterPixels: 30, distanceCentimetres: 0) == nil)
}

@Test func fitReturnsTheMedianOfFifteenValues() {
  let focalLengths = [
    1400.0, 1420, 1440, 1460, 1480, 1490, 1495, 1500, 1505, 1510, 1520, 1540, 1560, 1580, 1600,
  ]

  let fitted = FocalLengthCalibration.fit(focalLengthsPixels: focalLengths, frameHeight: 1080)

  #expect(fitted == 1500)
}

@Test func fitNeedsFifteenSamples() {
  let focalLengths = Array(repeating: 1500.0, count: 14)

  #expect(
    FocalLengthCalibration.fit(focalLengthsPixels: focalLengths, frameHeight: 1080) == nil)
}

@Test func fitRejectsAnImplausibleFieldOfView() {
  // A focal length whose implied vertical field of view is 15 degrees.
  let focalLength = 1080.0 / (2 * tan(15.0 / 2 * .pi / 180))
  let focalLengths = Array(repeating: focalLength, count: 15)

  #expect(
    FocalLengthCalibration.fit(focalLengthsPixels: focalLengths, frameHeight: 1080) == nil)
}

@Test func storedFocalScalesWithFrameHeight() {
  let camera = CameraFocalLength(focalLengthPerFrameHeight: 1.4)

  #expect(camera.verticalFocalLengthPixels(frameHeight: 1080) == 1512)
}
