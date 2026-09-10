import Foundation
import GazeKit

enum ProviderWire {
  case gemini, openAI, anthropic

  static func of(_ kind: ProviderKind) -> ProviderWire {
    switch kind {
    case .google: .gemini
    case .anthropic: .anthropic
    case .openai, .opencode, .proxy: .openAI
    }
  }

  func requestBody(
    model: String, system: String, prompt: String, imageJPEG: Data, maxOutputTokens: Int
  ) throws -> Data {
    switch self {
    case .gemini:
      try GeminiWire.requestBody(
        model: model, system: system, prompt: prompt, imageJPEG: imageJPEG,
        maxOutputTokens: maxOutputTokens)
    case .openAI:
      try OpenAIWire.requestBody(
        model: model, system: system, prompt: prompt, imageJPEG: imageJPEG,
        maxOutputTokens: maxOutputTokens)
    case .anthropic:
      try AnthropicWire.requestBody(
        model: model, system: system, prompt: prompt, imageJPEG: imageJPEG,
        maxOutputTokens: maxOutputTokens)
    }
  }

  func textDelta(fromEventData eventData: String) throws -> String? {
    switch self {
    case .gemini: try GeminiWire.textDelta(fromEventData: eventData)
    case .openAI: try OpenAIWire.textDelta(fromEventData: eventData)
    case .anthropic: try AnthropicWire.textDelta(fromEventData: eventData)
    }
  }

  func isTerminal(_ eventData: String) -> Bool {
    if eventData == "[DONE]" { return true }
    guard case .anthropic = self,
      let data = eventData.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return false
    }
    return object["type"] as? String == "message_stop"
  }
}

final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    guard let origin = task.originalRequest?.url,
      let target = request.url,
      HTTPProvider.allowsRedirect(from: origin, to: target)
    else {
      completionHandler(nil)
      task.cancel()
      return
    }
    completionHandler(request)
  }
}

public final class HTTPProvider: LLMProvider, @unchecked Sendable {
  public let kind: ProviderKind
  public let settings: ProviderSettings
  public let maximumOutputTokens: Int

  private let secrets: any SecretStore
  let session: URLSession

  public init(
    kind: ProviderKind,
    settings: ProviderSettings,
    secrets: any SecretStore,
    session: URLSession? = nil,
    maximumOutputTokens: Int = 1024
  ) {
    self.kind = kind
    self.settings = settings
    self.maximumOutputTokens = maximumOutputTokens
    self.secrets = secrets
    self.session = URLSession(
      configuration: Self.sanitizedConfiguration(session?.configuration),
      delegate: RedirectGuard(),
      delegateQueue: nil
    )
  }

  deinit {
    session.invalidateAndCancel()
  }

  static func sanitizedConfiguration(_ base: URLSessionConfiguration?) -> URLSessionConfiguration {
    let configuration =
      (base?.copy() as? URLSessionConfiguration) ?? URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieStorage = nil
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    return configuration
  }

