import AppKit
import SwiftUI

/// What a composer's typed `/` list offers and what choosing a row does. The task composer reads
/// its list from the session's options; the new-task composer reads it from a session that sends
/// nothing. Each decides when its list is read.
@MainActor
struct ComposerEditorCommands {
    var commands: [ProviderComposerCommand]
    var isLoading = false
    var error: String?
    /// A row chosen with Return, Tab or a click: inserted, or run (Codex's own commands).
    var choose: (ProviderComposerCommand) -> Void
    /// The text was edited while the typed list shows.
    var textEdited: () -> Void = {}
}

/// The spacing that differs between the task composer below a conversation and the larger
/// new-task composer on the home screen.
struct ComposerEditorMetrics: Equatable {
    var chipsTop: CGFloat
    var text: EdgeInsets
    var lineLimit: ClosedRange<Int>
    var minTextHeight: CGFloat?
    var noticeBottom: CGFloat

    /// `chipsTop` is smaller under the paused-queue line.
    static func task(chipsTop: CGFloat = 9) -> Self {
        Self(chipsTop: chipsTop, text: EdgeInsets(top: 12, leading: 15, bottom: 6, trailing: 15),
             lineLimit: 2...8, minTextHeight: 40, noticeBottom: 8)
    }

    static let newTask = Self(chipsTop: 10, text: EdgeInsets(top: 16, leading: 16, bottom: 12, trailing: 16),
                              lineLimit: 2...10, minTextHeight: nil, noticeBottom: 10)
}

/// The editing half shared by the task composer (`PromptComposer`) and the new-task composer
/// (`NewTaskComposer`): the text, the attachment chips, the typed `/` and `@` lists, paste and
/// drop, bash mode where the draft has it, and the guards that keep an input method's
/// composition and the reader's selection intact. Each composer keeps its own bottom row
/// (`footer`) and submit, and passes what differs as values; this view never compares harnesses.
struct ComposerEditor<Draft: ComposerDraftEditing, Header: View, Chips: View, Footer: View>: View {
    @Bindable var draft: Draft
    let placeholder: String
    let accessibilityHint: String?
    let metrics: ComposerEditorMetrics
    /// What the harness takes. Nil before a harness is chosen: no `@`, paste or drop.
    let input: HarnessComposerInputPolicy?
    /// Takes pasted and dropped files and pictures in place of the harness's rules, for a composer
    /// whose message carries files of its own (a dot's). Nil leaves them to `input`.
    let onExternalInput: ((ComposerExternalInput) -> Void)?
    /// The folders a typed `@word` searches.
    let mentionRoots: [URL]
    /// Nil where a typed `/` opens nothing.
    let commands: ComposerEditorCommands?
    /// Bash mode exists where the harness has it and the window can run the command.
    let bashModeAvailable: Bool
    /// The composer's command menu is open: its search takes the place of the typed list.
    let isCommandMenuOpen: Bool
    /// Any of the composer's menus is open: no typed list.
    let isMenuOpen: Bool
    /// The chip row shows for `chips` even without attachments (the follow-up queue).
    let showsChips: Bool
    let isFocused: FocusState<Bool>.Binding
    /// Return with no list open.
    let onSubmit: () -> Void
    /// ⌘Return with no list open, where it sends differently from Return (the task composer while
    /// a turn runs: the follow-up setting's other way). Nil where ⌘Return is Return.
    let onAlternateSubmit: (() -> Void)?
    /// Plain Tab with no typed list showing and no input method composing: puts the composer's
    /// suggested next message into the text and says whether one was there to take. Nil where the
    /// composer has no suggestions (the new-task composer). Otherwise Tab moves focus as before.
    let takeSuggestion: (() -> Bool)?
    /// The suggested next message, drawn as the empty composer's faint text, as the Claude app's
    /// composer shows it. Tab or → puts it in (`takeSuggestion`). Nil when there is none.
    let suggestion: String?
    /// Escape with no list open.
    let onEscape: () -> Void
    /// Tab with no list open: true when it moved the keyboard somewhere (the new-task screen's
    /// lists). Nil, or false, leaves Tab to the field.
    let onTab: (() -> Bool)?
    /// The typed `/` query changed, including from none to some when the list opens and back
    /// to none when it closes for any reason.
    let onCommandQueryChange: (_ old: String?, _ new: String?) -> Void
    let header: Header
    let chips: Chips
    let footer: Footer

