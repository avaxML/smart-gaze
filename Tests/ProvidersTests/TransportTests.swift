import CoreGraphics
import Foundation
import GazeKit
import ImageIO
import Testing

@testable import Providers

private final class Fixture: @unchecked Sendable {
  enum Ending { case finish, holdOpen }

  let status: Int
  let headers: [String: String]
  let chunks: [Data]
  let gated: Bool
  let ending: Ending
  let redirectLocation: String?

  private let lock = NSLock()
  private var storedRequest: URLRequest?
  private var storedStop = false

  let requestReceived = DispatchSemaphore(value: 0)
  let sendNextChunk = DispatchSemaphore(value: 0)
  let stopped = DispatchSemaphore(value: 0)
  let holdRelease = DispatchSemaphore(value: 0)

  init(
    status: Int = 200,
    headers: [String: String] = ["Content-Type": "text/event-stream"],
    chunks: [Data] = [],
    gated: Bool = false,
    ending: Ending = .finish,
    redirectLocation: String? = nil
  ) {
    self.status = status
    self.headers = headers
    self.chunks = chunks
    self.gated = gated
    self.ending = ending
    self.redirectLocation = redirectLocation
  }

  func record(_ request: URLRequest) {
    lock.lock()
    storedRequest = request
    lock.unlock()
    requestReceived.signal()
  }

  var capturedRequest: URLRequest? {
    lock.lock()
    defer { lock.unlock() }
    return storedRequest
  }

  func markStopped() {
    lock.lock()
    storedStop = true
    lock.unlock()
    stopped.signal()
    holdRelease.signal()
    sendNextChunk.signal()
  }

  var wasStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return storedStop
  }
}

private final class FixtureRegistry: @unchecked Sendable {
  static let shared = FixtureRegistry()
  private let lock = NSLock()
  private var fixtures: [String: Fixture] = [:]

  func register(_ fixture: Fixture, host: String) {
    lock.lock()
    fixtures[host] = fixture
    lock.unlock()
  }

  func fixture(for host: String) -> Fixture? {
    lock.lock()
    defer { lock.unlock() }
    return fixtures[host]
  }

  func reset() {
    lock.lock()
    fixtures.removeAll()
    lock.unlock()
  }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
  private var fixture: Fixture?
  private var worker: DispatchWorkItem?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let host = request.url?.host, let fixture = FixtureRegistry.shared.fixture(for: host)
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    self.fixture = fixture
    fixture.record(request)
    let work = DispatchWorkItem { [weak self] in self?.run(fixture) }
    worker = work
    DispatchQueue.global().async(execute: work)
  }

  override func stopLoading() {
    worker?.cancel()
    fixture?.markStopped()
  }

  private func run(_ fixture: Fixture) {
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: fixture.status,
        httpVersion: "HTTP/1.1",
        headerFields: fixture.headers
      )
    else { return }
    if let location = fixture.redirectLocation, let target = URL(string: location) {
      var redirected = request
      redirected.url = target
      client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    for (index, chunk) in fixture.chunks.enumerated() {
      if fixture.gated && index > 0 { fixture.sendNextChunk.wait() }
      if worker?.isCancelled == true { return }
      client?.urlProtocol(self, didLoad: chunk)
    }
    switch fixture.ending {
    case .finish:
      client?.urlProtocolDidFinishLoading(self)
    case .holdOpen:
      fixture.holdRelease.wait()
    }
  }
}

private struct FakeSecrets: SecretStore {
  let value: String?
  func read(account: String) throws -> String? { value }
  func write(_ secret: String, account: String) throws {}
  func delete(account: String) throws {}
}

private func fixtureSession() -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [FixtureURLProtocol.self]
  configuration.urlCache = nil
  return URLSession(configuration: configuration)
}

private func makeProvider(
  kind: ProviderKind,
  host: String,
  path: String,
  model: String = "m",
  key: String? = "test-secret"
) -> HTTPProvider {
  let settings = ProviderSettings(
    model: model,
    baseURL: URL(string: "https://\(host)\(path)")!,
    keychainAccount: .openAIKey
  )
  return HTTPProvider(
    kind: kind,
    settings: settings,
    secrets: FakeSecrets(value: key),
    session: fixtureSession()
  )
}

private func sse(_ json: String) -> Data { Data(("data: " + json + "\n\n").utf8) }

private func wait(_ semaphore: DispatchSemaphore, timeout: DispatchTime) async -> Bool {
  await withCheckedContinuation { continuation in
    DispatchQueue.global().async {
      continuation.resume(returning: semaphore.wait(timeout: timeout) == .success)
    }
  }
}

