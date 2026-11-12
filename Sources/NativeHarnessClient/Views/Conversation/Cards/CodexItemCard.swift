import SwiftUI

/// What only Codex sends, drawn by the card its record has (`ConversationItemSource`): a proposed
/// plan and a notice. Every other item is drawn from its normalized kind (`ConversationItemView`).
struct CodexItemCard: View {
    let item: CodexItemState
    let isTurnFinished: Bool
    let historyMatch: Bool

    var body: some View {
        Group {
            switch item.content {
            case let .plan(text):
                CodexProposedPlanCard(
                    text: text,
                    isWriting: item.lifecycle == .inProgress && !isTurnFinished
                )
            case let .notice(notice):
                CodexNoticeRow(notice: notice)
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
        .background(
            historyMatch ? ParityTheme.accent.opacity(0.055) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(
            [lifecycleLabel, historyMatch ? L10n.string("History match") : nil]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }

    private var title: String {
        if case .notice = item.content { return L10n.string("Notice") }
        return L10n.string("Plan step")
    }

    private var lifecycleLabel: String {
        switch item.lifecycle {
        case .historical: L10n.string("Completed")
        case .inProgress: L10n.string("In progress")
        case .completed: L10n.string("Completed")
        }
    }
}


struct CodexBoundedOutput: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    let text: String
    var characterLimit: Int = 2_400
    var monospaced = true
    @State private var isExpanded = false

    var body: some View {
        let window = TranscriptCodeWindow(text, lineLimit: 12, characterLimit: characterLimit)
        VStack(alignment: .leading, spacing: 5) {
            if isExpanded && window.isTruncated {
                TranscriptTextReader(text: text, fontSize: (monospaced ? 11 : 13.5) * interfaceScale,
                                     accessibilityLabel: L10n.string("Output"), monospaced: monospaced)
                    .frame(height: 280 * interfaceScale)
            } else {
                Text(window.text)
                    .font(.system(
                        size: (monospaced ? 11 : 13.5) * interfaceScale,
                        design: monospaced ? .monospaced : .default
                    ))
                    .foregroundStyle(monospaced ? Color.secondary : Color.primary)
                    .lineSpacing(monospaced ? 0 : 3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if window.isTruncated {
                Button(
                    isExpanded
                        ? L10n.string("Show less")
                        : L10n.format("Show more (%lld characters)", Int64(text.count))
                ) {
                    isExpanded.toggle()
                }
                .buttonStyle(.link)
                .parityPointer()
                .font(.caption2)
            }
        }
        .padding(monospaced ? 8 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            monospaced ? ParityTheme.subtleFill : .clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
    }

}

/// A command's output, ending at its latest line. While the command runs, the newest lines
/// stream in pinned to the bottom of the box, as in the Codex app's output box; a finished
/// command keeps the same bounded tail and offers the whole output in a reader.
struct CodexCommandOutput: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.yardletCodeFont) private var codeFont
    let text: String
    let isRunning: Bool
    /// The command that wrote it, offered to copy beside it where the card does not show it.
    var command: String? = nil

    /// The command, when the card does not show it on its own, and all of the output, not the lines
    /// shown: the Codex app's "Copy command" and "Copy output".
    private var copies: [HoverCopyItem] {
        var copies: [HoverCopyItem] = []
        if let command {
            copies.append(HoverCopyItem(title: L10n.string("Copy command"), systemName: "terminal") { command })
        }
        let output = text
        copies.append(HoverCopyItem(title: L10n.string("Copy output"), systemName: "doc.on.doc") { output })
        return copies
    }
    @State private var showsAll = false

    var body: some View {
        let window = CodexCommandOutputWindow(text)
        VStack(alignment: .leading, spacing: 5) {
            if showsAll && !isRunning && window.isTruncated {
                TranscriptTextReader(text: text, fontSize: 11 * interfaceScale,
                                     accessibilityLabel: L10n.string("Output"), monospaced: true)
                    .frame(height: 280 * interfaceScale)
            } else {
                Text(window.text)
                    .font(codeFont.font(ofSize: codeFont.size(11, scale: interfaceScale)))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The reader opens once the command ends; until then its output is still arriving.
            if !isRunning && window.isTruncated {
                Button(
                    showsAll
                        ? L10n.string("Show less")
                        : L10n.format("Show more (%lld characters)", Int64(text.count))
                ) {
                    showsAll.toggle()
                }
                .buttonStyle(.link)
                .parityPointer()
                .font(.caption2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 7))
        .hoverCopy(copies)
    }
}

/// Copy icons at a box's top trailing corner while the pointer is over it, as the Claude and Codex
/// apps put "Copy command" and "Copy output" on a command; assistive apps reach them as actions.
struct HoverCopyItem {
    let title: String
    let systemName: String
    let payload: () -> String
}

private struct HoverCopy: ViewModifier {
    let items: [HoverCopyItem]
    @Environment(\.revealsSentMessageActions) private var revealsActions
    @State private var isHovering = false
    @State private var copied: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if isHovering || revealsActions {
                    HStack(spacing: 2) {
                        ForEach(items, id: \.title) { item in
                            Button {
                                copied = TranscriptClipboard.copy(item.payload()) ? item.title : nil
                            } label: {
                                Image(systemName: copied == item.title ? "checkmark" : item.systemName)
                                    .font(.system(size: 10, weight: .medium))
                                    .frame(width: 22, height: 22)
                                    .background(ParityTheme.elevated, in: RoundedRectangle(cornerRadius: 5))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .parityPointer()
                            .accessibilityLabel(item.title)
                            .help(copied == item.title ? L10n.string("Copied") : item.title)
                        }
                    }
                    .padding(3)
                }
            }
            .onHover { hovering in
                isHovering = hovering
                if !hovering { copied = nil }
            }
    }
}

extension View {
    /// Offers what `items` copy from this box while the pointer is over it.
    func hoverCopy(_ items: [HoverCopyItem]) -> some View {
        modifier(HoverCopy(items: items))
    }

    func hoverCopy(_ title: String, systemName: String = "doc.on.doc", payload: @escaping () -> String) -> some View {
        hoverCopy([HoverCopyItem(title: title, systemName: systemName, payload: payload)])
    }
}

/// The end of a command's output that its card shows: the latest lines, not the first ones.
struct CodexCommandOutputWindow: Equatable {
    let text: String
    let isTruncated: Bool

    init(_ source: String, lineLimit: Int = 12, characterLimit: Int = 2_400) {
        // A trailing line break ends the last line; it does not start an empty one.
        var end = source.endIndex
        if end > source.startIndex, source[source.index(before: end)].isNewline {
            end = source.index(before: end)
        }
        var start = end
        var lines = 1
        var characters = 0
        while start > source.startIndex, characters < characterLimit {
            let previous = source.index(before: start)
            if source[previous].isNewline {
                guard lines < lineLimit else { break }
                lines += 1
            }
            characters += 1
            start = previous
        }
        text = String(source[start..<end])
        isTruncated = start > source.startIndex
    }
}
