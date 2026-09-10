import GazeKit
import SwiftUI

struct BubbleView: View {
  let state: BubbleState
  let onCopy: () -> Void
  let onTogglePin: () -> Void
  let onToggleExpand: () -> Void
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      content
      Divider().opacity(0.25)
      actions
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Explanation bubble")
  }

  private var header: some View {
    HStack(spacing: 8) {
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .bold))
          .frame(width: 20, height: 20)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Close")
      .accessibilityLabel("Close")

      Text("Explanation")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      Spacer(minLength: 0)

      if state.isPinned {
        Image(systemName: "pin.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Pinned")
      }
    }
  }

  @ViewBuilder private var content: some View {
    if let errorMessage = state.errorMessage {
      ScrollView {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .font(.callout)
          .foregroundStyle(.primary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    } else if state.isStreaming, state.text.isEmpty {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Reading the screen…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      .accessibilityLabel("Waiting for explanation")
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(markdownSegments(from: state.text)) { segment in
            segmentView(segment)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
      }
    }
  }

  @ViewBuilder private func segmentView(_ segment: MarkdownSegment) -> some View {
    if segment.isCode {
      Text(segment.content)
        .font(.system(.callout, design: .monospaced))
        .foregroundStyle(.primary)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    } else {
      Text(attributed(segment.content))
        .font(.callout)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func attributed(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
  }

  private var actions: some View {
    HStack(spacing: 6) {
      actionButton("Copy", systemImage: "doc.on.doc", action: onCopy)
      actionButton(
        state.isExpanded ? "Collapse" : "Expand",
        systemImage: state.isExpanded
          ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
        action: onToggleExpand
      )
      actionButton(
        state.isPinned ? "Unpin" : "Pin", systemImage: state.isPinned ? "pin.fill" : "pin",
        action: onTogglePin)
      Spacer(minLength: 0)
    }
  }

  private func actionButton(_ label: String, systemImage: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 13, weight: .medium))
        .frame(minWidth: 30, minHeight: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(label)
    .accessibilityLabel(label)
  }
}
