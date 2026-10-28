import SwiftUI

// A turn's work as the Claude desktop app's Code screen draws it (`TurnStatus`, `TurnStatusStep` in
// its design system; 2026-10-15 user decision), the same for every
// harness. Each call and the provider's own thinking is one line — what was done, muted, and what it
// was done to — with a caret after the words when it opens into what it holds. A run of two or more
// calls reads as one summary line that opens into a card with a one-point ring and a cell per call.
// The colors are Yardlet's own; the words are each provider's (`ConversationLineWording`): a Codex
// command reads as the Codex app words it ("Read Parser.swift", "Ran swift test"), a Claude Code
// call as Claude Code does ("Searched TODO", "Ran tests").
//
// A line keeps what the cards it replaced offered: a command's whole command, live output and exit
// code and "Run in terminal" (plan B10), a file change's diff box and file links, a call's input,
// output, MCP result and error, the "Allowed" mark of an answered request, "Copy item details", the
// history match's tint, and a failed call opening itself. Its actions stay in view at the end of the
// line. A command starts folded while it runs and after (2026-10-16, `ConversationWorkDisclosure`);
// its line marks that it runs, and a Claude Code shell task stops from it.

private struct OpensDetailsForReviewKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ConversationDisclosureChoicesKey: EnvironmentKey {
    static let defaultValue: ConversationDisclosureChoices? = nil
}

extension EnvironmentValues {
    /// Opens a file change's diff and the thinking when their lines appear, for window-less review
    /// renders that cannot click them open. False in the app.
    var opensDetailsForReview: Bool {
        get { self[OpensDetailsForReviewKey.self] }
        set { self[OpensDetailsForReviewKey.self] = newValue }
    }

    /// The turn's record of what the person opened and folded, which its lines start from.
    var conversationDisclosureChoices: ConversationDisclosureChoices? {
        get { self[ConversationDisclosureChoicesKey.self] }
        set { self[ConversationDisclosureChoicesKey.self] = newValue }
    }
}

/// The size of a status line's words, which the marks beside them are set on.
enum ConversationStatusLineFont {
    static let size: CGFloat = 14
}

/// The words, trailing marks and caret of one status line.
private struct ConversationStatusLineLabel<Trailing: View>: View {
    let words: ConversationLineWords
    let phase: ConversationItemPhase
    let isOpen: Bool
    let canOpen: Bool
    let trailing: Trailing

    @Environment(\.yardletInterfaceScale) private var interfaceScale

