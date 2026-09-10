import CoreGraphics
import Foundation
import GazeKit

public struct FaceObservation: Equatable, Sendable {
  public let boundingBox: CGRect
  public let yaw: Double
  public let pitch: Double
  public let roll: Double
  public let leftEye: EyeLandmarks
  public let rightEye: EyeLandmarks
  public let leftPupil: CGPoint
  public let rightPupil: CGPoint
  public let timestamp: TimeInterval

  public init(
    boundingBox: CGRect,
    yaw: Double,
    pitch: Double,
    roll: Double,
    leftEye: EyeLandmarks,
    rightEye: EyeLandmarks,
    leftPupil: CGPoint,
    rightPupil: CGPoint,
    timestamp: TimeInterval
  ) {
    self.boundingBox = boundingBox
    self.yaw = yaw
    self.pitch = pitch
    self.roll = roll
    self.leftEye = leftEye
    self.rightEye = rightEye
    self.leftPupil = leftPupil
    self.rightPupil = rightPupil
    self.timestamp = timestamp
  }
}

public protocol FaceObserving: Sendable {
  var faces: AsyncStream<FaceObservation?> { get }
  func start() async throws
  func stop()
}
