/// A second, optional capability behind `FaceObserving`: the vertical field of view
/// of the camera actually in use, once its capture format is known.
///
/// Mirrors `FrameProviding`: a caller that needs this for `GazePipeline` casts the
/// `any FaceObserving` it already holds to `FieldOfViewProviding` and treats a failed
/// cast, or a value that has not settled yet, as "keep the default", never as a reason
/// to invent a number.
public protocol FieldOfViewProviding: Sendable {
  var verticalFieldOfViewDegrees: Double? { get }
}
