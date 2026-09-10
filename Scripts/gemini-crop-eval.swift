import AppKit
import Foundation
import GazeKit
import Providers

private let modelName = "gemini-3.5-flash-lite"
private let baseURLString = "https://generativelanguage.googleapis.com/v1beta"
private let outputCapTokens = 512
private let inputPricePerMillionTokens = 0.30
private let outputPricePerMillionTokens = 2.50
private let costCeilingUSD = 0.10
private let wallTimeoutSeconds = 45.0
private let countTimeoutSeconds = 20.0
private let cropWidth = 800
private let cropHeight = 300

private let systemInstruction = """
  You explain small code crops. Answer in at most 80 words. Describe the visible code's behavior \
  and, when the code fully determines it, state the concrete result or output. Distinguish what you \
  deduce from what you assume. Do not assume missing surrounding code or runtime data. If a value \
  or definition is not visible, or the outcome is uncertain, say so.
  """

private let userPrompt = """
  Explain what this code does. If the visible code determines a concrete result or output, state \
  it. Note any missing context or uncertainty. Keep it under 80 words.
  """

private struct CropCase {
  let id: String
  let title: String
  let lines: [String]
  let expectation: String
}

private let cropCases: [CropCase] = [
  CropCase(
    id: "swift-reduce",
    title: "Swift array reduction",
    lines: ["let values = [1, 2, 3]", "let total = values.reduce(0, +)"],
    expectation: "Sums the array to 6."
  ),
  CropCase(
    id: "python-range",
    title: "Python counted loop",
    lines: ["for i in range(3):", "    print(i)"],
    expectation: "Prints 0, 1, 2 and never 3."
  ),
  CropCase(
    id: "sql-filter",
    title: "SQL filtered select",
    lines: ["SELECT name FROM users", "WHERE active = 1", "ORDER BY name;"],
    expectation: "Selects names of active users, sorted by name."
  ),
  CropCase(
    id: "swift-incomplete-return",
    title: "Incomplete Swift return",
    lines: ["return cachedValue"],
    expectation: "Returns cachedValue and notes its type and origin are not visible."
  ),
]

private enum EvalError: Error {
  case usage(String)
  case cropGenerationFailed(String)
  case keyMissing
  case countRejected(String)
  case countHTTP(Int)
  case countMalformed
  case generationRejected(String)
  case readOnlySecrets
}

extension EvalError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .usage(let message): message
    case .cropGenerationFailed(let id): "Could not render or decode crop \(id)."
    case .keyMissing: "No Google API key is stored for this provider."
    case .countRejected(let detail): "Token count rejected: \(detail)"
    case .countHTTP(let status): "Token count returned HTTP \(status)."
    case .countMalformed: "Token count response was malformed."
    case .generationRejected(let detail): "Generation rejected: \(detail)"
    case .readOnlySecrets: "The in-memory secret store is read-only."
    }
  }
}

private struct InMemorySecretStore: SecretStore {
  let key: String

  func read(account: String) throws -> String? {
    account == KeychainAccount.googleKey.rawValue ? key : nil
  }

  func write(_ secret: String, account: String) throws {
    throw EvalError.readOnlySecrets
  }

  func delete(account: String) throws {
    throw EvalError.readOnlySecrets
  }
}

// Progress lines carry caseID, timing, status, and the cost limit only. They never carry the key,
// request body, request headers, or any remote error body, so a stalled run stays diagnosable.
private func progress(_ message: String) {
  FileHandle.standardOutput.write(Data(("[progress] \(message)\n".utf8)))
}

private final class TripFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func trip() {
    lock.lock()
    value = true
    lock.unlock()
  }

  var tripped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
    task.cancel()
  }
}

private func makeSession() -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.urlCache = nil
  configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
  configuration.httpCookieStorage = nil
  configuration.httpCookieAcceptPolicy = .never
  configuration.httpShouldSetCookies = false
  configuration.urlCredentialStorage = nil
  return URLSession(
    configuration: configuration,
    delegate: RejectRedirects(),
    delegateQueue: nil
  )
}

