import Foundation
import UWP
import WinUI

/// The messages of a conversation as the Mac draws them (`ConversationMessageCards.swift`, `SentUserMessage`,
/// `TranscriptErrorCard`): what the person sent as a gray bubble on the right, at most 472 wide with at least 96 before
/// it and no name over it, clipped past 20 lines with "Show more"; what another task, a background command or a
/// schedule sent on the left, under whose it is; a provider's message as its Markdown, "Commentary" over its working
/// notes; and the turn's error card. A message's copy shows while the pointer is over it or the copy has the
/// keyboard's focus, and keeps its place while hidden.
@MainActor
enum ConversationMessages {
    // MARK: - What was sent

    /// A sent message: the person's bubble, or on the left what another sender sent in their place.
    static func sent(_ item: ConversationItem, text: String, images: [TranscriptImageAttachment]) -> UIElement {
        if let notice = item.backgroundTaskNotice {
            // A background command's notice that started the turn: one line on the left, as the conversation's own
            // lines read.
            let line = ConversationStyle.row([
                ConversationStyle.icon(ConversationStyle.Glyph.gear, size: 12),
                ConversationStyle.text(notice.summary, size: ConversationStyle.calloutSize, tone: .secondary)
            ])
            try? AutomationProperties.setName(line, L10n.string("Background task"))
            return line
        }
        if let message = item.taskMessage {
            let stack = StackPanel()
            stack.spacing = 4
            let label = ConversationStyle.row([
                ConversationStyle.icon(ConversationStyle.Glyph.message, size: 11),
                ConversationStyle.text(message.senderLabel, size: ConversationStyle.captionSize, tone: .secondary,
                                       wraps: false)
            ], spacing: 4)
            label.margin = Thickness(left: 4, top: 2, right: 4, bottom: 2)
            stack.children.append(label)
            stack.children.append(received(text, clip: .sentMessage))
            for quote in message.quotes { stack.children.append(quoted(quote)) }
            try? AutomationProperties.setName(stack, message.senderLabel)
            return stack
        }
        return bubble(text, images: images, clip: .sentMessage, label: nil, accessibleName: L10n.string("You"))
    }

    /// A message a schedule sent in the person's place: a Codex app automation's as a bubble under "Sent by
    /// scheduled task", Claude Code's own schedule's on the left under the Claude app's words for it.
    static func scheduled(_ message: ConversationScheduledTaskMessage) -> UIElement {
        if let kind = message.claudeSchedule {
            let stack = StackPanel()
            stack.spacing = 4
            stack.children.append(scheduleLabel(kind.label))
            if !message.instructions.isEmpty {
                stack.children.append(received(message.instructions, clip: .scheduledTaskMessage))
            }
            try? AutomationProperties.setName(stack, kind.label)
            return stack
        }
        return bubble(message.instructions, images: [], clip: .scheduledTaskMessage,
                      label: scheduleLabel(L10n.string("Sent by scheduled task")),
                      accessibleName: L10n.string("Scheduled task"))
    }

    /// The bubble on the right, its images' names above it and its copy under it.
    private static func bubble(_ text: String, images: [TranscriptImageAttachment], clip: ConversationMessageClip,
                               label: UIElement?, accessibleName: String) -> UIElement {
        let column = StackPanel()
        column.spacing = 6
        column.horizontalAlignment = .right
        column.margin = Thickness(left: ConversationStyle.sentMessageLeadingSpace, top: 0, right: 0, bottom: 0)
        if let label {
            if let element = label as? FrameworkElement { element.horizontalAlignment = .right }
            column.children.append(label)
        }
        if !images.isEmpty { column.children.append(imageNames(images)) }
        if !text.isEmpty || images.isEmpty {
            let bubble = Border()
            bubble.background = WindowsTheme.selectedFill.brush
            bubble.cornerRadius = ConversationStyle.corners(ConversationStyle.sentBubbleCornerRadius)
            bubble.padding = ConversationStyle.sentBubblePadding
            bubble.maxWidth = ConversationStyle.sentBubbleMaximumWidth
            bubble.horizontalAlignment = .right
            bubble.child = clipped(text, clip: clip)
            column.children.append(bubble)
        }
        let area = Grid()
        // A fill, clear as it is, so the pointer is over the message across the row, as on the Mac.
        area.background = ConversationStyle.clear.brush
        area.children.append(column)
        if !text.isEmpty {
            let copy = ConversationStyle.copyButton(L10n.string("Copy message")) { text }
            copy.horizontalAlignment = .right
            column.children.append(copy)
            ConversationStyle.revealOnHover(copy, in: area)
        }
        try? AutomationProperties.setName(area, accessibleName)
        return area
    }

