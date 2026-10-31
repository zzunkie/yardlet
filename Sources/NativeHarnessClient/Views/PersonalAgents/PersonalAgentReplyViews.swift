import AppKit
import SwiftUI

/// What a dot's conversation does with replies: open the thread a message belongs to, replying to a
/// message in it, close the dialog, and read the open thread's earlier replies.
struct PersonalAgentReplyActions {
    /// The message whose thread opens, and the message a reply there answers (the message itself
    /// when nil).
    var open: (_ messageID: String, _ target: String?) -> Void = { _, _ in }
    var close: () -> Void = {}
    var loadOlder: () -> Void = {}
    /// Reads the open thread again, after a read of it failed.
    var refresh: () -> Void = {}
}

/// What a reply in the room quotes of the message it answers, above it; choosing it opens the
/// thread, replying to that message.
struct PersonalAgentReplyQuoteView: View {
    let quote: PersonalAgentReplyQuote
    let alignsTrailing: Bool
    let open: () -> Void
    @Environment(\.yardletInterfaceScale) private var scale

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Image(systemName: "arrowshape.turn.up.left").font(.system(size: 10 * scale, weight: .semibold))
                Group {
                    switch quote {
                    case let .text(text): Text(text.replacingOccurrences(of: "\n", with: " "))
                    case .attachment: Text(L10n.string("Attachment"))
                    case .deleted: Text(L10n.string("Message deleted")).italic()
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .font(.system(size: 12 * scale))
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
            .overlay(alignment: .leading) { Rectangle().fill(ParityTheme.strongSeparator).frame(width: 2) }
            .frame(maxWidth: ConversationLayout.sentBubbleMaximumWidth, alignment: alignsTrailing ? .trailing : .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .help(L10n.string("View replies"))
        .accessibilityLabel(L10n.string("Reply to"))
        .accessibilityValue(accessibilityText)
    }

    private var accessibilityText: String {
        switch quote {
        case let .text(text): text
        case .attachment: L10n.string("Attachment")
        case .deleted: L10n.string("Message deleted")
        }
    }
}

/// Under a message with replies: their number where every one can be counted, else View replies.
struct PersonalAgentReplyIndicator: View {
    let count: Int?
    let open: () -> Void
    @Environment(\.yardletInterfaceScale) private var scale

    static func title(_ count: Int?) -> String {
        switch count {
        case nil: L10n.string("View replies")
        case 1?: L10n.string("1 reply")
        case let value?: L10n.format("%lld replies", Int64(value))
        }
    }

    var body: some View {
        Button(action: open) {
            Label(Self.title(count), systemImage: "bubble.left.and.bubble.right")
                .font(.system(size: 12 * scale, weight: .medium))
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .accessibilityLabel(Self.title(count))
    }
}

/// The dot's composer and, while a reply thread is open, the Replies dialog over the conversation
/// with that same composer at its foot, as the provider's app shows it. The composer stays where it
/// is and keeps its draft, files and focus; the room's history behind it keeps its place. Only this
/// view reads which thread is open, so opening, closing or reading replies never draws the room's
/// messages again.
struct PersonalAgentReplyArea<Composer: View>: View {
    let conversation: PersonalAgentConversation
    /// The height of the conversation's history, which the dialog never grows past.
    let viewportHeight: CGFloat
    let actions: PersonalAgentReplyActions
    let rows: PersonalAgentReplyRows
    /// The composer, given the thread its field takes focus for, the dialog's keys and focus, and what
    /// Escape in it does.
    @ViewBuilder let composer: (_ focusRequest: String?, _ keys: PersonalAgentReplyKeys,
                                _ onEscape: @escaping () -> Void) -> Composer
    @State private var composerHeight: CGFloat = 0
    @State private var panelHeight: CGFloat = 0
    @State private var keys = PersonalAgentReplyKeys()
    @Environment(\.yardletInterfaceScale) private var scale

    static var inset: CGFloat { 12 }

    var body: some View {
        let focus = conversation.replies.focus
        let thread = focus.flatMap { conversation.replies.threads[$0.rootID] }
        composer(focus?.rootID, keys, escape)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            .background(alignment: .bottom) {
                if thread != nil {
                    RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius + 4)
                        .fill(ParityTheme.elevated)
                        .overlay {
                            RoundedRectangle(cornerRadius: ParityTheme.panelCornerRadius + 4).stroke(ParityTheme.separator)
                        }
                        .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
                        .background(PersonalAgentReplyPanelMonitor(keys: keys, onOutside: actions.close))
                        .frame(height: panelHeight + composerHeight + Self.inset)
                        .padding(.horizontal, -Self.inset)
                        .offset(y: Self.inset)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottom) {
                // Its foot on the composer's top: the composer stays where it is, under the dialog's edge.
                if let thread {
                    PersonalAgentReplyPanel(thread: thread, maximumHeight: max(140, viewportHeight - 72),
                                            close: actions.close, loadOlder: actions.loadOlder, refresh: actions.refresh,
                                            rows: rows)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
                        .padding(.horizontal, -Self.inset)
                        .onExitCommand(perform: escape)
                        // Each thread its own place, following, drawn range and earlier reads; the composer stays.
                        .id(thread.rootID)
                        .offset(y: -composerHeight)
                }
            }
    }

    /// Escape closes the dialog, except the key an input method took while composing a character.
    private func escape() {
        guard conversation.replies.focus != nil, !keys.isComposing(NSApp.currentEvent) else { return }
        actions.close()
    }
}

/// How the reply dialog draws a message: the conversation's own row, what the row shows beyond the
/// dialog's look (`inputs`), and that shared look.
struct PersonalAgentReplyRows {
    let look: PersonalAgentReplyRowLook
    let inputs: (_ message: PersonalAgentMessage, _ startsRun: Bool) -> PersonalAgentReplyRowInputs
    let content: (_ message: PersonalAgentMessage, _ startsRun: Bool) -> AnyView
}

/// What every message of the dialog shares in how it is drawn: whose dot it is, its picture, and
/// whether an attachment is being read.
struct PersonalAgentReplyRowLook: Equatable {
    let agent: PersonalAgentIdentity
    let name: String
    /// The picture's version and size, standing for its bytes.
    let avatar: String
    let sheet: ObjectIdentifier?
    let isLoadingAttachment: Bool
}

/// What one message of the dialog shows that its message alone does not say: whether it starts a run
/// of one author's messages, the request card it holds, and its option question's answer. The card
/// and the question follow their own changes in the row; these are what the row is made with.
struct PersonalAgentReplyRowInputs: Equatable {
    let message: PersonalAgentMessage
    let startsRun: Bool
    let request: ObjectIdentifier?
    let optionChosen: Int?
    let optionAnswered: Bool
}

/// The Replies dialog above the composer: its close button, then the thread's start and every reply
/// read so far in a native list (`PersonalAgentReplyTable`) that draws only the rows in view. Its earlier
/// replies are read when its top comes into view, or while the thread does not fill the dialog; the row
/// being read stays in place as rows arrive above it, and a newer reply moves the thread to its end only
/// while the person is reading there, and otherwise offers New replies.
private struct PersonalAgentReplyPanel: View {
    let thread: PersonalAgentReplyThread
    let maximumHeight: CGFloat
    let close: () -> Void
    let loadOlder: () -> Void
    let refresh: () -> Void
    let rows: PersonalAgentReplyRows
    @State private var table = PersonalAgentReplyTableState()
    /// The cursor the dialog last read by itself, and how many messages it had then: each cursor is
    /// read once by itself, and a page that added nothing starts no other.
    @State private var autoRead: (cursor: PersonalAgentReplyThread.Cursor, count: Int)?
    @Environment(\.yardletInterfaceScale) private var scale

    private var showsEarlier: Bool { thread.cursor != .end || thread.olderFailure != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("Replies")).font(.system(size: 12 * scale, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.borderless).parityPointer()
                    .help(L10n.string("Close replies"))
                    .accessibilityLabel(L10n.string("Close replies"))
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            if let failure = thread.latestFailure {
                HStack(spacing: 8) {
                    Text(L10n.string("Replies could not be refreshed.")).help(failure.message)
                    Spacer()
                    Button(L10n.string("Try again"), action: refresh).buttonStyle(.borderless).parityPointer()
                }
                .font(.system(size: 12 * scale))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
            }
            PersonalAgentReplyTable(
                messages: thread.messages,
                earlier: showsEarlier ? .init(signature: earlierSignature, content: AnyView(earlier)) : nil,
                showsEmpty: thread.messages.isEmpty && !showsEarlier,
                empty: AnyView(Text(L10n.string("No replies loaded")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)),
                rows: rows, state: table, readEarlierByItself: readEarlierByItself)
                .frame(height: min(max(table.contentHeight, 44), maximumHeight))
                .overlay(alignment: .bottom) {
                    if !table.isFollowing, let last = thread.messages.last?.id, last != table.seenLast, table.seenLast != nil {
                        Button(L10n.string("New replies")) { table.showEnd() }
                            .help(L10n.string("Scroll to new replies"))
                            .padding(.bottom, 6)
                    }
                }
            Color.clear.frame(height: 8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// What the top row shows, which draws it again when it changes.
    private var earlierSignature: String {
        "\(thread.isLoadingOlder)|\(thread.olderFailure.map { "\($0)" } ?? "")|\(scale)"
    }

    /// The top of the thread: the state of its earlier replies, and a way to read them by hand.
    private var earlier: some View {
        HStack(spacing: 8) {
            if thread.isLoadingOlder {
                ProgressView().controlSize(.small)
                Text(L10n.string("Loading earlier replies…"))
            } else if thread.olderFailure != nil {
                Text(L10n.string("Earlier replies could not be loaded.")).help(thread.olderFailure?.message ?? "")
                Button(L10n.string("Try again"), action: readEarlier).buttonStyle(.borderless).parityPointer()
            } else {
                Button(L10n.string("Load earlier replies"), action: readEarlier).buttonStyle(.borderless).parityPointer()
            }
        }
        .font(.system(size: 12 * scale))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
    }

    /// With the top in view as laid out, or a thread that does not fill the dialog: reads the next
    /// earlier page, once for each cursor, and not again after a page that added nothing or failed.
    private func readEarlierByItself() {
        guard thread.hasRead, !thread.isLoadingOlder, thread.olderFailure == nil, case .before = thread.cursor else { return }
        if let autoRead, autoRead.cursor == thread.cursor || thread.messages.count <= autoRead.count { return }
        autoRead = (thread.cursor, thread.messages.count)
        loadOlder()
    }

    /// Asked for by the person.
    private func readEarlier() {
        guard !thread.isLoadingOlder, thread.cursor != .end else { return }
        loadOlder()
    }
}

/// The conversation's environment that a reply row reads, given to the row's own hosting view. The whole
/// environment is not handed over: it carries the conversation's tie to its own window's accessibility,
/// and a row in the list's own views would then be read by no assistive app. The system's values (an
/// assistive app, motion, contrast) are the row's window's own.
private struct PersonalAgentReplyRowEnvironment: ViewModifier {
    let environment: EnvironmentValues

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, environment.colorScheme)
            .environment(\.locale, environment.locale)
            .environment(\.layoutDirection, environment.layoutDirection)
            .environment(\.yardletInterfaceScale, environment.yardletInterfaceScale)
            .environment(\.conversationFind, environment.conversationFind)
            .environment(\.conversationFindSlot, environment.conversationFindSlot)
            .environment(\.conversationMessageActions, environment.conversationMessageActions)
            .environment(\.openImageViewer, environment.openImageViewer)
            .environment(\.pauseTranscriptFollowing, environment.pauseTranscriptFollowing)
            .environment(\.personalAgentConfirmationPrompt, environment.personalAgentConfirmationPrompt)
            .environment(\.personalAgentOriginalOpener, environment.personalAgentOriginalOpener)
            .environment(\.revealsSentMessageActions, environment.revealsSentMessageActions)
            .environment(\.transcriptCopyDetails, environment.transcriptCopyDetails)
            .environment(\.transcriptWorkspaceURL, environment.transcriptWorkspaceURL)
    }
}

/// One message's hosting controller in the reply dialog, what it last drew, and its heights by width.
/// The row's content and the conversation's environment are what it was last drawn with until what it
/// shows (`Shown`) or how the conversation looks change; the cards and questions in it follow their
/// own changes inside. A list row that shows another message gets content of that message's own, so
/// nothing one message's row held is left for the next.
@MainActor
final class PersonalAgentReplyRowHosting {
    /// What a row was drawn from: a message with its inputs and the dialog's look, or another row's
    /// own signature.
    enum Shown: Equatable {
        case message(PersonalAgentReplyRowInputs, PersonalAgentReplyRowLook)
        case other(String)
    }

    let controller = NSHostingController(rootView: AnyView(EmptyView()))
    private var shown: (shown: Shown, environment: ConversationTurnLook)?
    private var heights: [CGFloat: CGFloat] = [:]
    private var reportedHeight: CGFloat?
    var onResize: () -> Void = {}
#if DEBUG
    /// The hosting views alive now, across every dialog.
    nonisolated(unsafe) static var alive = 0
#endif

    init() {
        controller.sizingOptions = []
#if DEBUG
        ViewBodyCensus.note(.personalAgentReplyRowHosting)
        Self.alive += 1
#endif
    }

    deinit {
#if DEBUG
        Self.alive -= 1
#endif
    }

    /// Draws `content` unless the row already shows what `shown` says, as the conversation looks now.
    /// Returns whether it drew.
    @discardableResult
    func show(_ shown: Shown, identity: String, environment: EnvironmentValues, content: () -> AnyView) -> Bool {
        let look = ConversationTurnLook(environment)
        if let current = self.shown, current.shown == shown, current.environment == look { return false }
        self.shown = (shown, look)
#if DEBUG
        ViewBodyCensus.note(.personalAgentReplyRowGraph)
#endif
        heights = [:]
        reportedHeight = nil
        controller.rootView = AnyView(
            content()
                // A row's own state belongs to its message alone.
                .id(identity)
                .fixedSize(horizontal: false, vertical: true)
                // A row grows and shrinks on its own too: a card waits, an answer is chosen.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                    self?.contentHeightChanged(height)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .modifier(PersonalAgentReplyRowEnvironment(environment: environment))
        )
        return true
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard height != reportedHeight else { return }
        let first = reportedHeight == nil
        reportedHeight = height
        heights = [:]
        if !first { onResize() }
    }

    func size(forWidth width: CGFloat) -> CGSize {
        if let height = heights[width] { return CGSize(width: width, height: height) }
        let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = ceil(size.height)
        heights[width] = height
        return CGSize(width: width, height: height)
    }
}

/// The Escape keys an input method took while it composed a character, which then must not close
/// the dialog. Shared by reference, so noting a key redraws nothing.
/// It also keeps where focus was when the dialog opened, and whether a press outside closed it.
@MainActor
final class PersonalAgentReplyKeys {
    fileprivate var composingEscape: TimeInterval?
    fileprivate weak var window: NSWindow?
    fileprivate weak var previousFocus: NSResponder?
    fileprivate var closedByPress = false

    /// Whether the Escape being handled belongs to an input method: one still composing in the
    /// dialog's window, or one that was composing when this key went down and has passed it on.
    func isComposing(_ event: NSEvent?) -> Bool {
        if (window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return true }
        guard let event, event.type == .keyDown, event.keyCode == 53, let composing = composingEscape else { return false }
        return composing == event.timestamp
    }
}

/// Watches the window while the dialog shows: a press outside the dialog and its composer closes
/// it, and the press goes on to what it was on; an Escape pressed while an input method composes is
/// noted before the field sees it. It intercepts nothing.
struct PersonalAgentReplyPanelMonitor: NSViewRepresentable {
    let keys: PersonalAgentReplyKeys
    let onOutside: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.keys = keys
        view.onOutside = onOutside
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.keys = keys
        view.onOutside = onOutside
        view.isEnabled = context.environment.isEnabled
    }

    final class MonitorView: NSView {
        var keys: PersonalAgentReplyKeys?
        var onOutside: () -> Void = {}
        /// Whether the dialog takes input: under a view that covers it, a press elsewhere is not one
        /// outside the dialog.
        var isEnabled = true
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard let window else { return }
            keys?.window = window
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                self?.observe(event)
                return event
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { removeMonitor() }
            super.viewWillMove(toWindow: newWindow)
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// What the window's monitor hands over for each event; a test hands events here directly.
        func observe(_ event: NSEvent) {
            guard isEnabled, let window, event.window === window else { return }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return }
                let composing = (window.firstResponder as? NSTextView)?.hasMarkedText() == true
                keys?.composingEscape = composing ? event.timestamp : nil
                return
            }
            guard !bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            keys?.closedByPress = true
            let close = onOutside
            DispatchQueue.main.async { close() }
        }

    }
}

