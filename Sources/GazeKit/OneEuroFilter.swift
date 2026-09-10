import CoreGraphics
import Foundation

public struct OneEuroFilter: Sendable {
  private let minCutoff: Double
  private let beta: Double
  private let derivativeCutoff: Double

  private var hasPrevious = false
  private var tPrev: TimeInterval = 0
  private var xPrev: Double = 0
  private var dxHatPrev: Double = 0
  private var yPrev: Double = 0
  private var lastEmitted: Double = 0

  public init(minCutoff: Double = 1.0, beta: Double = 0.007, derivativeCutoff: Double = 1.0) {
    self.minCutoff = minCutoff
    self.beta = beta
    self.derivativeCutoff = derivativeCutoff
  }

  public mutating func apply(_ value: Double, at timestamp: TimeInterval) -> Double {
    guard hasPrevious else {
      hasPrevious = true
      tPrev = timestamp
      xPrev = value
      dxHatPrev = 0
      yPrev = value
      lastEmitted = value
      return value
    }

    let dt = timestamp - tPrev
    // A non-positive dt would divide by zero or run time backwards, so keep the last output and leave state intact.
    guard dt > 0 else {
      return lastEmitted
    }

    let dx = (value - xPrev) / dt
    let dxHat = lowPass(dx, alpha(cutoff: derivativeCutoff, dt: dt), previous: dxHatPrev)
    let cutoff = minCutoff + beta * abs(dxHat)
    let result = lowPass(value, alpha(cutoff: cutoff, dt: dt), previous: yPrev)

    tPrev = timestamp
    xPrev = value
    dxHatPrev = dxHat
    yPrev = result
    lastEmitted = result
    return result
  }

  public mutating func reset() {
    hasPrevious = false
    tPrev = 0
    xPrev = 0
    dxHatPrev = 0
    yPrev = 0
    lastEmitted = 0
  }

  private func alpha(cutoff: Double, dt: TimeInterval) -> Double {
    let tau = 1.0 / (2.0 * Double.pi * cutoff)
    return 1.0 / (1.0 + tau / dt)
  }

  private func lowPass(_ value: Double, _ alpha: Double, previous: Double) -> Double {
    return alpha * value + (1.0 - alpha) * previous
  }
}

public struct OneEuroPointFilter: Sendable {
  private var xFilter: OneEuroFilter
  private var yFilter: OneEuroFilter

  public init(minCutoff: Double = 1.0, beta: Double = 0.007, derivativeCutoff: Double = 1.0) {
    self.xFilter = OneEuroFilter(
      minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
    self.yFilter = OneEuroFilter(
      minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
  }

  public mutating func apply(_ point: CGPoint, at timestamp: TimeInterval) -> CGPoint {
    let x = xFilter.apply(Double(point.x), at: timestamp)
    let y = yFilter.apply(Double(point.y), at: timestamp)
    return CGPoint(x: x, y: y)
  }

  public mutating func reset() {
    xFilter.reset()
    yFilter.reset()
  }
}
