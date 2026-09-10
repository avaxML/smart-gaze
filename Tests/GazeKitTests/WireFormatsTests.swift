import Foundation
import Testing

@testable import GazeKit

@Test func sseReassemblesEventSplitOneByteAtATime() {
  let input = "data: hello\n\n"
  var carry = ""
  var collected: [String] = []
  for character in input {
    collected.append(contentsOf: SSE.events(from: String(character), carry: &carry))
  }
  #expect(collected == ["hello"])
}

@Test func sseHandlesTwoAndAHalfEvents() {
  var carry = ""
  let events = SSE.events(from: "data: a\n\ndata: b\n\ndata: c", carry: &carry)
  #expect(events == ["a", "b"])
  #expect(carry == "data: c")
}

@Test func sseJoinsMultipleDataLinesInOneEvent() {
  var carry = ""
  let events = SSE.events(from: "data: one\ndata: two\n\n", carry: &carry)
  #expect(events == ["one\ntwo"])
}

@Test func sseIgnoresNonDataLines() {
  var carry = ""
  let events = SSE.events(from: "event: ping\ndata: x\n\n", carry: &carry)
  #expect(events == ["x"])
}

@Test func geminiRequestBodyShape() throws {
  let jpeg = Data([0xFF, 0xD8])
  let body = try GeminiWire.requestBody(model: "m", system: "S", prompt: "P", imageJPEG: jpeg)
  let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

  let systemInstruction = try #require(json["systemInstruction"] as? [String: Any])
  let systemParts = try #require(systemInstruction["parts"] as? [[String: Any]])
  #expect(systemParts[0]["text"] as? String == "S")

  let contents = try #require(json["contents"] as? [[String: Any]])
  let parts = try #require(contents[0]["parts"] as? [[String: Any]])
  #expect(parts[0]["text"] as? String == "P")

  let inlineData = try #require(parts[1]["inline_data"] as? [String: Any])
  #expect(inlineData["mime_type"] as? String == "image/jpeg")
  #expect(inlineData["data"] as? String == jpeg.base64EncodedString())
}

@Test func openAIRequestBodyShape() throws {
  let jpeg = Data([0xFF, 0xD8])
  let body = try OpenAIWire.requestBody(model: "m", system: "S", prompt: "P", imageJPEG: jpeg)
  let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

  #expect(json["model"] as? String == "m")
  #expect(json["stream"] as? Bool == true)

  let messages = try #require(json["messages"] as? [[String: Any]])
  #expect(messages[0]["role"] as? String == "system")

  let content = try #require(messages[1]["content"] as? [[String: Any]])
  let imageURL = try #require(content[1]["image_url"] as? [String: Any])
  let url = try #require(imageURL["url"] as? String)
  #expect(url.hasPrefix("data:image/jpeg;base64,"))
}

@Test func anthropicRequestBodyShape() throws {
  let jpeg = Data([0xFF, 0xD8])
  let body = try AnthropicWire.requestBody(model: "m", system: "S", prompt: "P", imageJPEG: jpeg)
  let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

  #expect(json["model"] as? String == "m")
  #expect(json["stream"] as? Bool == true)
  #expect(json["system"] as? String == "S")

  let messages = try #require(json["messages"] as? [[String: Any]])
  let content = try #require(messages[0]["content"] as? [[String: Any]])
  let source = try #require(content[0]["source"] as? [String: Any])
  #expect(source["media_type"] as? String == "image/jpeg")
}

@Test func requestBodiesCarryLiteralOutputCap() throws {
  let jpeg = Data([0xFF, 0xD8])
  let gemini = try #require(
    try JSONSerialization.jsonObject(
      with: try GeminiWire.requestBody(
        model: "m", system: "S", prompt: "P", imageJPEG: jpeg, maxOutputTokens: 512)
    ) as? [String: Any])
  let config = try #require(gemini["generationConfig"] as? [String: Any])
  #expect(config["maxOutputTokens"] as? Int == 512)

  let openAI = try #require(
    try JSONSerialization.jsonObject(
      with: try OpenAIWire.requestBody(
        model: "m", system: "S", prompt: "P", imageJPEG: jpeg, maxOutputTokens: 512)
    ) as? [String: Any])
  #expect(openAI["max_tokens"] as? Int == 512)

  let anthropic = try #require(
    try JSONSerialization.jsonObject(
      with: try AnthropicWire.requestBody(
        model: "m", system: "S", prompt: "P", imageJPEG: jpeg, maxOutputTokens: 512)
    ) as? [String: Any])
  #expect(anthropic["max_tokens"] as? Int == 512)
}

