import SwiftUI

// The cards a Codex message's directives draw inside the message, after the Codex app's own
// (`CodexMessageDirectives`). A file citation needs no card: it
// is a link in the text, which the window opens in the task's file viewer like any file link.

private struct StartSuggestedTaskKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (String) -> Void)? = nil
}

extension EnvironmentValues {
    /// Opens a new task whose composer holds a suggested task's prompt ("Use suggestion"). Nil where
    /// the conversation cannot start a task, and the card then offers nothing.
    var startSuggestedTask: (@MainActor @Sendable (String) -> Void)? {
        get { self[StartSuggestedTaskKey.self] }
        set { self[StartSuggestedTaskKey.self] = newValue }
    }
}

/// `task-stub`: "Suggested task" over the task's title, and "Use suggestion", which in the Codex app
/// opens a new thread with the prompt in its composer (`qol`). Yardlet opens a new task the same way.
struct CodexSuggestedTaskCard: View {
    let task: CodexSuggestedTask

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.startSuggestedTask) private var startSuggestedTask

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("Suggested task"))
                    .font(.system(size: 13 * interfaceScale))
                    .foregroundStyle(.tertiary)
                if !task.title.isEmpty {
                    Text(task.title)
                        .font(.system(size: 13 * interfaceScale, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let startSuggestedTask {
                let prompt = task.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                Button(L10n.string("Use suggestion")) { startSuggestedTask(prompt) }
                    .buttonStyle(.bordered)
                    .font(.system(size: 13 * interfaceScale))
                    .parityPointer()
            }
        }
        .padding(12)
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius))
        .overlay { RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius).stroke(ParityTheme.strongSeparator) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Suggested task"))
    }
}

/// `github-details`: a disclosure of Markdown under its summary, open from the start when it says so
/// (`Hol`). Find's current match inside it opens it, as the app reveals one.
struct CodexDetailsBlock<Content: View>: View {
    let summary: String
    let path: [Int]
    @ViewBuilder let content: () -> Content

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.conversationFindSlot) private var findSlot
    @State private var isOpen: Bool

    init(summary: String, startsOpen: Bool, path: [Int], @ViewBuilder content: @escaping () -> Content) {
        self.summary = summary
        self.path = path
        self.content = content
        _isOpen = State(initialValue: startsOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isOpen.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    DisclosureCaret(isOpen: isOpen, size: 9 * interfaceScale, weight: .semibold)
                        .centeredOnCapHeight(ofTextSize: 14 * interfaceScale)
                    TranscriptInlineMarkdownText(
                        text: TranscriptInlineContent(plainText: summary),
                        font: ParityTheme.conversationFont(scale: interfaceScale).weight(.medium),
                        findKey: .block(path)
                    )
                    .textSelection(.disabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .parityPointer()
            .accessibilityLabel(summary)
            .accessibilityValue(isOpen ? L10n.string("Expanded") : L10n.string("Collapsed"))
            if isOpen {
                content()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius))
        .overlay { RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius).stroke(ParityTheme.separator) }
        .onChange(of: findSlot?.active, initial: true) { _, active in
            if let active, holds(active.key) { isOpen = true }
        }
    }

    /// The match sits in the Markdown inside the disclosure.
    private func holds(_ key: ConversationFindSegmentKey) -> Bool {
        switch key {
        case let .block(inner), let .cell(inner, _, _): inner.count > path.count && inner.starts(with: path)
        case .text: false
        }
    }
}

/// `code-comment` lines: the review comments the model left, in a card that counts them and lists
/// the first three, each with its priority, title and place, and opens the rest on request (`bb`, `rb`).
/// A comment opens its file at its line in the task's file viewer; the Codex app opens it on the
/// diff, which Yardlet's review panel does not annotate. Hovering a comment shows its words.
struct CodexReviewCommentsCard: View {
    let comments: [CodexReviewComment]

    /// The comments shown before "Show more" (`hb`).
    static let foldedCount = 3

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.transcriptWorkspaceURL) private var workspaceURL
    @Environment(\.openURL) private var openURL
    @State private var isExpanded = false

    var body: some View {
        let shown = isExpanded ? comments : Array(comments.prefix(Self.foldedCount))
        let count = comments.count == 1 ? L10n.string("1 comment") : L10n.format("%lld comments", comments.count)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 13 * interfaceScale))
                    .foregroundStyle(.secondary)
                    .frame(width: 28 * interfaceScale, height: 28 * interfaceScale)
                    .background(ParityTheme.selectedFill, in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                Text(count)
                    .font(ParityTheme.conversationFont(scale: interfaceScale).weight(.medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            ForEach(Array(shown.enumerated()), id: \.offset) { _, comment in
                Rectangle().fill(ParityTheme.separator).frame(height: 1)
                row(comment)
            }
            if comments.count > Self.foldedCount {
                Rectangle().fill(ParityTheme.separator).frame(height: 1)
                toggle(hidden: comments.count - shown.count)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius))
        .overlay { RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius).stroke(ParityTheme.separator) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(count)
    }

    private func row(_ comment: CodexReviewComment) -> some View {
        let location = comment.location(relativeTo: workspaceURL)
        return Button {
            if let link = comment.link(relativeTo: workspaceURL) { openURL(link) }
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let priority = comment.priority {
                        Text(priority)
                            .font(.system(size: 11 * interfaceScale, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .overlay { RoundedRectangle(cornerRadius: 4).stroke(ParityTheme.strongSeparator) }
                    }
                }
                .frame(width: 32 * interfaceScale)
                Text(comment.title)
                    .font(ParityTheme.conversationFont(scale: interfaceScale).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text(location)
                    .font(ParityTheme.conversationFont(scale: interfaceScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(minWidth: 96, maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .frame(height: 36 * interfaceScale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .help(comment.body)
        .accessibilityLabel(L10n.format("View %@ in %@", comment.title, location))
        .conversationLinkMenu(comment.link(relativeTo: workspaceURL))
    }

    private func toggle(hidden: Int) -> some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(isExpanded
                     ? L10n.string("Collapse comments")
                     : hidden == 1 ? L10n.string("Show 1 more comment") : L10n.format("Show %lld more comments", hidden))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9 * interfaceScale, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .font(ParityTheme.conversationFont(scale: interfaceScale))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 36 * interfaceScale, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .parityPointer()
    }
}

/// `codex-inline-vis`: the Codex app runs the visualization's HTML in the conversation (`Erl`). Yardlet
/// has no such runtime, so it names the visualization and says it cannot show it here, in the Codex
/// CLI's words for the same case; there is nothing to open.
struct CodexVisualizationCard: View {
    let visualization: CodexVisualization

    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 13 * interfaceScale))
                .foregroundStyle(.secondary)
                .frame(width: 28 * interfaceScale, height: 28 * interfaceScale)
                .background(ParityTheme.selectedFill, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(visualization.title)
                    .font(ParityTheme.conversationFont(scale: interfaceScale).weight(.medium))
                    .lineLimit(2)
                Text(L10n.string("Visualization unavailable on this device."))
                    .font(.system(size: 12 * interfaceScale))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius))
        .overlay { RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius).stroke(ParityTheme.separator) }
        .accessibilityElement(children: .contain)
    }
}