    /// A message another sender sent, in a quiet box on the left.
    private static func received(_ text: String, clip: ConversationMessageClip) -> UIElement {
        let box = Border()
        box.background = WindowsTheme.subtleFill.brush
        box.borderBrush = WindowsTheme.separator.brush
        box.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        box.cornerRadius = ConversationStyle.corners(ConversationStyle.sentBubbleCornerRadius)
        box.padding = ConversationStyle.sentBubblePadding
        box.child = clipped(text, clip: clip)
        return box
    }

    /// The person's own words that a sending task passed on: a quote under the message, whose and when.
    private static func quoted(_ quote: TaskMessage.Quote) -> UIElement {
        let words = StackPanel()
        words.spacing = 2
        words.children.append(ConversationStyle.text(quote.text))
        words.children.append(ConversationStyle.text(quote.label, size: ConversationStyle.captionSize, tone: .secondary))
        let bar = Border()
        bar.borderBrush = WindowsTheme.separator.brush
        bar.borderThickness = Thickness(left: 2, top: 0, right: 0, bottom: 0)
        bar.padding = Thickness(left: 8, top: 0, right: 0, bottom: 0)
        bar.margin = Thickness(left: 4, top: 2, right: 0, bottom: 0)
        bar.child = words
        return bar
    }

    private static func scheduleLabel(_ text: String) -> UIElement {
        let label = ConversationStyle.row([
            ConversationStyle.icon(ConversationStyle.Glyph.clock, size: 11),
            ConversationStyle.text(text, size: ConversationStyle.captionSize, tone: .secondary, wraps: false)
        ], spacing: 4)
        label.margin = Thickness(left: 4, top: 2, right: 4, bottom: 2)
        return label
    }

    /// The names of a message's images, each beside a picture mark, as the Mac names an image it cannot show.
    private static func imageNames(_ images: [TranscriptImageAttachment]) -> UIElement {
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 6
        row.horizontalAlignment = .right
        for image in images {
            let chip = Border()
            chip.background = WindowsTheme.subtleFill.brush
            chip.cornerRadius = ConversationStyle.corners(12)
            chip.padding = Thickness(left: 10, top: 4, right: 10, bottom: 4)
            chip.child = ConversationStyle.row([
                ConversationStyle.icon(ConversationStyle.Glyph.picture, size: 12),
                ConversationStyle.text(image.name ?? L10n.string("Image"), size: ConversationStyle.captionSize,
                                       tone: .secondary, wraps: false)
            ])
            row.children.append(chip)
        }
        return row
    }

    /// A sent message's words, clipped as the Codex app clips them (`ConversationMessageClip`): past its lines it
    /// shows its first ones and "Show more", which opens the whole message; "Show less" folds it again.
    private static func clipped(_ text: String, clip: ConversationMessageClip) -> UIElement {
        let words = ConversationStyle.text(text)
        words.lineHeight = ConversationStyle.lineHeight(ConversationStyle.bodySize)
        let prefix = clip.prefix(of: text)
        let stack = StackPanel()
        stack.spacing = 4
        stack.children.append(words)
        // The link's words change, not the link: its handler holds no Swift object of the link's own.
        let label = ConversationStyle.text("", size: ConversationStyle.captionSize, selectable: false, wraps: false)
        label.foreground = WindowsTheme.accent.brush
        let toggle = HyperlinkButton()
        toggle.padding = Thickness(left: 0, top: 0, right: 0, bottom: 0)
        toggle.content = label
        toggle.visibility = prefix.isWhole ? .collapsed : .visible
        stack.children.append(toggle)
        let state = ClipState()
        let fold = { (folded: Bool) in
            state.isFolded = folded
            words.text = folded ? prefix.text : text
            words.maxLines = folded ? Int32(clip.lineCount) : 0
            words.textTrimming = folded ? .characterEllipsis : .none
            label.text = L10n.string(folded ? "Show more" : "Show less")
        }
        fold(true)
        toggle.click.addHandler { _, _ in fold(!state.isFolded) }
        // A message of few lines that wraps past its lines clips too, which only its layout tells.
        words.isTextTrimmedChanged.addHandler { sender, _ in
            guard let sender, state.isFolded, prefix.isWhole else { return }
            toggle.visibility = sender.isTextTrimmed ? .visible : .collapsed
        }
        return stack
    }

    private final class ClipState {
        var isFolded = true
    }

    // MARK: - What the provider said

