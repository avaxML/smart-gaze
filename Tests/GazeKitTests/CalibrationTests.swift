import CoreGraphics
import Foundation
import Testing

@testable import GazeKit

private let gridPoints: [NormalizedGazePoint] = [
  NormalizedGazePoint(x: -0.4, y: -0.3),
  NormalizedGazePoint(x: 0.0, y: -0.3),
  NormalizedGazePoint(x: 0.4, y: -0.3),
  NormalizedGazePoint(x: -0.4, y: 0.0),
  NormalizedGazePoint(x: 0.0, y: 0.0),
  NormalizedGazePoint(x: 0.4, y: 0.0),
  NormalizedGazePoint(x: -0.4, y: 0.3),
  NormalizedGazePoint(x: 0.0, y: 0.3),
  NormalizedGazePoint(x: 0.4, y: 0.3),
]

private let exactXCoefficients = [100.0, 500.0, 50.0, 20.0, 10.0, 5.0]
private let exactYCoefficients = [200.0, 400.0, 30.0, 15.0, 8.0, 3.0]

private func makeSamples(
  xCoefficients: [Double],
  yCoefficients: [Double],
  gaze: [NormalizedGazePoint] = gridPoints
) -> [CalibrationSample] {
  let map = CalibrationMap(xCoefficients: xCoefficients, yCoefficients: yCoefficients)
  return gaze.map { CalibrationSample(gaze: $0, screenPoint: map.project($0)) }
}

private struct SeededPerturbation {
  private var state: UInt64

  init(seed: UInt64) {
    self.state = seed
  }

  mutating func next() -> Double {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    let unit = Double(state >> 11) / Double(UInt64(1) << 53)
    return (unit * 2.0 - 1.0) * 0.001
  }
}

@Test func recoversKnownCoefficients() throws {
  let samples = makeSamples(
    xCoefficients: exactXCoefficients, yCoefficients: exactYCoefficients)
  let map = try solveCalibration(samples)

  for index in 0..<6 {
    #expect(abs(map.xCoefficients[index] - exactXCoefficients[index]) <= 1e-9)
    #expect(abs(map.yCoefficients[index] - exactYCoefficients[index]) <= 1e-9)
  }
}

@Test func roundTripsProjection() throws {
  let samples = makeSamples(
    xCoefficients: exactXCoefficients, yCoefficients: exactYCoefficients)
  let map = try solveCalibration(samples)

  for sample in samples {
    let projected = map.project(sample.gaze)
    #expect(abs(projected.x - sample.screenPoint.x) <= 1e-9)
    #expect(abs(projected.y - sample.screenPoint.y) <= 1e-9)
  }
}

@Test func literalAffineRecoversScreenPointsIncludingOutsideUnitRange() throws {
  let samples = gridPoints.map { point in
    CalibrationSample(
      gaze: point,
      screenPoint: CGPoint(x: 100 + 800 * point.x, y: 50 + 600 * point.y))
  }
  let map = try solveCalibration(samples)

  let expected: [(gaze: NormalizedGazePoint, screenPoint: CGPoint)] = [
    (NormalizedGazePoint(x: 0, y: 0), CGPoint(x: 100, y: 50)),
    (NormalizedGazePoint(x: 0.25, y: 0.75), CGPoint(x: 300, y: 500)),
    (NormalizedGazePoint(x: 1.2, y: -0.1), CGPoint(x: 1060, y: -10)),
  ]
  for entry in expected {
    let projected = map.project(entry.gaze)
    #expect(abs(projected.x - entry.screenPoint.x) <= 1e-6)
    #expect(abs(projected.y - entry.screenPoint.y) <= 1e-6)
  }
}

@Test func linearRelationshipHasNearZeroQuadraticTerms() throws {
  let samples = makeSamples(
    xCoefficients: [100, 500, 50, 0, 0, 0],
    yCoefficients: [200, 400, 30, 0, 0, 0])
  let map = try solveCalibration(samples)

  for index in 3..<6 {
    #expect(abs(map.xCoefficients[index]) <= 1e-9)
    #expect(abs(map.yCoefficients[index]) <= 1e-9)
  }
}

@Test func tooFewSamplesThrows() {
  let samples = makeSamples(
    xCoefficients: exactXCoefficients, yCoefficients: exactYCoefficients,
    gaze: Array(gridPoints.prefix(5)))
  #expect(throws: CalibrationError.insufficientSamples(got: 5, need: 6)) {
    try solveCalibration(samples)
  }
}

@Test func identicalSamplesThrowDegenerate() {
  let sample = CalibrationSample(
    gaze: NormalizedGazePoint(x: 0.1, y: 0.2), screenPoint: CGPoint(x: 10, y: 20))
  let samples = [CalibrationSample](repeating: sample, count: 9)
  #expect(throws: CalibrationError.degenerate) {
    try solveCalibration(samples)
  }
}

@Test func codableRoundTrip() throws {
  let map = try solveCalibration(
    makeSamples(xCoefficients: exactXCoefficients, yCoefficients: exactYCoefficients))
  let data = try JSONEncoder().encode(map)
  let decoded = try JSONDecoder().decode(CalibrationMap.self, from: data)
  #expect(decoded == map)
}

@Test func encodedMapCarriesInputSpaceMarker() throws {
  let map = try solveCalibration(
    makeSamples(xCoefficients: exactXCoefficients, yCoefficients: exactYCoefficients))
  let data = try JSONEncoder().encode(map)
  let json = try #require(String(data: data, encoding: .utf8))
  #expect(json.contains(CalibrationMap.inputSpaceMarker))
}

@Test func untaggedLegacyMapFailsToDecode() {
  let json = """
    {"xCoefficients":[1,2,3,4,5,6],"yCoefficients":[6,5,4,3,2,1]}
    """
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(CalibrationMap.self, from: Data(json.utf8))
  }
}

@Test func wrongInputSpaceMarkerFailsToDecode() {
  let json = """
    {"inputSpace":"gaze-angles-v1","xCoefficients":[1,2,3,4,5,6],"yCoefficients":[6,5,4,3,2,1]}
    """
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(CalibrationMap.self, from: Data(json.utf8))
  }
}

@Test func wrongCoefficientCountFailsToDecode() {
  let json = """
    {"inputSpace":"normalized-screen-point-v1","xCoefficients":[1,2,3,4,5],
    "yCoefficients":[6,5,4,3,2,1]}
    """
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(CalibrationMap.self, from: Data(json.utf8))
  }
}

@Test func noiseStillRecoversScreenPoints() throws {
  var generator = SeededPerturbation(seed: 0x1234_5678_9ABC_DEF0)
  let clean = makeSamples(
    xCoefficients: exactXCoefficients, yCoefficients: exactYCoefficients)
  let noisy = clean.map { sample in
    CalibrationSample(
      gaze: NormalizedGazePoint(
        x: sample.gaze.x + generator.next(),
        y: sample.gaze.y + generator.next()),
      screenPoint: sample.screenPoint)
  }

  let map = try solveCalibration(noisy)
  for sample in clean {
    let projected = map.project(sample.gaze)
    #expect(abs(projected.x - sample.screenPoint.x) <= 5.0)
    #expect(abs(projected.y - sample.screenPoint.y) <= 5.0)
  }
}

@Test func coefficientsAreNeverNaN() throws {
  let map = try solveCalibration(
    makeSamples(xCoefficients: exactXCoefficients, yCoefficients: exactYCoefficients))
  for coefficient in map.xCoefficients + map.yCoefficients {
    #expect(coefficient.isFinite)
  }
}
