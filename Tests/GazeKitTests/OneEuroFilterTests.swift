import CoreGraphics
import Testing

@testable import GazeKit

private struct SeededNoise {
  private var state: UInt64

  init(seed: UInt64) {
    self.state = seed
  }

  mutating func next() -> Double {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    let unit = Double(state >> 11) / Double(UInt64(1) << 53)
    return (unit * 2.0 - 1.0) * 5.0
  }
}

private func variance(_ values: [Double]) -> Double {
  let mean = values.reduce(0, +) / Double(values.count)
  let sum = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
  return sum / Double(values.count)
}

@Test func firstSamplePassesThroughUnchanged() {
  var filter = OneEuroFilter()
  let result = filter.apply(5.0, at: 0.0)
  #expect(result == 5.0)
}

@Test func constantInputConvergesToConstant() {
  var filter = OneEuroFilter()
  var result = 0.0
  for i in 0..<200 {
    result = filter.apply(10.0, at: Double(i) / 60.0)
  }
  #expect(abs(result - 10.0) <= 0.001)
}

@Test func stepInputDoesNotOvershoot() {
  var filter = OneEuroFilter()
  var maximum = -Double.greatestFiniteMagnitude
  for i in 0..<100 {
    let value = i < 50 ? 0.0 : 1.0
    let output = filter.apply(value, at: Double(i) / 60.0)
    if output > maximum {
      maximum = output
    }
  }
  #expect(maximum <= 1.0)
}

@Test func noiseVarianceIsReducedByFactorOfFour() {
  var filter = OneEuroFilter()
  var generator = SeededNoise(seed: 0x2545_F491_4F6C_DD1D)
  var input: [Double] = []
  var output: [Double] = []
  for i in 0..<500 {
    let value = 100.0 + generator.next()
    input.append(value)
    output.append(filter.apply(value, at: Double(i) / 60.0))
  }
  let inputVariance = variance(input)
  let outputVariance = variance(output)
  #expect(outputVariance * 4.0 <= inputVariance)
}

@Test func higherBetaTracksFastRampWithLessLag() {
  var adaptive = OneEuroFilter(minCutoff: 1.0, beta: 0.007, derivativeCutoff: 1.0)
  var plain = OneEuroFilter(minCutoff: 1.0, beta: 0.0, derivativeCutoff: 1.0)
  var adaptiveResult = 0.0
  var plainResult = 0.0
  for i in 0..<100 {
    let value = Double(i) * 10.0
    let time = Double(i) / 60.0
    adaptiveResult = adaptive.apply(value, at: time)
    plainResult = plain.apply(value, at: time)
  }
  let lastValue = 99.0 * 10.0
  let adaptiveError = abs(adaptiveResult - lastValue)
  let plainError = abs(plainResult - lastValue)
  #expect(adaptiveError < plainError)
}

@Test func duplicateTimestampDoesNotProduceNaN() {
  var filter = OneEuroFilter()
  _ = filter.apply(1.0, at: 1.0)
  let result = filter.apply(2.0, at: 1.0)
  #expect(result.isFinite)
}

@Test func outOfOrderTimestampDoesNotProduceNaN() {
  var filter = OneEuroFilter()
  _ = filter.apply(1.0, at: 2.0)
  let result = filter.apply(2.0, at: 1.0)
  #expect(result.isFinite)
}

@Test func resetRestoresFirstSampleBehaviour() {
  var filter = OneEuroFilter()
  for i in 0..<10 {
    _ = filter.apply(Double(i), at: Double(i) / 60.0)
  }
  filter.reset()
  let result = filter.apply(42.0, at: 100.0)
  #expect(result == 42.0)
}

@Test func pointFilterFiltersBothAxes() {
  var filter = OneEuroPointFilter()
  var result = CGPoint.zero
  for i in 0..<200 {
    result = filter.apply(CGPoint(x: 3.0, y: -7.0), at: Double(i) / 60.0)
  }
  #expect(abs(result.x - 3.0) <= 0.001)
  #expect(abs(result.y - (-7.0)) <= 0.001)
}