    init(
        draft: Draft,
        placeholder: String,
        accessibilityHint: String? = nil,
        metrics: ComposerEditorMetrics,
        input: HarnessComposerInputPolicy?,
        onExternalInput: ((ComposerExternalInput) -> Void)? = nil,
        mentionRoots: [URL],
        commands: ComposerEditorCommands?,
        bashModeAvailable: Bool = false,
        isCommandMenuOpen: Bool,
        isMenuOpen: Bool,
        showsChips: Bool = false,
        isFocused: FocusState<Bool>.Binding,
        onSubmit: @escaping () -> Void,
        onAlternateSubmit: (() -> Void)? = nil,
        takeSuggestion: (() -> Bool)? = nil,
        suggestion: String? = nil,
        onEscape: @escaping () -> Void = {},
        onTab: (() -> Bool)? = nil,
        onCommandQueryChange: @escaping (_ old: String?, _ new: String?) -> Void = { _, _ in },
        @ViewBuilder header: () -> Header,
        @ViewBuilder chips: () -> Chips,
        @ViewBuilder footer: () -> Footer
    ) {
        _draft = Bindable(draft)
        self.placeholder = placeholder
        self.accessibilityHint = accessibilityHint
        self.metrics = metrics
        self.input = input
        self.onExternalInput = onExternalInput
        self.mentionRoots = mentionRoots
        self.commands = commands
        self.bashModeAvailable = bashModeAvailable
        self.isCommandMenuOpen = isCommandMenuOpen
        self.isMenuOpen = isMenuOpen
        self.showsChips = showsChips
        self.isFocused = isFocused
        self.onSubmit = onSubmit
        self.onAlternateSubmit = onAlternateSubmit
        self.takeSuggestion = takeSuggestion
        self.suggestion = suggestion
        self.onEscape = onEscape
        self.onTab = onTab
        self.onCommandQueryChange = onCommandQueryChange
        self.header = header()
        self.chips = chips()
        self.footer = footer()
    }

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.taskKeyboardFocus) private var keyboardFocus
    @State private var commandHighlight = 0
    @State private var dismissedCommandText: String?
    @State private var fileMentions = ComposerFileMentionSearch()
    @State private var promptCaret: ComposerCaret?
    @State private var dismissedMentionText: String?
    @State private var isDropTargeted = false
    /// The field's window and the Return an input method's composition took, read by the key
    /// handlers without redrawing the editor.
    @State private var fieldContext = ComposerFieldContext()

    private var isBashMode: Bool {
        bashModeAvailable && draft.isBashMode
    }

    /// Where a paste or drop goes: the composer's own handler, or the harness's attachments.
    private var externalInput: ((ComposerExternalInput) -> Void)? {
        if let onExternalInput { return onExternalInput }
        guard let input, input.showsMentionControl else { return nil }
        return { [draft] in draft.receive($0, policy: input) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !draft.attachments.isEmpty || showsChips {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(draft.attachments.enumerated()), id: \.offset) { index, input in
                            ComposerInputChip(input: input, window: fieldContext.window,
                                              onMarkedUp: { draft.replaceAttachment(at: index, withMarkedUp: $0) }) {
                                draft.removeAttachment(at: index)
                            }
                        }
                        chips
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, metrics.chipsTop)
                }
            }
            if let query = typedCommandQuery, let commands {
                ComposerCommandPicker(
                    commands: commands.commands, query: query, isLoading: commands.isLoading,
                    error: commands.error, highlightedIndex: commandHighlight, onSelect: commands.choose
                )
                .padding(.horizontal, 10).padding(.top, 8)
            } else if let mention = typedMention {
                ComposerFileMentionPicker(search: fileMentions, showsRoot: mentionRoots.count > 1) {
                    insertMention($0, replacing: mention)
                }
                .padding(.horizontal, 10).padding(.top, 8)
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if isBashMode {
                    // The Claude app marks bash mode with a "bash" badge and its accent ring.
                    Text(verbatim: "bash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ParityTheme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(ParityTheme.accent.opacity(0.12), in: Capsule())
                        .help(L10n.string("Run as a shell command"))
                        .accessibilityHidden(true)
                }
                textField
            }
            .scrollsPastLines(metrics.lineLimit.upperBound)
            .textFieldStyle(.plain)
            .font(isBashMode
                ? .system(size: 13 * interfaceScale, design: .monospaced)
                : ParityTheme.conversationFont(scale: interfaceScale))
            .padding(metrics.text)

            if let notice = draft.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, metrics.text.leading)
                    .padding(.bottom, metrics.noticeBottom)
            }

            footer
        }
        .background(ParityTheme.input, in: RoundedRectangle(cornerRadius: ParityTheme.composerCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ParityTheme.composerCornerRadius)
                .stroke(isBashMode ? ParityTheme.accent
                    : isFocused.wrappedValue ? ParityTheme.strongSeparator : ParityTheme.separator)
        }
        .overlay {
            if let receive = externalInput {
                // Backspace in the empty composer returns bash mode to chat.
                ComposerExternalInputTarget(
                    isTargeted: $isDropTargeted, onInput: receive,
                    onDeleteInEmptyText: bashModeAvailable ? { isBashMode && draft.leaveBashMode() } : nil)
                    .accessibilityHidden(true)
            }
        }
        .overlay { if isDropTargeted { ComposerDropHighlight() } }
        .background { ComposerWindowProbe(context: fieldContext).accessibilityHidden(true) }
        .onChange(of: typedMention?.query, initial: true) { _, query in
            fileMentions.update(query: query, roots: mentionRoots)
        }
        .onChange(of: typedCommandQuery) { old, query in
            commandHighlight = 0
            onCommandQueryChange(old, query)
        }
        .onChange(of: draft.text) { previous, text in
            // `!` typed into the empty composer switches it to bash mode instead of being kept.
            if bashModeAvailable, isFocused.wrappedValue, draft.enterBashModeIfTyped(after: previous) { return }
            if dismissedCommandText != text { dismissedCommandText = nil }
            if dismissedMentionText != text { dismissedMentionText = nil }
            if typedCommandQuery != nil { commands?.textEdited() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { notification in
            guard isFocused.wrappedValue, let editor = notification.object as? NSTextView,
                  NSApp.keyWindow?.firstResponder === editor,
                  editor.isEditable else { return }
            // A mouse click can move first responder before a panel request arrives. Capture
            // the native range together with its text. SwiftUI may publish selection indices
            // before its text binding changes, so those indices cannot safely be converted here.
            let range = editor.selectedRange(), text = editor.string
            promptCaret = ComposerCaret(text: text, selection: range)
            let draft = draft
            draft.rememberSelection(range, in: text)
            // Editing can notify before the binding catches up. Revalidate after that update
            // so a caret in the middle of newly typed text also survives navigation.
            DispatchQueue.main.async { draft.rememberSelection(range, in: text) }
        }
        .onChange(of: keyboardFocus?.request) { _, request in
            guard let request, request.target != .chat, isFocused.wrappedValue,
                  let editor = ComposerFieldEditor.focused else { return }
            // AX selection and native selection can arrive before SwiftUI updates its binding.
            // Capture the actual editor before the destination receives keyboard focus.
            draft.rememberSelection(editor.selectedRange(), in: editor.string)
        }
        .task(id: keyboardFocus?.request) {
            guard let request = keyboardFocus?.request, request.target == .chat else { return }
            let text = draft.text
            let selection = draft.selection.map { NSRange($0, in: text) }
            await Task.yield()
            guard !Task.isCancelled, keyboardFocus?.request == request else { return }
            isFocused.wrappedValue = true
            await Task.yield()
            guard !Task.isCancelled, keyboardFocus?.request == request else { return }
            // AppKit selects all text when a field becomes first responder programmatically.
            // Restore the reader's selection only while it still belongs to this exact draft.
            // Keep selection in the native editor. SwiftUI's TextSelection binding can
            // replay old String.Index values against the empty string after submission.
            if let editor = ComposerFieldEditor.focused, editor.string.utf16.elementsEqual(draft.text.utf16) {
                let range = draft.text.utf16.elementsEqual(text.utf16)
                    ? selection ?? NSRange(location: text.utf16.count, length: 0)
                    : NSRange(location: editor.string.utf16.count, length: 0)
                editor.setSelectedRange(range)
            }
            keyboardFocus?.consume(request)
        }
    }

    private var textField: some View {
        // It grows with its text; past the line limit's upper bound the editor scrolls it
        // (`scrollsPastLines`), which also gives it its font and style.
        TextField(suggestion ?? placeholder, text: $draft.text, axis: .vertical)
            .lineLimit(metrics.lineLimit.lowerBound...)
            .frame(minHeight: metrics.minTextHeight, alignment: .topLeading)
            .focused(isFocused)
            .accessibilityLabel(placeholder)
            .accessibilityHint(accessibilityHint ?? "")
            .onSubmit {
                // The field editor's Return: a plain one, or one an input method passed on after
                // committing its composition, which the key handler noted.
                takeReturn(fieldContext.takeComposedReturn() ?? ComposerReturnKey(event: NSApp.currentEvent) ?? .send)
            }
            .onExitCommand {
                if typedCommandQuery != nil { dismissedCommandText = draft.text }
                else if typedMention != nil { dismissedMentionText = draft.text }
                else { onEscape() }
            }
            .onKeyPress(.return, phases: [.down, .repeat]) { press in
                // Shift-Return adds a line and ⌘Return sends the other way; plain Return reaches
                // `onSubmit` through the field editor and Option-Return adds a line there. While an
                // input method composes, the key is the input method's: it commits the composition
                // first, and `onSubmit` then does what this Return asks, never a send for a line.
                guard let key = ComposerReturnKey(press.modifiers) else { return .ignored }
                if fieldContext.hasMarkedText {
                    fieldContext.composedReturn = key
                    return .ignored
                }
                fieldContext.composedReturn = nil
                guard key != .send else { return .ignored }
                takeReturn(key)
                return .handled
            }
            .onKeyPress(.upArrow) { moveHighlight(by: -1) }
            .onKeyPress(.downArrow) { moveHighlight(by: 1) }
            // → in the empty composer takes the suggestion too, as the Claude app's composer does.
            .onKeyPress(.rightArrow) {
                guard suggestion != nil, draft.text.isEmpty, !fieldContext.hasMarkedText,
                      takeSuggestion?() == true else { return .ignored }
                return .handled
            }
            .onKeyPress(.tab, phases: [.down, .repeat]) { press in
                if typedCommandQuery != nil {
                    guard !ComposerFieldEditor.hasMarkedText, let command = highlightedCommand else { return .ignored }
                    commands?.choose(command)
                    return .handled
                }
                if let mention = typedMention {
                    guard !ComposerFieldEditor.hasMarkedText, let match = fileMentions.highlightedMatch else { return .ignored }
                    insertMention(match, replacing: mention)
                    return .handled
                }
                // The suggested next message, as the Claude app's composer takes it on Tab. While an
                // input method composes, the key is the input method's and nothing is taken.
                if ComposerTypedLists.takesSuggestion(
                    modifiers: press.modifiers, isRepeat: press.phase == .repeat,
                    hasMarkedText: fieldContext.hasMarkedText, take: takeSuggestion) { return .handled }
                // Then, on the new-task screen, its lists take the keyboard, on the same plain Tab.
                return ComposerTypedLists.takesSuggestion(
                    modifiers: press.modifiers, isRepeat: press.phase == .repeat,
                    hasMarkedText: fieldContext.hasMarkedText, take: onTab)
                    ? .handled : .ignored
            }
    }

    // MARK: - The typed lists

    /// A typed `/word` at the start of the text, while the composer offers commands. A shell
    /// command is plain text: no slash commands or `@` mentions in bash mode.
    private var typedCommandQuery: String? {
        ComposerTypedLists.commandQuery(
            in: draft.text, offersCommands: commands != nil, isFocused: isFocused.wrappedValue,
            isCommandMenuOpen: isCommandMenuOpen, isBashMode: isBashMode, dismissedText: dismissedCommandText)
    }

    /// The typed list's row that Return and Tab choose.
    private var highlightedCommand: ProviderComposerCommand? {
        guard let query = typedCommandQuery, let commands else { return nil }
        let matches = ComposerCommands.matching(commands.commands, query: query)
        return matches.indices.contains(commandHighlight) ? matches[commandHighlight] : matches.first
    }

    /// A typed `@word` searches the task's folders wherever the `@` button is offered.
    private var typedMention: ComposerMentionToken? {
        ComposerTypedLists.mention(
            in: draft.text, caret: promptCaret, offersMentions: input?.showsMentionControl == true,
            hasRoots: !mentionRoots.isEmpty, isFocused: isFocused.wrappedValue, isMenuOpen: isMenuOpen,
            isBashMode: isBashMode, showsCommands: typedCommandQuery != nil, dismissedText: dismissedMentionText)
    }

    /// Arrow keys move through the list only while it shows matches. An input method still
    /// composing a character keeps the key, so composition is never interrupted.
    private func moveHighlight(by offset: Int) -> KeyPress.Result {
        if let query = typedCommandQuery {
            let count = commands.map { ComposerCommands.matching($0.commands, query: query).count } ?? 0
            guard let highlight = ComposerTypedLists.movedCommandHighlight(
                commandHighlight, by: offset, count: count, hasMarkedText: ComposerFieldEditor.hasMarkedText)
            else { return .ignored }
            commandHighlight = highlight
            return .handled
        }
        guard typedMention != nil, !fileMentions.matches.isEmpty, !ComposerFieldEditor.hasMarkedText else {
            return .ignored
        }
        fileMentions.moveHighlight(by: offset)
        return .handled
    }

    /// One Return, after any composition: a typed list's row takes it whatever its modifiers,
    /// as it takes Return; otherwise it sends, sends the other way, or adds a line.
    private func takeReturn(_ key: ComposerReturnKey) {
        if typedCommandQuery != nil {
            if let command = highlightedCommand { commands?.choose(command) }
        } else if let mention = typedMention, let match = fileMentions.highlightedMatch {
            insertMention(match, replacing: mention)
        } else {
            switch key {
            case .send: onSubmit()
            case .alternate: (onAlternateSubmit ?? onSubmit)()
            case .newline: fieldContext.insertLine(into: draft)
            }
        }
    }

    /// The chosen file joins the draft exactly as the `@` button adds it; the typed word is
    /// removed so the reference is not sent twice.
    private func insertMention(_ match: WorkspaceFileMatch, replacing token: ComposerMentionToken) {
        guard let edit = draft.insertMention(match, replacing: token) else { return }
        dismissedMentionText = draft.text
        fileMentions.reset()
        isFocused.wrappedValue = true
        guard let caret = edit.caret else { return }
        ComposerFieldEditor.placeCaret(at: caret, in: draft, isFocused: isFocused)
    }
}

