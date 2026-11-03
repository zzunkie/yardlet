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
    @State private var drafts = RemoteComposerDrafts()

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
                RemoteTaskView(model: model, conversation: conversation, draft: drafts.draft(for: taskID))
                    .id(taskID)
            }
        case .newTask:
            RemoteNewTaskView(model: model, draft: drafts.newTask)
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

/// Each task's unsent words, kept on this Mac while the window is open (a host's own drafts stay there).
@MainActor
final class RemoteComposerDrafts {
    private var drafts: [String: TaskComposerDraft] = [:]
    let newTask = TaskComposerDraft()

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

/// A task of the host: its conversation in the app's own timeline, the queue's chips, the plan limit's
/// actions, and the composer.
struct RemoteTaskView: View {
    let model: RemoteHostModel
    let conversation: RemoteConversationModel
    let draft: TaskComposerDraft
    /// An answer that leaves a rule behind, asked about once more before it goes.
    @State private var standingAnswer: (requestID: String, action: PermissionRequestAction)?

    private var task: RemoteTask? { model.task(conversation.taskID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ConversationTimeline(source: .presented(conversation.presentation), actions: actions,
                                 isLoading: !conversation.isLoaded, diagnosticID: nil)
            VStack(alignment: .leading, spacing: 8) {
                if let error = model.commandError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let limit = conversation.usageLimit, !(limit.options ?? []).isEmpty {
                    RemoteUsageLimitBar(model: model, taskID: conversation.taskID, limit: limit)
                }
                RemoteComposer(model: model, taskID: conversation.taskID, draft: draft, queued: conversation.queued)
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
        return actions
    }

    private func respond(_ requestID: String, _ route: ConversationRequestRoute) {
        model.respond(taskID: conversation.taskID, requestID: requestID, route: route)
    }
}

/// The plan limit card's actions (§15.17): continue under another account that shares the task's history,
/// and continuing on its own once the limit resets.
private struct RemoteUsageLimitBar: View {
    let model: RemoteHostModel
    let taskID: String
    let limit: RemoteItem
    @State private var accounts: [RemoteAccount]?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.100percent")
                .foregroundStyle(.orange)
            Text(limit.title ?? L10n.string("Usage limit reached"))
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 8)
            if limit.options?.contains("autoContinue") == true {
                Toggle(L10n.string("Auto-continue when limits reset"), isOn: Binding(
                    get: { limit.autoContinue == true },
                    set: { enabled in model.send(.setAutoContinue(taskID: taskID, enabled: enabled)) }))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
            if limit.options?.contains("continueWithAccount") == true {
                Menu(L10n.string("Continue with…")) {
                    if let accounts {
                        ForEach(accounts.filter { $0.available == true }, id: \.id) { account in
                            Button([account.name, account.detail].compactMap { $0 }.joined(separator: " · ")) {
                                model.send(.continueWithAccount(taskID: taskID, accountID: account.id))
                            }
                        }
                        if !accounts.contains(where: { $0.available == true }) {
                            Text(L10n.string("No other account can continue this task."))
                        }
                    } else {
                        Text(L10n.string("Loading…"))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .task {
                    let response = await model.response(to: .limitAccounts(taskID: taskID))
                    accounts = response.accounts ?? []
                }
            }
        }
        .padding(10)
        .background(ParityTheme.subtleFill, in: RoundedRectangle(cornerRadius: 10))
    }
}
