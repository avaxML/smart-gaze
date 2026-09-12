import CoreGraphics
import Foundation

/// Moves the projected gaze point to undo the share of head rotation the
/// gaze model does not cancel. Gains are in screen points per radian, fitted
/// from the calibration head sweep; the reference is the mean pose over the
/// accepted fit bursts, the pose the map is valid at.
public struct HeadRotationCorrection: Equatable, Sendable, Codable {
  public let referenceYawRadians: Double
  public let referencePitchRadians: Double
  public let yawGainPointsPerRadian: Double
  public let pitchGainPointsPerRadian: Double

  public init(
    referenceYawRadians: Double, referencePitchRadians: Double,
    yawGainPointsPerRadian: Double, pitchGainPointsPerRadian: Double
  ) {
    self.referenceYawRadians = referenceYawRadians
    self.referencePitchRadians = referencePitchRadians
    self.yawGainPointsPerRadian = yawGainPointsPerRadian
    self.pitchGainPointsPerRadian = pitchGainPointsPerRadian
  }

  /// point - (yawGain * (yaw - referenceYaw), pitchGain * (pitch - referencePitch)).
  /// Non-finite pose returns point unchanged.
  public func correct(_ point: CGPoint, yawRadians: Double, pitchRadians: Double) -> CGPoint {
    guard yawRadians.isFinite, pitchRadians.isFinite else { return point }
    let dx = yawGainPointsPerRadian * (yawRadians - referenceYawRadians)
    let dy = pitchGainPointsPerRadian * (pitchRadians - referencePitchRadians)
    return CGPoint(x: point.x - dx, y: point.y - dy)
  }
}

/// Fits the head rotation correction from a calibration sweep: the map's
/// projection of the raw gaze while the user held the centre target, paired
/// with the head pose on each frame.
public enum HeadRotationFit {
  public static let minimumYawRangeRadians = 0.15
  public static let minimumPitchRangeRadians = 0.10
  public static let maximumGainPointsPerRadian = 6000.0

  /// One sweep sample: the map's projection of the raw gaze while the user
  /// held the centre target, and the head pose on that frame.
  public struct Sample: Equatable, Sendable {
    public let projected: CGPoint
    public let yawRadians: Double
    public let pitchRadians: Double

    public init(projected: CGPoint, yawRadians: Double, pitchRadians: Double) {
      self.projected = projected
      self.yawRadians = yawRadians
      self.pitchRadians = pitchRadians
    }
  }

  /// Least-squares slope of (projected.x - target.x) on (yaw - referenceYaw)
  /// and of (projected.y - target.y) on (pitch - referencePitch). A gain is 0
  /// when that axis' pose range across the samples is below its minimum, and
  /// the fit is nil when there are fewer than 20 samples. Gains are clamped to
  /// +-maximumGainPointsPerRadian.
  public static func fit(
    samples: [Sample], target: CGPoint, referenceYawRadians: Double,
    referencePitchRadians: Double
  ) -> HeadRotationCorrection? {
    guard samples.count >= 20 else { return nil }
    let yawGain = slope(
      points: samples.map {
        (x: $0.yawRadians - referenceYawRadians, y: Double($0.projected.x - target.x))
      },
      range: poseRange(samples.map(\.yawRadians)), minimum: minimumYawRangeRadians)
    let pitchGain = slope(
      points: samples.map {
        (x: $0.pitchRadians - referencePitchRadians, y: Double($0.projected.y - target.y))
      },
      range: poseRange(samples.map(\.pitchRadians)), minimum: minimumPitchRangeRadians)
    return HeadRotationCorrection(
      referenceYawRadians: referenceYawRadians, referencePitchRadians: referencePitchRadians,
      yawGainPointsPerRadian: yawGain, pitchGainPointsPerRadian: pitchGain)
  }

  /// The pose ranges of a sample array, for the sweep ring.
  public static func sweepCoverage(_ samples: [Sample]) -> (yaw: Double, pitch: Double) {
    (yaw: poseRange(samples.map(\.yawRadians)), pitch: poseRange(samples.map(\.pitchRadians)))
  }

  private static func poseRange(_ values: [Double]) -> Double {
    guard let low = values.min(), let high = values.max() else { return 0 }
    return high - low
  }

  private static func slope(points: [(x: Double, y: Double)], range: Double, minimum: Double)
    -> Double
  {
    guard range >= minimum else { return 0 }
    let count = Double(points.count)
    let meanX = points.map(\.x).reduce(0, +) / count
    let meanY = points.map(\.y).reduce(0, +) / count
    var covariance = 0.0
    var variance = 0.0
    for point in points {
      let dx = point.x - meanX
      covariance += dx * (point.y - meanY)
      variance += dx * dx
    }
    guard covariance.isFinite, variance.isFinite, variance > 0 else { return 0 }
    let gain = covariance / variance
    guard gain.isFinite else { return 0 }
    return min(max(gain, -maximumGainPointsPerRadian), maximumGainPointsPerRadian)
  }
}