extension ComposerEditor where Header == EmptyView, Chips == EmptyView {
    /// An editor with no line above its chips and no chips of its own.
    init(
        draft: Draft,
        placeholder: String,
        accessibilityHint: String? = nil,
        metrics: ComposerEditorMetrics,
        input: HarnessComposerInputPolicy?,
        mentionRoots: [URL],
        commands: ComposerEditorCommands?,
        isCommandMenuOpen: Bool,
        isMenuOpen: Bool,
        isFocused: FocusState<Bool>.Binding,
        onSubmit: @escaping () -> Void,
        onEscape: @escaping () -> Void = {},
        onTab: (() -> Bool)? = nil,
        onCommandQueryChange: @escaping (_ old: String?, _ new: String?) -> Void = { _, _ in },
        @ViewBuilder footer: () -> Footer
    ) {
        self.init(draft: draft, placeholder: placeholder, accessibilityHint: accessibilityHint, metrics: metrics,
                  input: input, mentionRoots: mentionRoots, commands: commands, isCommandMenuOpen: isCommandMenuOpen,
                  isMenuOpen: isMenuOpen, isFocused: isFocused, onSubmit: onSubmit, onEscape: onEscape, onTab: onTab,
                  onCommandQueryChange: onCommandQueryChange,
                  header: { EmptyView() }, chips: { EmptyView() }, footer: footer)
    }
}

