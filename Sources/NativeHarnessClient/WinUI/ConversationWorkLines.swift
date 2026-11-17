import Foundation
import UWP
import WinUI

/// What a line of a turn's work draws from its turn: whose words it reads in, the folder its paths are read against,
/// and the person's open and fold choices in the turn, which a line reads where it starts and records when it is
/// opened or folded (`ConversationDisclosureChoices`), so a turn drawn again keeps them.
@MainActor
struct ConversationLineContext {
    let harness: HarnessKind
    let workspaceURL: URL?
    let choices: ConversationDisclosureChoices
}

/// A turn's work as the Mac draws it (`ConversationWorkLines.swift`, `ConversationLiveWorkLine.swift`): a status line
/// for each call and for the provider's thinking, which opens into what it ran and returned; a run of calls folded on
/// its summary line (`ConversationWorkSummary`), which opens into a ringed box with a cell for each; and under a
/// running turn, the one live line that says what the provider does now with the turn's steps and time
/// (`ConversationLiveWork`). What a line holds is drawn when it first opens, so a long conversation draws only what is
/// open. Where each starts is the shared rule (`ConversationWorkDisclosure`).
///
/// A line's handlers hold only what is inside or beside the line, never what holds the line: the bindings keep no
/// Swift object alive for an element XAML holds, and an element holding a handler that holds the element would never
/// be freed.
@MainActor
enum ConversationWorkLines {
    // MARK: - Status line