  public func explain(
    imageJPEG: Data,
    prompt: String,
    system: String
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await run(imageJPEG: imageJPEG, prompt: prompt, system: system) {
            continuation.yield($0)
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: Self.safeError(error))
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  static func allowsRedirect(from origin: URL, to target: URL) -> Bool {
    origin.scheme == target.scheme && origin.host == target.host && origin.port == target.port
  }

  func endpointURL() throws -> URL {
    let base = settings.baseURL
    guard let scheme = base.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = base.host, !host.isEmpty,
      base.query == nil, base.fragment == nil
    else {
      throw ProviderError.invalidConfiguration
    }
    if kind != .proxy {
      let model = settings.model
      guard !model.isEmpty,
        !model.contains(where: { $0 == "/" || $0 == "?" || $0 == "#" || $0.isWhitespace })
      else {
        throw ProviderError.invalidConfiguration
      }
    }
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
    var path = components?.path ?? ""
    while path.hasSuffix("/") { path.removeLast() }
    switch kind {
    case .google:
      path += "/models/\(settings.model):streamGenerateContent"
      components?.queryItems = [URLQueryItem(name: "alt", value: "sse")]
    case .anthropic:
      path += "/messages"
    case .openai, .opencode, .proxy:
      path += "/chat/completions"
    }
    components?.path = path
    guard let url = components?.url, url.host != nil else {
      throw ProviderError.invalidConfiguration
    }
    return url
  }

  func makeRequest(key: String, imageJPEG: Data, prompt: String, system: String) throws
    -> URLRequest
  {
    guard maximumOutputTokens > 0 else { throw ProviderError.invalidConfiguration }
    let body = try ProviderWire.of(kind).requestBody(
      model: settings.model,
      system: system,
      prompt: prompt,
      imageJPEG: imageJPEG,
      maxOutputTokens: maximumOutputTokens
    )
    var request = URLRequest(url: try endpointURL())
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    switch kind {
    case .google:
      request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
    case .anthropic:
      request.setValue(key, forHTTPHeaderField: "x-api-key")
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    case .openai, .opencode, .proxy:
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    return request
  }

  private func resolvedKey() throws -> String {
    guard let key = try secrets.read(account: settings.keychainAccount.rawValue), !key.isEmpty
    else {
      throw ProviderError.missingKey
    }
    return key
  }

  private func run(
    imageJPEG: Data,
    prompt: String,
    system: String,
    yield: @escaping @Sendable (String) -> Void
  ) async throws {
    let key = try resolvedKey()
    let request = try makeRequest(key: key, imageJPEG: imageJPEG, prompt: prompt, system: system)
    let (bytes, response) = try await session.bytes(for: request)
    let networkTask = bytes.task
    defer { networkTask.cancel() }
    guard let http = response as? HTTPURLResponse else { throw ProviderError.malformedResponse }
    guard (200..<300).contains(http.statusCode) else {
      throw ProviderError.httpStatus(http.statusCode)
    }

    let wire = ProviderWire.of(kind)
    var carry = ""
    var pending = Data()
    var pendingCarriageReturn = false
    var delivered = false

    func drainPending() throws -> Bool {
      let (text, rest) = Self.decodeValidPrefix(pending)
      pending = rest
      guard !text.isEmpty else { return false }
      for event in SSE.events(from: text, carry: &carry) {
        if wire.isTerminal(event) { return true }
        guard Self.isJSON(event) else { throw ProviderError.malformedResponse }
        let delta = try wire.textDelta(fromEventData: event)
        if let delta, !delta.isEmpty {
          delivered = true
          yield(delta)
        }
      }
      return false
    }

    try await withTaskCancellationHandler {
      for try await byte in bytes {
        if byte == 0x0D {
          if pendingCarriageReturn { pending.append(0x0A) }
          pendingCarriageReturn = true
          continue
        }
        if byte == 0x0A {
          pendingCarriageReturn = false
          pending.append(0x0A)
        } else {
          if pendingCarriageReturn {
            pendingCarriageReturn = false
            pending.append(0x0A)
          }
          pending.append(byte)
        }
        if try drainPending() { return }
      }
      if pendingCarriageReturn { pending.append(0x0A) }
      if try drainPending() { return }
    } onCancel: {
      networkTask.cancel()
    }

    guard delivered else { throw ProviderError.emptyCompletion }
  }

  static func decodeValidPrefix(_ data: Data) -> (String, Data) {
    guard !data.isEmpty else { return ("", Data()) }
    let bytes = [UInt8](data)
    var index = bytes.count - 1
    while index >= 0 && (bytes[index] & 0xC0) == 0x80 { index -= 1 }
    guard index >= 0 else { return ("", data) }
    let required: Int
    switch bytes[index] {
    case 0x00...0x7F: required = 1
    case 0xC0...0xDF: required = 2
    case 0xE0...0xEF: required = 3
    case 0xF0...0xF7: required = 4
    default: required = 1
    }
    if bytes.count - index < required {
      return (String(decoding: bytes[0..<index], as: UTF8.self), Data(bytes[index...]))
    }
    return (String(decoding: bytes, as: UTF8.self), Data())
  }

  static func isJSON(_ event: String) -> Bool {
    guard let data = event.data(using: .utf8) else { return false }
    return (try? JSONSerialization.jsonObject(with: data)) != nil
  }

  static func safeError(_ error: Error) -> ProviderError {
    switch error {
    case let providerError as ProviderError: providerError
    case is WireError: .remote
    case is CancellationError: .network
    default: error is URLError ? .network : .malformedResponse
    }
  }
}