/// When a typed `/` or `@` list shows, and how the keyboard moves through it. Both composers
/// read these through `ComposerEditor`.
enum ComposerTypedLists {
    static func commandQuery(
        in text: String, offersCommands: Bool, isFocused: Bool, isCommandMenuOpen: Bool, isBashMode: Bool,
        dismissedText: String?
    ) -> String? {
        guard offersCommands, isFocused, !isCommandMenuOpen, !isBashMode, dismissedText != text else { return nil }
        return ComposerCommands.query(in: text)
    }

    static func mention(
        in text: String, caret: ComposerCaret?, offersMentions: Bool, hasRoots: Bool, isFocused: Bool,
        isMenuOpen: Bool, isBashMode: Bool, showsCommands: Bool, dismissedText: String?
    ) -> ComposerMentionToken? {
        guard offersMentions, hasRoots, isFocused, !isBashMode, !isMenuOpen, !showsCommands,
              dismissedText != text else { return nil }
        return ComposerMentions.token(in: text, caret: caret)
    }

    /// Whether a Tab with no typed list takes the suggested next message: a plain Tab, not held
    /// down, while no input method composes (a Korean syllable in progress keeps the key), and only
    /// when the composer had one to take. `take` runs only when the rest allows it.
    static func takesSuggestion(modifiers: EventModifiers, isRepeat: Bool, hasMarkedText: Bool,
                                take: (() -> Bool)?) -> Bool {
        guard let take, !isRepeat, !hasMarkedText,
              modifiers.intersection([.shift, .option, .control, .command]).isEmpty else { return false }
        return take()
    }