    /// One status line (the Mac's `ConversationStatusLine`): each of `words` on a line of its own, the first with
    /// `trailing` marks and, when the line holds `detail`, the caret that opens it, and at its far end its
    /// `pictures`, small while it is folded, and `actions`.
    static func statusLine(words: [ConversationLineWords], phase: ConversationItemPhase, name: String,
                           size: Double = ConversationStyle.statusLineSize,
                           startsOpen: Bool, trailing: [UIElement] = [], actions: [UIElement] = [],
                           pictures: [ConversationPicture] = [],
                           detail: (@MainActor () -> UIElement)?,
                           onToggle: (@MainActor (Bool) -> Void)? = nil) -> UIElement {
        let lines = words.isEmpty ? [ConversationLineWords(verb: name)] : words
        let isOpen = startsOpen && detail != nil
        var subjects: [TextBlock] = []
        let labels = StackPanel()
        let caret = ConversationStyle.caret(isOpen: isOpen)
        for (index, line) in lines.enumerated() {
            var pieces: [(element: UIElement, shrinks: Bool)] = []
            for (part, isSubject) in [(line.leading, true), (line.verb, false), (line.trailing, true)] where !part.isEmpty {
                let tone: ConversationStyle.Tone = isSubject ? (isOpen ? .primary : .secondary)
                    : phase == .running ? .secondary : .tertiary
                let piece = ConversationStyle.text(part, size: size, tone: tone, selectable: false, wraps: false)
                piece.verticalAlignment = .center
                if isSubject { subjects.append(piece) }
                pieces.append((piece, isSubject))
            }
            if index == 0 {
                pieces += trailing.map { (element: $0, shrinks: false) }
                if detail != nil { pieces.append((caret, false)) }
            }
            let row = wordsRow(pieces)
            row.minHeight = ConversationStyle.statusLineHeight
            labels.children.append(row)
        }
        let header = Grid()
        for width in [GridLength(value: 1, gridUnitType: .star), GridLength(value: 0, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = width
            header.columnDefinitions.append(column)
        }
        let panel = StackPanel()
        panel.spacing = 4
        panel.children.append(header)
        let accessibleName = lines.map(\.text).joined(separator: ", ")
        let thumbnails = ConversationImages.thumbnails(pictures)
        if let detail {
            let detailPanel = StackPanel()
            detailPanel.margin = Thickness(left: 4, top: 0, right: 0, bottom: 4)
            let drawn = DrawnOnce()
            let show = { (open: Bool) in
                caret.glyph = open ? ConversationStyle.Glyph.chevronDown : ConversationStyle.Glyph.chevronRight
                for subject in subjects { subject.foreground = ConversationStyle.brush(open ? .primary : .secondary) }
                if open, !drawn.isDrawn {
                    drawn.isDrawn = true
                    detailPanel.children.append(detail())
                }
                detailPanel.visibility = open ? .visible : .collapsed
                // Opened, the details show the pictures whole.
                thumbnails?.visibility = open ? .collapsed : .visible
            }
            let toggle = ConversationStyle.disclosure(labels, name: accessibleName, isOpen: isOpen) { open in
                show(open)
                onToggle?(open)
            }
            header.children.append(toggle)
            show(isOpen)
            panel.children.append(detailPanel)
        } else {
            labels.margin = Thickness(left: 2, top: 0, right: 2, bottom: 0)
            try? AutomationProperties.setName(labels, accessibleName)
            header.children.append(labels)
        }
        var end: [UIElement] = actions
        if let thumbnails {
            thumbnails.margin = Thickness(left: 6, top: 0, right: actions.isEmpty ? 0 : 4, bottom: 0)
            end.insert(thumbnails, at: 0)
        }
        let actionRow = ConversationStyle.row(end, spacing: 2)
        actionRow.verticalAlignment = .top
        try? Grid.setColumn(actionRow, 1)
        header.children.append(actionRow)
        return panel
    }

    /// A line's words and marks side by side as the Mac sets them (`ConversationStatusLineLabel`): a subject too long
    /// for the column gives way first and ends in an ellipsis, so the verb, the marks and the caret stay in view, and
    /// a short line keeps them right after its words. Left-aligned, the grid is as wide as what it holds, and its
    /// subjects' star columns take only what is left after the rest.
    private static func wordsRow(_ pieces: [(element: UIElement, shrinks: Bool)]) -> Grid {
        let row = Grid()
        row.horizontalAlignment = .left
        row.columnSpacing = 6
        for (index, piece) in pieces.enumerated() {
            let column = ColumnDefinition()
            column.width = piece.shrinks ? GridLength(value: 1, gridUnitType: .star)
                : GridLength(value: 0, gridUnitType: .auto)
            row.columnDefinitions.append(column)
            if let placed = piece.element as? FrameworkElement { try? Grid.setColumn(placed, Int32(index)) }
            row.children.append(piece.element)
        }
        return row
    }

    /// Whether what a line holds was drawn yet.
    private final class DrawnOnce {
        var isDrawn = false
    }

    // MARK: - A run of calls

    /// A run of calls as Claude Code folds it (the Mac's `ConversationWorkGroup`): its summary line, with a spinner
    /// while one of its calls runs and it is folded, and opened, a box with a one-point ring and 10-point corners and
    /// a cell for each call and each thought among them, divided by rules.
    static func group(_ items: [ConversationItem], context: ConversationLineContext, startsOpen: Bool,
                      onToggle: @escaping @MainActor (Bool) -> Void) -> UIElement {
        let title = ConversationWorkSummary.header(for: items, harness: context.harness)
        let phase = ConversationWorkSummary.phase(of: items)
        let spinner = ConversationStyle.spinner()
        let showsSpinner = { (open: Bool) in spinner.visibility = phase == .running && !open ? .visible : .collapsed }
        showsSpinner(startsOpen)
        return statusLine(words: [title], phase: phase, name: title.text, startsOpen: startsOpen, trailing: [spinner],
                          pictures: items.flatMap(\.toolPictures),
                          detail: { box(items.map { line(for: $0, context: context) }) }) { open in
            showsSpinner(open)
            onToggle(open)
        }
    }

    /// The ringed box a run of calls opens into, a cell for each line, divided by rules.
    static func box(_ cells: [UIElement?]) -> UIElement {
        let stack = StackPanel()
        stack.padding = Thickness(left: 0, top: 4, right: 0, bottom: 4)
        for cell in cells.compactMap({ $0 }) {
            if stack.children.size > 0 {
                let rule = Border()
                rule.height = 1
                rule.background = WindowsTheme.separator.brush
                stack.children.append(rule)
            }
            let padded = Border()
            padded.padding = Thickness(left: 8, top: 2, right: 8, bottom: 2)
            padded.child = cell
            stack.children.append(padded)
        }
        let frame = Border()
        frame.cornerRadius = ConversationStyle.corners(10)
        frame.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        frame.borderBrush = WindowsTheme.separator.brush
        frame.margin = Thickness(left: 0, top: 0, right: 0, bottom: 4)
        frame.child = stack
        return frame
    }

    // MARK: - The live line

    /// The one live line under a running turn (the Mac's `ConversationLiveWorkLine`): its mark (thinking, the
    /// spinner of a running call, an orange raised hand while it waits on the person), what the provider does now,
    /// then the turn's steps and time in `detail`, which the turn counts on each second. While a call runs or the
    /// thinking streams, the line opens into what it stands for.
    static func liveLine(_ live: ConversationLiveWork, detail: TextBlock, context: ConversationLineContext,
                         startsOpen: Bool, onToggle: @escaping @MainActor (Bool) -> Void) -> UIElement {
        let activity = ConversationStyle.text(live.activity.text, size: ConversationStyle.statusLineSize,
                                              tone: .secondary, selectable: false, wraps: false)
        if live.activity.isWaitingOnPerson { activity.foreground = ConversationStyle.orange.solid.brush }
        activity.verticalAlignment = .center
        detail.fontSize = ConversationStyle.statusLineSize
        detail.foreground = WindowsTheme.tertiaryText.brush
        detail.verticalAlignment = .center
        detail.isTextSelectionEnabled = false
        let mark = liveMark(live.activity.mark)
        var pieces: [UIElement] = [mark, activity, detail]
        let caret = ConversationStyle.caret(isOpen: startsOpen && !live.items.isEmpty)
        if !live.items.isEmpty { pieces.append(caret) }
        // Folded, the line shows its calls' pictures, as a summary line does.
        let thumbnails = live.items.isEmpty ? nil : ConversationImages.thumbnails(live.items.flatMap(\.toolPictures))
        if let thumbnails {
            thumbnails.margin = Thickness(left: 4, top: 0, right: 0, bottom: 0)
            pieces.append(thumbnails)
        }
        let label = ConversationStyle.row(pieces)
        label.minHeight = ConversationStyle.statusLineHeight
        guard !live.items.isEmpty else {
            label.margin = Thickness(left: 2, top: 0, right: 2, bottom: 0)
            try? AutomationProperties.setName(label, live.activity.text)
            return label
        }
        let panel = StackPanel()
        panel.spacing = 6
        let cells = StackPanel()
        let drawn = DrawnOnce()
        let show = { (open: Bool) in
            caret.glyph = open ? ConversationStyle.Glyph.chevronDown : ConversationStyle.Glyph.chevronRight
            if open, !drawn.isDrawn {
                drawn.isDrawn = true
                cells.children.append(box(live.items.map { line(for: $0, context: context) }))
            }
            cells.visibility = open ? .visible : .collapsed
            thumbnails?.visibility = open ? .collapsed : .visible
        }
        panel.children.append(ConversationStyle.disclosure(label, name: live.activity.text, isOpen: startsOpen) { open in
            show(open)
            onToggle(open)
        })
        panel.children.append(cells)
        show(startsOpen)
        return panel
    }

    /// The mark the live line leads with, one for each kind of state, 14 wide as the Mac's.
    private static func liveMark(_ mark: ConversationLiveWork.Mark) -> UIElement {
        let element: FrameworkElement
        switch mark {
        case .thinking:
            element = ConversationStyle.icon(ConversationStyle.Glyph.lightbulb, size: 12)
        case .working:
            element = ConversationStyle.spinner()
        case .waitingOnPerson:
            // A raised hand, as the Mac's `hand.raised.fill`: Segoe UI Symbol's, drawn in the line's orange.
            let hand = TextBlock()
            hand.text = "\u{270B}"
            hand.fontFamily = FontFamily("Segoe UI Symbol")
            hand.isColorFontEnabled = false
            hand.fontSize = 12
            hand.foreground = ConversationStyle.orange.solid.brush
            hand.verticalAlignment = .center
            element = hand
        case .reconnecting:
            element = ConversationStyle.icon(ConversationStyle.Glyph.sync, size: 12)
        }
        let frame = Border()
        frame.width = 14
        frame.height = 14
        frame.verticalAlignment = .center
        element.horizontalAlignment = .center
        frame.child = element
        return frame
    }

    // MARK: - Each line

    /// The status line of a call or of the provider's thinking (the Mac's `ConversationWorkLine`); nil for anything
    /// else, which its turn draws.
    static func line(for item: ConversationItem, context: ConversationLineContext) -> UIElement? {
        let startsOpen = ConversationWorkDisclosure.lineStartsOpen(item, choice: context.choices.choice(item.id))
        let choices = context.choices
        let record: @MainActor (Bool) -> Void = { open in choices.record(item.id, isOpen: open) }
        let actions = copyDetails(item.copyDetails)
        switch item.kind {
        case let .command(command):
            return commandLine(item, command, context: context, startsOpen: startsOpen, actions: actions, record: record)
        case let .fileChange(change):
            return fileChangeLine(item, change, context: context, startsOpen: startsOpen, actions: actions, record: record)
        case let .tool(tool):
            return toolLine(item, tool, context: context, startsOpen: startsOpen, actions: actions, record: record)
        case let .reasoning(summary, detail, isStreaming) where ConversationWorkGrouping.showsThought(item):
            // A summary (Codex) reads first, then the provider's own words.
            let texts = [summary, detail].compactMap { $0 }.filter { !$0.isEmpty }
            let title = L10n.string(isStreaming ? "Thinking" : "Thought process")
            var thought: (@MainActor () -> UIElement)?
            if !texts.isEmpty {
                thought = {
                    let stack = StackPanel()
                    stack.spacing = 6
                    for text in texts {
                        let block = ConversationStyle.text(text, size: ConversationStyle.captionSize, tone: .secondary)
                        block.lineHeight = ConversationStyle.lineHeight(ConversationStyle.captionSize)
                        stack.children.append(block)
                    }
                    return stack
                }
            }
            return statusLine(words: [ConversationLineWords(verb: title)], phase: isStreaming ? .running : .completed,
                              name: L10n.string("Thought process"), startsOpen: startsOpen, actions: actions,
                              detail: thought, onToggle: record)
        default:
            return nil
        }
    }

    private static func commandLine(_ item: ConversationItem, _ command: ConversationCommand,
                                    context: ConversationLineContext, startsOpen: Bool, actions: [UIElement],
                                    record: @escaping @MainActor (Bool) -> Void) -> UIElement {
        let commandOutput = command.output ?? ""
        let words = ConversationLineWording.command(command, phase: item.phase, harness: context.harness)
        // The details keep the whole command as it ran whenever the line words it otherwise.
        let showsCommand = !ConversationLineWording.showsWholeCommand(command, words: words)
            && !command.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let failedExit = command.exitCode.map { $0 != 0 } ?? false
        var trailing: [UIElement] = []
        if item.phase == .running { trailing.append(ConversationStyle.spinner()) }
        if command.isApproved { trailing.append(allowedMark()) }
        var detail: (@MainActor () -> UIElement)?
        if !commandOutput.isEmpty || showsCommand || failedExit {
            detail = {
                let stack = StackPanel()
                stack.spacing = 6
                if showsCommand {
                    let text = ConversationStyle.text(command.command, size: ConversationStyle.smallCodeSize)
                    text.fontFamily = ConversationStyle.codeFont()
                    stack.children.append(text)
                }
                if !commandOutput.isEmpty { stack.children.append(outputBox(commandOutput)) }
                if let exitCode = command.exitCode, exitCode != 0 {
                    let exit = ConversationStyle.text(L10n.format("Exit code %lld", exitCode),
                                                      size: ConversationStyle.captionSize)
                    exit.foreground = ConversationStyle.red.solid.brush
                    stack.children.append(exit)
                }
                return stack
            }
        }
        return statusLine(words: words, phase: item.phase, name: L10n.string("Command"), startsOpen: startsOpen,
                          trailing: trailing, actions: actions, detail: detail, onToggle: record)
    }

    private static func fileChangeLine(_ item: ConversationItem, _ change: ConversationFileChange,
                                       context: ConversationLineContext, startsOpen: Bool, actions: [UIElement],
                                       record: @escaping @MainActor (Bool) -> Void) -> UIElement {
        let rows = change.placesRowsInWorkspace ? change.rows.map { $0.placed(in: context.workspaceURL) } : change.rows
        let error = change.errorMessage.flatMap { $0.isEmpty ? nil : $0 }
        var trailing: [UIElement] = []
        if rows.count == 1, let counts = rows[0].lineCounts { trailing.append(FileChangeView.counts(counts, size: 13)) }
        if item.phase == .failed, rows.allSatisfy({ $0.state != .rejected }) { trailing.append(failed()) }
        if change.isApproved { trailing.append(allowedMark()) }
        let shown = rows.filter(\.canExpand)
        var detail: (@MainActor () -> UIElement)?
        if !shown.isEmpty || error != nil {
            detail = {
                let stack = StackPanel()
                stack.spacing = 6
                for row in shown { stack.children.append(FileChangeView.diffBox(row, title: row.displayPath)) }
                if let error { stack.children.append(errorText(error)) }
                return stack
            }
        }
        return statusLine(words: [ConversationLineWords(verb: rows.first?.verb ?? L10n.string("Edited"),
                                                        trailing: rows.map(\.fileName).joined(separator: ", "))],
                          phase: item.phase, name: L10n.string("File change"), startsOpen: startsOpen,
                          trailing: trailing, actions: actions, detail: detail, onToggle: record)
    }

    private static func toolLine(_ item: ConversationItem, _ tool: ConversationTool, context: ConversationLineContext,
                                 startsOpen: Bool, actions: [UIElement],
                                 record: @escaping @MainActor (Bool) -> Void) -> UIElement {
        let texts = [tool.input, tool.output, tool.detail, tool.errorMessage].compactMap { $0 }.filter { !$0.isEmpty }
        let mcpBlocks = tool.mcpResult?.blocks ?? []
        let pictures = tool.pictures
        var trailing: [UIElement] = []
        if let counts = tool.lineCounts { trailing.append(FileChangeView.counts(counts, size: 13)) }
        if item.phase == .running {
            trailing.append(ConversationStyle.spinner())
        } else if item.phase == .failed {
            trailing.append(failed())
        }
        if tool.isApproved { trailing.append(allowedMark()) }
        let hasDetail = !texts.isEmpty || !mcpBlocks.isEmpty || tool.diff != nil || !tool.diffs.isEmpty
            || !tool.images.isEmpty
        let words = tool.kind.wordedLines
            ?? [ConversationLineWording.tool(tool, phase: item.phase, harness: context.harness,
                                             workspaceURL: context.workspaceURL)]
        let workspaceURL = context.workspaceURL
        var detail: (@MainActor () -> UIElement)?
        if hasDetail {
            detail = {
                let stack = StackPanel()
                stack.spacing = 10
                if let input = tool.input, !input.isEmpty { stack.children.append(section(L10n.string("Input"), input)) }
                if let output = tool.output, !output.isEmpty {
                    stack.children.append(section(L10n.string("Output"), output))
                }
                if let detail = tool.detail, !detail.isEmpty { stack.children.append(outputBox(detail)) }
                if let error = tool.errorMessage, !error.isEmpty { stack.children.append(errorText(error)) }
                // The call's own pictures, then its MCP result as it came: its words and its pictures in order.
                if let own = ConversationImages.details(Array(pictures.prefix(tool.images.count))) {
                    stack.children.append(own)
                }
                let resultPictures = pictures.dropFirst(tool.images.count)
                for block in mcpBlocks {
                    switch block {
                    case let .text(_, text):
                        stack.children.append(outputBox(text))
                    case let .image(id, data, _):
                        let key = CodexMCPResultProjection.previewKey(block: id, data: data)
                        if let picture = resultPictures.first(where: { $0.key == key }) {
                            stack.children.append(ConversationImages.tile(picture, isOneOfSeveral: resultPictures.count > 1))
                        }
                    case .resourceLink:
                        break
                    }
                }
                if let diff = tool.diff {
                    let row = ConversationFileChangeProjection.row(for: diff, phase: item.phase, workspaceURL: workspaceURL)
                    if row.canExpand { stack.children.append(FileChangeView.diffBox(row, title: row.displayPath)) }
                }
                // The files of another computer's change, named as that computer named them.
                for diff in tool.diffs {
                    let row = ConversationFileChangeProjection.row(for: diff, phase: item.phase, workspaceURL: nil)
                    if row.canExpand { stack.children.append(FileChangeView.diffBox(row, title: diff.path)) }
                }
                return stack
            }
        }
        return statusLine(words: words, phase: item.phase, name: tool.name.isEmpty ? tool.kind.label : tool.name,
                          startsOpen: startsOpen, trailing: trailing, actions: actions, pictures: pictures,
                          detail: detail, onToggle: record)
    }

    // MARK: - Pieces

    /// A call's output or other text in the code font, in a box that scrolls once it is long, as the Mac's reader.
    static func outputBox(_ text: String) -> UIElement {
        let block = ConversationStyle.text(text, size: ConversationStyle.smallCodeSize, tone: .secondary)
        block.fontFamily = ConversationStyle.codeFont()
        let scroller = ScrollViewer()
        scroller.maxHeight = 280
        scroller.content = block
        let frame = Border()
        frame.background = WindowsTheme.subtleFill.brush
        frame.cornerRadius = ConversationStyle.corners(6)
        frame.padding = Thickness(left: 8, top: 8, right: 8, bottom: 8)
        frame.child = scroller
        return frame
    }

    /// "Input" or "Output" over a call's text (the Mac's `ConversationActivitySection`).
    private static func section(_ title: String, _ text: String) -> UIElement {
        let stack = StackPanel()
        stack.spacing = 5
        stack.children.append(ConversationStyle.text(title, size: ConversationStyle.captionSize, tone: .tertiary,
                                                     semibold: true))
        stack.children.append(outputBox(text))
        return stack
    }

    private static func errorText(_ text: String) -> TextBlock {
        let block = ConversationStyle.text(text, size: ConversationStyle.captionSize)
        block.foreground = ConversationStyle.red.solid.brush
        return block
    }

    private static func failed() -> TextBlock {
        let block = ConversationStyle.text(L10n.string("Failed"), size: ConversationStyle.statusLineSize,
                                           selectable: false, wraps: false)
        block.foreground = ConversationStyle.red.solid.brush
        block.verticalAlignment = .center
        return block
    }

    /// "Allowed" beside a call the person allowed (the Mac's `ConversationAllowedMark`).
    private static func allowedMark() -> UIElement {
        let words = ConversationStyle.text(L10n.string("Allowed"), size: ConversationStyle.captionSize, tone: .secondary,
                                           selectable: false, wraps: false)
        words.verticalAlignment = .center
        let mark = ConversationStyle.row([
            ConversationStyle.icon(ConversationStyle.Glyph.shield, size: 11, brush: ConversationStyle.green.solid.brush), words
        ], spacing: 3)
        mark.verticalAlignment = .center
        return mark
    }

    /// "Copy item details" at a line's far end, its mark alone in the tertiary tone (the Mac's
    /// `ConversationCopyDetailsButton`).
    private static func copyDetails(_ details: String?) -> [UIElement] {
        guard let details else { return [] }
        let mark = ConversationStyle.icon(ConversationStyle.Glyph.copy, size: 11, brush: WindowsTheme.tertiaryText.brush)
        let frame = Border()
        frame.width = 22
        frame.height = 22
        frame.child = mark
        mark.horizontalAlignment = .center
        let button = ConversationStyle.plainButton(frame, name: L10n.string("Copy item details")) {
            if ConversationStyle.copy(details) { mark.glyph = ConversationStyle.Glyph.check }
        }
        button.padding = Thickness(left: 0, top: 0, right: 0, bottom: 0)
        try? ToolTipService.setToolTip(button, L10n.string("Copy item details"))
        return [button]
    }
}
