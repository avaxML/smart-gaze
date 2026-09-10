import Foundation

public protocol LLMProvider: Sendable {
  func explain(imageJPEG: Data, prompt: String, system: String) -> AsyncThrowingStream<
    String, Error
  >
  func testConnection(timeout: Duration) async throws
}

public enum ProviderError: Error, Equatable, Sendable {
  case missingKey
  case httpStatus(Int)
  case malformedResponse
  case remote
  case network
  case emptyCompletion
  case timedOut
  case invalidConfiguration
}

extension ProviderError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .missingKey: "No API key is stored for this provider."
    case .httpStatus(let status): "The provider returned HTTP \(status)."
    case .malformedResponse: "The provider returned a malformed response."
    case .remote: "The provider reported an error."
    case .network: "The provider could not be reached."
    case .emptyCompletion: "The provider returned no text."
    case .timedOut: "The provider did not respond in time."
    case .invalidConfiguration: "The provider configuration is invalid."
    }
  }
}

// A 1x1 JPEG kept in memory for the bounded connection probe.
let connectionTestImage = Data(
  base64Encoded:
    "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q=="
)!

extension LLMProvider {
  public func testConnection(timeout: Duration = .seconds(15)) async throws {
    let stream = explain(
      imageJPEG: connectionTestImage,
      prompt: "Reply with the single word OK.",
      system: "You are a connection test."
    )
    let probe = Task { () throws in
      for try await _ in stream { return }
      if Task.isCancelled { throw CancellationError() }
      throw ProviderError.emptyCompletion
    }
    let watchdog = Task {
      try await Task.sleep(for: timeout)
      probe.cancel()
    }
    defer {
      probe.cancel()
      watchdog.cancel()
    }
    do {
      try await withTaskCancellationHandler {
        try await probe.value
      } onCancel: {
        probe.cancel()
        watchdog.cancel()
      }
      if Task.isCancelled { throw CancellationError() }
    } catch {
      if Task.isCancelled { throw CancellationError() }
      if error is CancellationError { throw ProviderError.timedOut }
      throw error
    }
  }
}
