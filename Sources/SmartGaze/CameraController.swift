import Foundation
import Perception

@MainActor
final class CameraController {
  enum State: Equatable {
    case off
    case starting
    case live
  }

  private(set) var state: State = .off
  var onChange: (() -> Void)?
  var onError: ((Error) -> Void)?
  var onObservation: ((FaceObservation?) -> Void)?

  private let makeObserver: () -> any FaceObserving
  private var observer: (any FaceObserving)?
  private var drain: Task<Void, Never>?
  private var generation = 0

  init(makeObserver: @escaping () -> any FaceObserving = { WebcamFaceObserver() }) {
    self.makeObserver = makeObserver
  }

  func start() async {
    generation += 1
    let token = generation

    stopCurrentObserver()
    update(state: .starting)

    let fresh = makeObserver()
    observer = fresh
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
    update(state: .live)
    beginDraining(fresh, token: token)
  }

  func pause() {
    generation += 1
    stopCurrentObserver()
    update(state: .off)
  }

  private func beginDraining(_ observer: any FaceObserving, token: Int) {
    drain = Task { [weak self] in
      for await observation in observer.faces {
        if Task.isCancelled { return }
        guard let self, token == self.generation else { return }
        self.onObservation?(observation)
      }
    }
  }

  private func stopCurrentObserver() {
    drain?.cancel()
    drain = nil
    observer?.stop()
    observer = nil
  }

  private func update(state newState: State) {
    guard state != newState else { return }
    state = newState
    onChange?()
  }
}
