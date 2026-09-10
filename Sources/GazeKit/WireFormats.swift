import Foundation

public enum SSE {
  public static func events(from chunk: String, carry: inout String) -> [String] {
    carry.append(chunk)
    var pieces = carry.components(separatedBy: "\n\n")
    // A chunk can split anywhere, so the tail after the last blank line stays in carry until more bytes arrive.
    carry = pieces.removeLast()

    var events: [String] = []
    for piece in pieces {
      var dataLines: [String] = []
      for line in piece.components(separatedBy: "\n") where line.hasPrefix("data: ") {
        dataLines.append(String(line.dropFirst(6)))
      }
      if !dataLines.isEmpty {
        events.append(dataLines.joined(separator: "\n"))
      }
    }
    return events
  }
}

public protocol WireFormat {
  static func requestBody(
    model: String, system: String, prompt: String, imageJPEG: Data, maxOutputTokens: Int
  ) throws -> Data
  static func textDelta(fromEventData: String) throws -> String?
}

extension WireFormat {
  public static func requestBody(model: String, system: String, prompt: String, imageJPEG: Data)
    throws -> Data
  {
    try requestBody(
      model: model,
      system: system,
      prompt: prompt,
      imageJPEG: imageJPEG,
      maxOutputTokens: 1024
    )
  }
}

public enum WireError: Error, Equatable {
  case providerError(message: String)
}

private func eventObject(_ eventData: String) throws -> [String: Any]? {
  guard let data = eventData.data(using: .utf8),
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  else {
    return nil
  }
  if let error = object["error"] as? [String: Any],
    let message = error["message"] as? String
  {
    throw WireError.providerError(message: message)
  }
  return object
}

private struct GeminiTextPart: Encodable {
  let text: String
}

private struct GeminiInlineData: Encodable {
  let mimeType: String
  let data: String

  enum CodingKeys: String, CodingKey {
    case mimeType = "mime_type"
    case data
  }
}

private struct GeminiPart: Encodable {
  let text: String?
  let inlineData: GeminiInlineData?

  enum CodingKeys: String, CodingKey {
    case text
    case inlineData = "inline_data"
  }
}

private struct GeminiContent: Encodable {
  let role: String
  let parts: [GeminiPart]
}

private struct GeminiSystemInstruction: Encodable {
  let parts: [GeminiTextPart]
}

private struct GeminiGenerationConfig: Encodable {
  let maxOutputTokens: Int
}

private struct GeminiRequest: Encodable {
  let systemInstruction: GeminiSystemInstruction
  let contents: [GeminiContent]
  let generationConfig: GeminiGenerationConfig
}

public enum GeminiWire: WireFormat {
  public static func requestBody(
    model: String, system: String, prompt: String, imageJPEG: Data, maxOutputTokens: Int
  ) throws -> Data {
    let request = GeminiRequest(
      systemInstruction: GeminiSystemInstruction(parts: [GeminiTextPart(text: system)]),
      contents: [
        GeminiContent(
          role: "user",
          parts: [
            GeminiPart(text: prompt, inlineData: nil),
            GeminiPart(
              text: nil,
              inlineData: GeminiInlineData(
                mimeType: "image/jpeg",
                data: imageJPEG.base64EncodedString()
              )
            ),
          ]
        )
      ],
      generationConfig: GeminiGenerationConfig(maxOutputTokens: maxOutputTokens)
    )
    return try JSONEncoder().encode(request)
  }

  public static func textDelta(fromEventData eventData: String) throws -> String? {
    guard eventData != "[DONE]" else { return nil }
    guard let object = try eventObject(eventData) else { return nil }
    guard let candidates = object["candidates"] as? [[String: Any]],
      let content = candidates.first?["content"] as? [String: Any],
      let parts = content["parts"] as? [[String: Any]]
    else {
      return nil
    }
    return parts.first?["text"] as? String
  }
}