/// The composer's focus around the reply dialog, from the composer's own window. As the dialog opens
/// (`request` from nil), it notes where focus is; closed by its button or Escape, focus goes back
/// there if it is still in the window, while a press outside leaves focus with what it chose. Once the
/// window gives the composer's field focus for the dialog, which AppKit does by selecting all its text
/// for the next key to replace, the caret goes to the end. Only the field laid out within this view's
/// frame counts; no other field is touched, and a field already focused is left as it is. It takes no
/// clicks.
struct PersonalAgentComposerFocus: NSViewRepresentable {
    let request: String?
    let keys: PersonalAgentReplyKeys?

    func makeNSView(context: Context) -> FocusView { FocusView() }

    func updateNSView(_ view: FocusView, context: Context) { view.update(request, keys: keys) }

    final class FocusView: NSView {
        private var request: String?
        nonisolated(unsafe) private var observation: NSObjectProtocol?

        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }

        private func disarm() {
            if let observation { NotificationCenter.default.removeObserver(observation) }
            observation = nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(_ next: String?, keys: PersonalAgentReplyKeys?) {
            guard next != request else { return }
            let opening = request == nil
            request = next
            disarm()
            guard let window else { return }
            guard next != nil else { return restoreFocus(in: window, keys: keys) }
            if opening {
                keys?.previousFocus = Self.owner(of: window.firstResponder)
                keys?.closedByPress = false
            }
            guard !owns(window.firstResponder) else { return }
            // The field shows it has focus by selecting: everything, as a field taking focus does, is
            // turned into the caret at the end; anything else is the person's, and ends the watch.
            observation = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification,
                                                                 object: nil, queue: .main) { [weak self] note in
                let editor = note.object as? NSTextView
                MainActor.assumeIsolated { self?.selectionChanged(in: editor) }
            }
        }

        private func selectionChanged(in editor: NSTextView?) {
            guard let editor, let window, window.firstResponder === editor, owns(editor) else { return }
            let length = (editor.string as NSString).length
            guard length > 0, editor.selectedRange() == NSRange(location: 0, length: length) else { return disarm() }
            editor.setSelectedRange(NSRange(location: length, length: 0))
        }

        private func restoreFocus(in window: NSWindow, keys: PersonalAgentReplyKeys?) {
            guard let keys, !keys.closedByPress, let previous = keys.previousFocus as? NSView, previous.window === window,
                  Self.owner(of: window.firstResponder) !== previous else { return }
            window.makeFirstResponder(previous)
        }

        /// The control a field editor edits for, rather than the editor every field shares.
        private static func owner(of responder: NSResponder?) -> NSResponder? {
            if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder { return field }
            return responder
        }

        /// Whether `responder` edits the field within this view's frame.
        private func owns(_ responder: NSResponder?) -> Bool {
            guard let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView,
                  let window, field.window === window else { return false }
            let frame = field.convert(field.bounds, to: nil)
            return convert(bounds, to: nil).contains(CGPoint(x: frame.midX, y: frame.midY))
        }
    }
}
