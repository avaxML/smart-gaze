import CoreGraphics

/// The subset of `BubbleController` a coordinator needs to drive the bubble.
/// Exists so code that presents the bubble can be tested against a fake
/// that never creates a real `NSPanel`, instead of every test needing a
/// live window server connection.
@MainActor
public protocol BubblePresenting: AnyObject, Sendable {
  var onDismiss: (() -> Void)? { get set }

  @discardableResult
  func show(anchoredTo region: CGRect, within bounds: CGRect, size: CGSize) -> PresentationHandle
  func append(_ token: String, for handle: PresentationHandle)
  func finish(for handle: PresentationHandle)
  func showError(_ message: String, for handle: PresentationHandle)
  func dismiss()
}

extension BubbleController: BubblePresenting {}

/// The outline of the pending capture region. Kept separate from the bubble
/// because it is shown before any capture exists and hidden the moment one does.
@MainActor
public protocol ReticlePresenting: AnyObject, Sendable {
  func show(centredOn point: CGPoint, size: CGSize)
  func hide()
  func flash(capturedRect rect: CGRect)
}

extension ReticleController: ReticlePresenting {}