private func renderCrop(lines: [String]) -> Data? {
  guard
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: cropWidth,
      pixelsHigh: cropHeight,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ),
    let context = NSGraphicsContext(bitmapImageRep: rep)
  else {
    return nil
  }

  let saved = NSGraphicsContext.current
  NSGraphicsContext.current = context
  context.cgContext.setFillColor(NSColor(calibratedWhite: 0.12, alpha: 1).cgColor)
  context.cgContext.fill(CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight))

  let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .regular),
    .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1),
  ]
  for (index, line) in lines.enumerated() {
    let y = CGFloat(cropHeight - 46 - index * 36)
    (line as NSString).draw(at: NSPoint(x: 26, y: y), withAttributes: attributes)
  }

  NSGraphicsContext.current = saved
  return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
}

private func decodedDimensions(_ jpeg: Data) -> (width: Int, height: Int)? {
  guard let rep = NSBitmapImageRep(data: jpeg) else { return nil }
  return (rep.pixelsWide, rep.pixelsHigh)
}

private func seconds(_ duration: Duration) -> Double {
  let components = duration.components
  return Double(components.seconds) + Double(components.attoseconds) / 1e18
}

private func costUpperBound(inputTokens: Int) -> Double {
  (Double(inputTokens) * inputPricePerMillionTokens
    + Double(outputCapTokens) * outputPricePerMillionTokens) / 1_000_000
}

private func geminiRequestBody(jpeg: Data) throws -> [String: Any] {
  let encoded = try GeminiWire.requestBody(
    model: modelName,
    system: systemInstruction,
    prompt: userPrompt,
    imageJPEG: jpeg,
    maxOutputTokens: outputCapTokens
  )
  guard let request = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
    throw EvalError.countMalformed
  }
  return request
}

private func countTokensBody(jpeg: Data) throws -> Data {
  var request = try geminiRequestBody(jpeg: jpeg)
  request["model"] = "models/\(modelName)"
  return try JSONSerialization.data(withJSONObject: ["generateContentRequest": request])
}

private func validateWireShape(jpeg: Data) throws {
  let generation = try geminiRequestBody(jpeg: jpeg)
  guard let system = generation["systemInstruction"] as? [String: Any],
    let systemParts = system["parts"] as? [[String: Any]],
    systemParts.first?["text"] as? String == systemInstruction,
    let contents = generation["contents"] as? [[String: Any]],
    let content = contents.first,
    content["role"] as? String == "user",
    let parts = content["parts"] as? [[String: Any]],
    parts.count == 2,
    parts.first?["text"] as? String == userPrompt,
    let config = generation["generationConfig"] as? [String: Any],
    config["maxOutputTokens"] as? Int == outputCapTokens,
    let inline = parts.last?["inline_data"] as? [String: Any],
    inline["mime_type"] as? String == "image/jpeg",
    let encodedImage = inline["data"] as? String,
    Data(base64Encoded: encodedImage) == jpeg
  else {
    throw EvalError.countMalformed
  }

  let body = try countTokensBody(jpeg: jpeg)
  guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
    root.count == 1,
    root["contents"] == nil,
    root["systemInstruction"] == nil,
    let request = root["generateContentRequest"] as? [String: Any],
    request["model"] as? String == "models/\(modelName)",
    request["systemInstruction"] != nil,
    request["contents"] != nil
  else {
    throw EvalError.countMalformed
  }
}

private func countTokens(session: URLSession, key: String, jpeg: Data) async throws -> Int {
  guard let url = URL(string: "\(baseURLString)/models/\(modelName):countTokens") else {
    throw EvalError.countMalformed
  }
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.timeoutInterval = countTimeoutSeconds
  request.httpBody = try countTokensBody(jpeg: jpeg)
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  request.setValue(key, forHTTPHeaderField: "x-goog-api-key")

  let (data, response) = try await session.data(for: request)
  guard let http = response as? HTTPURLResponse else { throw EvalError.countMalformed }
  guard (200..<300).contains(http.statusCode) else { throw EvalError.countHTTP(http.statusCode) }
  guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
    let total = object["totalTokens"] as? Int,
    total >= 0
  else {
    throw EvalError.countMalformed
  }
  return total
}

