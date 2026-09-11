import CoreVideo

/// A camera frame moved across isolation domains.
///
/// `CVPixelBuffer` has no `Sendable` conformance in the SDK. Declaring one
/// retroactively would impose it on every module that imports this one and
/// would collide if the SDK ever adds its own, so the unchecked assertion is
/// confined to this type instead. It holds because a yielded frame is never
/// mutated again: the camera delegate starts no further writes once it hands
/// the buffer over, and every consumer reads pixel data under its own lock.
public struct CameraFrame: @unchecked Sendable {
  public let pixelBuffer: CVPixelBuffer

  public init(pixelBuffer: CVPixelBuffer) {
    self.pixelBuffer = pixelBuffer
  }
}

/// A second, optional stream of the raw camera frames behind `FaceObserving`.
///
/// `FaceObserving` stays a pure landmark feed so every existing conformer
/// (including test doubles) keeps working unchanged. A concrete observer that
/// can also hand out the frame it derived those landmarks from additionally
/// conforms to this protocol; a caller that needs `GazePipeline` input casts
/// the `any FaceObserving` it already holds to `FrameProviding` and treats a
/// failed cast as "no frame source", never as a reason to invent one.
public protocol FrameProviding: Sendable {
  var frames: AsyncStream<CameraFrame> { get }
}
