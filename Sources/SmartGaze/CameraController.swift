import CoreVideo
import Foundation
import Perception

@MainActor
final class CameraController {
  enum State: Equatable {
    case off
    case waitingForPermission
    case permissionDenied
    case starting
    case timedOut
    case live
  }

  /// How long `.starting` may run with no frame before it reports itself as
  /// stuck instead of waiting silently. Chosen well above the sub-second
  /// time a healthy session needs to deliver its first frame, but short
  /// enough that a new user sees feedback within the time they would
  /// otherwise spend wondering whether the app is broken.
  static let startupTimeout: Duration = .seconds(5)

  private(set) var state: State = .off
  var onChange: (() -> Void)?
  var onError: ((Error) -> Void)?
  var onObservation: ((FaceObservation?) -> Void)?
  var onFrame: ((CameraFrame) -> Void)?
  var onFocalLength: ((Double?) -> Void)?

  private let makeObserver: () -> any FaceObserving
  private let sleep: @Sendable (Duration) async throws -> Void
  private var observer: (any FaceObserving)?
  private var drain: Task<Void, Never>?
  private var frameDrain: Task<Void, Never>?
  private var timeoutTask: Task<Void, Never>?
  private var generation = 0
  private var focalLengthReported = false

  /// The active camera's stable identifier and name, once an observer has been
  /// created. `nil` before the first `start()`, or when the observer cannot
  /// identify its device.
  var cameraID: String? { (observer as? any CameraIdentityProviding)?.cameraID }
  var cameraName: String? { (observer as? any CameraIdentityProviding)?.cameraName }

  init(
    makeObserver: @escaping () -> any FaceObserving = { WebcamFaceObserver() },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.makeObserver = makeObserver
    self.sleep = sleep
  }

  func start() async {
    generation += 1
    let token = generation
    focalLengthReported = false

    stopCurrentObserver()

    let fresh = makeObserver()
    observer = fresh

    switch fresh.authorizationStatus {
    case .denied:
      observer = nil
      update(state: .permissionDenied)
      return
    case .notDetermined:
      update(state: .waitingForPermission)
    case .authorized:
      update(state: .starting)
    }

    do {
      try await fresh.start()
    } catch {
      if token == generation {
        observer = nil
        update(state: .off)
        onError?(error)
      }
      return
    }

    guard token == generation else {
      fresh.stop()
      return
    }
    update(state: .starting)
    beginDraining(fresh, token: token)
    scheduleStartupTimeout(token: token)
  }

  func pause() {
    generation += 1
    stopCurrentObserver()
    update(state: .off)
  }

  private func beginDraining(_ observer: any FaceObserving, token: Int) {
    var sawFirstObservation = false
    drain = Task { [weak self] in
      for await observation in observer.faces {
        if Task.isCancelled { return }
        guard let self, token == self.generation else { return }
        if !sawFirstObservation {
          sawFirstObservation = true
          self.reportLive(token: token)
        }
        self.onObservation?(observation)
      }
    }

    // Not every `FaceObserving` conformer can also hand out raw frames (a
    // test double built only for landmark behavior, for instance). A failed
    // cast means no gaze samples run this session, never a fabricated one.
    guard let frameSource = observer as? any FrameProviding else { return }
    frameDrain = Task { [weak self] in
      for await frame in frameSource.frames {
        if Task.isCancelled { return }
        guard let self, token == self.generation else { return }
        self.reportFocalLengthOnce()
        self.onFrame?(frame)
      }
    }
  }

  /// The intrinsic matrix, if the camera attaches one, only arrives with a
  /// frame, so this cannot run at `start()` time like the rest of session
  /// setup. Reports exactly once per session, present or absent, since the
  /// answer does not change frame to frame for a fixed capture format.
  private func reportFocalLengthOnce() {
    guard !focalLengthReported, let provider = observer as? any FocalLengthProviding else {
      return
    }
    focalLengthReported = true
    onFocalLength?(provider.verticalFocalLengthPixels)
  }

  /// A face-observation arriving proves the session is actually delivering
  /// frames, whatever state `.starting` last landed in (including
  /// `.timedOut`), so the controller self-heals here rather than staying
  /// stuck on a bad first impression.
  private func reportLive(token: Int) {
    guard token == generation, state != .live else { return }
    timeoutTask?.cancel()
    timeoutTask = nil
    update(state: .live)
  }

  private func scheduleStartupTimeout(token: Int) {
    timeoutTask = Task { [weak self] in
      guard let self else { return }
      try? await self.sleep(CameraController.startupTimeout)
      guard !Task.isCancelled else { return }
      guard token == self.generation, self.state == .starting else { return }
      self.update(state: .timedOut)
    }
  }

  private func stopCurrentObserver() {
    drain?.cancel()
    drain = nil
    frameDrain?.cancel()
    frameDrain = nil
    timeoutTask?.cancel()
    timeoutTask = nil
    observer?.stop()
    observer = nil
  }

  private func update(state newState: State) {
    guard state != newState else { return }
    state = newState
    onChange?()
  }
}
