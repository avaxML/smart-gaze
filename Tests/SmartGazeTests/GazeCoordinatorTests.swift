import CoreGraphics
import Foundation
import GazeKit
import OverlayUI
import Providers
import ScreenCapture
import Testing

@testable import SmartGaze

private struct FakeCapturer: RegionCapturing {
  let onCapture: @Sendable () async throws -> CapturedRegion

  func capture(_ request: CaptureRequest) async throws -> CapturedRegion {
    try await onCapture()
  }
}

@MainActor
private final class FakeBubble: BubblePresenting {
  var onDismiss: (() -> Void)?
  private(set) var shownCount = 0
  private(set) var appendedTokens: [String] = []
  private(set) var errorMessage: String?
  private(set) var finishedCount = 0
  private var nextGeneration = 0

  @discardableResult
  func show(anchoredTo region: CGRect, within bounds: CGRect, size: CGSize) -> PresentationHandle {
    shownCount += 1
    nextGeneration += 1
    return PresentationHandle.forTesting(generation: nextGeneration)
  }

  func append(_ token: String, for handle: PresentationHandle) {
    appendedTokens.append(token)
  }

  func finish(for handle: PresentationHandle) {
    finishedCount += 1
  }

  func showError(_ message: String, for handle: PresentationHandle) {
    errorMessage = message
  }

  func dismiss() {
    onDismiss?()
  }
}

private func oneByOneJPEG() -> Data {
  Data([0xFF, 0xD8, 0xFF, 0xD9])
}

@MainActor
@Test func aSecondCaptureWhileOneIsInFlightIsSuppressed() async {
  let started = Signal()
  let release = Signal()
  let captureCalls = Counter()

  let capturer = FakeCapturer {
    captureCalls.increment()
    started.signal()
    await release.wait()
    return CapturedRegion(jpeg: oneByOneJPEG(), rect: .zero, displayID: CGMainDisplayID())
  }

  let coordinator = GazeCoordinator(
    settings: .default,
    gazePipeline: nil,
    capturer: capturer,
    bubble: FakeBubble(),
    makeExplanationStream: { _ in nil })

  await coordinator.apply([.capture(at: CGPoint(x: 10, y: 10))])
  await started.wait()

  await coordinator.apply([.capture(at: CGPoint(x: 20, y: 20))])
  #expect(captureCalls.value == 1)

  release.signal()
  await coordinator.waitUntilCaptureSettled()
}

@MainActor
@Test func dismissingTheBubbleCancelsTheInFlightRequestAndIsCounted() async {
  let started = Signal()
  let cancelledInsideStream = Counter()

  let capturer = FakeCapturer {
    started.signal()
    return CapturedRegion(jpeg: oneByOneJPEG(), rect: .zero, displayID: CGMainDisplayID())
  }

  let bubble = FakeBubble()
  let coordinator = GazeCoordinator(
    settings: .default,
    gazePipeline: nil,
    capturer: capturer,
    bubble: bubble,
    makeExplanationStream: { _ in
      AsyncThrowingStream { continuation in
        let task = Task {
          do {
            for index in 0..<50 {
              try await Task.sleep(for: .milliseconds(20))
              continuation.yield("token\(index)")
            }
            continuation.finish()
          } catch is CancellationError {
            cancelledInsideStream.increment()
            continuation.finish(throwing: CancellationError())
          } catch {
            continuation.finish(throwing: error)
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    })
  await coordinator.start()

  await coordinator.apply([.capture(at: CGPoint(x: 5, y: 5))])
  await started.wait()
  try? await Task.sleep(for: .milliseconds(50))

  bubble.dismiss()
  await coordinator.waitUntilCaptureSettled()

  #expect(await coordinator.cancelledCaptureCount == 1)
  #expect(await coordinator.completedCaptureCount == 0)
  #expect(cancelledInsideStream.value == 1)
  #expect(bubble.finishedCount == 0)
}

@MainActor
@Test func aProviderErrorSurfacesAsReadableTextOnTheBubble() async {
  let bubble = FakeBubble()
  let coordinator = GazeCoordinator(
    settings: .default,
    gazePipeline: nil,
    capturer: FakeCapturer {
      CapturedRegion(jpeg: oneByOneJPEG(), rect: .zero, displayID: CGMainDisplayID())
    },
    bubble: bubble,
    makeExplanationStream: { _ in
      AsyncThrowingStream { continuation in
        continuation.finish(throwing: ProviderError.httpStatus(500))
      }
    })

  await coordinator.apply([.capture(at: CGPoint(x: 5, y: 5))])
  await coordinator.waitUntilCaptureSettled()

  #expect(bubble.errorMessage == "The provider returned HTTP 500.")
  #expect(await coordinator.providerErrorCount == 1)
}

@MainActor
@Test func aSuccessfulExplanationStreamsTokensAndFinishes() async {
  let bubble = FakeBubble()
  let coordinator = GazeCoordinator(
    settings: .default,
    gazePipeline: nil,
    capturer: FakeCapturer {
      CapturedRegion(jpeg: oneByOneJPEG(), rect: .zero, displayID: CGMainDisplayID())
    },
    bubble: bubble,
    makeExplanationStream: { _ in
      AsyncThrowingStream { continuation in
        continuation.yield("Hello")
        continuation.yield(", world.")
        continuation.finish()
      }
    })

  await coordinator.apply([.capture(at: CGPoint(x: 5, y: 5))])
  await coordinator.waitUntilCaptureSettled()

  #expect(bubble.appendedTokens == ["Hello", ", world."])
  #expect(bubble.finishedCount == 1)
  #expect(await coordinator.completedCaptureCount == 1)
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  func increment() { lock.withLock { storage += 1 } }
  var value: Int { lock.withLock { storage } }
}