    /// The command row an arrow key highlights, clamped to the list, or nil when the key is not
    /// the list's: no rows, or an input method still composing a character.
    static func movedCommandHighlight(_ highlight: Int, by offset: Int, count: Int, hasMarkedText: Bool) -> Int? {
        guard count > 0, !hasMarkedText else { return nil }
        return min(max(highlight + offset, 0), count - 1)
    }
}

/// What a Return asks of the composer, by its modifiers, as the Codex and Claude apps have it:
/// Return sends, ⌘Return sends the other way while a turn runs (the Codex app's inverted
/// follow-up, the Claude app's "Queue for later"), Shift-Return adds a line. Option-Return adds a
/// line through AppKit's field editor and is not one of these, nor is a Return with Control.
enum ComposerReturnKey: Equatable {
    case send
    case alternate
    case newline

    /// Caps Lock does not count.
    init?(_ modifiers: EventModifiers) {
        switch modifiers.intersection([.shift, .option, .control, .command]) {
        case []: self = .send
        case .command: self = .alternate
        case .shift: self = .newline
        default: return nil
        }
    }

    init?(_ flags: NSEvent.ModifierFlags) {
        var modifiers: EventModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self.init(modifiers)
    }

    /// The Return the app is handling, when it is handling one: Return or the keypad's Enter.
    init?(event: NSEvent?) {
        guard let event, event.type == .keyDown, [36, 76].contains(event.keyCode) else { return nil }
        self.init(event.modifierFlags)
    }
}