    /// The line's words (Claude Code's `--chat-body`), which its marks are set on.
    static var fontSize: CGFloat { ConversationStatusLineFont.size }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !words.leading.isEmpty { subject(words.leading) }
                if !words.verb.isEmpty {
                    Text(words.verb)
                        .foregroundStyle(phase == .running ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                        .layoutPriority(1)
                }
                if !words.trailing.isEmpty { subject(words.trailing) }
            }
            // A selection across the conversation takes the line's words, as the apps copy a folded line.
            .conversationSelectionText(words.text)
            .layoutPriority(1)
            trailing
            if canOpen {
                DisclosureCaret(isOpen: isOpen, size: 8 * interfaceScale)
                    .foregroundStyle(.tertiary)
                    .centeredOnCapHeight(ofTextSize: Self.fontSize * interfaceScale)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: Self.fontSize * interfaceScale))
        .lineLimit(1)
        // `--cds-h-control`: a 24 pt row around the 20 pt line.
        .frame(minHeight: 24 * interfaceScale)
        .contentShape(Rectangle())
    }

    private func subject(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(isOpen ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// One line that opens into what it holds, set under the line. A Codex command the App Server parsed
/// into several things (two files read in one `&&`) reads one line of words for each, as the Codex
/// app gives each its row; they open together.
struct ConversationStatusLine<Trailing: View, Actions: View, Detail: View>: View {
    let words: [ConversationLineWords]
    let phase: ConversationItemPhase
    let hasDetail: Bool
    /// What assistive apps call the line: the kind of call ("Command", "File change", the tool's name).
    let accessibilityLabel: String
    /// Opens for a review render (`opensDetailsForReview`).
    let opensForReview: Bool
    let isHistoryMatch: Bool
    let trailing: Trailing
    let actions: Actions
    let detail: Detail
    /// The call's images, small at the line's end while it is folded; opened, its details show them.
    let images: [ConversationToolImage]
    /// The person opened or folded the line.
    let onToggle: ((Bool) -> Void)?

    @Environment(\.opensDetailsForReview) private var reviewOpensDetails
    @State private var isOpen: Bool

    /// `startsOpen` is where the line starts (`ConversationWorkDisclosure.lineStartsOpen`); a call
    /// that fails later opens itself.
    init(
        words: [ConversationLineWords], phase: ConversationItemPhase, hasDetail: Bool, startsOpen: Bool,
        accessibilityLabel: String, opensForReview: Bool = false,
        isHistoryMatch: Bool = false, images: [ConversationToolImage] = [], onToggle: ((Bool) -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing, @ViewBuilder actions: () -> Actions,
        @ViewBuilder detail: () -> Detail
    ) {
        self.onToggle = onToggle
        self.images = images
        self.words = words.isEmpty ? [ConversationLineWords(verb: accessibilityLabel)] : words
        self.phase = phase
        self.hasDetail = hasDetail
        self.accessibilityLabel = accessibilityLabel
        self.opensForReview = opensForReview
        self.isHistoryMatch = isHistoryMatch
        self.trailing = trailing()
        self.actions = actions()
        self.detail = detail()
        // A finished turn still folds its work (D2).
        _isOpen = State(initialValue: startsOpen)
    }

    var body: some View {
        let showsDetail = isOpen && hasDetail
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 2) {
                if hasDetail {
                    Button {
                        isOpen.toggle()
                        onToggle?(isOpen)
                    } label: {
                        labels(isOpen: showsDetail)
                    }
                    .buttonStyle(.plain)
                    .parityPointer()
                    .accessibilityLabel(words.map(\.text).joined(separator: ", "))
                    .accessibilityValue(L10n.string(showsDetail ? "Expanded" : "Collapsed"))
                } else {
                    labels(isOpen: false)
                        .accessibilityElement(children: .combine)
                }
                if !showsDetail {
                    ConversationToolImageThumbnails(images: images)
                }
                actions
            }
            if showsDetail {
                detail
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                    .padding(.bottom, 4)
            }
        }
        .background(isHistoryMatch ? ParityTheme.accent.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: phase) { _, newPhase in
            if newPhase == .failed { isOpen = true }
        }
        .onAppear { if reviewOpensDetails, opensForReview { isOpen = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(ConversationActivityAccessibility.value(phase: phase, isHistoryMatch: isHistoryMatch))
    }

    /// The first line carries the marks and the caret.
    private func labels(isOpen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, line in
                if index == 0 {
                    ConversationStatusLineLabel(words: line, phase: phase, isOpen: isOpen, canOpen: hasDetail,
                                                trailing: trailing)
                } else {
                    ConversationStatusLineLabel(words: line, phase: phase, isOpen: isOpen, canOpen: false,
                                                trailing: EmptyView())
                }
            }
        }
    }
}

/// A run of calls as Claude Code folds it: one summary line that opens into a card with a one-point
/// ring (`shadow-card-ring`, 10 pt corners) and a cell per call (`px-md`), divided by rules. Where it
/// starts is `ConversationWorkDisclosure.groupStartsOpen`; it opens when one of its calls fails, and
/// folded while one runs, it marks that it runs.
struct ConversationWorkGroup<Cell: View>: View {
    let items: [ConversationItem]
    let harness: HarnessKind
    /// The person opened or folded the summary.
    let onToggle: ((Bool) -> Void)?
    let cell: (ConversationItem) -> Cell

    @State private var isOpen: Bool
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    init(items: [ConversationItem], harness: HarnessKind, startsOpen: Bool, onToggle: ((Bool) -> Void)? = nil,
         @ViewBuilder cell: @escaping (ConversationItem) -> Cell) {
        self.items = items
        self.harness = harness
        self.onToggle = onToggle
        self.cell = cell
        _isOpen = State(initialValue: startsOpen)
    }

    var body: some View {
        let title = ConversationWorkSummary.header(for: items, harness: harness)
        let phase = ConversationWorkSummary.phase(of: items)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 2) {
                Button {
                    isOpen.toggle()
                    onToggle?(isOpen)
                } label: {
                    ConversationStatusLineLabel(words: title, phase: phase, isOpen: isOpen, canOpen: true,
                                                trailing: ConversationRunningMark(isShown: phase == .running && !isOpen)
                                                    .centeredOnCapHeight(ofTextSize: ConversationStatusLineFont.size * interfaceScale))
                }
                .buttonStyle(.plain)
                .parityPointer()
                .accessibilityLabel(title.text)
                .accessibilityValue(L10n.string(isOpen ? "Expanded" : "Collapsed"))
                // Folded, the summary shows its calls' images, as the Claude app's turn summary does.
                if !isOpen {
                    ConversationToolImageThumbnails(images: items.flatMap(\.toolPreviewImages))
                }
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Rectangle().fill(ParityTheme.separator).frame(height: 1)
                        }
                        cell(item)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                    }
                }
                .padding(.vertical, 4)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ParityTheme.separator, lineWidth: 1)
                }
                .padding(.bottom, 4)
            }
        }
        .onChange(of: ConversationWorkDisclosure.groupHasFailure(items)) { _, failed in
            if failed { isOpen = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title.text)
        .accessibilityValue(ConversationActivityStatus.label(phase))
    }
}

