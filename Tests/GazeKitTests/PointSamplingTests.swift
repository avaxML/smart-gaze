import CoreGraphics
import Testing

@testable import GazeKit

@Test func centroidAveragesAllPoints() {
  let points = [CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0), CGPoint(x: 2, y: 6)]
  #expect(centroid(of: points) == CGPoint(x: 2, y: 2))
}

@Test func centroidOfEmptyInputIsZero() {
  #expect(centroid(of: []) == .zero)
}