@Test func requestBodiesDefaultOutputCapTo1024() throws {
  let jpeg = Data([0xFF, 0xD8])
  let gemini = try #require(
    try JSONSerialization.jsonObject(
      with: try GeminiWire.requestBody(model: "m", system: "S", prompt: "P", imageJPEG: jpeg)
    ) as? [String: Any])
  #expect((gemini["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int == 1024)

  let openAI = try #require(
    try JSONSerialization.jsonObject(
      with: try OpenAIWire.requestBody(model: "m", system: "S", prompt: "P", imageJPEG: jpeg)
    ) as? [String: Any])
  #expect(openAI["max_tokens"] as? Int == 1024)

  let anthropic = try #require(
    try JSONSerialization.jsonObject(
      with: try AnthropicWire.requestBody(model: "m", system: "S", prompt: "P", imageJPEG: jpeg)
    ) as? [String: Any])
  #expect(anthropic["max_tokens"] as? Int == 1024)
}

@Test func requestBodiesContainNoAPIKey() throws {
  let jpeg = Data([0xFF, 0xD8])
  let bodies = [
    try GeminiWire.requestBody(model: "m", system: "S", prompt: "P", imageJPEG: jpeg),
    try OpenAIWire.requestBody(model: "m", system: "S", prompt: "P", imageJPEG: jpeg),
    try AnthropicWire.requestBody(model: "m", system: "S", prompt: "P", imageJPEG: jpeg),
  ]

  for body in bodies {
    let text = try #require(String(data: body, encoding: .utf8))
    #expect(!text.contains("sk-"))
    #expect(!text.contains("Bearer"))
  }
}

@Test func geminiTextDeltaExtractsText() throws {
  let event = #"{"candidates":[{"content":{"parts":[{"text":"hi"}]}}]}"#
  #expect(try GeminiWire.textDelta(fromEventData: event) == "hi")
}

@Test func openAITextDeltaExtractsContent() throws {
  let event = #"{"choices":[{"delta":{"content":"hi"}}]}"#
  #expect(try OpenAIWire.textDelta(fromEventData: event) == "hi")
}

@Test func openAIRoleOnlyOpenerReturnsNil() throws {
  let event = #"{"choices":[{"delta":{"role":"assistant"}}]}"#
  #expect(try OpenAIWire.textDelta(fromEventData: event) == nil)
}

@Test func anthropicContentBlockDeltaExtractsText() throws {
  let event = #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}"#
  #expect(try AnthropicWire.textDelta(fromEventData: event) == "hi")
}

@Test func anthropicNonDeltaEventsReturnNil() throws {
  #expect(try AnthropicWire.textDelta(fromEventData: #"{"type":"message_start"}"#) == nil)
  #expect(try AnthropicWire.textDelta(fromEventData: #"{"type":"ping"}"#) == nil)
}

@Test func doneSentinelReturnsNilForAllFormats() throws {
  #expect(try GeminiWire.textDelta(fromEventData: "[DONE]") == nil)
  #expect(try OpenAIWire.textDelta(fromEventData: "[DONE]") == nil)
  #expect(try AnthropicWire.textDelta(fromEventData: "[DONE]") == nil)
}

@Test func malformedJSONReturnsNilForAllFormats() throws {
  #expect(try GeminiWire.textDelta(fromEventData: "not json at all") == nil)
  #expect(try OpenAIWire.textDelta(fromEventData: "not json at all") == nil)
  #expect(try AnthropicWire.textDelta(fromEventData: "not json at all") == nil)
}

@Test func providerErrorThrows() throws {
  let event = #"{"error":{"message":"quota exceeded"}}"#
  #expect(throws: WireError.providerError(message: "quota exceeded")) {
    try OpenAIWire.textDelta(fromEventData: event)
  }
}
