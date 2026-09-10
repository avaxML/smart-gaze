import Foundation

public struct MarkdownSegment: Identifiable, Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case prose
    case code(language: String?)
  }

  public let id: Int
  public let kind: Kind
  public let content: String

  public init(id: Int, kind: Kind, content: String) {
    self.id = id
    self.kind = kind
    self.content = content
  }

  public var isCode: Bool {
    if case .code = kind { return true }
    return false
  }
}

public func markdownSegments(from text: String) -> [MarkdownSegment] {
  var segments: [MarkdownSegment] = []
  var buffer: [String] = []
  var bufferStart: Int?
  var inCode = false
  var language: String?
  var offset = 0

  func flush(prose: Bool) {
    guard !buffer.isEmpty, let start = bufferStart else { return }
    let content = buffer.joined(separator: "\n")
    buffer.removeAll()
    bufferStart = nil
    segments.append(
      MarkdownSegment(
        id: start,
        kind: prose ? .prose : .code(language: language),
        content: content
      )
    )
  }

  for line in text.components(separatedBy: "\n") {
    defer { offset += line.count + 1 }
    if line.hasPrefix("```") {
      if inCode {
        flush(prose: false)
        inCode = false
        language = nil
      } else {
        flush(prose: true)
        let tag = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        language = tag.isEmpty ? nil : tag
        inCode = true
      }
    } else {
      if bufferStart == nil {
        bufferStart = offset
      }
      buffer.append(line)
    }
  }

  flush(prose: !inCode)
  return segments
}
