import QuickLook
import SwiftUI
import YardletRemote

/// A window for another Mac's Yardlet (File › Connect to Mac…): one window per host, its title the host's
/// name and how it is connected. Its sidebar lists the host's projects and tasks with their marks, a task
/// opens in the app's own conversation view with the same request cards, and the composer sends through the
/// host's own paths (docs/REMOTE_PROTOCOL.md). This Mac's own tasks stay in their own window; nothing of
/// the host's is mixed into them.
struct RemoteHostWindow: View {
    static let sceneID = "remote-host"

    let hostID: String?
    let directory: RemoteHostDirectory
    @State private var model: RemoteHostModel?

    var body: some View {
        Group {
            // A host removed meanwhile (from File › Connect to Mac…) leaves its window with nothing to show.
            if let model, directory.host(model.id) != nil {
                RemoteHostView(model: model, directory: directory)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text(L10n.string("This Mac is no longer paired."))
                        .font(.callout.weight(.semibold))
                    Text(L10n.string("Pair it again from File › Connect to Mac…."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ParityTheme.canvas)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task(id: hostID) {
            model = hostID.flatMap(directory.model(for:))
        }
        // A closed window ends its connection; reopening it connects again.
        .onDisappear { if let hostID { directory.close(hostID) } }
    }
}

/// The window's content once its host is known.
struct RemoteHostView: View {
    let model: RemoteHostModel
    let directory: RemoteHostDirectory
    @State private var drafts: RemoteComposerDrafts

    init(model: RemoteHostModel, directory: RemoteHostDirectory, drafts: RemoteComposerDrafts = RemoteComposerDrafts()) {
        self.model = model
        self.directory = directory
        _drafts = State(initialValue: drafts)
    }

    var body: some View {
        HStack(spacing: 0) {
            RemoteHostSidebar(model: model)
                .frame(width: ParityTheme.sidebarWidth + 20)
                .background(ParityTheme.sidebar)
            Divider()
            VStack(spacing: 0) {
                RemoteConnectionBanner(model: model, directory: directory)
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ParityTheme.canvas)
        }
        .navigationTitle(model.name)
        .navigationSubtitle(RemoteConnectionText.line(model.connection))
        .modifier(RemotePresence(model: model))
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case let .task(taskID):
            if let conversation = model.conversations[taskID] {
                RemoteTaskView(model: model, conversation: conversation, draft: drafts.draft(for: taskID),
                               editing: Binding(get: { drafts.edits[taskID] }, set: { drafts.edits[taskID] = $0 }))
                    .id(taskID)
            }
        case .newTask:
            RemoteNewTaskView(model: model, draft: drafts.newTask)
        case let .schedule(id):
            if let schedule = model.schedules.schedule(id) {
                RemoteScheduleDetail(model: model, schedule: schedule)
            } else {
                schedulePlaceholder
            }
        case .none where model.showsSchedules:
            schedulePlaceholder
        case .none:
            VStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text(model.hasSnapshot ? L10n.format("Choose a task on %@, or start a new one.", model.name)
                                       : L10n.format("Connecting to %@…", model.name))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if model.hasSnapshot, model.newTask != nil {
                    Button(L10n.string("New task")) { model.select(.newTask) }
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Tells the host whether the person is using its window: in front, with input in the last two minutes. The
/// host holds its phone pushes meanwhile (docs/REMOTE_PROTOCOL.md §18), as Claude Code's remote control does not
/// push to a phone while the person watches the terminal.
private struct RemotePresence: ViewModifier {
    let model: RemoteHostModel
    @Environment(\.controlActiveState) private var activeState

    static let idleLimit: Double = 120
    static let checkInterval: Duration = .seconds(30)

    func body(content: Content) -> some View {
        content
            .task(id: activeState == .key) {
                while !Task.isCancelled {
                    model.setPresence(activeState == .key && UserIdleTime.seconds < Self.idleLimit)
                    try? await Task.sleep(for: Self.checkInterval)
                }
            }
            .onDisappear { model.setPresence(false) }
    }
}

extension RemoteHostView {
    /// The detail while the host's scheduled tasks are listed and none is chosen.
    var schedulePlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(L10n.string(model.schedules.list?.isEmpty == false ? "Choose a scheduled task." : "No scheduled tasks."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Each task's unsent words and the message it edits, kept on this Mac while the window is open (a host's own drafts
/// stay there).
@MainActor
@Observable
final class RemoteComposerDrafts {
    @ObservationIgnored private var drafts: [String: TaskComposerDraft] = [:]
    @ObservationIgnored let newTask = TaskComposerDraft()
    var edits: [String: RemoteMessageEdit] = [:]

    func draft(for taskID: String) -> TaskComposerDraft {
        if let draft = drafts[taskID] { return draft }
        let draft = TaskComposerDraft()
        drafts[taskID] = draft
        return draft
    }
}

// MARK: - Connection

enum RemoteConnectionText {
    /// The window's subtitle: how the host is reached now.
    static func line(_ connection: RemoteHostModel.Connection) -> String {
        switch connection {
        case let .connected(.direct(address)):
            if isTailscale(address) { return L10n.string("Connected over Tailscale") }
            return L10n.string("Connected on the same network")
        case .connected(.relay): return L10n.string("Connected through the Yardlet server")
        case .connecting: return L10n.string("Connecting…")
        case .unreachable: return L10n.string("Reconnecting…")
        case .removed: return L10n.string("Not paired")
        case .stopped: return ""
        }
    }

    /// Tailscale's addresses (100.64.0.0/10, fd7a:115c:a1e0::/48) and MagicDNS names.
    static func isTailscale(_ address: String) -> Bool {
        let host = address.hasPrefix("[") ? String(address.dropFirst().prefix { $0 != "]" })
            : String(address.split(separator: ":").first ?? "")
        if host.hasSuffix(".ts.net") || host.lowercased().hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }
}

/// One line above the conversation while the host cannot be reached, closed its connection, or removed
/// this Mac. What was last read stays below it; sending waits for the connection.
private struct RemoteConnectionBanner: View {
    let model: RemoteHostModel
    let directory: RemoteHostDirectory

    var body: some View {
        if let text {
            HStack(spacing: 10) {
                Image(systemName: model.connection == .removed ? "xmark.octagon" : "wifi.exclamationmark")
                    .foregroundStyle(.orange)
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if model.connection == .removed {
                    Button(L10n.string("Remove from This Mac")) {
                        Task { await directory.forget(model.id) }
                    }
                    .controlSize(.small)
                } else {
                    Button(L10n.string("Try Again")) { model.reconnectNow() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.orange.opacity(0.08))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var text: String? {
        switch model.connection {
        case .unreachable:
            switch model.closingReason {
            case "disabled": return L10n.format("%@ turned off remote connections.", model.name)
            case "quitting": return L10n.format("Yardlet on %@ quit.", model.name)
            default: return L10n.format("Can't reach %@. It may be off or asleep.", model.name)
            }
        case .removed:
            return L10n.format("%@ removed this Mac. To connect again, pair with a new link from its Settings › Remote.", model.name)
        case .connecting, .connected, .stopped:
            return nil
        }
    }
}

// MARK: - Sidebar

/// The host's sidebar: New task, then Pinned, each project and Chats, in the host's order, each task with
/// its harness, its title and the host sidebar's mark, a task started from another nested under it.
struct RemoteHostSidebar: View {
    let model: RemoteHostModel
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        if model.showsSchedules {
            RemoteScheduleList(model: model)
        } else {
            tasks
        }
    }

    private var tasks: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.select(.newTask) } label: {
                SidebarActionRow(systemName: "square.and.pencil", title: L10n.string("New task"), symbolWeight: .bold,
                                 titleWeight: .medium, height: 32, isFilled: model.selection == .newTask)
            }
            .buttonStyle(.borderless)
            .parityPointer()
            .padding(.horizontal, SidebarMetrics.rowInset)
            .padding(.top, 10)
            .disabled(model.newTask == nil)

            if model.offersSchedules {
                Button {
                    model.showsSchedules = true
                    model.schedules.load()
                } label: {
                    SidebarActionRow(systemName: "clock", title: L10n.string("Scheduled tasks"))
                }
                .buttonStyle(.borderless)
                .parityPointer()
                .padding(.horizontal, SidebarMetrics.rowInset)
                .padding(.top, 2)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: SidebarMetrics.rowSpacing) {
                    ForEach(sections, id: \.id) { section in
                        Text(section.title)
                            .font(.system(size: SidebarMetrics.projectHeaderFontSize * interfaceScale, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.leading, SidebarMetrics.projectHeaderLeading)
                            .frame(height: SidebarMetrics.projectHeaderHeight * interfaceScale, alignment: .bottomLeading)
                            .padding(.top, SidebarMetrics.projectHeaderTopSpacing)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.rows, id: \.task.id) { row in
                            RemoteTaskRow(task: row.task, depth: row.depth,
                                          isSelected: model.selection == .task(row.task.id), model: model)
                        }
                        if section.rows.isEmpty {
                            Text(L10n.string("No tasks"))
                                .font(.system(size: 12 * interfaceScale))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, SidebarRowLeading<EmptyView>.titleLeading())
                                .frame(height: SidebarMetrics.secondaryLineHeight * interfaceScale)
                        }
                    }
                }
                .padding(.horizontal, SidebarMetrics.rowInset)
                .padding(.bottom, 12)
            }
        }
    }

    struct Row {
        let task: RemoteTask
        let depth: Int
    }

    struct Section {
        let id: String
        let title: String
        let rows: [Row]
    }

    /// Pinned first, then the host's projects in its order with Chats among them, each listing its tasks
    /// most recently active first, nested under the task they were started from.
    private var sections: [Section] {
        let pinned = model.tasks.filter(\.pinned)
        var sections: [Section] = []
        if !pinned.isEmpty { sections.append(Section(id: "pinned", title: L10n.string("Pinned"), rows: Self.nest(pinned))) }
        for project in model.projects {
            let tasks = model.tasks.filter { !$0.pinned && $0.projectId == project.id }
            guard !tasks.isEmpty || project.kind == .chats else { continue }
            sections.append(Section(id: project.id, title: project.name, rows: Self.nest(tasks)))
        }
        return sections
    }

    /// Each task under the one it was started from when that one is in the same list.
    static func nest(_ tasks: [RemoteTask]) -> [Row] {
        let listed = Set(tasks.map(\.id))
        var children: [String: [RemoteTask]] = [:]
        var roots: [RemoteTask] = []
        for task in tasks {
            if let parent = task.parentTaskId, parent != task.id, listed.contains(parent) {
                children[parent, default: []].append(task)
            } else {
                roots.append(task)
            }
        }
        var rows: [Row] = []
        var visited: Set<String> = []
        func add(_ task: RemoteTask, depth: Int) {
            guard visited.insert(task.id).inserted else { return }
            rows.append(Row(task: task, depth: depth))
            for child in children[task.id] ?? [] { add(child, depth: min(depth + 1, 3)) }
        }
        for root in roots { add(root, depth: 0) }
        return rows
    }
}

/// One task of the host: its harness, its title (bold while unread) and the mark the host's sidebar shows,
/// with Pin and Archive on hover and in its menu.
private struct RemoteTaskRow: View {
    let task: RemoteTask
    let depth: Int
    let isSelected: Bool
    let model: RemoteHostModel
    @State private var isHovering = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        ZStack(alignment: .trailing) {
            Button { model.select(.task(task.id)) } label: {
                HStack(spacing: 0) {
                    SidebarRowLeading(nestingDepth: depth) {
                        HarnessIdentityIcon(harness: HarnessKind(rawValue: task.harness),
                                            size: SidebarMetrics.nestedIconSize * interfaceScale)
                    }
                    Text(task.title)
                        .font(.system(size: 13 * interfaceScale, weight: task.unread ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 3)
                    if !isHovering, let status = Self.status(of: task) {
                        SidebarTaskStatusView(status: status)
                    }
                }
                .padding(.trailing, isHovering ? 53 : SidebarMetrics.rowTrailingPadding)
                .frame(height: SidebarMetrics.rowHeight * interfaceScale)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .parityPointer()
            .accessibilityLabel("\(task.title), \(task.harnessName)")
            .accessibilityValue(Self.status(of: task)?.accessibilityName ?? "")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if isHovering {
                HStack(spacing: 1) {
                    hoverButton(task.pinned ? "pin.fill" : "pin", task.pinned ? L10n.string("Unpin") : L10n.string("Pin")) {
                        model.send(.setPinned(taskID: task.id, pinned: !task.pinned))
                    }
                    hoverButton("archivebox", L10n.string("Archive")) { model.send(.archiveTask(taskID: task.id)) }
                }
                .padding(.trailing, 4)
            }
        }
        .frame(height: SidebarMetrics.rowHeight * interfaceScale)
        .background(isSelected ? ParityTheme.selectedFill : (isHovering ? ParityTheme.hoverFill : .clear),
                    in: SidebarMetrics.rowShape())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(task.pinned ? L10n.string("Unpin") : L10n.string("Pin")) {
                model.send(.setPinned(taskID: task.id, pinned: !task.pinned))
            }
            Button(L10n.string("Archive")) { model.send(.archiveTask(taskID: task.id)) }
        }
    }

    private func hoverButton(_ systemName: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11 * interfaceScale, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .help(label)
        .accessibilityLabel(label)
    }

    /// The host sidebar's mark (§4.1 `indicator`), drawn as the local sidebar draws it.
    static func status(of task: RemoteTask) -> SidebarTaskStatus? {
        if task.pendingKind == "browserHandoff" { return .waitingInBrowser }
        switch task.indicator {
        case .awaitingApproval?: return .awaitingApproval
        case .needsInput?: return .needsInput
        case .failed?: return .failed(message: nil)
        case .usageLimit?: return .usageLimit(HarnessRateLimit(status: .rejected))
        case .running?: return .running
        case .unread?: return .unread
        case nil: return nil
        }
    }
}

// MARK: - A task

/// A task of the host: its conversation in the app's own timeline, with the plan limit's actions on its card,
/// the queue's chips, and the composer; beside it, as the local session rail, the task's outputs when the host
/// serves its files (§15.22). Suggested tasks' chips act through the host (§15.9), and a file a link names or an
/// output is read from the host and opened here (`RemoteHostFiles`).
struct RemoteTaskView: View {
    let model: RemoteHostModel
    let conversation: RemoteConversationModel
    let draft: TaskComposerDraft
    /// A turn's message being edited in the composer (§15.23).
    @Binding var editing: RemoteMessageEdit?
    /// An answer that leaves a rule behind, asked about once more before it goes.
    @State private var standingAnswer: (requestID: String, action: PermissionRequestAction)?
    /// The rail is shown, as the local rail is unless the person hid it; it draws only where it fits.
    @State private var showsRail = true
    @State private var width: CGFloat = 0
    /// A file read from the host, shown in Quick Look.
    @State private var preview: URL?

    private var task: RemoteTask? { model.task(conversation.taskID) }

    private var outputs: [RemoteOutput] { model.offersTaskFiles ? model.files.outputs[conversation.taskID] ?? [] : [] }

    private var drawsRail: Bool {
        showsRail && !outputs.isEmpty && SessionRailPlacement.fits(sessionWidth: width, panelOpen: false)
    }

    var body: some View {
        HStack(spacing: 0) {
            conversationColumn
            if drawsRail {
                Divider()
                RemoteTaskRail(outputs: outputs, open: { open($0, .viewer) }, openInItsApp: { open($0, .itsApp) },
                               revealInFinder: { open($0, .finder) })
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .environment(\.taskSuggestionActions, suggestionActions)
        // The host's files: named here, and opened once read from the host where it serves them.
        .environment(\.transcriptOpensLocalFiles, false)
        .transformEnvironment(\.conversationLinkPlaces) { $0.fileElsewhere = fileElsewhere }
        .environment(\.openURL, OpenURLAction(handler: openLink))
        .quickLookPreview($preview)
        // What the task made, read again as it settles.
        .task(id: outputsMoment) {
            if model.offersTaskFiles { model.files.loadOutputs(conversation.taskID) }
        }
    }

    /// Where a file link of the host's opens: read from the host first, where it serves files.
    private var fileElsewhere: (@MainActor (URL) -> Void)? {
        guard model.offersTaskFiles else { return nil }
        return { url in open(url, .viewer) }
    }

    private var conversationColumn: some View {
        VStack(spacing: 0) {
            header
            ConversationTimeline(source: .presented(conversation.presentation), actions: actions,
                                 isLoading: !conversation.isLoaded, diagnosticID: nil)
            if let editing {
                ConversationEditBanner(canCancel: true) {
                    draft.text = editing.previousText
                    draft.attachments = editing.previousAttachments
                    self.editing = nil
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if let error = model.commandError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let name = model.files.reading {
                    Text(L10n.format("Reading %@ from %@…", name, model.name))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                RemoteComposer(model: model, taskID: conversation.taskID, draft: draft, queued: conversation.queued,
                               editing: $editing)
            }
            // Where the local composer sits under its conversation.
            .frame(maxWidth: ParityTheme.contentWidth)
            .padding(.horizontal, 24)
            .padding(.top, 6)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog(
            L10n.string("Allow and save this rule?"),
            isPresented: Binding(get: { standingAnswer != nil }, set: { if !$0 { standingAnswer = nil } })
        ) {
            Button(standingAnswer?.action.label ?? "") {
                if let standingAnswer { respond(standingAnswer.requestID, .providerAction(standingAnswer.action)) }
                standingAnswer = nil
            }
            Button(L10n.string("Cancel"), role: .cancel) { standingAnswer = nil }
        } message: {
            Text(L10n.format("This answer stays in effect on %@ after this request.", model.name))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let task {
                HarnessIdentityIcon(harness: HarnessKind(rawValue: task.harness), size: 15)
                Text(task.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(task.harnessName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(L10n.format("On %@", model.name))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            if !outputs.isEmpty {
                ParityIconButton(systemName: "sidebar.squares.right",
                                 help: L10n.string(drawsRail ? "Hide session rail" : "Show session rail")) {
                    showsRail = !drawsRail
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: ParityTheme.paneToolbarHeight)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var actions: ConversationActions {
        var actions = ConversationActions()
        actions.decide = { id, decision in respond(id, .decision(decision)) }
        actions.chooseOption = { id, action in
            if action.kind == RemoteTurnProjection.Route.standing {
                standingAnswer = (id, action)
            } else {
                respond(id, .providerAction(action))
            }
        }
        actions.answer = { id, answer in respond(id, .answer(answer)) }
        actions.respondToCodexRequest = { id, response in respond(id, .codex(response)) }
        actions.loadMoreCodexTurns = { [model, taskID = conversation.taskID] in model.loadOlder(taskID) }
        actions.loadLineDetail = { [model, taskID = conversation.taskID] itemID in model.loadDetail(taskID, itemID: itemID) }
        if model.taskControls {
            // A turn's edit and fork, as the host's turn offers them (§15.23).
            actions.editTurnMessage = { turnID, text in beginEdit(turnID: turnID, text: text) }
            actions.branch = { [model, taskID = conversation.taskID] point in
                if case let .turn(turnID) = point { model.fork(taskID, turnID: turnID) } else { model.fork(taskID, turnID: nil) }
            }
        }
        // A subagent's child thread is the host's task it runs in (§15.24).
        actions.openCodexSubagent = { [model] taskID in model.select(.task(taskID)) }
        actions.providerNotices = limitActions
        return actions
    }

    /// What the latest limit card offers, as the host offers it (§15.17): continuing under another account that
    /// shares the task's history, and continuing once the limit resets.
    private var limitActions: TaskProviderNotices? {
        guard let limit = conversation.usageLimit, let options = limit.options, !options.isEmpty else { return nil }
        let taskID = conversation.taskID
        var notices = TaskProviderNotices()
        notices.canContinue = true
        // An armed continue is known by the reset it waits for, as on the host.
        if limit.autoContinue == true, let resetsAt = limit.resetsAt {
            notices.autoContinueResetsAt = Date(timeIntervalSince1970: TimeInterval(resetsAt) / 1000)
        }
        notices.setAutoContinue = { [model] enabled, _ in model.send(.setAutoContinue(taskID: taskID, enabled: enabled)) }
        if options.contains("continueWithAccount") {
            notices.hostAccounts = { [model] in
                let response = await model.response(to: .limitAccounts(taskID: taskID))
                return (response.accounts ?? []).filter { $0.available == true }
                    .map { UsageLimitHostAccount(id: $0.id, name: $0.name, detail: $0.detail) }
            }
            notices.continueWithHostAccount = { [model] id in model.send(.continueWithAccount(taskID: taskID, accountID: id)) }
        }
        return notices
    }

    private func respond(_ requestID: String, _ route: ConversationRequestRoute) {
        model.respond(taskID: conversation.taskID, requestID: requestID, route: route)
    }

    /// The chips' Start, Do it here and ✕, sent to the host (§15.9); what became of each is the host's.
    /// Options stays the host's: a suggestion starts with that Mac's choices.
    private var suggestionActions: TaskSuggestionActions {
        let taskID = conversation.taskID
        let model = model, conversation = conversation
        func act(_ id: String, _ action: RemoteSuggestionAction) {
            model.send(.actOnSuggestion(taskID: taskID, suggestionID: id, action: action))
        }
        return TaskSuggestionActions(
            resolution: { conversation.suggestions[$0].flatMap(RemoteSuggestionState.resolution) },
            progress: { id in conversation.suggestions[id].flatMap { RemoteSuggestionState.progress($0, host: model.name) } },
            start: { act($0.id, .start) },
            doHere: { act($0.id, .here) },
            optionsUnavailable: L10n.format("It starts with the choices set on %@.", model.name),
            dismiss: { act($0, .dismiss) },
            openTask: { model.select(.task($0.uuidString)) },
            canOpenTask: { model.task($0.uuidString) != nil })
    }

    /// A link in the conversation: a file is read from the host where it serves files, and never opened at
    /// the same path on this Mac; a task the host lists opens here; a web page in the default browser.
    private func openLink(_ url: URL) -> OpenURLAction.Result {
        switch ConversationLinkKind(url) {
        case .file:
            guard model.offersTaskFiles else { return .discarded }
            open(url, .viewer)
            return .handled
        case let .task(.task(id)):
            guard model.task(id.uuidString) != nil else { return .discarded }
            model.select(.task(id.uuidString))
            return .handled
        case .task, .place:
            return .discarded
        case .web, .other:
            return .systemAction
        }
    }

    private func open(_ url: URL, _ opening: RemoteFileOpening) {
        let path = url.path(percentEncoded: false)
        guard !path.isEmpty else { return }
        let taskID = conversation.taskID
        Task {
            switch await model.files.copy(taskID: taskID, path: path) {
            case let .success(copy):
                switch opening {
                case .viewer: preview = copy
                // A program is only shown: its own app would run it.
                case .itsApp where !FileElsewhereButtons.runs(copy): NSWorkspace.shared.open(copy)
                case .itsApp, .finder: NSWorkspace.shared.activateFileViewerSelecting([copy])
                }
            case let .failure(failure):
                model.commandError = RemoteFileOpening.message(failure, host: model.name)
            }
        }
    }

    /// When the outputs are read again: the task's state, and its last activity once it rests.
    private var outputsMoment: String {
        guard let task else { return "" }
        return "\(task.attention.rawValue)-\(task.running)-\(task.running ? 0 : task.lastActivityAt)"
    }

    /// The message goes into the composer to edit, as the local turn's Edit message puts it there; what the composer
    /// held waits to come back if the edit is cancelled.
    private func beginEdit(turnID: String, text: String) {
        let previous = editing.map { ($0.previousText, $0.previousAttachments) } ?? (draft.text, draft.attachments)
        editing = RemoteMessageEdit(turnID: turnID, previousText: previous.0, previousAttachments: previous.1)
        draft.text = text
        draft.attachments = []
        draft.notice = nil
    }
}