private enum GenerationOutcome {
  case success(text: String, firstTokenSeconds: Double?, totalSeconds: Double)
  case failure(status: String, totalSeconds: Double)
}

private func safeStatus(_ error: Error) -> String {
  if let evalError = error as? EvalError {
    return evalError.errorDescription ?? "eval error"
  }
  if let providerError = error as? ProviderError {
    return providerError.errorDescription ?? "provider error"
  }
  return "request failed"
}

private func generate(provider: HTTPProvider, jpeg: Data) async -> GenerationOutcome {
  let start = ContinuousClock.now
  let timeoutFlag = TripFlag()
  let callerCancelled = TripFlag()
  let probe = Task { () -> (String, Double?) in
    var text = ""
    var firstToken: Double?
    for try await delta in provider.explain(
      imageJPEG: jpeg, prompt: userPrompt, system: systemInstruction)
    {
      if firstToken == nil { firstToken = seconds(ContinuousClock.now - start) }
      text += delta
    }
    return (text, firstToken)
  }
  let watchdog = Task {
    try await Task.sleep(for: .seconds(wallTimeoutSeconds))
    timeoutFlag.trip()
    probe.cancel()
  }
  defer { watchdog.cancel() }

  do {
    let (text, firstToken) = try await withTaskCancellationHandler {
      try await probe.value
    } onCancel: {
      callerCancelled.trip()
      probe.cancel()
      watchdog.cancel()
    }
    let total = seconds(ContinuousClock.now - start)
    if timeoutFlag.tripped {
      return .failure(status: "timeout after \(Int(wallTimeoutSeconds))s", totalSeconds: total)
    }
    if callerCancelled.tripped {
      return .failure(status: "cancelled", totalSeconds: total)
    }
    return .success(text: text, firstTokenSeconds: firstToken, totalSeconds: total)
  } catch {
    let total = seconds(ContinuousClock.now - start)
    if timeoutFlag.tripped {
      return .failure(status: "timeout after \(Int(wallTimeoutSeconds))s", totalSeconds: total)
    }
    if callerCancelled.tripped {
      return .failure(status: "cancelled", totalSeconds: total)
    }
    return .failure(status: safeStatus(error), totalSeconds: total)
  }
}

private struct CaseResult {
  let cropCase: CropCase
  var cropBytes: Int
  var dimensions: (width: Int, height: Int)?
  var inputTokens: Int?
  var costUpperBound: Double?
  var status: String
  var explanation: String?
  var firstTokenSeconds: Double?
  var totalSeconds: Double?
}

private func formatCurrency(_ value: Double) -> String {
  String(format: "$%.6f", value)
}

private func renderReport(mode: String, results: [CaseResult], cumulative: Double?) -> String {
  var lines: [String] = []
  lines.append("# Gemini crop explanation eval")
  lines.append("")
  lines.append("- Mode: \(mode)")
  lines.append("- Model: \(modelName)")
  lines.append("- Output cap: \(outputCapTokens) tokens")
  lines.append(
    "- Prices: input $\(String(format: "%.2f", inputPricePerMillionTokens))/M, output (incl. thinking) $\(String(format: "%.2f", outputPricePerMillionTokens))/M"
  )
  lines.append("- Cost ceiling: \(formatCurrency(costCeilingUSD))")
  lines.append("- Generation request budget: 4 (one per case, no retries)")
  lines.append("- Wall timeout per case: \(Int(wallTimeoutSeconds))s")
  if let cumulative {
    lines.append("- Cumulative maximum cost estimate: \(formatCurrency(cumulative))")
  }
  lines.append("")
  lines.append(
    "Cost values are worst-case upper bounds derived from the input token count and the output cap. They are not actual billing."
  )
  lines.append("")
  lines.append(
    "These are synthetic in-memory crops. They are not evidence that gaze targeting or live screen capture works."
  )
  lines.append("")

  lines.append("## Cases")
  for (index, result) in results.enumerated() {
    lines.append("")
    lines.append("### \(index + 1). \(result.cropCase.id): \(result.cropCase.title)")
    lines.append("")
    lines.append("- Status: \(result.status)")
    if let dimensions = result.dimensions {
      let size = "\(dimensions.width)x\(dimensions.height)"
      lines.append("- Crop: \(size) JPEG, \(result.cropBytes) bytes")
    } else {
      lines.append("- Crop: not decoded")
    }
    if let tokens = result.inputTokens {
      lines.append("- Input tokens (countTokens): \(tokens)")
    } else {
      lines.append("- Input tokens (countTokens): n/a")
    }
    lines.append("- Output cap: \(outputCapTokens) tokens")
    if let bound = result.costUpperBound {
      lines.append("- Maximum cost estimate: \(formatCurrency(bound))")
    } else {
      lines.append("- Maximum cost estimate: n/a")
    }
    if let first = result.firstTokenSeconds {
      lines.append("- First token: \(String(format: "%.3f", first))s")
    }
    if let total = result.totalSeconds {
      lines.append("- Full response: \(String(format: "%.3f", total))s")
    }
    lines.append("- Review check: \(result.cropCase.expectation)")
    lines.append("")
    lines.append("Synthetic source:")
    lines.append("")
    lines.append("```")
    lines.append(contentsOf: result.cropCase.lines)
    lines.append("```")
    if let explanation = result.explanation {
      lines.append("")
      lines.append("Explanation:")
      lines.append("")
      lines.append("```")
      lines.append(explanation.trimmingCharacters(in: .whitespacesAndNewlines))
      lines.append("```")
    }
  }
  lines.append("")
  return lines.joined(separator: "\n")
}