/// The composer field's window and the Return an input method took while composing: a reference
/// the key handlers share, so noting a key redraws nothing.
@MainActor
final class ComposerFieldContext {
    weak var window: NSWindow?
    /// A Return pressed while an input method composed, for the `onSubmit` it passes on.
    var composedReturn: ComposerReturnKey?

    /// The field's editor while it has keyboard focus: in this composer's window, or the key window.
    var editor: NSTextView? {
        if let editor = window?.firstResponder as? NSTextView, editor.isEditable { return editor }
        return ComposerFieldEditor.focused
    }

    /// An input method is composing a character in the field.
    var hasMarkedText: Bool {
        editor?.hasMarkedText() == true || ComposerFieldEditor.hasMarkedText
    }

    func takeComposedReturn() -> ComposerReturnKey? {
        defer { composedReturn = nil }
        return composedReturn
    }

    /// A line at the caret, as Option-Return adds one: through the field editor, so undo and the
    /// caret follow; at the end of the draft if the editor is not there.
    func insertLine(into draft: some ComposerDraftEditing) {
        if let editor, editor.string.utf16.elementsEqual(draft.text.utf16) {
            editor.insertNewlineIgnoringFieldEditor(nil)
        } else {
            draft.text += "\n"
        }
    }
}

/// Tells the composer's field context which window the composer is in.
private struct ComposerWindowProbe: NSViewRepresentable {
    let context: ComposerFieldContext

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.fieldContext = self.context
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.fieldContext = self.context
        self.context.window = view.window
    }

    final class ProbeView: NSView {
        weak var fieldContext: ComposerFieldContext?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            fieldContext?.window = window
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The composer's text field as AppKit edits it. SwiftUI hands the field editor keyboard focus a
/// turn after it is asked to, and an input method's composition lives in that editor.
@MainActor
enum ComposerFieldEditor {
    /// The editable field editor with keyboard focus in the key window.
    static var focused: NSTextView? {
        guard let editor = NSApplication.shared.keyWindow?.firstResponder as? NSTextView, editor.isEditable else { return nil }
        return editor
    }

    /// An input method is composing a character in the key window's field.
    static var hasMarkedText: Bool {
        (NSApplication.shared.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    /// Puts the caret at `location` (UTF-16; the end when nil) once the field has focus, while it
    /// still shows the draft's text.
    static func placeCaret(at location: Int?, in draft: some ComposerDraftEditing, isFocused: FocusState<Bool>.Binding) {
        Task { @MainActor in
            await Task.yield()
            guard isFocused.wrappedValue, let editor = focused,
                  editor.string.utf16.elementsEqual(draft.text.utf16) else { return }
            editor.setSelectedRange(NSRange(location: location ?? editor.string.utf16.count, length: 0))
        }
    }

    /// A chosen command goes into the draft and the field takes focus with the caret after it.
    static func insert(_ command: ProviderComposerCommand, into draft: some ComposerDraftEditing,
                       isFocused: FocusState<Bool>.Binding) {
        draft.insertCommand(command)
        isFocused.wrappedValue = true
        placeCaret(at: nil, in: draft, isFocused: isFocused)
    }
}

extension ComposerDraftEditing {
    /// What a paste or drop hands the composer. Files join as the pickers would add them; image
    /// data is written to a private file first, off the main thread.
    func receive(_ input: ComposerExternalInput, policy: HarnessComposerInputPolicy) {
        switch input {
        case let .files(urls):
            attachFiles(urls, policy: policy)
        case let .image(data, type):
            guard policy.carriesImages else {
                notice = L10n.string("Unsupported attachment type")
                return
            }
            Task { await attachPastedImage(data, type: type) }
        }
    }

    func attachPastedImage(_ data: Data, type: NSPasteboard.PasteboardType) async {
        let stored = await Task.detached(priority: .userInitiated) {
            ComposerExternalInput.pngData(data, type: type)
                .flatMap { try? ComposerAttachmentIntake.storePastedImage($0) }
        }.value
        guard let image = stored.flatMap(CodexUserInput.localAttachment(for:)) else {
            notice = L10n.string("The pasted image could not be attached.")
            return
        }
        attachments.append(image)
    }
}

/// What a composer chip shows for one input: an image it can preview, as a thumbnail whose name
/// stays for the pointer and VoiceOver, or a symbol and a name. A remote image is never fetched.
enum ComposerChipContent: Equatable {
    case thumbnail(URL, name: String)
    case label(symbol: String, text: String)

    init(_ input: CodexUserInput) {
        switch input {
        case let .image(url, _) where TranscriptImageThumbnails.canPreview(url),
             let .localImage(url, _) where TranscriptImageThumbnails.canPreview(url):
            self = .thumbnail(url, name: Self.label(for: input))
        default:
            self = .label(symbol: Self.symbol(for: input), text: Self.label(for: input))
        }
    }

    /// The chip's name: a file's own, except a pasted image's, whose file name Yardlet made up.
    static func label(for input: CodexUserInput) -> String {
        switch input {
        case let .text(value, _): value
        case let .image(url, _) where url.scheme == "data": L10n.string("Image")
        case let .localImage(url, _) where ComposerAttachmentIntake.isPastedImage(url): L10n.string("Image")
        case let .image(url, _), let .localImage(url, _), let .audio(url), let .localAudio(url):
            url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
        case let .skill(name, _): "$\(name)"
        case let .mention(name, _): "@\(name)"
        case .unknown: L10n.string("Unknown input")
        }
    }

    static func symbol(for input: CodexUserInput) -> String {
        switch input {
        case .text: "text.alignleft"
        case .image, .localImage: "photo"
        case .audio, .localAudio: "waveform"
        case .skill: "wand.and.stars"
        case .mention: "at"
        case .unknown: "questionmark"
        }
    }
}

/// One attachment, mention or skill in a composer's chip row. An image shows as a thumbnail, as
/// the Codex and Claude apps show one; anything else, or an image that cannot be read, as its name.
/// A click on an image opens it over the window, where an attached image file can be marked up
/// (`ImageMarkupPresenter`) and its marked copy takes its place.
struct ComposerInputChip: View {
    let input: CodexUserInput
    var window: NSWindow?
    var onMarkedUp: ((URL) -> Void)?
    let onRemove: () -> Void

    var body: some View {
        switch ComposerChipContent(input) {
        case let .thumbnail(url, name):
            ComposerImageChip(url: url, name: name, onMarkup: markup(url), onRemove: onRemove)
        case let .label(symbol, text):
            ComposerLabelChip(symbol: symbol, label: text, onRemove: onRemove)
        }
    }

    private func markup(_ url: URL) -> (() -> Void)? {
        guard case .localImage = input, url.isFileURL, let onMarkedUp else { return nil }
        return { [window] in ImageMarkupPresenter.open(url, window, onMarkedUp) }
    }
}

/// A chip of a symbol and a name, with its remove button.
struct ComposerLabelChip: View {
    let symbol: String
    let label: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(label)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .parityPointer()
            .accessibilityLabel(L10n.string("Remove attachment"))
            .help(L10n.string("Remove attachment"))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(ParityTheme.subtleFill, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Attached input"))
        .accessibilityValue(label)
    }
}

/// An attached image as a small thumbnail with its remove button in the corner. The preview is
/// decoded off the main thread at a bounded size and shared with the sent message's
/// (`TranscriptImageThumbnails`), so typing never waits for it. Until it is ready the tile is
/// empty; an image that cannot be read shows its name as other attachments do. A click opens it
/// over the window (`openImageViewer`).
struct ComposerImageChip: View {
    let url: URL
    let name: String
    /// Opens the image to mark up; nil for an image that cannot be marked up here.
    var onMarkup: (() -> Void)?
    let onRemove: () -> Void

    static let side: CGFloat = 48

    @State private var loaded: (url: URL, preview: TranscriptImageThumbnails.Preview)?
    @Environment(\.openImageViewer) private var openImageViewer

    var body: some View {
        content
            .task(id: url) {
                // A cached preview is kept here too: NSCache may drop it later, and this task does
                // not run again for the same file.
                let preview = await TranscriptImageThumbnails.shared.preview(for: url)
                guard !Task.isCancelled else { return }
                loaded = (url, preview)
            }
    }

    @ViewBuilder
    private var content: some View {
        if case .unavailable? = preview {
            ComposerLabelChip(symbol: "photo", label: name, onRemove: onRemove)
        } else {
            tile
        }
    }

    private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return ZStack {
            shape.fill(ParityTheme.subtleFill)
            if case let .image(image)? = preview {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: Self.side, height: Self.side)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(shape)
        .overlay { shape.stroke(ParityTheme.separator) }
        .contentShape(shape)
        .onTapGesture(perform: open)
        .parityPointer()
        // Read as the label chip's name is: the image by its name, then its remove button.
        .accessibilityElement()
        .accessibilityLabel(name)
        .accessibilityAddTraits(.isImage)
        .accessibilityAction { open() }
        .accessibilityAction(named: L10n.string("Mark Up")) { onMarkup?() }
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(.black.opacity(0.6), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .parityPointer()
            .padding(3)
            .accessibilityLabel(L10n.string("Remove attachment"))
            .help(L10n.string("Remove attachment"))
        }
        .help(L10n.format("%@ · Click to view", name))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Attached input"))
        .accessibilityValue(name)
    }

    private func open() {
        openImageViewer(ImageViewerRequest(items: [ImageViewerItem(name: name, source: .url(url))], index: 0,
                                           markUp: onMarkup))
    }

    /// The loaded preview, or one already cached (a sent message's, a chip shown before).
    private var preview: TranscriptImageThumbnails.Preview? {
        if let loaded, loaded.url == url { return loaded.preview }
        return TranscriptImageThumbnails.shared.cachedPreview(for: url)
    }
}