/// The small spinner a folded line shows while what it stands for runs. The line's own value already
/// says it is in progress, so assistive apps skip the spinner.
struct ConversationRunningMark: View {
    let isShown: Bool

    var body: some View {
        if isShown {
            ProgressView()
                .controlSize(.mini)
                .accessibilityHidden(true)
        }
    }
}

/// Which items of a turn's work are status lines, and which of them fold together.
enum ConversationWorkGrouping {
    enum Run: Identifiable {
        case single(ConversationItem)
        case group([ConversationItem])
        /// Consecutive suggested tasks, one card as the Claude app aggregates its `spawn_task` chips.
        case suggestions([ConversationItem])

        var id: String {
            switch self {
            case let .single(item): item.id
            case let .group(items): "group-" + (items.first?.id ?? "")
            case let .suggestions(items): "suggestions-" + (items.first?.id ?? "")
            }
        }
    }

    /// A call, and reasoning without a summary to read (Claude Code's thinking, Codex's raw content).
    static func drawsAsLine(_ item: ConversationItem) -> Bool {
        switch item.kind {
        case .command, .fileChange, .tool: true
        case let .reasoning(summary, _, _): summary == nil
        default: false
        }
    }

    /// Consecutive calls, two or more, become one group, and consecutive suggested tasks one card;
    /// everything else stays as it is.
    static func runs(_ items: [ConversationItem]) -> [Run] {
        var runs: [Run] = []
        var pending: [ConversationItem] = []
        func flush() {
            if pending.count > 1 { runs.append(.group(pending)) } else if let one = pending.first { runs.append(.single(one)) }
            pending = []
        }
        for item in items {
            if ConversationWorkSummary.category(of: item) != nil {
                pending.append(item)
            } else if case .taskSuggestion = item.kind {
                flush()
                if case let .suggestions(previous)? = runs.last {
                    runs[runs.count - 1] = .suggestions(previous + [item])
                } else {
                    runs.append(.suggestions([item]))
                }
            } else {
                flush()
                runs.append(.single(item))
            }
        }
        flush()
        return runs
    }

