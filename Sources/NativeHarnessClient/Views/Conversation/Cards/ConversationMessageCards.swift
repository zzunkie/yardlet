import AppKit
import SwiftUI

// The messages of a conversation, one card each for every harness (D12, plan M12f): the sent bubble
// in Claude Code's shape (at most 472 pt wide, 10 pt corners, 12 × 8 pt inside; 2026-10-15) with at
// least 96 pt before it, clipped past 20 lines as the Codex app clips it, a provider's message as
// Markdown with "Show more" after 5,000 characters, a "Commentary" caption on its working notes and
// its copy action shown on hover or focus as Claude Code shows a message's actions, and the Codex
// reasoning summary row. A provider's own thinking is a status line (`ConversationWorkLine`). What
// the provider is doing while it has not written yet is the turn's status line ("Thinking"), not a
// label on its message.

/// What the person sent: the bubble, in the conversation font, which follows the interface
/// size setting (`ParityTheme.conversationFont(scale:)`). A long message clips as the Codex app clips
/// it (`ConversationMessageClip`). A message a scheduled task sent in the person's place (a Codex app
/// automation's heartbeat) reads "Sent by scheduled task" above a bubble of its instructions, clipped
/// to two lines; "Copy message" copies the whole text either way. A prompt Claude Code's own schedule
/// sent (`ClaudeScheduledPrompt`) is not the person's either: it reads on the left under the Claude
/// app's words for it, "Scheduled check-in" or "Scheduled task: {name}", clipped to two lines. A
/// message the Codex app wrote around the person's request shows the request, its attachments above
/// it and the mode it was sent in under it (`CodexUserPrompt`); "Copy message" copies the request, as
/// the app's copy does.
struct ConversationSentMessage: View {
    let itemID: String
    let text: String
    let images: [TranscriptImageAttachment]
    /// A scheduled task sent it, not the person.
    var isSentByScheduledTask = false
    /// Claude Code's own schedule sent it, which the Claude app draws as an event, not a bubble.
    var claudeSchedule: ClaudeScheduledPrompt.Kind? = nil
    /// The context the Codex app sent with the request that the message draws.
    var attachments: CodexPromptAttachments? = nil
    /// Another task sent it with `send_message`, not the person (`TaskMessage`).
    var sentFromTask: TaskMessage? = nil
    /// Claude Code started the turn with a background command's notice (`ClaudeTaskNotification`).
    var backgroundTaskNotice: ClaudeTaskNotification? = nil
    var phase: ConversationItemPhase = .completed
    var isHistoryMatch = false

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.taskSuggestionActions) private var taskActions

    var body: some View {
        if let backgroundTaskNotice {
            noticeOfBackgroundTask(backgroundTaskNotice)
        } else if let claudeSchedule {
            sentByClaudeSchedule(claudeSchedule)
        } else if let sentFromTask {
            receivedFromTask(sentFromTask)
        } else {
            sentByPerson
        }
    }

    /// A background command's notice that started the turn: one line on the left under "Background
    /// task", as the conversation's own lines read, not the person's bubble.
    private func noticeOfBackgroundTask(_ notice: ClaudeTaskNotification) -> some View {
        Label {
            Text(notice.summary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "gearshape.2")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ConversationMessageFrame(label: L10n.string("Background task"), phase: phase,
                                           isHistoryMatch: isHistoryMatch))
    }

    /// A message another task sent: not the person's, so not their bubble on the right. It reads as
    /// a note from that task, on the left where the conversation's own lines are, under "Sent from
    /// {task}" (2026-10-22: messages from child sessions looked like the person's own).
    private func receivedFromTask(_ message: TaskMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            taskMessageLabel(message)
            receivedText(clip: .sentMessage)
            ForEach(Array(message.quotes.enumerated()), id: \.offset) { _, quote in
                quotedWords(quote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ConversationMessageFrame(label: Self.senderLabel(message), phase: phase,
                                           isHistoryMatch: isHistoryMatch))
    }

    /// A prompt Claude Code's own schedule sent: on the left like another sender's note, under the
    /// Claude app's words for it and its clock, with the prompt clipped to two lines as a scheduled
    /// task's message is (2026-10-22: a check-in had read as the person's message, folded into the
    /// turn before).
    private func sentByClaudeSchedule(_ kind: ClaudeScheduledPrompt.Kind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 11 * interfaceScale))
                    .accessibilityHidden(true)
                Text(Self.scheduleLabel(kind))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 12 * interfaceScale))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            if !text.isEmpty {
                receivedText(clip: .scheduledTaskMessage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ConversationMessageFrame(label: Self.scheduleLabel(kind), phase: phase,
                                           isHistoryMatch: isHistoryMatch))
    }

    /// The Claude app's words for what its schedule sent: "Scheduled check-in" for a `CronCreate` job
    /// or a `/loop` wakeup, "Scheduled task: {name}" for a named scheduled task.
    static func scheduleLabel(_ kind: ClaudeScheduledPrompt.Kind) -> String {
        switch kind {
        case .checkIn: L10n.string("Scheduled check-in")
        case let .task(name): L10n.format("Scheduled task: %@", name)
        }
    }

    /// A message someone other than the person sent, in a quiet box on the left.
    private func receivedText(clip: ConversationMessageClip) -> some View {
        ConversationClippedSentText(itemID: itemID, text: text, clip: clip)
            .padding(ConversationLayout.sentBubblePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ParityTheme.subtleFill.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: ConversationLayout.sentBubbleCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ConversationLayout.sentBubbleCornerRadius)
                    .strokeBorder(ParityTheme.separator, lineWidth: 1)
            }
            .contextMenu {
                Button(L10n.string("Copy message")) {
                    TranscriptClipboard.copy(text)
                }
            }
    }

    /// The person's own words the sending task passed on, as Yardlet found them in that task: a quote
    /// under the message, with whose they are and when.
    private func quotedWords(_ quote: TaskMessage.Quote) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(ParityTheme.separator)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(quote.label)
                    .font(.system(size: 12 * interfaceScale))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 4)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sentByPerson: some View {
        let imagePaths = images.compactMap { $0.url?.isFileURL == true ? $0.url?.path(percentEncoded: false) : nil }
        let drawsChips = attachments.map { CodexPromptAttachmentRow.drawsChips($0, imagePaths: imagePaths) } ?? false
        return VStack(alignment: .trailing, spacing: 4) {
            if isSentByScheduledTask {
                scheduledTaskLabel
            }
            SentUserMessage(copyText: text, images: images, minimumLeadingSpace: ConversationLayout.sentMessageLeadingSpace) {
                VStack(alignment: .trailing, spacing: 6) {
                    if drawsChips, let attachments {
                        CodexPromptAttachmentRow(attachments: attachments, imagePaths: imagePaths)
                    }
                    // The Codex app draws a scheduled task's label alone when it asked for nothing, and a
                    // request with nothing typed as its attachments alone.
                    if isSentByScheduledTask ? !text.isEmpty : (!text.isEmpty || (images.isEmpty && !drawsChips)) {
                        ConversationClippedSentText(
                            itemID: itemID, text: text,
                            clip: isSentByScheduledTask ? .scheduledTaskMessage : .sentMessage
                        )
                        .padding(ConversationLayout.sentBubblePadding)
                        .background(ParityTheme.selectedFill,
                                    in: RoundedRectangle(cornerRadius: ConversationLayout.sentBubbleCornerRadius))
                        .frame(maxWidth: ConversationLayout.sentBubbleMaximumWidth, alignment: .trailing)
                    }
                    if let modes = attachments?.modes, !modes.isEmpty {
                        CodexPromptModes(modes: modes)
                    }
                }
            }
        }
        .modifier(ConversationMessageFrame(
            label: isSentByScheduledTask ? L10n.string("Scheduled task") : L10n.string("You"),
            phase: phase, isHistoryMatch: isHistoryMatch
        ))
    }

    /// "Sent from {task}" above a message another task sent; it opens that task while it is there.
    static func senderLabel(_ message: TaskMessage) -> String {
        message.senderName.map { L10n.format("Sent from %@", $0) } ?? L10n.string("Sent from another task")
    }

    @ViewBuilder
    private func taskMessageLabel(_ message: TaskMessage) -> some View {
        let label = HStack(spacing: 4) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 11 * interfaceScale))
                .accessibilityHidden(true)
            Text(Self.senderLabel(message))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12 * interfaceScale))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        if let id = UUID(uuidString: message.senderID), let taskActions, let open = taskActions.openTask,
           taskActions.canOpenTask(id) {
            Button { open(id) } label: { label }
                .buttonStyle(.plain)
                .help(L10n.string("Open the task that sent this message"))
                .accessibilityHint(L10n.string("Opens the task that sent this message"))
        } else {
            label
        }
    }

    /// The Codex app's label above a scheduled task's message: its clock and "Sent by scheduled task".
    /// In the app it opens the task's panel; Yardlet has no such panel, so it only reads.
    private var scheduledTaskLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 11 * interfaceScale))
                .accessibilityHidden(true)
            Text(L10n.string("Sent by scheduled task"))
        }
        .font(.system(size: 12 * interfaceScale))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
}

