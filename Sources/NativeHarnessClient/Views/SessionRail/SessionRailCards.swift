import AppKit
import SwiftUI

/// The inside of one rail card.
struct SessionRailCardBody: View {
    let kind: SessionRailCardKind
    let content: SessionRailContent
    let actions: SessionRailActions

    var body: some View {
        switch kind {
        case .environment:
            SessionRailEnvironmentCard(environment: content.environment, actions: actions)
        case .settings:
            if let settings = content.settings { SessionRailSettingsCard(settings: settings, actions: actions) }
        case .context:
            if let summary = content.context {
                ComposerContextUsageDetails(summary: summary, usage: content.contextUsage,
                                            breakdowns: content.usageBreakdowns, compact: actions.compact,
                                            limit: .make(content.contextLimit, onChoose: actions.onChoose), isInline: true)
            }
        case .usage:
            if let usage = content.usage { SessionRailUsageCard(account: usage) }
        case .connectors:
            if let list = content.connectors { SessionRailConnectorsCard(list: list, actions: actions) }
        case .progress:
            if let progress = content.progress { SessionRailProgressCard(progress: progress) }
        case .changes:
            if let changes = content.changes { SessionRailChangesCard(changes: changes, actions: actions) }
        case .suggestions:
            // A chip's own row: Start and ✕ act as the chip's do, so the two change together.
            SessionRailLimitedList(items: content.suggestions, limit: 5) { TaskSuggestionRailRow(suggestion: $0) }
        case .agents:
            if let agents = content.agents { SessionRailAgentsCard(agents: agents, actions: actions.agents) }
        case .backgroundTasks:
            SessionRailBackgroundTasksCard(projection: content.backgroundTasks ?? BackgroundTasksProjection(entries: []),
                                           terminals: content.backgroundTerminals, jobs: content.sessionJobs,
                                           actions: actions.backgroundTasks, openOutput: actions.openTaskOutput,
                                           terminalActions: actions.terminals)
        case .preview:
            if let preview = content.preview { SessionRailPreviewCard(preview: preview, openBrowser: actions.openBrowser) }
        case .outputs:
            SessionRailOutputsCard(outputs: content.outputs, actions: actions)
        case .goal, .servers:
            EmptyView()
        }
    }
}

// MARK: - Outputs

/// The files the task wrote, newest first: five, then "Show N more". A file opens in the task's Files
/// panel; its menu opens it in its own app or shows it in Finder.
struct SessionRailOutputsCard: View {
    let outputs: [SessionRailContent.Output]
    let actions: SessionRailActions
    @Environment(\.openURL) private var openURL

