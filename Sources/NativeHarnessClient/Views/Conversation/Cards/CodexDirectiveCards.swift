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

/// `codex-inline-vis` where its page could not be drawn (`CodexVisualizationView`): the visualization's name and,
/// in the Codex CLI's words for the same case, that it cannot be shown here, with a way to try again and its file.
struct CodexVisualizationCard: View {
    let visualization: CodexVisualization
    /// Draws it again, where it could be drawn and was not.
    var retry: (() -> Void)? = nil
    /// Opens its file in the Files panel.
    var openFile: (() -> Void)? = nil

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
            if let retry {
                Button(L10n.string("Show view again"), action: retry)
                    .parityLinkButton()
                    .font(.system(size: 12 * interfaceScale))
            }
            if let openFile {
                Button(L10n.string("Open file"), action: openFile)
                    .parityLinkButton()
                    .font(.system(size: 12 * interfaceScale))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius))
        .overlay { RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius).stroke(ParityTheme.separator) }
        .accessibilityElement(children: .contain)
    }
}

private struct TranscriptItemIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The conversation item whose Markdown is drawn below, which a visualization's page is kept by while its message
    /// streams.
    var transcriptItemID: String? {
        get { self[TranscriptItemIDKey.self] }
        set { self[TranscriptItemIDKey.self] = newValue }
    }
}

/// What the task's area gives a conversation to put words in its composer after what is typed there, without sending
/// them: a Codex visualization's follow-up. A conversation without a composer of its own has none. Equal while it is
/// there or not, as `TranscriptTerminalRun` is, so the area's redraws leave the conversation alone.
struct TranscriptComposerDraft: Equatable {
    var draft: (@MainActor (String) -> Void)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.draft == nil) == (rhs.draft == nil)
    }
}

private struct TranscriptComposerDraftKey: EnvironmentKey {
    static let defaultValue = TranscriptComposerDraft()
}

extension EnvironmentValues {
    var transcriptComposerDraft: TranscriptComposerDraft {
        get { self[TranscriptComposerDraftKey.self] }
        set { self[TranscriptComposerDraftKey.self] = newValue }
    }
}

/// A Codex inline visualization drawn in the conversation, as the Codex app draws it: the page the model wrote, in
/// the sandbox MCP App views use (`MCPAppViewController.startVisualization`), as tall as it reports up to a limit and
/// scrolling inside past it. A placeholder keeps its place until it is live; one that cannot be drawn is its card.
/// "Expand visualization" on hover moves the same page into a sheet as wide as the skill's wide layout, as a table
/// expands, so what the person chose in it stays.
struct CodexVisualizationView: View {
    let visualization: CodexVisualization
    /// The row's identity across redraws.
    let key: String
    /// A `show_widget` call's view, drawn from its HTML rather than a file (docs/CONVERSATION_MEDIA.md, "Views from
    /// other harnesses"); `visualization` then only names it.
    var widget: ConversationWidget? = nil

    init(visualization: CodexVisualization, key: String) {
        self.visualization = visualization
        self.key = key
    }

    init(widget: ConversationWidget, key: String) {
        self.visualization = CodexVisualization(title: widget.title.isEmpty ? L10n.string("Visualization") : widget.title,
                                                file: "")
        self.key = key
        self.widget = widget
    }