/// A sent message's words, clipped as the Codex app clips them (`ConversationMessageClip`): past its
/// line count it shows its first lines, an ellipsis line and "Show more" under them; "Show less" folds
/// it again. Opening it is like opening a card: it does not stop following the latest output. Find's
/// current match in a folded message opens it.
private struct ConversationClippedSentText: View {
    let itemID: String
    let text: String
    let clip: ConversationMessageClip

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.conversationFind) private var find
    @State private var isExpanded = false
    /// The shown text's height laid out whole.
    @State private var height: CGFloat = 0
    /// The folded text's height at `clip.lineCount` lines, and at the lines a folded message shows.
    @State private var heightAtLineCount: CGFloat = 0
    @State private var heightAtVisibleLines: CGFloat = 0

    var body: some View {
        let prefix = clip.prefix(of: text)
        let clips = clip.clips(isWhole: prefix.isWhole, height: height, heightAtLineCount: heightAtLineCount)
        let isFolded = clips && !isExpanded
        VStack(alignment: .leading, spacing: 0) {
            words(isExpanded ? text : prefix.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .frame(height: isFolded && heightAtVisibleLines > 0 ? heightAtVisibleLines : nil, alignment: .top)
                .clipped()
                .background(alignment: .topLeading) {
                    if !isExpanded { measurements(prefix.text) }
                }
            if isFolded, clip.showsEllipsisLine {
                // A line of the text's own: the same space above it as between its lines.
                Text(verbatim: "…")
                    .font(ParityTheme.conversationFont(scale: interfaceScale))
                    .padding(.top, ParityTheme.proseLineSpacing * interfaceScale)
                    .accessibilityHidden(true)
            }
            if clips {
                toggle
                    .padding(.top, 6)
            }
        }
        .onChange(of: find?.slot(for: .unit(itemID)).active, initial: true) { _, active in
            if active != nil, !isExpanded,
               clip.clips(isWhole: prefix.isWhole, height: height, heightAtLineCount: heightAtLineCount) {
                isExpanded = true
            }
        }
    }

    private func words(_ shown: String) -> some View {
        TranscriptPlainText(text: shown)
            .environment(\.conversationFindSlot, find?.slot(for: .unit(itemID)))
    }

    /// The folded text laid out at its line limits, unseen, at the width the shown text has. Find's
    /// marks only colour the text, so the copies leave them (and the match's scroll target) out.
    private func measurements(_ folded: String) -> some View {
        ZStack(alignment: .topLeading) {
            measured(folded, lines: clip.lineCount) { heightAtLineCount = $0 }
            measured(folded, lines: clip.visibleLineCount) { heightAtVisibleLines = $0 }
        }
        .hidden()
        .accessibilityHidden(true)
    }

    private func measured(_ folded: String, lines: Int, action: @escaping (CGFloat) -> Void) -> some View {
        Text(verbatim: folded)
            .font(ParityTheme.conversationFont(scale: interfaceScale))
            .lineSpacing(ParityTheme.proseLineSpacing * interfaceScale)
            .lineLimit(lines)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: action)
    }

    private var toggle: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(isExpanded ? L10n.string("Show less of a sent message") : L10n.string("Show more"))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9 * interfaceScale, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(ParityTheme.conversationFont(scale: interfaceScale))
        .foregroundStyle(.secondary)
        .parityPointer()
    }
}