    var body: some View {
        SessionRailLimitedList(items: outputs, limit: 5) { output in
            Button { openURL(output.url) } label: {
                HStack(spacing: 8) {
                    Image(systemName: Self.symbol(output.url))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(output.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    if let date = output.writtenAt {
                        Text(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .parityPointer()
            .help(output.url.path(percentEncoded: false))
            .contextMenu {
                Button(L10n.string("Open in its app")) { actions.openURL(output.url) }
                Button(L10n.string("Show in Finder")) { actions.revealInFinder(output.url) }
            }
        }
    }

    static func symbol(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic": "photo"
        case "mp4", "mov", "webm": "film"
        case "mp3", "wav", "m4a": "waveform"
        case "pdf": "doc.richtext"
        case "csv", "tsv", "xls", "xlsx", "numbers": "tablecells"
        case "zip": "doc.zipper"
        case "html", "htm": "globe"
        default: "doc.text"
        }
    }
}

/// A list of rows that shows its first `limit` and "Show {count} more" (`Z184O6N3fq`).
struct SessionRailLimitedList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let limit: Int
    @ViewBuilder let row: (Item) -> Row
    @State private var showsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(showsAll ? items : Array(items.prefix(limit))) { item in row(item) }
            if !showsAll, items.count > limit {
                Button(L10n.format("Show %lld more", Int64(items.count - limit))) { showsAll = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .parityPointer()
                    .padding(.top, 2)
            }
        }
    }
}

// MARK: - Environment

/// Where the task runs: on this Mac or in its own worktree, its folder and extra folders, its branch,
/// the instruction files there and its harness. What the title bar's Environment popover listed.
struct SessionRailEnvironmentCard: View {
    let environment: SessionRailContent.Environment
    let actions: SessionRailActions
    private static let visibleInstructionSourceLimit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SessionRailRow(systemName: environment.worktreeName == nil ? "laptopcomputer" : "arrow.triangle.branch",
                           title: environment.locationTitle) {
                if let name = environment.worktreeName {
                    Text(name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            if let folderURL = environment.folderURL {
                Button { actions.revealInFinder(folderURL) } label: {
                    SessionRailRow(systemName: "folder", title: environment.folderName).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .parityPointer()
                .help(folderURL.path(percentEncoded: false))
                .accessibilityHint(L10n.string("Show in Finder"))
                .contextMenu {
                    Button(L10n.string("Show in Finder")) { actions.revealInFinder(folderURL) }
                    Button(L10n.string("Copy path")) { Self.copy(folderURL.path(percentEncoded: false)) }
                }
            } else {
                SessionRailRow(systemName: "folder", title: environment.folderName)
            }
            if !environment.additionalRoots.isEmpty {
                SessionRailRow(systemName: "folder.badge.plus", title: L10n.string("Additional folders")) {
                    Text(String(environment.additionalRoots.count)).foregroundStyle(.secondary)
                }
                .help(environment.additionalRoots.joined(separator: "\n"))
            }
            if let branch = environment.branch {
                Button {
                    if let url = environment.branchURL { actions.openURL(url) } else { Self.copy(branch) }
                } label: {
                    SessionRailRow(systemName: "arrow.triangle.pull", title: branch).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .parityPointer()
                .help(environment.branchURL == nil ? L10n.string("Copy branch name")
                                                   : L10n.string("Open branch on GitHub"))
                .contextMenu {
                    if let url = environment.branchURL {
                        Button(L10n.string("Open branch on GitHub")) { actions.openURL(url) }
                    }
                    Button(L10n.string("Copy branch name")) { Self.copy(branch) }
                }
            }
            instructionSources
            HarnessIdentityLabel(harness: environment.harness, size: 14)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    /// Instruction files stay owned by the folder and the harness. Codex reports what it loaded;
    /// every other harness can only be told that the file exists, never that it was read.
    @ViewBuilder private var instructionSources: some View {
        let sources = environment.instructionSources
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string(sources.origin == .provider ? "Applied instruction files" : "Instruction files present"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(sources.paths.prefix(Self.visibleInstructionSourceLimit), id: \.self) { path in
                    Text(ProjectSidebarPresentation.abbreviatedPath(for: URL(filePath: path)))
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
                if sources.paths.count > Self.visibleInstructionSourceLimit {
                    Text(L10n.format("%lld more", sources.paths.count - Self.visibleInstructionSourceLimit))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
        }
    }

    static func copy(_ text: String) {
        TranscriptClipboard.copy(text)
    }
}

// MARK: - Settings

/// The model, mode, permissions and account the task's next turn runs with, through the same
/// controls as the composer's row.
struct SessionRailSettingsCard: View {
    let settings: SessionRailContent.Settings
    let actions: SessionRailActions
    @State private var isPreparing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let model = settings.model {
                row(L10n.string("Model")) {
                    ComposerModelControl(menu: model.menu, onPrepare: actions.onPrepareSettings, onSetOption: { id, value in
                        if let choice = model.apply.choice(id: id, value: value) { actions.onChoose(choice) }
                    }, registersTaskFocus: false)
                }
            }
            if case let .selector(selector, canChoose, apply)? = settings.mode {
                row(selector.name) {
                    ComposerModeControl(selector: selector, canChoose: canChoose, isPreparing: $isPreparing,
                                        isDisabled: false, onPrepare: actions.onPrepareSettings) { id, value in
                        if let choice = apply.choice(id: id, value: value) { actions.onChoose(choice) }
                    }
                }
            }
            if let permission = settings.permission {
                row(L10n.string("Permissions")) {
                    ComposerPermissionControl(slot: permission, isPreparing: $isPreparing, isDisabled: false,
                                              onChoose: actions.onChoose, onPrepare: actions.onPrepareSettings,
                                              registersTaskFocus: false)
                }
            }
            if let account = settings.accountName {
                row(L10n.string("Account")) {
                    if let choose = actions.chooseAccount {
                        Button(action: choose) {
                            ParityComposerControl(title: account, systemName: nil, showsChevron: true)
                        }
                        .buttonStyle(.borderless)
                        .parityPointer()
                        .help(L10n.string("Choose account…"))
                        .accessibilityLabel(L10n.string("Account"))
                        .accessibilityValue(account)
                    } else {
                        // Its end where the controls above end their words (`ParityComposerControl`).
                        Text(account).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 7)
                    }
                }
            }
        }
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 4)
            control()
                .lineLimit(1)
        }
        .frame(minHeight: 28)
    }
}

// MARK: - Usage

/// What is left of the account's plan limits, as the account list draws them.
struct SessionRailUsageCard: View {
    let account: SessionRailAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(account.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            ForEach(account.windows) { window in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(window.name).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(L10n.format("%lld%% left", Int64((window.remainingPercent ?? 0).rounded())))
                            .monospacedDigit()
                            .foregroundStyle(window.isNearlySpent ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                    }
                    SessionRailMeter(fraction: (window.remainingPercent ?? 0) / 100,
                                     tint: window.isNearlySpent ? .orange : .secondary)
                        .frame(height: 4)
                    if let resetsAt = window.resetsAt {
                        Text(L10n.format("Resets %@", ProviderNoticeText.resetTime(resetsAt)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if let checkedAt = account.checkedAt {
                Text(L10n.format("Checked %@", checkedAt.formatted(.relative(presentation: .named))))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Connectors

/// Yardlet's connectors and the session's MCP servers, those that need the person first: three, then
/// "Show N more", what the composer's list notes, and "Add connectors" (the directory over the window)
/// beside "Manage connectors" (Settings), as the Claude app's connector list offers both.
struct SessionRailConnectorsCard: View {
    let list: ComposerConnectorList
    let actions: SessionRailActions

    /// The pauses before reading a server still connecting again: the Claude app's
    /// `repollForLateStdioServers` reads once after a second and once two seconds later (`[1e3,2e3]`).
    static let followPauses: [Duration] = [.seconds(1), .seconds(2)]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SessionRailLimitedList(items: list.rows, limit: 3) { row in
                ComposerConnectorRow(row: row, onSwitch: actions.connectors?.setOn,
                                     onReconnect: actions.connectors?.reconnect)
                    .padding(.horizontal, -6)
            }
            ForEach(ComposerConnectorsMenu.footnotes(list: list, switches: actions.connectors?.setOn != nil),
                    id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                if let add = actions.connectors?.addConnector {
                    Button(L10n.string("Add connectors"), action: add)
                }
                if let open = actions.connectors?.openSettings {
                    Button(L10n.string("Manage connectors"), action: open)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .parityPointer()
            .padding(.top, 4)
        }
        // Read when the card appears and again whenever what it lists changes.
        .task(id: list) {
            await Self.follow(list, refresh: actions.refreshConnectors) { pause in
                try await Task.sleep(for: pause)
            }
        }
    }

    /// Reads the session's servers once and, while one of them is still connecting, again after
    /// each of `followPauses`, as the Claude app reads a session's late servers; a list that changes
    /// starts the card's task afresh.
    static func follow(_ list: ComposerConnectorList, refresh: () async -> Void,
                       pause: (Duration) async throws -> Void) async {
        await refresh()
        guard list.rows.contains(where: { $0.state == .pending }) else { return }
        for duration in followPauses {
            do { try await pause(duration) } catch { return }
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }
}

// MARK: - Progress

/// The task's plan, its current step marked (the Claude app's Progress card).
struct SessionRailProgressCard: View {
    let progress: SessionRailContent.Progress

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let explanation = progress.plan.explanation, !explanation.isEmpty {
                Text(explanation)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(progress.plan.steps) { step in
                let isCurrent = step.id == progress.currentStepID
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: Self.symbol(step.status))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Self.tint(step.status, current: isCurrent))
                        .frame(width: 13)
                    Text(step.text)
                        .foregroundStyle(step.status == .completed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .strikethrough(step.status == .completed, color: .secondary.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(isCurrent ? L10n.string("In progress")
                                    : step.status == .completed ? L10n.string("Completed") : L10n.string("Pending"))
            }
        }
    }

    static func symbol(_ status: ConversationPlan.StepStatus) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "circle.dotted.circle"
        case .pending, .unknown: "circle"
        }
    }

    static func tint(_ status: ConversationPlan.StepStatus, current: Bool) -> Color {
        if current { return ParityTheme.accent }
        return switch status {
        case .completed: .green
        default: .secondary
        }
    }
}

// MARK: - Background tasks

/// What the Background tasks card asks of the task for Codex's background terminals.
@MainActor
struct SessionRailTerminalActions {
    var open: (CodexBackgroundTerminal) -> Void = { _ in }
    var canOpen = true
    var stop: (CodexBackgroundTerminal) -> Void = { _ in }
    /// The Codex app's "Stop all background terminals".
    var stopAll: () -> Void = {}
    var isStopping: (String) -> Bool = { _ in false }
}

/// The task's real background work while it runs: a Claude Code task's session jobs (soonest first,
/// where the Claude app lists its loops), shells, monitors and workflows, a Codex thread's background
/// terminals; four, then "Show N more". Agents have their own card. A row opens its output beside the
/// task (the Claude app's Background tasks pane, the Codex app's output tab) and stops it; "Stop all"
/// stops every one after asking, as the composer's line. A session job has no stop: the CLI takes no
/// request to end one (the Claude app's stop sends the model a message asking it to).
struct SessionRailBackgroundTasksCard: View {
    let projection: BackgroundTasksProjection
    var terminals: [CodexBackgroundTerminal] = []
    var jobs: [ClaudeSessionJob] = []
    let actions: HarnessActivityActions?
    var openOutput: ((HarnessActivity) -> Void)? = nil
    var terminalActions: SessionRailTerminalActions? = nil
    @State private var stopAll = BackgroundTasksStopAll()
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    private enum Item: Identifiable {
        case job(ClaudeSessionJob)
        case task(BackgroundTasksProjection.Row)
        case terminal(CodexBackgroundTerminal)

        var id: String {
            switch self {
            case let .job(job): "job:\(job.id)"
            case let .task(row): "task:\(row.id)"
            case let .terminal(terminal): "terminal:\(terminal.id)"
            }
        }
    }

    private var items: [Item] {
        let now = Date()
        let soonest = jobs.sorted {
            ($0.nextRun(after: now)?.date ?? .distantFuture) < ($1.nextRun(after: now)?.date ?? .distantFuture)
        }
        return soonest.map(Item.job) + projection.rows.map(Item.task) + terminals.map(Item.terminal)
    }

    /// The tasks "Stop all" would stop.
    private var stoppableCount: Int {
        let tasks = actions.flatMap { actions in
            actions.stop == nil ? nil : projection.stopAllTargets(isStopping: actions.isStopping).count
        } ?? 0
        let codex = terminalActions == nil ? 0 : terminals.filter { !(terminalActions?.isStopping($0.id) ?? false) }.count
        return tasks + codex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SessionRailLimitedList(items: items, limit: 4) { item in
                switch item {
                case let .job(job):
                    SessionJobRailRow(job: job)
                case let .task(row):
                    BackgroundTaskRowView(row: row, actions: actions, leadingInset: 0, openOutput: openOutput)
                        .padding(.trailing, -8)
                case let .terminal(terminal):
                    terminalRow(terminal)
                }
            }
            if stoppableCount > 1 {
                Button(L10n.string("Stop all")) { stopAll.request() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .parityPointer()
                    .padding(.top, 2)
                    .help(L10n.string("Stop all running tasks?"))
            }
        }
        .confirmationDialog(
            L10n.string("Stop all running tasks?"),
            isPresented: Binding(get: { stopAll.isConfirming }, set: { if !$0 { stopAll.cancel() } })
        ) {
            Button(L10n.string("Stop all"), role: .destructive) {
                if let actions { stopAll.confirm(projection, actions: actions) } else { stopAll.cancel() }
                if !terminals.isEmpty { terminalActions?.stopAll() }
            }
            Button(L10n.string("Keep running"), role: .cancel) { stopAll.cancel() }
        }
    }

    private func terminalRow(_ terminal: CodexBackgroundTerminal) -> some View {
        let isStopping = terminalActions?.isStopping(terminal.id) == true
        return HStack(spacing: 8) {
            Button { terminalActions?.open(terminal) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11 * interfaceScale))
                        .foregroundStyle(.secondary)
                    Text(terminal.command.isEmpty ? L10n.string("Background terminal") : terminal.command)
                        .font(.system(size: 12 * interfaceScale, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .parityPointer()
            .help(terminal.command)
            .disabled(terminalActions?.canOpen != true)
            Spacer(minLength: 8)
            if isStopping {
                Text(L10n.string("Stopping…"))
                    .font(.system(size: 12 * interfaceScale))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if let terminalActions {
                BackgroundTasksGhostButton(action: { terminalActions.stop(terminal) }) {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 12 * interfaceScale))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .disabled(isStopping)
                .help(L10n.string("Stop process"))
                .accessibilityLabel(L10n.string("Stop process"))
            }
        }
        .padding(.trailing, 0)
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }
}

/// A session job the task's CLI holds: its prompt, then its schedule, when it runs next and when it
/// ends, kept current by the minute.
struct SessionJobRailRow: View {
    let job: ClaudeSessionJob
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let detail = SessionJobText.detail(job, now: context.date)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: job.kind == .once ? "clock" : "arrow.clockwise")
                    .font(.system(size: 11 * interfaceScale))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(SessionJobText.title(job))
                        .font(.system(size: 12 * interfaceScale))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(detail)
                        .font(.system(size: 11 * interfaceScale))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .help(job.prompt)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SessionJobText.title(job))
            .accessibilityValue(detail)
        }
    }
}

// MARK: - Preview

/// A small live view of where the agent works out of sight: the browser tab it drives, or the
/// screen a computer-use call returned (`SessionRailPreview`). Clicking the browser view opens the
/// browser panel, where the Preview card then goes away, as the Codex app's picture in picture focuses
/// the Browser Use tab; clicking the screen opens it over the window, as a conversation image opens.
struct SessionRailPreviewCard: View {
    let preview: SessionRailPreview
    var openBrowser: (() -> Void)? = nil
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.openImageViewer) private var openImageViewer

    /// The Claude app's computer-use preview keeps to 288 pt high (`max-h-72`); a page fits 16:10.
    private static let height: CGFloat = 156

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            frame
                .frame(maxWidth: .infinity)
                .frame(height: Self.height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(ParityTheme.separator) }
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(preview.caption)
                    .font(.system(size: 11.5 * interfaceScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format("%@ preview", preview.title))
        .accessibilityValue(preview.caption)
    }

    @ViewBuilder
    private var frame: some View {
        switch preview.source {
        case let .browser(tab):
            if MacBrowserHost.isAvailable {
                Button { openBrowser?() } label: {
                    BrowserFramePreview(tab: tab)
                        .allowsHitTesting(false)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .parityPointer()
                .disabled(openBrowser == nil)
                .help(L10n.string("Open in the browser panel"))
            } else {
                Color.clear
            }
        case let .computer(frame):
            if let image = NSImage(data: frame.data) {
                Button {
                    openImageViewer(ImageViewerRequest(
                        items: [ImageViewerItem(name: preview.title, source: .data(frame.data))], index: 0))
                } label: {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(ParityTheme.canvas)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .parityPointer()
                .help(L10n.string("View the image"))
            } else {
                Color.clear
            }
        }
    }
}