private func writeReport(_ text: String, to path: String) throws {
  try text.write(toFile: path, atomically: true, encoding: .utf8)
}

private func runDryRun(reportPath: String) throws {
  var results: [CaseResult] = []
  for cropCase in cropCases {
    guard let jpeg = renderCrop(lines: cropCase.lines) else {
      throw EvalError.cropGenerationFailed(cropCase.id)
    }
    guard let dimensions = decodedDimensions(jpeg),
      dimensions.width == cropWidth, dimensions.height == cropHeight
    else {
      throw EvalError.cropGenerationFailed(cropCase.id)
    }
    try validateWireShape(jpeg: jpeg)
    let status =
      "dry-run: crop decoded \(dimensions.width)x\(dimensions.height), countTokens generateContentRequest shape validated, no network or key access"
    results.append(
      CaseResult(
        cropCase: cropCase,
        cropBytes: jpeg.count,
        dimensions: dimensions,
        inputTokens: nil,
        costUpperBound: nil,
        status: status,
        explanation: nil,
        firstTokenSeconds: nil,
        totalSeconds: nil
      )
    )
    print("[dry-run] \(cropCase.id): \(dimensions.width)x\(dimensions.height), \(jpeg.count) bytes")
  }
  try writeReport(renderReport(mode: "dry-run", results: results, cumulative: nil), to: reportPath)
  print("dry-run complete, report written to \(reportPath)")
}