    /// A provider's message: its Markdown, "Commentary" over its working notes, and once it is written, its copy.
    static func agent(_ item: ConversationItem, text: String, isCommentary: Bool, isStreaming: Bool,
                      harness: HarnessKind) -> UIElement {
        let dialect = TranscriptMarkdownDialect(messagesOf: harness)
        let stack = StackPanel()
        stack.spacing = 8
        let body = StackPanel()
        body.spacing = 4
        if isCommentary || item.isSummary {
            var words: [String] = []
            if isCommentary { words.append(L10n.string("Commentary")) }
            if item.isSummary { words.append(L10n.string("Summarized")) }
            body.children.append(ConversationStyle.text(words.joined(separator: " · "), size: ConversationStyle.captionSize,
                                                        tone: .secondary))
        }
        body.children.append(MarkdownView.element(text, dialect: dialect))
        stack.children.append(body)
        let area = Grid()
        area.background = ConversationStyle.clear.brush
        area.children.append(stack)
        if !isStreaming {
            let copy = ConversationStyle.copyButton(L10n.string("Copy response")) { dialect.copyText(text) }
            stack.children.append(copy)
            ConversationStyle.revealOnHover(copy, in: area)
        }
        try? AutomationProperties.setName(area, harness.displayName)
        return area
    }

    // MARK: - The error card

    /// The turn's error card (the Mac's `TranscriptErrorCard`): its mark, a plain heading, the error's summary or
    /// what to do next, the actions the turn offers (`signIn` placed where they go, and Retry), and the whole error
    /// under "Error details" with its copy.
    static func errorCard(_ error: ConversationTurnError, harness: HarnessKind, retry: (@MainActor () -> Void)?,
                          signIn: SignInRow?) -> UIElement {
        let heading = ConversationStyle.text(
            TranscriptRecoveryProjection.errorCardTitle(error.title, message: error.message, harness: harness),
            size: ConversationStyle.calloutSize, semibold: true
        )
        let summary = ConversationStyle.text(TranscriptRecoveryProjection.errorCardSummary(error.message),
                                             size: ConversationStyle.calloutSize, tone: .secondary)
        let words = StackPanel()
        words.spacing = 5
        words.children.append(heading)
        words.children.append(summary)
        let mark = ConversationStyle.icon(ConversationStyle.Glyph.warning, size: 15, brush: ConversationStyle.red.solid.brush)
        mark.verticalAlignment = .top
        mark.margin = Thickness(left: 0, top: 1, right: 0, bottom: 0)
        let top = Grid()
        top.columnSpacing = 10
        for width in [GridLength(value: 0, gridUnitType: .auto), GridLength(value: 1, gridUnitType: .star)] {
            let column = ColumnDefinition()
            column.width = width
            top.columnDefinitions.append(column)
        }
        top.children.append(mark)
        try? Grid.setColumn(words, 1)
        top.children.append(words)

        let card = StackPanel()
        card.spacing = 10
        card.children.append(top)
        if let signIn { signIn.place(in: card) }
        if let retry {
            let row = ConversationStyle.row([ConversationStyle.grayButton(L10n.string("Retry"), action: retry)], spacing: 8)
            card.children.append(row)
        }
        card.children.append(errorDetails(error))

        let frame = Border()
        frame.padding = Thickness(left: 14, top: 14, right: 14, bottom: 14)
        frame.cornerRadius = ConversationStyle.corners(11)
        frame.background = ConversationStyle.red.opacity(0.035).brush
        frame.borderBrush = ConversationStyle.red.opacity(0.18).brush
        frame.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        frame.child = card
        try? AutomationProperties.setName(frame, heading.text)
        return frame
    }

    /// "Error details": whether the action or the session failed, the provider's whole text in the code font, and
    /// its copy.
    private static func errorDetails(_ error: ConversationTurnError) -> UIElement {
        let title = L10n.string("Error details")
        let message = error.message
        let recoverable = error.isRecoverable
        return ConversationWorkLines.statusLine(
            words: [ConversationLineWords(verb: title)], phase: .completed, name: title,
            size: ConversationStyle.captionSize, startsOpen: false,
            detail: {
                let stack = StackPanel()
                stack.spacing = 10
                stack.margin = Thickness(left: 0, top: 4, right: 0, bottom: 0)
                stack.children.append(ConversationStyle.text(
                    L10n.string(recoverable ? "Action failed" : "Session failed"),
                    size: ConversationStyle.captionSize, tone: .secondary, semibold: true
                ))
                stack.children.append(ConversationWorkLines.outputBox(message))
                stack.children.append(ConversationStyle.copyButton(L10n.string("Copy error details")) { message })
                return stack
            }
        )
    }
}
