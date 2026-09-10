import CoreGraphics
import Foundation

public enum EyeContourError: Error, Equatable {
  case tooFewPoints(got: Int, need: Int)
  case degenerateContour
}

public func eyeLandmarks(fromContour points: [CGPoint]) throws -> EyeLandmarks {
  guard points.count >= 4 else {
    throw EyeContourError.tooFewPoints(got: points.count, need: 4)
  }

  let p1 = corner(in: points, smallestX: true)
  let p4 = corner(in: points, smallestX: false)

  guard pointDistance(p1, p4) >= 1e-9 else {
    throw EyeContourError.degenerateContour
  }

  let axisX = Double(p4.x - p1.x)
  let axisY = Double(p4.y - p1.y)
  let axisLengthSquared = axisX * axisX + axisY * axisY

  var positiveSide: [CGPoint] = []
  var negativeSide: [CGPoint] = []
  for point in points where point != p1 && point != p4 {
    let dx = Double(point.x - p1.x)
    let dy = Double(point.y - p1.y)
    let cross = axisX * dy - axisY * dx
    if cross > 0 {
      positiveSide.append(point)
    } else if cross < 0 {
      negativeSide.append(point)
    }
  }

  // In image coordinates y grows downward, so the upper lid is the side with smaller mean y.
  let lids = classifyLids(
    positiveSide, negativeSide, axisMidpointY: Double(p1.y + p4.y) / 2)

  func projection(_ point: CGPoint) -> Double {
    let dx = Double(point.x - p1.x)
    let dy = Double(point.y - p1.y)
    return (axisX * dx + axisY * dy) / axisLengthSquared
  }

  func nearest(_ candidates: [CGPoint], to target: Double) -> CGPoint? {
    var best: CGPoint?
    var bestDistance = Double.infinity
    for candidate in candidates {
      let candidateDistance = abs(projection(candidate) - target)
      if candidateDistance < bestDistance {
        best = candidate
        bestDistance = candidateDistance
      } else if candidateDistance == bestDistance, let current = best,
        isOrderedBefore(candidate, current)
      {
        best = candidate
      }
    }
    return best
  }

  // A lid with no points collapses to the corner midpoint, so a closed eye stays valid.
  let midpoint = CGPoint(x: (p1.x + p4.x) / 2, y: (p1.y + p4.y) / 2)
  let p2 = nearest(lids.upper, to: 1.0 / 3.0) ?? midpoint
  let p3 = nearest(lids.upper, to: 2.0 / 3.0) ?? midpoint
  let p5 = nearest(lids.lower, to: 2.0 / 3.0) ?? midpoint
  let p6 = nearest(lids.lower, to: 1.0 / 3.0) ?? midpoint

  guard let landmarks = EyeLandmarks(points: [p1, p2, p3, p4, p5, p6]) else {
    throw EyeContourError.degenerateContour
  }
  return landmarks
}

private func corner(in points: [CGPoint], smallestX: Bool) -> CGPoint {
  var best = points[0]
  for point in points.dropFirst() {
    let betterX = smallestX ? point.x < best.x : point.x > best.x
    if betterX || (point.x == best.x && point.y < best.y) {
      best = point
    }
  }
  return best
}

private func classifyLids(
  _ positiveSide: [CGPoint], _ negativeSide: [CGPoint], axisMidpointY: Double
) -> (upper: [CGPoint], lower: [CGPoint]) {
  guard let positiveMean = meanY(positiveSide) else {
    guard let negativeMean = meanY(negativeSide) else { return ([], []) }
    return negativeMean < axisMidpointY ? (negativeSide, []) : ([], negativeSide)
  }
  guard let negativeMean = meanY(negativeSide) else {
    return positiveMean < axisMidpointY ? (positiveSide, []) : ([], positiveSide)
  }
  return positiveMean < negativeMean
    ? (positiveSide, negativeSide) : (negativeSide, positiveSide)
}

private func meanY(_ points: [CGPoint]) -> Double? {
  guard !points.isEmpty else { return nil }
  let total = points.reduce(0.0) { $0 + Double($1.y) }
  return total / Double(points.count)
}

private func isOrderedBefore(_ a: CGPoint, _ b: CGPoint) -> Bool {
  if a.x != b.x { return a.x < b.x }
  return a.y < b.y
}

private func pointDistance(_ a: CGPoint, _ b: CGPoint) -> Double {
  let dx = Double(a.x) - Double(b.x)
  let dy = Double(a.y) - Double(b.y)
  return (dx * dx + dy * dy).squareRoot()
}