private func runLive(reportPath: String) async throws {
  let keychain = KeychainStore()
  guard let key = try keychain.read(account: KeychainAccount.googleKey.rawValue), !key.isEmpty
  else {
    throw EvalError.keyMissing
  }

  var crops: [(CropCase, Data, (width: Int, height: Int))] = []
  for cropCase in cropCases {
    guard let jpeg = renderCrop(lines: cropCase.lines),
      let dimensions = decodedDimensions(jpeg),
      dimensions.width == cropWidth, dimensions.height == cropHeight
    else {
      throw EvalError.cropGenerationFailed(cropCase.id)
    }
    crops.append((cropCase, jpeg, dimensions))
  }

  let countSession = makeSession()
  defer { countSession.invalidateAndCancel() }
  let countStart = ContinuousClock.now
  var inputTokens: [String: Int] = [:]
  for (cropCase, jpeg, _) in crops {
    do {
      let tokens = try await countTokens(session: countSession, key: key, jpeg: jpeg)
      inputTokens[cropCase.id] = tokens
    } catch let error as EvalError {
      throw error
    } catch {
      throw EvalError.countRejected(safeStatus(error))
    }
  }
  let countElapsed = seconds(ContinuousClock.now - countStart)
  progress(
    "counts caseIDs=\(crops.map { $0.0.id }.joined(separator: ",")) status=ok "
      + "elapsed=\(String(format: "%.3f", countElapsed))s "
      + "costlimit=\(formatCurrency(costCeilingUSD))"
  )

  let cumulative = inputTokens.values.reduce(0.0) { $0 + costUpperBound(inputTokens: $1) }
  guard cumulative <= costCeilingUSD else {
    throw EvalError.generationRejected(
      "cumulative maximum estimate \(formatCurrency(cumulative)) exceeds ceiling \(formatCurrency(costCeilingUSD))"
    )
  }

  let settings = ProviderSettings(
    model: modelName,
    baseURL: URL(string: baseURLString)!,
    keychainAccount: .googleKey
  )
  let provider = HTTPProvider(
    kind: .google,
    settings: settings,
    secrets: InMemorySecretStore(key: key),
    maximumOutputTokens: outputCapTokens
  )

  var results: [CaseResult] = []
  var cancelled = false
  for (cropCase, jpeg, dimensions) in crops {
    if Task.isCancelled { break }
    guard let tokens = inputTokens[cropCase.id] else { continue }
    let bound = costUpperBound(inputTokens: tokens)
    progress(
      "generate start caseID=\(cropCase.id) wall=\(String(format: "%.3f", wallTimeoutSeconds))s "
        + "costlimit=\(formatCurrency(bound))"
    )
    let outcome = await generate(provider: provider, jpeg: jpeg)
    if case .failure(let status, _) = outcome, status == "cancelled" { cancelled = true }
    let status: String
    let total: Double
    switch outcome {
    case .success(let text, let firstToken, let elapsed):
      status = "success"
      total = elapsed
      results.append(
        CaseResult(
          cropCase: cropCase,
          cropBytes: jpeg.count,
          dimensions: dimensions,
          inputTokens: tokens,
          costUpperBound: bound,
          status: "success",
          explanation: text,
          firstTokenSeconds: firstToken,
          totalSeconds: elapsed
        )
      )
    case .failure(let failureStatus, let elapsed):
      status = failureStatus
      total = elapsed
      results.append(
        CaseResult(
          cropCase: cropCase,
          cropBytes: jpeg.count,
          dimensions: dimensions,
          inputTokens: tokens,
          costUpperBound: bound,
          status: failureStatus,
          explanation: nil,
          firstTokenSeconds: nil,
          totalSeconds: elapsed
        )
      )
    }
    progress(
      "generate done caseID=\(cropCase.id) status=\(status) "
        + "elapsed=\(String(format: "%.3f", total))s costlimit=\(formatCurrency(bound))"
    )
    if cancelled { break }
  }

  try writeReport(
    renderReport(mode: "live", results: results, cumulative: cumulative), to: reportPath)
  print("live run complete, report written to \(reportPath)")
}

private func usage() -> String {
  """
  Usage: gemini-crop-eval <report-path> [--live]

  Default mode is dry-run: generates the four synthetic crops in memory, validates they decode,
  and writes a report without any network or key access. Pass --live to make budget-bounded,
  capped requests to gemini-3.5-flash-lite. The report path is required.
  """
}

@main
private struct GeminiCropEval {
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    var live = false
    var reportPath: String?

    for argument in arguments {
      switch argument {
      case "--live":
        live = true
      case "--dry-run":
        live = false
      case "--help", "-h":
        print(usage())
        return
      default:
        if argument.hasPrefix("-") {
          FileHandle.standardError.write(Data("Unknown flag: \(argument)\n".utf8))
          print(usage())
          exit(2)
        }
        if reportPath == nil {
          reportPath = argument
        } else {
          FileHandle.standardError.write(Data("Unexpected argument: \(argument)\n".utf8))
          print(usage())
          exit(2)
        }
      }
    }

    guard let reportPath else {
      FileHandle.standardError.write(Data((usage() + "\n").utf8))
      exit(2)
    }

    do {
      if live {
        try await runLive(reportPath: reportPath)
      } else {
        try runDryRun(reportPath: reportPath)
      }
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? "eval failed"
      FileHandle.standardError.write(Data("\(message)\n".utf8))
      exit(1)
    }
  }
}
