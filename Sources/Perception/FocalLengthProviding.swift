/// A second, optional capability behind `FaceObserving`: the camera's real
/// vertical focal length in pixels, read from the capture buffer's own
/// intrinsic matrix attachment when macOS delivers one.
///
/// Mirrors `FrameProviding`: a caller that needs this for `GazePipeline` casts the
/// `any FaceObserving` it already holds to `FocalLengthProviding` and treats a failed
/// cast, or a value that has not settled yet, as "keep the default", never as a reason
/// to invent a number.
public protocol FocalLengthProviding: Sendable {
  var verticalFocalLengthPixels: Double? { get }
}
