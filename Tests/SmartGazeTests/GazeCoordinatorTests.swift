import CoreGraphics
import Foundation
import GazeKit
import OverlayUI
import Perception
import Providers
import ScreenCapture
import Testing

@testable import SmartGaze

private final class RecordedRequests: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [CaptureRequest] = []
  var all: [CaptureRequest] { lock.withLock { storage } }
  func record(_ request: CaptureRequest) { lock.withLock { storage.append(request) } }
}

private struct FakeCapturer: RegionCapturing {
  let onCapture: @Sendable () async throws -> CapturedRegion
  let recorded = RecordedRequests()

  func capture(_ request: CaptureRequest) async throws -> CapturedRegion {
    recorded.record(request)
    return try await onCapture()
  }
}

@MainActor
private final class FakeBubble: BubblePresenting {
  var onDismiss: (() -> Void)?
  private(set) var shownCount = 0
  private(set) var shownSizes: [CGSize] = []
  private(set) var appendedTokens: [String] = []
  private(set) var errorMessage: String?
  private(set) var finishedCount = 0
  private var nextGeneration = 0

  @discardableResult
  func show(anchoredTo region: CGRect, within bounds: CGRect, size: CGSize) -> PresentationHandle {
    shownCount += 1
    shownSizes.append(size)
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

private func openEye() -> EyeLandmarks {
  EyeLandmarks(points: [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 2, y: 3),
    CGPoint(x: 8, y: 3),
    CGPoint(x: 10, y: 0),
    CGPoint(x: 8, y: -3),
    CGPoint(x: 2, y: -3),
  ])!
}

private func closedEye() -> EyeLandmarks {
  EyeLandmarks(points: [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 2, y: 0.2),
    CGPoint(x: 8, y: 0.2),
    CGPoint(x: 10, y: 0),
    CGPoint(x: 8, y: -0.2),
    CGPoint(x: 2, y: -0.2),
  ])!
}

private func faceObservation(eyesClosed: Bool, at timestamp: TimeInterval) -> FaceObservation {
  let eye = eyesClosed ? closedEye() : openEye()
  return FaceObservation(
    boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
    yaw: 0, pitch: 0, roll: 0,
    leftEye: eye, rightEye: eye,
    leftPupil: .zero, rightPupil: .zero,
    timestamp: timestamp)
}

/// Reproduces the exact defect in issue #87: nothing upstream of
/// `TriggerMachine` ever produced a `.blink` input, so `doubleBlink` was
/// selectable and permanently inert. This drives the real chain, a sequence
/// of `FaceObservation`s through `GazeCoordinator.handleObservation`, into a
/// `BlinkDetector` it owns, and confirms the resulting event reaches the
/// trigger machine and fires a capture.
@MainActor
@Test func doubleBlinkFromFaceObservationsReachesTheTriggerMachine() async {
  let started = Signal()
  let capturer = FakeCapturer {
    started.signal()
    return CapturedRegion(jpeg: oneByOneJPEG(), rect: .zero, displayID: CGMainDisplayID())
  }

  var settings = Settings.default
  settings.activationMode = .doubleBlink

  let bubble = FakeBubble()
  let coordinator = GazeCoordinator(
    settings: settings,
    gazePipeline: nil,
    capturer: capturer,
    bubble: bubble,
    makeExplanationStream: { _ in nil })

  await coordinator.handleGazeSample(CGPoint(x: 100, y: 100), at: 0.0)

  // First blink: closed for two frames, then open.
  await coordinator.handleObservation(faceObservation(eyesClosed: false, at: 0.0), at: 0.0)
  await coordinator.handleObservation(faceObservation(eyesClosed: true, at: 0.1), at: 0.1)
  await coordinator.handleObservation(faceObservation(eyesClosed: true, at: 0.2), at: 0.2)
  await coordinator.handleObservation(faceObservation(eyesClosed: false, at: 0.3), at: 0.3)

  // Second blink inside the double-blink window: this is the input that
  // reaches `TriggerMachine` as `.blink(.doubleBlink, _)`.
  await coordinator.handleObservation(faceObservation(eyesClosed: true, at: 0.4), at: 0.4)
  await coordinator.handleObservation(faceObservation(eyesClosed: true, at: 0.5), at: 0.5)
  await coordinator.handleObservation(faceObservation(eyesClosed: false, at: 0.55), at: 0.55)

  await started.wait()
  await coordinator.waitUntilCaptureSettled()

  #expect(bubble.shownCount == 1)
  #expect(bubble.errorMessage == "No provider is configured. Add an API key in Settings.")
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  func increment() { lock.withLock { storage += 1 } }
  var value: Int { lock.withLock { storage } }
}

