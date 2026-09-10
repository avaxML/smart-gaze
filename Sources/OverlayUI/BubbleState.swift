import Foundation
import GazeKit
import Observation

public struct PresentationHandle: Equatable, Sendable {
  fileprivate let generation: Int
}

@MainActor
@Observable
public final class BubbleState {
  public private(set) var text = ""
  public private(set) var isStreaming = false
  public private(set) var errorMessage: String?
  public private(set) var isPinned = false
  public private(set) var isExpanded = false
  public private(set) var isVisible = false

  @ObservationIgnored private var dismissal = DismissalTimer()
  @ObservationIgnored private var generation = 0

  public init() {}

  @discardableResult
  func begin() -> PresentationHandle {
    generation += 1
    text = ""
    isStreaming = true
    errorMessage = nil
    isPinned = false
    isExpanded = false
    isVisible = true
    dismissal.reset()
    return PresentationHandle(generation: generation)
  }

  @discardableResult
  func append(_ token: String, for handle: PresentationHandle) -> Bool {
    guard isStreaming, handle.generation == generation else { return false }
    text += token
    return true
  }

  @discardableResult
  func finish(for handle: PresentationHandle) -> Bool {
    guard handle.generation == generation else { return false }
    isStreaming = false
    return true
  }

  @discardableResult
  func fail(_ message: String, for handle: PresentationHandle) -> Bool {
    guard handle.generation == generation else { return false }
    errorMessage = message
    isStreaming = false
    return true
  }

  func end() {
    isVisible = false
    isStreaming = false
    dismissal.reset()
  }

  func setPinned(_ pinned: Bool) {
    guard pinned != isPinned else { return }
    isPinned = pinned
    dismissal.reset()
  }

  func togglePinned() {
    setPinned(!isPinned)
  }

  func setExpanded(_ expanded: Bool) {
    isExpanded = expanded
  }

  func updateGaze(inside: Bool, at timestamp: TimeInterval) -> Bool {
    guard isVisible, !isPinned else { return false }
    return dismissal.update(gazeInside: inside, at: timestamp)
  }
}

struct DismissalLatch {
  private var fired = false

  mutating func arm() {
    fired = false
  }

  mutating func fireOnce() -> Bool {
    guard !fired else { return false }
    fired = true
    return true
  }
}
