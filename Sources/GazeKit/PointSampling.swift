import CoreGraphics

public func resample(_ points: [CGPoint], to count: Int) -> [CGPoint] {
  guard count > 0, !points.isEmpty else { return [] }
  guard points.count > count else {
    let last = points[points.count - 1]
    return points + Array(repeating: last, count: count - points.count)
  }
  let stride = Double(points.count) / Double(count)
  return (0..<count).map { points[Int(Double($0) * stride)] }
}

public func centroid(of points: [CGPoint]) -> CGPoint {
  guard !points.isEmpty else { return .zero }
  let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
  return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
}