private func withDeadline<T: Sendable>(
  seconds: Double,
  _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw ProviderError.timedOut
    }
    guard let result = try await group.next() else { throw ProviderError.timedOut }
    group.cancelAll()
    return result
  }
}

private actor ResumeOnce {
  private var claimed = false
  func claim() -> Bool {
    if claimed { return false }
    claimed = true
    return true
  }
}

private func boundedResult<T: Sendable>(
  of task: Task<T, Error>,
  seconds: Double
) async -> Result<T, Error>? {
  let gate = ResumeOnce()
  return await withCheckedContinuation { continuation in
    Task {
      let result = await task.result
      if await gate.claim() { continuation.resume(returning: result) }
    }
    Task {
      try? await Task.sleep(for: .seconds(seconds))
      if await gate.claim() { continuation.resume(returning: nil) }
    }
  }
}

private func collect(
  _ provider: HTTPProvider, timeout: Double = 5
) async throws -> [String] {
  try await withDeadline(seconds: timeout) {
    var values: [String] = []
    for try await delta in provider.explain(
      imageJPEG: Data([0xFF, 0xD8]), prompt: "P", system: "S")
    {
      values.append(delta)
    }
    return values
  }
}

@Suite(.serialized)
struct ProviderTransportTests {
  init() { FixtureRegistry.shared.reset() }

  @Test func streamsChunksIncrementallyBeforeEOF() async throws {
    let host = "stream.test"
    let first = Data("data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n".utf8)
    let second = Data("data: {\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\n".utf8)
    let fixture = Fixture(chunks: [first, second], gated: true)
    FixtureRegistry.shared.register(fixture, host: host)
    let provider = makeProvider(kind: .openai, host: host, path: "/v1")

    let values = try await withDeadline(seconds: 5) {
      var out: [String] = []
      for try await delta in provider.explain(
        imageJPEG: Data([0xFF, 0xD8]), prompt: "P", system: "S")
      {
        out.append(delta)
        if out.count == 1 { fixture.sendNextChunk.signal() }
      }
      return out
    }
    #expect(values == ["Hello", " world"])
  }

