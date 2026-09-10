import CoreGraphics
import Foundation

public struct EyeLandmarks: Equatable, Sendable {
  public let points: [CGPoint]

  public init?(points: [CGPoint]) {
    guard points.count == 6 else { return nil }
    self.points = points
  }
}

public func eyeAspectRatio(_ eye: EyeLandmarks) -> Double {
  let p = eye.points
  let horizontal = distance(p[0], p[3])
  guard horizontal != 0 else { return 0 }
  let vertical = distance(p[1], p[5]) + distance(p[2], p[4])
  return vertical / (2 * horizontal)
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
  let dx = Double(a.x - b.x)
  let dy = Double(a.y - b.y)
  return (dx * dx + dy * dy).squareRoot()
}

public enum BlinkEvent: Equatable, Sendable {
  case blink
  case doubleBlink
}

public struct BlinkDetector: Sendable {
  private let closedThreshold: Double
  private let minFrames: Int
  private let doubleBlinkWindow: TimeInterval
  private var closedRun = 0
  private var blinkTimestamps: [TimeInterval] = []

  public init(
    closedThreshold: Double = 0.21, minFrames: Int = 2, doubleBlinkWindow: TimeInterval = 0.6
  ) {
    self.closedThreshold = closedThreshold
    self.minFrames = minFrames
    self.doubleBlinkWindow = doubleBlinkWindow
  }

  public mutating func add(left: Double, right: Double, at timestamp: TimeInterval) -> BlinkEvent? {
    blinkTimestamps.removeAll { timestamp - $0 > 60 }

    let average = (left + right) / 2
    guard average < closedThreshold else {
      let endedRun = closedRun
      closedRun = 0
      // Short closures are blinks mid-transition, not sustained closure.
      guard endedRun >= minFrames else { return nil }
      let isDouble = blinkTimestamps.last.map { timestamp - $0 <= doubleBlinkWindow } ?? false
      blinkTimestamps.append(timestamp)
      return isDouble ? .doubleBlink : .blink
    }

    closedRun += 1
    return nil
  }

  public var blinkRate: Double {
    Double(blinkTimestamps.count) * (60.0 / 60.0)
  }

  public mutating func reset() {
    closedRun = 0
    blinkTimestamps.removeAll()
  }
}