/// A provider's message: its answer, or the working notes it writes along the way ("Commentary").
/// It reads the same for every harness; the provider's name labels it for assistive apps. A Codex
/// message also draws the directives the Codex app draws (`CodexMessageDirectives`).
struct ConversationAgentMessage: View {
    let itemID: String
    let harness: HarnessKind
    let text: String
    let isCommentary: Bool
    let isStreaming: Bool
    /// A message phase the provider sent that Yardlet does not know (Codex), named above the text.
    var providerPhase: String? = nil
    /// Only a summary of what the provider wrote came (`ConversationItem.isSummary`), marked above it.
    var isSummary = false
    var phase: ConversationItemPhase = .completed
    /// "Copy item details" in the message's context menu (Codex's item handoff).
    var copyDetails: String? = nil
    var isHistoryMatch = false

    @Environment(\.conversationFind) private var find
    /// The turn's fork, when this is the turn's answer (`ConversationTurnAction`).
    @Environment(\.conversationMessageActions) private var messageActions
    @Environment(\.conversationStreamedText) private var streamedText

    private var dialect: TranscriptMarkdownDialect { TranscriptMarkdownDialect(messagesOf: harness) }

    /// The words so far: a message being written takes the fragments its turn streamed since the
    /// turn was last drawn whole (`ConversationStreamedText`), and its details copy them.
    private var streamed: ConversationStreamedText.Message? {
        isStreaming ? streamedText?.message(for: itemID) : nil
    }

