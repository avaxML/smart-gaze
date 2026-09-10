import CoreGraphics
import Testing

@testable import GazeKit

@Test func resampleDownsizesEvenlyAcrossTheOriginalOrder() {
  let points = (0..<12).map { CGPoint(x: Double($0), y: 0) }
  let sampled = resample(points, to: 6)
  #expect(
    sampled == [
      CGPoint(x: 0, y: 0),
      CGPoint(x: 2, y: 0),
      CGPoint(x: 4, y: 0),
      CGPoint(x: 6, y: 0),
      CGPoint(x: 8, y: 0),
      CGPoint(x: 10, y: 0),
    ])
}

@Test func resamplePadsWithTheLastPointWhenTooFewAreGiven() {
  let points = [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)]
  let sampled = resample(points, to: 6)
  #expect(
    sampled == [
      CGPoint(x: 1, y: 1),
      CGPoint(x: 2, y: 2),
      CGPoint(x: 2, y: 2),
      CGPoint(x: 2, y: 2),
      CGPoint(x: 2, y: 2),
      CGPoint(x: 2, y: 2),
    ])
}

@Test func resampleOfEmptyInputIsEmpty() {
  #expect(resample([], to: 6) == [])
}

@Test func centroidAveragesAllPoints() {
  let points = [CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0), CGPoint(x: 2, y: 6)]
  #expect(centroid(of: points) == CGPoint(x: 2, y: 2))
}

@Test func centroidOfEmptyInputIsZero() {
  #expect(centroid(of: []) == .zero)
}
