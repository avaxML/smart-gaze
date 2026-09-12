/// A second, optional capability behind `FaceObserving`: the capture device's
/// stable identifier and human-readable name, used to key a stored focal
/// length to the camera it was measured on.
///
/// Mirrors `FrameProviding` and `FocalLengthProviding`: a caller casts the
/// `any FaceObserving` it already holds and treats a failed cast or a `nil`
/// field as "this camera cannot be identified", never as a reason to invent
/// an identifier.
public protocol CameraIdentityProviding: Sendable {
  /// `AVCaptureDevice.uniqueID`.
  var cameraID: String? { get }
  /// `AVCaptureDevice.localizedName`.
  var cameraName: String? { get }
}