@MainActor
@Test func theConfiguredBubbleSizeReachesThePresentation() async {
  var settings = Settings.default
  settings.bubbleWidth = 512
  settings.bubbleMaxHeight = 300

  let bubble = FakeBubble()
  let coordinator = GazeCoordinator(
    settings: settings,
    gazePipeline: nil,
    capturer: FakeCapturer {
      CapturedRegion(jpeg: oneByOneJPEG(), rect: .zero, displayID: CGMainDisplayID())
    },
    bubble: bubble,
    makeExplanationStream: { _ in nil })
  await coordinator.start()

  await coordinator.apply([.capture(at: CGPoint(x: 5, y: 5))])
  await coordinator.waitUntilCaptureSettled()

  #expect(bubble.shownSizes.first?.width == 512)
  #expect(bubble.shownSizes.first?.height == 300)
}

@MainActor
@Test func theCaptureRequestIsSizedAsConfigured() async {
  let capturer = FakeCapturer {
    CapturedRegion(jpeg: oneByOneJPEG(), rect: .zero, displayID: CGMainDisplayID())
  }
  let coordinator = GazeCoordinator(
    settings: .default,
    gazePipeline: nil,
    capturer: capturer,
    bubble: FakeBubble(),
    captureSize: CGSize(width: 600, height: 400),
    makeExplanationStream: { _ in nil })
  await coordinator.start()

  await coordinator.apply([.capture(at: CGPoint(x: 100, y: 100))])
  await coordinator.waitUntilCaptureSettled()

  guard let request = capturer.recorded.all.first else {
    Issue.record("expected a capture request")
    return
  }
  #expect(request.size == CGSize(width: 600, height: 400))
}

@Test func aPointOnAnOffsetDisplayMapsIntoThatDisplaysOwnCoordinates() {
  let builtIn = (id: CGDirectDisplayID(1), bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117))
  let external = (
    id: CGDirectDisplayID(2), bounds: CGRect(x: -1920, y: 219, width: 1920, height: 1080)
  )

  let result = GazeCoordinator.displayLocalPoint(
    for: CGPoint(x: -960, y: 759), displays: [builtIn, external], fallback: builtIn)

  #expect(result.displayID == 2)
  #expect(result.localPoint == CGPoint(x: 960, y: 540))
}

@Test func aPointOnTheBuiltInDisplayKeepsItsCoordinates() {
  let builtIn = (id: CGDirectDisplayID(1), bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117))
  let external = (
    id: CGDirectDisplayID(2), bounds: CGRect(x: -1920, y: 219, width: 1920, height: 1080)
  )

  let result = GazeCoordinator.displayLocalPoint(
    for: CGPoint(x: 864, y: 558), displays: [builtIn, external], fallback: builtIn)

  #expect(result.displayID == 1)
  #expect(result.localPoint == CGPoint(x: 864, y: 558))
}

@Test func aPointOnNoDisplayClampsIntoTheFallback() {
  let builtIn = (id: CGDirectDisplayID(1), bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117))

  let result = GazeCoordinator.displayLocalPoint(
    for: CGPoint(x: 9999, y: -9999), displays: [builtIn], fallback: builtIn)

  #expect(result.displayID == 1)
  #expect(result.localPoint == CGPoint(x: 1728, y: 0))
}
