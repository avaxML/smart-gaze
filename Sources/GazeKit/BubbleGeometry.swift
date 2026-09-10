import CoreGraphics
import Foundation

public func bubbleFrame(
  anchoredTo region: CGRect,
  size: CGSize,
  within bounds: CGRect,
  gap: CGFloat = 12
) -> CGRect {
  let rightOrigin = CGPoint(
    x: region.maxX + gap,
    y: region.midY - size.height / 2
  )
  let leftOrigin = CGPoint(
    x: region.minX - gap - size.width,
    y: region.midY - size.height / 2
  )
  let belowOrigin = CGPoint(
    x: region.midX - size.width / 2,
    y: region.minY - gap - size.height
  )
  let aboveOrigin = CGPoint(
    x: region.midX - size.width / 2,
    y: region.maxY + gap
  )

  let right = clampedVertically(CGRect(origin: rightOrigin, size: size), within: bounds)
  if bounds.contains(right) {
    return right
  }

  let left = clampedVertically(CGRect(origin: leftOrigin, size: size), within: bounds)
  if bounds.contains(left) {
    return left
  }

  let below = clampedHorizontally(CGRect(origin: belowOrigin, size: size), within: bounds)
  if bounds.contains(below) {
    return below
  }

  let above = clampedHorizontally(CGRect(origin: aboveOrigin, size: size), within: bounds)
  if bounds.contains(above) {
    return above
  }

  // Nothing fits cleanly, so the bubble has to overlap the region. Keep it inside
  // bounds and choose the side that covers the least of what it is explaining,
  // starting with below so the reading position is preferred over the region.
  let candidates = [
    clampedInside(CGRect(origin: belowOrigin, size: size), within: bounds),
    clampedInside(CGRect(origin: aboveOrigin, size: size), within: bounds),
    clampedInside(CGRect(origin: rightOrigin, size: size), within: bounds),
    clampedInside(CGRect(origin: leftOrigin, size: size), within: bounds),
  ]

  var best = candidates[0]
  var bestOverlap = overlapArea(candidates[0], region)
  for candidate in candidates.dropFirst() {
    let overlap = overlapArea(candidate, region)
    if overlap < bestOverlap {
      best = candidate
      bestOverlap = overlap
    }
  }
  return best
}

public struct DismissalTimer: Sendable {
  private let graceperiod: TimeInterval
  private var outsideSince: TimeInterval?
  private var hasFired: Bool

  public init(graceperiod: TimeInterval = 2.0) {
    self.graceperiod = graceperiod
    self.outsideSince = nil
    self.hasFired = false
  }

  public mutating func update(gazeInside: Bool, at timestamp: TimeInterval) -> Bool {
    if gazeInside {
      outsideSince = nil
      hasFired = false
      return false
    }

    if hasFired {
      return false
    }

    guard let start = outsideSince else {
      outsideSince = timestamp
      return false
    }

    if timestamp - start >= graceperiod {
      hasFired = true
      return true
    }

    return false
  }

  public mutating func reset() {
    outsideSince = nil
    hasFired = false
  }
}

private func clampedVertically(_ rect: CGRect, within bounds: CGRect) -> CGRect {
  var rect = rect
  rect.origin.y = min(max(rect.origin.y, bounds.minY), bounds.maxY - rect.height)
  return rect
}

private func clampedHorizontally(_ rect: CGRect, within bounds: CGRect) -> CGRect {
  var rect = rect
  rect.origin.x = min(max(rect.origin.x, bounds.minX), bounds.maxX - rect.width)
  return rect
}

private func clampedInside(_ rect: CGRect, within bounds: CGRect) -> CGRect {
  clampedHorizontally(clampedVertically(rect, within: bounds), within: bounds)
}

private func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
  let intersection = a.intersection(b)
  if intersection.isNull {
    return 0
  }
  return intersection.width * intersection.height
}
