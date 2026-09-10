import CoreGraphics

public func centroid(of points: [CGPoint]) -> CGPoint {
  guard !points.isEmpty else { return .zero }
  let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
  return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
}
