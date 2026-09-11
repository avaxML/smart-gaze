import Foundation
import GazeKit
import Perception
import Providers

struct TestFailure: Error {}

/// One-shot async signal. `wait()` returns immediately once `signal()` has fired,
/// so a waiter can never miss an earlier signal.
final class Signal: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func signal() {
    let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
      guard !fired else { return [] }
      fired = true
      let pending = waiters
      waiters.removeAll()
      return pending
    }
    for waiter in pending { waiter.resume() }
  }

  func wait() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let alreadyFired = lock.withLock {
        guard !fired else { return true }
        waiters.append(continuation)
        return false
      }
      if alreadyFired { continuation.resume() }
    }
  }
}

final class FakeFaceObserver: FaceObserving, @unchecked Sendable {
  let faces: AsyncStream<FaceObservation?>
  private let continuation: AsyncStream<FaceObservation?>.Continuation
  private let lock = NSLock()
  private let suspended = Signal()
  private let terminated = Signal()

  private var gate: CheckedContinuation<Void, Error>?
  private var startCountStorage = 0
  private var stopCountStorage = 0
  private var startErrorStorage: Error?
  private var suspendsStartStorage = false
  private var finishesOnStopStorage = true
  private var authorizationStatusStorage: CameraAuthorization = .authorized

  var startCount: Int { lock.withLock { startCountStorage } }
  var stopCount: Int { lock.withLock { stopCountStorage } }
  var isSuspended: Bool { lock.withLock { gate != nil } }

  var authorizationStatus: CameraAuthorization {
    get { lock.withLock { authorizationStatusStorage } }
    set { lock.withLock { authorizationStatusStorage = newValue } }
  }

  var startError: Error? {
    get { lock.withLock { startErrorStorage } }
    set { lock.withLock { startErrorStorage = newValue } }
  }

  var suspendsStart: Bool {
    get { lock.withLock { suspendsStartStorage } }
    set { lock.withLock { suspendsStartStorage = newValue } }
  }

  var finishesOnStop: Bool {
    get { lock.withLock { finishesOnStopStorage } }
    set { lock.withLock { finishesOnStopStorage = newValue } }
  }

  init() {
    var captured: AsyncStream<FaceObservation?>.Continuation!
    faces = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { captured = $0 }
    continuation = captured
    continuation.onTermination = { [terminated] _ in terminated.signal() }
  }

  func waitUntilSuspended() async { await suspended.wait() }
  func waitUntilTerminated() async { await terminated.wait() }

  func start() async throws {
    let (error, shouldSuspend) = lock.withLock { () -> (Error?, Bool) in
      startCountStorage += 1
      return (startErrorStorage, suspendsStartStorage)
    }
    if let error { throw error }
    guard shouldSuspend else { return }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      lock.withLock { gate = continuation }
      suspended.signal()
    }
  }

  func resumeStart() {
    resumeGate(throwing: nil)
  }

  func failStart(_ error: Error) {
    lock.withLock { startErrorStorage = error }
    resumeGate(throwing: error)
  }

  func emit(_ observation: FaceObservation?) {
    continuation.yield(observation)
  }

  func stop() {
    let shouldFinish = lock.withLock { () -> Bool in
      stopCountStorage += 1
      return finishesOnStopStorage
    }
    if shouldFinish { continuation.finish() }
  }

  private func resumeGate(throwing error: Error?) {
    let gate = lock.withLock { () -> CheckedContinuation<Void, Error>? in
      let pending = self.gate
      self.gate = nil
      return pending
    }
    if let error { gate?.resume(throwing: error) } else { gate?.resume() }
  }
}

final class FakeSettingsStore: SettingsStore, @unchecked Sendable {
  private let lock = NSLock()
  private var currentStorage: Settings
  private var savedCountStorage = 0
  private var saveErrorStorage: Error?

  var current: Settings {
    get { lock.withLock { currentStorage } }
    set { lock.withLock { currentStorage = newValue } }
  }

  var savedCount: Int { lock.withLock { savedCountStorage } }

  var saveError: Error? {
    get { lock.withLock { saveErrorStorage } }
    set { lock.withLock { saveErrorStorage = newValue } }
  }

  init(current: Settings = .default) {
    currentStorage = current
  }

  func load() -> Settings { lock.withLock { currentStorage } }

  func save(_ settings: Settings) throws {
    let error = lock.withLock { () -> Error? in
      if let saveErrorStorage { return saveErrorStorage }
      currentStorage = settings
      savedCountStorage += 1
      return nil
    }
    if let error { throw error }
  }
}

final class FakeSecrets: SecretStore, SecretPresence, @unchecked Sendable {
  private let lock = NSLock()
  private var storageStorage: [String: String] = [:]
  private var writeErrorStorage: Error?

  var storage: [String: String] {
    get { lock.withLock { storageStorage } }
    set { lock.withLock { storageStorage = newValue } }
  }

  var writeError: Error? {
    get { lock.withLock { writeErrorStorage } }
    set { lock.withLock { writeErrorStorage = newValue } }
  }

  func read(account: String) throws -> String? { lock.withLock { storageStorage[account] } }

  func write(_ secret: String, account: String) throws {
    let error = lock.withLock { () -> Error? in
      if let writeErrorStorage { return writeErrorStorage }
      storageStorage[account] = secret
      return nil
    }
    if let error { throw error }
  }

  func delete(account: String) throws { lock.withLock { storageStorage[account] = nil } }

  func contains(account: String) throws -> Bool { lock.withLock { storageStorage[account] != nil } }
}

final class SuspendingConnectionProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let called = Signal()
  private var gate: CheckedContinuation<Void, Error>?
  private var callsStorage = 0

  var calls: Int { lock.withLock { callsStorage } }
  var isSuspended: Bool { lock.withLock { gate != nil } }

  func test() async throws {
    lock.withLock { callsStorage += 1 }
    called.signal()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      lock.withLock { gate = continuation }
    }
  }

  func waitUntilCalled() async { await called.wait() }

  func resume() {
    let gate = lock.withLock { () -> CheckedContinuation<Void, Error>? in
      let pending = self.gate
      self.gate = nil
      return pending
    }
    gate?.resume()
  }
}