    private var shownText: String { streamed?.text ?? text }

    private var shownCopyDetails: String? { streamed.map(\.copyDetails) ?? copyDetails }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if isCommentary || isSummary {
                    label
                } else if let providerPhase {
                    Text(providerPhase)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                TranscriptMarkdownText(text: shownText, characterLimit: ConversationLayout.messageCharacterLimit,
                                       dialect: dialect)
                    .environment(\.conversationFindSlot, find?.slot(for: .unit(itemID)))
                    .environment(\.transcriptCopyDetails, shownCopyDetails)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !isStreaming {
                // A Codex message copies as the Codex app copies it (`CodexMessageDirectives.copyText`).
                // Its actions show on hover or focus, as Claude Code shows a message's actions.
                HStack(spacing: 12) {
                    HoverRevealedAction {
                        TranscriptCopyButton(title: L10n.string("Copy response")) { dialect.copyText(text) }
                    }
                    ConversationMessageActionButtons(actions: messageActions)
                }
            }
        }
        .modifier(RevealsActionsOnHover())
        .padding(.vertical, 2)
        .contextMenu {
            if let copyDetails = shownCopyDetails {
                Button(L10n.string("Copy item details")) { TranscriptClipboard.copy(copyDetails) }
            }
        }
        .modifier(ConversationMessageFrame(label: harness.displayName, phase: phase, isHistoryMatch: isHistoryMatch))
        // The message's own actions, for an assistive app wherever its focus is in the message.
        .accessibilityActions {
            if !isStreaming {
                Button(L10n.string("Copy response")) { TranscriptClipboard.copy(dialect.copyText(text)) }
                ForEach(messageActions) { action in
                    Button(action.title, action: action.perform)
                }
            }
        }
    }

    /// "Commentary" over working notes, and "Summarized" over words of which only a summary came, as
    /// Claude Code's terminal follows such a note with "summarized".
    private var label: some View {
        let words = [isCommentary ? L10n.string("Commentary") : nil, isSummary ? L10n.string("Summarized") : nil]
            .compactMap { $0 }
        return HStack(spacing: 4) {
            if isCommentary {
                Text(L10n.string("Commentary"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if isSummary {
                if isCommentary { Text(verbatim: "·").font(.caption2).foregroundStyle(.tertiary) }
                Text(L10n.string("Summarized"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(L10n.string("A summary that came as thinking. Claude's own wording did not come through."))
            }
        }
        .conversationSelectionText(words.joined(separator: " · "))
    }
}

/// A reasoning summary the provider wrote to be read (Codex), in the reasoning row, its raw
/// reasoning folded under "Thought process". Reasoning without a summary (Codex's raw content,
/// Claude Code's thinking) is a status line (`ConversationWorkLine`).
struct ConversationReasoningCard: View {
    let summary: String
    let detail: String?
    var phase: ConversationItemPhase = .completed
    var copyDetails: String? = nil
    var isHistoryMatch = false

    var body: some View {
        ConversationCodexActivityRow(
            title: L10n.string("Reasoning"), symbolName: "brain", phase: phase, isApproved: false,
            copyDetails: copyDetails, isHistoryMatch: isHistoryMatch
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let detail {
                    ReasoningCard(text: detail, isStreaming: false)
                }
            }
        }
    }
}

/// The frame every message sits in: a little room above and below, the history match's tint, and
/// one element for assistive apps named for who wrote it, valued by its phase.
private struct ConversationMessageFrame: ViewModifier {
    let label: String
    let phase: ConversationItemPhase
    let isHistoryMatch: Bool

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 2)
            .background(isHistoryMatch ? ParityTheme.accent.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
            .accessibilityValue(ConversationActivityAccessibility.value(phase: phase, isHistoryMatch: isHistoryMatch))
    }
}
