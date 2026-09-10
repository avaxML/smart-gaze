import CoreGraphics
import Foundation

public struct Fixation: Equatable, Sendable {
  public let centroid: CGPoint
  public let startedAt: TimeInterval
  public let duration: TimeInterval
  public let sampleCount: Int
}

public struct FixationDetector: Sendable {
  private struct Sample: Sendable {
    let point: CGPoint
    let timestamp: TimeInterval
  }

  private let window: TimeInterval
  private let dispersionThreshold: Double
  private var buffer: [Sample] = []
  private var isLatched = false

  public init(window: TimeInterval = 1.2, dispersionThreshold: Double = 160) {
    self.window = window
    self.dispersionThreshold = dispersionThreshold
  }

  public mutating func add(_ point: CGPoint, at timestamp: TimeInterval) -> Fixation? {
    if let last = buffer.last, timestamp <= last.timestamp {
      return nil
    }

    if let last = buffer.last, timestamp - last.timestamp > window {
      reset()
    }

    buffer.append(Sample(point: point, timestamp: timestamp))

    let cutoff = timestamp - window
    var straddler: Sample?
    while let first = buffer.first, first.timestamp < cutoff {
      straddler = buffer.removeFirst()
    }

    if let straddler, let firstKept = buffer.first,
      firstKept.timestamp > cutoff,
      firstKept.timestamp - straddler.timestamp <= window
    {
      buffer.insert(straddler, at: 0)
    }

    let dispersion = currentDispersion

    // The latch yields one fixation per settling: gaze must leave the cluster
    // and break the threshold before another fixation can be reported.
    if isLatched {
      if dispersion >= dispersionThreshold {
        isLatched = false
      } else {
        return nil
      }
    }

    guard buffer.count >= 2,
      let oldest = buffer.first,
      let newest = buffer.last,
      newest.timestamp - oldest.timestamp >= window,
      dispersion < dispersionThreshold
    else {
      return nil
    }

    isLatched = true
    return Fixation(
      centroid: centroid(),
      startedAt: oldest.timestamp,
      duration: newest.timestamp - oldest.timestamp,
      sampleCount: buffer.count
    )
  }

  public mutating func reset() {
    buffer.removeAll()
    isLatched = false
  }

  public var currentDispersion: Double {
    guard buffer.count >= 2 else { return 0 }

    var minX = buffer[0].point.x
    var maxX = buffer[0].point.x
    var minY = buffer[0].point.y
    var maxY = buffer[0].point.y

    for sample in buffer.dropFirst() {
      minX = min(minX, sample.point.x)
      maxX = max(maxX, sample.point.x)
      minY = min(minY, sample.point.y)
      maxY = max(maxY, sample.point.y)
    }

    return Double((maxX - minX) + (maxY - minY))
  }

  public var sampleCount: Int {
    buffer.count
  }

  private func centroid() -> CGPoint {
    var sumX: CGFloat = 0
    var sumY: CGFloat = 0

    for sample in buffer {
      sumX += sample.point.x
      sumY += sample.point.y
    }

    let count = CGFloat(buffer.count)
    return CGPoint(x: sumX / count, y: sumY / count)
  }
}
