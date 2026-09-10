import GazeKit
import Testing

@Test func markdownSegmentsSplitFencedCodeFromProse() {
  let text = "Look here:\n\n```swift\nlet x = 1\nlet y = 2\n```\n\nThat is all."

  let segments = markdownSegments(from: text)

  #expect(segments.count == 3)
  #expect(segments[0].isCode == false)
  #expect(segments[0].content == "Look here:\n")
  #expect(segments[1].kind == .code(language: "swift"))
  #expect(segments[1].content == "let x = 1\nlet y = 2")
  #expect(segments[2].isCode == false)
  #expect(segments[2].content == "\nThat is all.")
}

@Test func markdownSegmentsPreserveBlankLinesInProse() {
  let segments = markdownSegments(from: "First line.\n\nSecond line.")

  #expect(segments.count == 1)
  #expect(segments[0].content == "First line.\n\nSecond line.")
}

@Test func markdownSegmentsTreatUnclosedFenceAsCode() {
  let segments = markdownSegments(from: "Before\n```\nstill streaming")

  #expect(segments.count == 2)
  #expect(segments[0].content == "Before")
  #expect(segments[1].isCode == true)
  #expect(segments[1].content == "still streaming")
}

@Test func markdownSegmentIdentifiersComeFromSourcePosition() {
  let segments = markdownSegments(from: "Look here:\n\n```swift\nlet x = 1")

  #expect(segments.map(\.id) == [0, 21])
}

@Test func markdownSegmentIdentifiersStayStableAsTrailingTokenArrives() {
  let prefix = "Look here:\n\n```swift\nlet x = 1"
  let before = markdownSegments(from: prefix)
  let after = markdownSegments(from: prefix + "\nlet y = 2")

  #expect(after.count == before.count)
  #expect(after.map(\.id).prefix(before.count).elementsEqual(before.map(\.id)))
}

@Test func markdownSegmentIdentifiersStayStableWhenTrailingFenceOpens() {
  let before = markdownSegments(from: "Before\n``")
  let after = markdownSegments(from: "Before\n```")

  #expect(after.map(\.id).prefix(before.count).elementsEqual(before.map(\.id)))
}