    /// Past this the page scrolls inside, so one tall page does not push the conversation away.
    static let maximumHeight: CGFloat = 1_200

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.transcriptWorkspaceURL) private var workspaceURL
    @Environment(\.transcriptComposerDraft) private var composerDraft
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.pauseTranscriptFollowing) private var pauseFollowing
    @Environment(\.revealsSentMessageActions) private var revealsActions
    @State private var isHovering = false
    @State private var isExpanded = false
    @State private var focusBookmark: WindowFocusBookmark?

    var body: some View {
        let controller = MCPAppViewPool.shared.controller(key)
        let display = controller.display
        if display.state == .failed {
            CodexVisualizationCard(visualization: visualization, retry: { controller.retry() },
                                   openFile: widget == nil ? fileURL.map { url in { openURL(url) } } : nil)
        } else {
            MCPAppContainer(key: key, controller: controller, start: { [visualization, widget, key, workspaceURL] in
                let isDark = colorScheme == .dark
                if let widget {
                    controller.startWidget(widget, key: key, isDark: isDark, maximumHeight: Self.maximumHeight,
                                           openLink: { url in openURL(url) }, followUp: composerDraft.draft)
                } else {
                    controller.startVisualization(visualization, key: key, workspace: workspaceURL, isDark: isDark,
                                                  maximumHeight: Self.maximumHeight, openLink: { url in openURL(url) },
                                                  followUp: composerDraft.draft)
                }
            })
            .frame(maxWidth: .infinity)
            .frame(height: display.state == .live || display.state == .parked ? display.height : 240)
            .background(ParityTheme.subtleFill.opacity(display.state == .live && !isExpanded ? 0 : 1))
            .overlay {
                if display.state != .live {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(L10n.string("Loading"))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topTrailing) {
                // In the corner the skill keeps clear for the host's controls.
                if display.state == .live, isHovering || revealsActions, !isExpanded {
                    TranscriptBlockButton(systemName: "arrow.up.left.and.arrow.down.right",
                                          title: L10n.string("Expand visualization"), action: expand)
                        .padding(4)
                        .background(ParityTheme.elevated, in: RoundedRectangle(cornerRadius: 6))
                        .overlay { RoundedRectangle(cornerRadius: 6).stroke(ParityTheme.separator) }
                        .padding(6)
                }
            }
            .pointerHover { isHovering = $0 }
            // Also as the card appears: a row drawn again finds its pooled page still live, in the appearance it
            // started with.
            .onChange(of: colorScheme, initial: true) { _, scheme in controller.setDark(scheme == .dark) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(visualization.title)
            .accessibilityActions {
                if display.state == .live {
                    Button(L10n.string("Expand visualization"), action: expand)
                }
            }
            .sheet(isPresented: $isExpanded, onDismiss: {
                focusBookmark?.restore()
                focusBookmark = nil
            }) {
                CodexVisualizationExpanded(title: visualization.title, controller: controller) { isExpanded = false }
            }
        }
    }

    private func expand() {
        focusBookmark = WindowFocusBookmark(window: NSApp.keyWindow)
        pauseFollowing()
        isExpanded = true
    }

    /// The visualization's file, for "Open file" on its card.
    private var fileURL: URL? {
        let file = visualization.file
        if file.hasPrefix("/") { return URL(filePath: file) }
        if file.hasPrefix("~/") { return FileManager.default.homeDirectoryForCurrentUser.appending(path: String(file.dropFirst(2))) }
        return workspaceURL?.appending(path: file)
    }
}

/// An expanded visualization: its page moved out of the row into a sheet, at the width the skill designs a wide
/// visualization for, scrolling inside when taller.
struct CodexVisualizationExpanded: View {
    let title: String
    let controller: MCPAppViewController
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Button(L10n.string("Done"), action: close)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            // In the row the page lines up with the message's words; here it keeps off the sheet's edges.
            MCPAppExpandedPlace(controller: controller)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ParityTheme.canvas)
        }
        .frame(minWidth: 520, idealWidth: 1_064, minHeight: 360, idealHeight: 760)
    }
}

/// The sheet's place for a view's web view, which goes back to its row when the sheet goes.
struct MCPAppExpandedPlace: NSViewRepresentable {
    let controller: MCPAppViewController

    func makeCoordinator() -> MCPAppViewController { controller }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        controller.expandedContainer = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if controller.expandedContainer !== view { controller.expandedContainer = view }
    }

    static func dismantleNSView(_ view: NSView, coordinator controller: MCPAppViewController) {
        if controller.expandedContainer === view { controller.expandedContainer = nil }
    }
}