  @Test func googleRequestShape() async throws {
    let host = "google.test"
    FixtureRegistry.shared.register(
      Fixture(chunks: [sse("{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"ok\"}]}}]}")]),
      host: host
    )
    let provider = makeProvider(
      kind: .google, host: host, path: "/v1beta", model: "gemini-2.5-flash")
    _ = try await collect(provider)

    let request = try #require(FixtureRegistry.shared.fixture(for: host)?.capturedRequest)
    #expect(
      request.url?.absoluteString
        == "https://\(host)/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse"
    )
    #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-secret")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.url?.query?.contains("key=") == false)
  }

  @Test func openAIRequestShape() async throws {
    let host = "openai.test"
    FixtureRegistry.shared.register(
      Fixture(chunks: [sse("{\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}")]),
      host: host
    )
    let provider = makeProvider(kind: .openai, host: host, path: "/v1")
    _ = try await collect(provider)

    let request = try #require(FixtureRegistry.shared.fixture(for: host)?.capturedRequest)
    #expect(request.url?.absoluteString == "https://\(host)/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
  }

  @Test func anthropicRequestShape() async throws {
    let host = "anthropic.test"
    FixtureRegistry.shared.register(
      Fixture(chunks: [sse("{\"type\":\"content_block_delta\",\"delta\":{\"text\":\"ok\"}}")]),
      host: host
    )
    let provider = makeProvider(kind: .anthropic, host: host, path: "/v1")
    _ = try await collect(provider)

    let request = try #require(FixtureRegistry.shared.fixture(for: host)?.capturedRequest)
    #expect(request.url?.absoluteString == "https://\(host)/v1/messages")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-secret")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
  }

  @Test func openCodeGoRequestShape() async throws {
    let host = "opencode.test"
    FixtureRegistry.shared.register(
      Fixture(chunks: [sse("{\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}")]),
      host: host
    )
    let provider = makeProvider(kind: .opencode, host: host, path: "/zen/go/v1")
    _ = try await collect(provider)

    let request = try #require(FixtureRegistry.shared.fixture(for: host)?.capturedRequest)
    #expect(request.url?.absoluteString == "https://\(host)/zen/go/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
  }

  @Test func proxyRequestShape() async throws {
    let host = "proxy.test"
    FixtureRegistry.shared.register(
      Fixture(chunks: [sse("{\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}")]),
      host: host
    )
    let provider = makeProvider(kind: .proxy, host: host, path: "/v1")
    _ = try await collect(provider)

    let request = try #require(FixtureRegistry.shared.fixture(for: host)?.capturedRequest)
    #expect(request.url?.absoluteString == "https://\(host)/v1/chat/completions")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
  }

  @Test func unauthorizedIsReadableAndDoesNotEchoBody() async throws {
    let host = "unauth.test"
    FixtureRegistry.shared.register(
      Fixture(
        status: 401,
        headers: ["Content-Type": "application/json"],
        chunks: [Data("{\"error\":{\"message\":\"bad key sk-live-SECRET\"}}".utf8)]
      ),
      host: host
    )
    let provider = makeProvider(kind: .openai, host: host, path: "/v1")

    do {
      _ = try await collect(provider)
      Issue.record("expected an HTTP error")
    } catch let error as ProviderError {
      #expect(error == .httpStatus(401))
      let message = error.errorDescription ?? ""
      #expect(message == "The provider returned HTTP 401.")
      #expect(!message.contains("SECRET"))
    }
  }

  @Test func remoteErrorEventIsSanitized() async throws {
    let host = "remote.test"
    FixtureRegistry.shared.register(
      Fixture(chunks: [
        Data("data: {\"error\":{\"message\":\"key sk-live-SECRET rejected\"}}\n\n".utf8)
      ]),
      host: host
    )
    let provider = makeProvider(kind: .openai, host: host, path: "/v1")

    do {
      _ = try await collect(provider)
      Issue.record("expected a remote error")
    } catch let error as ProviderError {
      #expect(error == .remote)
      let message = error.errorDescription ?? ""
      #expect(message == "The provider reported an error.")
      #expect(!message.contains("SECRET"))
    }
  }

  @Test func malformedEventIsSafeError() async throws {
    let host = "malformed.test"
    FixtureRegistry.shared.register(
      Fixture(chunks: [Data("data: {not json}\n\n".utf8)]),
      host: host
    )
    let provider = makeProvider(kind: .openai, host: host, path: "/v1")

    do {
      _ = try await collect(provider)
      Issue.record("expected a malformed response error")
    } catch let error as ProviderError {
      #expect(error == .malformedResponse)
    }
  }

  @Test func crlfEventSplitAcrossDataLinesKeepsOneEvent() async throws {
    let host = "crlf-lines.test"
    let payload =
      "data: {\"choices\":[\r\ndata: {\"delta\":{\"content\":\"joined\"}}]}\r\n\r\n"
    FixtureRegistry.shared.register(
      Fixture(chunks: [Data(payload.utf8)]),
      host: host
    )
    let provider = makeProvider(kind: .openai, host: host, path: "/v1")

    let values = try await collect(provider)
    #expect(values == ["joined"])
  }

  @Test func handlesCRLFAndSplitUTF8() async throws {
    let host = "utf8.test"
    let payload = "data: {\"choices\":[{\"delta\":{\"content\":\"café\"}}]}\r\n\r\n"
    let bytes = [UInt8](Data(payload.utf8))
    let firstByte = try #require(bytes.firstIndex(of: 0xC3))
    #expect(bytes[firstByte + 1] == 0xA9)
    FixtureRegistry.shared.register(
      Fixture(chunks: [Data(bytes[0...firstByte]), Data(bytes[(firstByte + 1)...])]),
      host: host
    )
    let provider = makeProvider(kind: .openai, host: host, path: "/v1")

    let values = try await collect(provider)
    #expect(values == ["café"])
  }

  @Test func emptyCompletionIsExplicitFailure() async throws {
    let host = "empty.test"
    FixtureRegistry.shared.register(
      Fixture(chunks: [Data("data: [DONE]\n\n".utf8)]),
      host: host
    )
    let provider = makeProvider(kind: .openai, host: host, path: "/v1")

    do {
      _ = try await collect(provider)
      Issue.record("expected an empty completion error")
    } catch let error as ProviderError {
      #expect(error == .emptyCompletion)
    }
  }

  @Test func doneTerminalFinishesWhileConnectionHeldOpen() async throws {
    let host = "done.test"
    let fixture = Fixture(
      chunks: [
        sse("{\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}"),
        Data("data: [DONE]\n\n".utf8),
      ],
      ending: .holdOpen
    )
    FixtureRegistry.shared.register(fixture, host: host)
    let provider = makeProvider(kind: .openai, host: host, path: "/v1")

    let values = try await collect(provider)
    #expect(values == ["hello"])
    #expect(await wait(fixture.stopped, timeout: .now() + 5))
    #expect(fixture.wasStopped)
  }

  @Test func anthropicMessageStopFinishesWhileConnectionHeldOpen() async throws {
    let host = "stop.test"
    let fixture = Fixture(
      chunks: [
        sse("{\"type\":\"content_block_delta\",\"delta\":{\"text\":\"hi\"}}"),
        sse("{\"type\":\"message_stop\"}"),
      ],
      ending: .holdOpen
    )
    FixtureRegistry.shared.register(fixture, host: host)
    let provider = makeProvider(kind: .anthropic, host: host, path: "/v1")

    let values = try await collect(provider)
    #expect(values == ["hi"])
    #expect(await wait(fixture.stopped, timeout: .now() + 5))
    #expect(fixture.wasStopped)
  }

  @Test func cancellingConsumerStopsTheRequest() async throws {
    let host = "cancel.test"
    let fixture = Fixture(chunks: [], ending: .holdOpen)
    FixtureRegistry.shared.register(fixture, host: host)
    let provider = makeProvider(kind: .openai, host: host, path: "/v1")

    let consumer = Task {
      let stream = provider.explain(imageJPEG: Data([0xFF, 0xD8]), prompt: "P", system: "S")
      do {
        for try await _ in stream {}
      } catch {}
    }

    #expect(await wait(fixture.requestReceived, timeout: .now() + 5))
    consumer.cancel()
    #expect(await wait(fixture.stopped, timeout: .now() + 5))
    #expect(fixture.wasStopped)
    _ = await consumer.value
  }

  @Test func crossOriginRedirectIsNotFollowedByTheProtocol() async throws {
    let originHost = "origin.test"
    let targetHost = "evil.test"
    let location = "https://\(targetHost)/steal"
    let originFixture = Fixture(
      status: 302,
      headers: ["Location": location],
      redirectLocation: location
    )
    let targetFixture = Fixture(
      chunks: [sse("{\"choices\":[{\"delta\":{\"content\":\"stolen\"}}]}")]
    )
    FixtureRegistry.shared.register(originFixture, host: originHost)
    FixtureRegistry.shared.register(targetFixture, host: targetHost)
    let provider = makeProvider(kind: .openai, host: originHost, path: "/v1")

    do {
      let values = try await collect(provider)
      Issue.record("expected the redirect to be rejected, got \(values)")
    } catch let error as ProviderError {
      #expect(error == .network)
    }
    #expect(targetFixture.capturedRequest == nil)
  }

  @Test func redirectDecisionAllowsSameOriginOnly() {
    let origin = URL(string: "https://api.test/v1")!
    #expect(HTTPProvider.allowsRedirect(from: origin, to: URL(string: "https://api.test/other")!))
    #expect(!HTTPProvider.allowsRedirect(from: origin, to: URL(string: "https://evil.test/v1")!))
    #expect(!HTTPProvider.allowsRedirect(from: origin, to: URL(string: "http://api.test/v1")!))
    #expect(
      !HTTPProvider.allowsRedirect(from: origin, to: URL(string: "https://api.test:8443/v1")!))
  }

  @Test func missingKeyFailsSafely() async throws {
    let settings = ProviderSettings(
      model: "m",
      baseURL: URL(string: "https://nokey.test/v1")!,
      keychainAccount: .openAIKey
    )
    let provider = HTTPProvider(
      kind: .openai,
      settings: settings,
      secrets: FakeSecrets(value: nil)
    )

    do {
      _ = try await collect(provider)
      Issue.record("expected a missing key error")
    } catch let error as ProviderError {
      #expect(error == .missingKey)
    }
  }

  @Test func testConnectionSucceedsOnFirstChunk() async throws {
    let host = "probe-ok.test"
    FixtureRegistry.shared.register(
      Fixture(chunks: [sse("{\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}")]),
      host: host
    )
    let provider = makeProvider(kind: .openai, host: host, path: "/v1")
    try await provider.testConnection(timeout: .seconds(5))
  }

  @Test func testConnectionStopsRequestAfterFirstToken() async throws {
    let host = "probe-cancel.test"
    let fixture = Fixture(
      chunks: [sse("{\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}")],
      ending: .holdOpen
    )
    FixtureRegistry.shared.register(fixture, host: host)
    let provider = makeProvider(kind: .openai, host: host, path: "/v1")

    try await provider.testConnection(timeout: .seconds(5))
    #expect(await wait(fixture.stopped, timeout: .now() + 5))
    #expect(fixture.wasStopped)
  }

  @Test func testConnectionTimesOutWhenProviderHoldsOpen() async throws {
    let host = "probe-timeout.test"
    let fixture = Fixture(chunks: [], ending: .holdOpen)
    FixtureRegistry.shared.register(fixture, host: host)
    let provider = makeProvider(kind: .openai, host: host, path: "/v1")

    let start = ContinuousClock.now
    do {
      try await provider.testConnection(timeout: .milliseconds(300))
      Issue.record("expected a timeout")
    } catch let error as ProviderError {
      #expect(error == .timedOut)
    }
    #expect(ContinuousClock.now - start < .seconds(3))
    #expect(await wait(fixture.stopped, timeout: .now() + 5))
    #expect(fixture.wasStopped)
  }

  @Test func cancellingCallerStopsProbeImmediately() async throws {
    let host = "probe-caller-cancel.test"
    let fixture = Fixture(chunks: [], ending: .holdOpen)
    FixtureRegistry.shared.register(fixture, host: host)
    let provider = makeProvider(kind: .openai, host: host, path: "/v1")

    let caller = Task { try await provider.testConnection(timeout: .seconds(30)) }
    #expect(await wait(fixture.requestReceived, timeout: .now() + 5))

    let start = ContinuousClock.now
    caller.cancel()
    let stoppedInTime = await wait(fixture.stopped, timeout: .now() + 1)

    if !stoppedInTime {
      caller.cancel()
      fixture.markStopped()
    }

    let result = await boundedResult(of: caller, seconds: 3)
    let elapsed = ContinuousClock.now - start

    #expect(stoppedInTime, "stopLoading not observed within 1s of caller cancellation")
    switch result {
    case .failure(let error):
      #expect(error is CancellationError, "expected cancellation, got \(error)")
      #expect((error as? ProviderError) != .timedOut)
    case .success, nil:
      Issue.record("testConnection did not return cancellation after caller cancellation")
    }
    #expect(elapsed < .seconds(3))
  }

  @Test func endpointTrailingSlashDoesNotDouble() throws {
    let provider = makeProvider(kind: .openai, host: "trail.test", path: "/v1/")
    #expect(try provider.endpointURL().absoluteString == "https://trail.test/v1/chat/completions")
  }

  @Test func endpointRejectsQueryAndFragmentWithoutSendingARequest() async throws {
    for path in ["/v1?token=secret", "/v1#frag"] {
      let host = "bad-\(path.hashValue).test"
      let provider = makeProvider(kind: .openai, host: host, path: path)
      do {
        _ = try await collect(provider)
        Issue.record("expected an invalid configuration error for \(path)")
      } catch let error as ProviderError {
        #expect(error == .invalidConfiguration)
      }
      #expect(FixtureRegistry.shared.fixture(for: host)?.capturedRequest == nil)
    }
  }

  @Test func endpointRejectsMalformedModel() throws {
    let provider = makeProvider(kind: .openai, host: "model.test", path: "/v1", model: "bad model")
    do {
      _ = try provider.endpointURL()
      Issue.record("expected an invalid configuration error")
    } catch let error as ProviderError {
      #expect(error == .invalidConfiguration)
    }
  }

  @Test func injectedSessionConfigurationIsSanitizedForMemoryOnly() {
    let configuration = URLSessionConfiguration.default
    configuration.urlCache = URLCache(
      memoryCapacity: 1024, diskCapacity: 10_000_000, diskPath: "u30-cache")
    configuration.requestCachePolicy = .useProtocolCachePolicy
    configuration.httpCookieStorage = HTTPCookieStorage.shared
    configuration.urlCredentialStorage = URLCredentialStorage.shared

    let sanitized = HTTPProvider.sanitizedConfiguration(configuration)
    #expect(sanitized.urlCache == nil)
    #expect(sanitized.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(sanitized.httpCookieStorage == nil)
    #expect(sanitized.httpCookieAcceptPolicy == .never)
    #expect(sanitized.urlCredentialStorage == nil)
  }

  @Test func injectedProviderSessionDropsDiskCache() {
    let configuration = URLSessionConfiguration.default
    configuration.urlCache = URLCache(
      memoryCapacity: 1024, diskCapacity: 10_000_000, diskPath: "u30-cache")
    let provider = HTTPProvider(
      kind: .openai,
      settings: ProviderSettings(
        model: "m",
        baseURL: URL(string: "https://cache.test/v1")!,
        keychainAccount: .openAIKey
      ),
      secrets: FakeSecrets(value: "x"),
      session: URLSession(configuration: configuration)
    )
    #expect(provider.session.configuration.urlCache == nil)
  }

  @Test func connectionTestImageIsAOnePixelJPEG() throws {
    let source = try #require(CGImageSourceCreateWithData(connectionTestImage as CFData, nil))
    #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 1)
    #expect(image.height == 1)
  }
}