private struct OpenAIURL: Encodable {
  let url: String
}

private struct OpenAIPart: Encodable {
  let type: String
  let text: String?
  let imageURL: OpenAIURL?

  enum CodingKeys: String, CodingKey {
    case type
    case text
    case imageURL = "image_url"
  }
}

private enum OpenAIContent: Encodable {
  case text(String)
  case parts([OpenAIPart])

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .text(let value):
      try container.encode(value)
    case .parts(let parts):
      try container.encode(parts)
    }
  }
}

private struct OpenAIMessage: Encodable {
  let role: String
  let content: OpenAIContent
}

private struct OpenAIRequest: Encodable {
  let model: String
  let stream: Bool
  let maxTokens: Int
  let messages: [OpenAIMessage]

  enum CodingKeys: String, CodingKey {
    case model
    case stream
    case maxTokens = "max_tokens"
    case messages
  }
}

public enum OpenAIWire: WireFormat {
  public static func requestBody(
    model: String, system: String, prompt: String, imageJPEG: Data, maxOutputTokens: Int
  ) throws -> Data {
    let request = OpenAIRequest(
      model: model,
      stream: true,
      maxTokens: maxOutputTokens,
      messages: [
        OpenAIMessage(role: "system", content: .text(system)),
        OpenAIMessage(
          role: "user",
          content: .parts([
            OpenAIPart(type: "text", text: prompt, imageURL: nil),
            OpenAIPart(
              type: "image_url",
              text: nil,
              imageURL: OpenAIURL(url: "data:image/jpeg;base64," + imageJPEG.base64EncodedString())
            ),
          ])
        ),
      ]
    )
    return try JSONEncoder().encode(request)
  }

  public static func textDelta(fromEventData eventData: String) throws -> String? {
    guard eventData != "[DONE]" else { return nil }
    guard let object = try eventObject(eventData) else { return nil }
    guard let choices = object["choices"] as? [[String: Any]],
      let delta = choices.first?["delta"] as? [String: Any]
    else {
      return nil
    }
    return delta["content"] as? String
  }
}

private struct AnthropicImageSource: Encodable {
  let type: String
  let mediaType: String
  let data: String

  enum CodingKeys: String, CodingKey {
    case type
    case mediaType = "media_type"
    case data
  }
}

private struct AnthropicPart: Encodable {
  let type: String
  let source: AnthropicImageSource?
  let text: String?
}

private struct AnthropicMessage: Encodable {
  let role: String
  let content: [AnthropicPart]
}

private struct AnthropicRequest: Encodable {
  let model: String
  let stream: Bool
  let maxTokens: Int
  let system: String
  let messages: [AnthropicMessage]

  enum CodingKeys: String, CodingKey {
    case model
    case stream
    case maxTokens = "max_tokens"
    case system
    case messages
  }
}

public enum AnthropicWire: WireFormat {
  public static func requestBody(
    model: String, system: String, prompt: String, imageJPEG: Data, maxOutputTokens: Int
  ) throws -> Data {
    let request = AnthropicRequest(
      model: model,
      stream: true,
      maxTokens: maxOutputTokens,
      system: system,
      messages: [
        AnthropicMessage(
          role: "user",
          content: [
            AnthropicPart(
              type: "image",
              source: AnthropicImageSource(
                type: "base64",
                mediaType: "image/jpeg",
                data: imageJPEG.base64EncodedString()
              ),
              text: nil
            ),
            AnthropicPart(type: "text", source: nil, text: prompt),
          ]
        )
      ]
    )
    return try JSONEncoder().encode(request)
  }

  public static func textDelta(fromEventData eventData: String) throws -> String? {
    guard eventData != "[DONE]" else { return nil }
    guard let object = try eventObject(eventData) else { return nil }
    guard object["type"] as? String == "content_block_delta",
      let delta = object["delta"] as? [String: Any]
    else {
      return nil
    }
    return delta["text"] as? String
  }
}