    /// What a folded turn keeps of its work (`ConversationTurn.workKeptWhenFolded`) but the calls the
    /// live line stands for, in the runs the listed work has: consecutive calls still one summary line,
    /// suggested tasks one card.
    static func runsKeptWhenFolded(_ turn: ConversationTurn, live: ConversationLiveWork?) -> [Run] {
        let liveIDs = Set(live?.items.map(\.id) ?? [])
        return runs(turn.workKeptWhenFolded.filter { !liveIDs.contains($0.id) })
    }
}

/// The status line of each kind of call, and of reasoning without a summary.
struct ConversationWorkLine: View, Equatable {
    let item: ConversationItem
    /// Whose words the line reads in (`ConversationLineWording`).
    let harness: HarnessKind
    /// The task's folder: a file change's rows and a call's paths are read against it.
    let workspaceURL: URL?
    var runInTerminal: ((String) -> Void)? = nil
    /// Stops a Claude Code shell task from its command's line, as the subagent card stops a task.
    var subtaskControls: HarnessActivityActions? = nil
    /// What the line draws from its closures, for telling an unchanged line apart.
    private let offers: Offers

    private struct Offers: Equatable, Sendable {
        /// Whose words the line reads in, which is all the line takes from its harness.
        let wording: HarnessKind
        let workspaceURL: URL?
        let canRunInTerminal: Bool
        let canStop: Bool
        let isStopping: Bool
        let stopError: String?
    }

    init(item: ConversationItem, harness: HarnessKind, workspaceURL: URL?,
         runInTerminal: ((String) -> Void)? = nil, subtaskControls: HarnessActivityActions? = nil) {
        self.item = item
        self.harness = harness
        self.workspaceURL = workspaceURL
        self.runInTerminal = runInTerminal
        self.subtaskControls = subtaskControls
        let task: String? = if case let .command(command) = item.kind { command.task?.activityID } else { nil }
        offers = Offers(
            wording: harness, workspaceURL: workspaceURL, canRunInTerminal: runInTerminal != nil, canStop: subtaskControls?.stop != nil,
            isStopping: task.map { subtaskControls?.isStopping($0) ?? false } ?? false,
            stopError: task.flatMap { subtaskControls?.error($0) }
        )
    }

