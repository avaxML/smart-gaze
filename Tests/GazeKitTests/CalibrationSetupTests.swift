import CoreGraphics
import Foundation
import Testing

@testable import GazeKit

private func mesh(_ landmarks: [Int: CGPoint], count: Int = 468) -> [CGPoint] {
  var points = [CGPoint](repeating: CGPoint(x: 0.5, y: 0.5), count: count)
  for (index, point) in landmarks { points[index] = point }
  return points
}

private func face(center: CGPoint = CGPoint(x: 0.5, y: 0.5), depth: Double? = 60)
  -> CalibrationSetupFace
{
  CalibrationSetupFace(
    mesh: [center],
    imageLeftEyeContour: [],
    imageRightEyeContour: [],
    imageLeftIris: [],
    imageRightIris: [],
    depthCentimetres: depth)
}

@Test func centerIsTheMeanOfTheMeshAndNilWhenEmpty() throws {
  let mean = CalibrationSetupFace(
    mesh: [CGPoint(x: 0.2, y: 0.4), CGPoint(x: 0.6, y: 0.8)],
    imageLeftEyeContour: [],
    imageRightEyeContour: [],
    imageLeftIris: [],
    imageRightIris: [],
    depthCentimetres: nil)
  let center = try #require(mean.center)
  #expect(abs(Double(center.x) - 0.4) <= 1e-12)
  #expect(abs(Double(center.y) - 0.6) <= 1e-12)

  let empty = CalibrationSetupFace(
    mesh: [],
    imageLeftEyeContour: [],
    imageRightEyeContour: [],
    imageLeftIris: [],
    imageRightIris: [],
    depthCentimetres: nil)
  #expect(empty.center == nil)
}

@Test func eyeBandPadsTheLandmarkBoxByTheDocumentedFactors() throws {
  let landmarks: [Int: CGPoint] = [
    70: CGPoint(x: 0.25, y: 0.375),
    300: CGPoint(x: 0.75, y: 0.375),
    33: CGPoint(x: 0.3125, y: 0.5),
    133: CGPoint(x: 0.375, y: 0.5),
    362: CGPoint(x: 0.625, y: 0.5),
    263: CGPoint(x: 0.6875, y: 0.5),
  ]
  let band = try #require(
    CalibrationSetupFace(
      mesh: mesh(landmarks),
      imageLeftEyeContour: [],
      imageRightEyeContour: [],
      imageLeftIris: [],
      imageRightIris: [],
      depthCentimetres: nil
    ).eyeBand)

  #expect(abs(band.minX - 0.125) <= 1e-12)
  #expect(abs(band.minY - 0.3) <= 1e-12)
  #expect(abs(band.width - 0.75) <= 1e-12)
  #expect(abs(band.height - 0.275) <= 1e-12)
}

@Test func eyeBandClampsThePaddedBoxToTheUnitSquare() throws {
  let landmarks: [Int: CGPoint] = [
    70: CGPoint(x: 0, y: 0),
    300: CGPoint(x: 1, y: 1),
  ]
  let band = try #require(
    CalibrationSetupFace(
      mesh: mesh(landmarks),
      imageLeftEyeContour: [],
      imageRightEyeContour: [],
      imageLeftIris: [],
      imageRightIris: [],
      depthCentimetres: nil
    ).eyeBand)

  #expect(band == CGRect(x: 0, y: 0, width: 1, height: 1))
}

@Test func eyeBandIsNilWithFewerThanFourHundredSixtyEightPoints() {
  let short = CalibrationSetupFace(
    mesh: mesh([:], count: 100),
    imageLeftEyeContour: [],
    imageRightEyeContour: [],
    imageLeftIris: [],
    imageRightIris: [],
    depthCentimetres: nil)
  #expect(short.eyeBand == nil)
}

@Test func reducerWalksFromSearchToHoldToReady() throws {
  var reducer = CalibrationSetupReducer()

  #expect(reducer.update(face: nil, at: 0) == .findingFace)
  #expect(reducer.update(face: face(depth: 90), at: 0) == .moveCloser)
  #expect(reducer.update(face: face(depth: 30), at: 0) == .moveBack)

  let offCentre = reducer.update(face: face(center: CGPoint(x: 0.7, y: 0.5)), at: 0)
  guard case .centerFace(let offsetX, let offsetY) = offCentre else {
    Issue.record("expected centerFace, got \(offCentre)")
    return
  }
  #expect(abs(offsetX - 0.2) <= 1e-12)
  #expect(abs(offsetY) <= 1e-12)

  #expect(reducer.update(face: face(), at: 0) == .holdStill(progress: 0))
  #expect(reducer.update(face: face(), at: 0.5) == .holdStill(progress: 0.5))
  #expect(reducer.update(face: face(), at: 1.0) == .ready)

  #expect(reducer.update(face: nil, at: 1.2) == .findingFace)
  #expect(reducer.update(face: face(), at: 1.3) == .holdStill(progress: 0))
}

@Test func centerIsNilWhenTheMeshMeanIsNotFinite() {
  let nonFinite = CalibrationSetupFace(
    mesh: [CGPoint(x: CGFloat.nan, y: 0.5)],
    imageLeftEyeContour: [],
    imageRightEyeContour: [],
    imageLeftIris: [],
    imageRightIris: [],
    depthCentimetres: 60)
  #expect(nonFinite.center == nil)

  var reducer = CalibrationSetupReducer()
  #expect(reducer.update(face: nonFinite, at: 0) == .findingFace)
}