    /// A running turn's lines are drawn again each time the turn streams; their closures are made
    /// afresh each time, so a line compared `.equatable()` is drawn again only when its item, its
    /// words or what it offers changed, not once per streamed fragment for every call of the turn.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.offers == rhs.offers
    }

    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.conversationDisclosureChoices) private var choices

    /// Where the line starts: folded unless it failed or the person opened it, here or wherever
    /// it was drawn before in the turn.
    private var startsOpen: Bool {
        ConversationWorkDisclosure.lineStartsOpen(item, choice: choices?.choice(item.id))
    }

    private func record(_ isOpen: Bool) {
        choices?.record(item.id, isOpen: isOpen)
    }

    var body: some View {
        switch item.kind {
        case let .command(command):
            commandLine(command)
        case let .fileChange(change):
            fileChangeLine(change)
        case let .tool(tool):
            toolLine(tool)
        case let .reasoning(_, detail, isStreaming) where isStreaming || detail?.isEmpty == false:
            ConversationStatusLine(
                words: [ConversationLineWords(verb: isStreaming ? L10n.string("Thinking") : L10n.string("Thought process"))],
                phase: isStreaming ? .running : .completed, hasDetail: detail?.isEmpty == false,
                startsOpen: startsOpen,
                accessibilityLabel: L10n.string("Thought process"), opensForReview: true,
                isHistoryMatch: item.isHistoryMatch, onToggle: record
            ) {
                EmptyView()
            } actions: {
                EmptyView()
            } detail: {
                Text(detail ?? "")
                    .font(.system(size: 12 * interfaceScale))
                    .foregroundStyle(.secondary)
                    .lineSpacing(ParityTheme.proseLineSpacing * interfaceScale)
                    .textSelection(.enabled)
            }
        default:
            EmptyView()
        }
    }

    // MARK: Command

    private func commandLine(_ command: ConversationCommand) -> some View {
        let output = command.output ?? ""
        let words = ConversationLineWording.command(command, phase: item.phase, harness: harness)
        // The details keep the whole command as it ran whenever the line words it otherwise.
        let showsCommand = !ConversationLineWording.showsWholeCommand(command, words: words)
            && !command.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let failedExit = command.exitCode.map { $0 != 0 } ?? false
        let stop = stopTask(command)
        return VStack(alignment: .leading, spacing: 2) {
            commandStatusLine(command, words: words, output: output, showsCommand: showsCommand,
                              failedExit: failedExit, stop: stop)
            if let error = stop?.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private func commandStatusLine(
        _ command: ConversationCommand, words: [ConversationLineWords], output: String, showsCommand: Bool,
        failedExit: Bool, stop: ConversationStopTaskButton?
    ) -> some View {
        ConversationStatusLine(
            words: words, phase: item.phase,
            hasDetail: !output.isEmpty || showsCommand || failedExit,
            startsOpen: startsOpen,
            accessibilityLabel: L10n.string("Command"), isHistoryMatch: item.isHistoryMatch, onToggle: record
        ) {
            // Folded while it runs, the line says so.
            ConversationRunningMark(isShown: item.phase == .running)
                .centeredOnCapHeight(ofTextSize: ConversationStatusLineFont.size * interfaceScale)
            if command.isApproved { ConversationAllowedMark() }
        } actions: {
            if let stop { stop }
            // The terminal gets the command exactly as it ran, wrapper and all, never the line's words.
            if let terminalCommand = ConversationRunInTerminalButton.offer(command.command, runInTerminal) {
                ConversationRunInTerminalButton(action: terminalCommand)
            }
            ConversationCopyDetailsButton(details: item.copyDetails)
        } detail: {
            VStack(alignment: .leading, spacing: 6) {
                if showsCommand {
                    Text(verbatim: command.command)
                        .font(.system(size: 11 * interfaceScale, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.trailing, 26)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hoverCopy(L10n.string("Copy command")) { command.command }
                }
                if !output.isEmpty {
                    CodexCommandOutput(text: output, isRunning: item.phase == .running,
                                       command: showsCommand ? nil : command.command)
                }
                if let exitCode = command.exitCode, exitCode != 0 {
                    Text(L10n.format("Exit code %lld", exitCode))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.red)
                }
            }
        }
    }

    /// "Stop task" for a running shell task the task can stop: the provider's task with an ID, as
    /// the subagent card offers it (B8, 13.14).
    private func stopTask(_ command: ConversationCommand) -> ConversationStopTaskButton? {
        guard item.phase == .running, let task = command.task, task.reference.taskID != nil,
              let controls = subtaskControls, let stop = controls.stop else { return nil }
        let activity = HarnessActivity(id: task.activityID, kind: "Bash", title: command.description ?? command.command,
                                       subtask: task.reference)
        return ConversationStopTaskButton(isStopping: controls.isStopping(task.activityID),
                                          error: controls.error(task.activityID)) { stop(activity) }
    }

    // MARK: File change

    private func fileChangeLine(_ change: ConversationFileChange) -> some View {
        let rows = change.placesRowsInWorkspace ? change.rows.map { $0.placed(in: workspaceURL) } : change.rows
        let first = rows.first
        let error = change.errorMessage.flatMap { $0.isEmpty ? nil : $0 }
        return ConversationStatusLine(
            words: [ConversationLineWords(verb: first?.verb ?? L10n.string("Edited"),
                                          trailing: rows.map(\.fileName).joined(separator: ", "))],
            phase: item.phase, hasDetail: rows.contains(where: \.canExpand) || error != nil,
            startsOpen: startsOpen,
            accessibilityLabel: L10n.string("File change"),
            opensForReview: true, isHistoryMatch: item.isHistoryMatch, onToggle: record
        ) {
            if rows.count == 1, let counts = first?.lineCounts {
                CodexLineCountsText(counts: counts)
                    .font(.system(size: 13 * interfaceScale).monospacedDigit())
            }
            if item.phase == .failed, rows.allSatisfy({ $0.state != .rejected }) {
                Text(L10n.string("Failed")).foregroundStyle(Color.red)
            }
            if change.isApproved { ConversationAllowedMark() }
        } actions: {
            ConversationCopyDetailsButton(details: item.copyDetails)
        } detail: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows.filter(\.canExpand)) { row in
                    let handoff = change.handoffs.first { $0.relativePath == row.id }
                    CodexFileDiffBox(row: row) {
                        CodexFileChangeLink(row: row, handoff: handoff, label: row.displayPath)
                    }
                }
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: Other calls

    private func toolLine(_ tool: ConversationTool) -> some View {
        let texts = [tool.input, tool.output, tool.detail, tool.errorMessage].compactMap { $0 }.filter { !$0.isEmpty }
        let images = tool.previewImages
        return ConversationStatusLine(
            words: [ConversationLineWording.tool(tool, phase: item.phase, harness: harness, workspaceURL: workspaceURL)],
            phase: item.phase,
            hasDetail: !texts.isEmpty || tool.mcpResult?.isEmpty == false || tool.diff != nil || !tool.images.isEmpty,
            startsOpen: startsOpen,
            accessibilityLabel: tool.name.isEmpty ? tool.kind.label : tool.name, isHistoryMatch: item.isHistoryMatch,
            images: images, onToggle: record
        ) {
            if let connector = tool.connector {
                ConnectorIcon(name: connector.connector, presetID: connector.presetID, sources: connector.icons, size: 16 * interfaceScale)
                    .centeredOnCapHeight(ofTextSize: ConversationStatusLineFont.size * interfaceScale)
            }
            if item.phase == .running {
                ProgressView().controlSize(.mini)
                    .centeredOnCapHeight(ofTextSize: ConversationStatusLineFont.size * interfaceScale)
            } else if item.phase == .failed {
                Text(L10n.string("Failed")).foregroundStyle(Color.red)
            }
            if tool.isApproved { ConversationAllowedMark() }
        } actions: {
            ConversationCopyDetailsButton(details: item.copyDetails)
        } detail: {
            VStack(alignment: .leading, spacing: 10) {
                if let input = tool.input, !input.isEmpty {
                    ConversationActivitySection(title: L10n.string("Input"), text: input,
                                                accessibilityLabel: L10n.string("Tool input"))
                }
                if let output = tool.output, !output.isEmpty {
                    ConversationActivitySection(title: L10n.string("Output"), text: output,
                                                accessibilityLabel: L10n.string("Tool output"))
                }
                if let detail = tool.detail, !detail.isEmpty {
                    ConversationActivityText(text: detail, accessibilityLabel: tool.name)
                }
                if let error = tool.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                ConversationToolImageDetails(images: Array(images.prefix(tool.images.count)))
                if let result = tool.mcpResult, !result.isEmpty {
                    CodexMCPResultContent(projection: result)
                }
                if let diff = tool.diff {
                    CodexFileChangeRows(
                        rows: [ConversationFileChangeProjection.row(for: diff, phase: item.phase, workspaceURL: workspaceURL)],
                        handoffs: []
                    )
                }
            }
        }
    }
}

/// A line's "Stop task": stops the provider's task the line stands for, then reads "Stop requested"
/// until the task ends. Why it could not be stopped shows under the line.
struct ConversationStopTaskButton: View {
    let isStopping: Bool
    let error: String?
    let action: () -> Void

    var body: some View {
        let title = L10n.string(isStopping ? "Stop requested" : "Stop task")
        Button(action: action) {
            Image(systemName: "stop.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .disabled(isStopping)
        .accessibilityLabel(title)
        .help(title)
    }
}
