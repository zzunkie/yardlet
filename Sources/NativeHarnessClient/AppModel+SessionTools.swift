import Foundation
import YardletAgentTools

// The session tools (`SessionToolCatalog`, docs/AGENT_BROWSER_TOOLS.md, "Session tools"): an agent reads the person's other
// tasks, messages one, waits for one, creates a child task, runs a prompt as a subagent on a
// harness, archives tasks, or hides or shows a project (`AppModel+ProjectTools`). Every call comes
// from one task's harness through the Yardlet MCP server and is answered here, through the same paths
// the window uses: a message goes the composer's way, a child task the new-task screen's, an archive
// and a hidden project the sidebar's, an approval the request card's. Nothing is pushed into a turn the agent did not ask for; the one message Yardlet
// sends on its own is the end of a child or subagent the agent asked to be told about.

/// Who made a session tool call: a task, or a subagent `run_agent` started (whose approvals and
/// card belong to the task that hosts it).
struct SessionToolCaller: Equatable {
    let id: UUID
    let hostTaskID: UUID
    let harness: HarnessKind
    let workspaceURL: URL
    let roots: [URL]
    let projectID: UUID?
    let title: String
    let depth: Int
    /// What the caller may do without asking; a subagent it starts gets no more.
    let permission: TaskPermissionLevel
    /// When the call must have answered, below the caller harness's own limit on one MCP call
    /// (`SessionToolPolicy.waitCeiling`): every wait in the call, the person's approval included,
    /// shares it.
    let deadline: ContinuousClock.Instant

    /// What is left of the call's time.
    var remaining: Duration {
        max(.zero, deadline - ContinuousClock.now)
    }
}

/// What became of a message `send_message_to_task` delivered.
enum TaskMessageDelivery: Equatable {
    /// An idle task started a turn on it.
    case delivered
    /// A running task gets it in its turn: Claude Code reads it at its next step, Codex as a steer.
    case steered
    /// It waits behind the task's running turn (a harness that takes nothing while its turn runs).
    case queued
    /// The task waits for room to start; it follows the task's first message.
    case afterStart
    case undelivered(String)
}

extension AppModel: SessionToolHandling {
    func callSessionTool(named name: String, arguments: ToolJSON, callerID: UUID) async -> AgentToolResult {
        let arguments = JSONValue(arguments)
        guard let caller = sessionToolCaller(callerID) else {
            return .error("Yardlet no longer has the task that made this call.")
        }
        switch name {
        case SessionToolCatalog.listTasks: return listTasks(arguments, caller: caller)
        case SessionToolCatalog.readTask: return await readTask(arguments, caller: caller)
        case SessionToolCatalog.sendMessageToTask: return await sendMessageToTask(arguments, caller: caller)
        case SessionToolCatalog.waitTasks: return await waitTasks(arguments, caller: caller)
        case SessionToolCatalog.createTask: return await createChildTask(arguments, caller: caller)
        case SessionToolCatalog.runAgent: return await runAgent(arguments, caller: caller)
        case SessionToolCatalog.archiveTask: return await archiveTasks(arguments, caller: caller)
        case SessionToolCatalog.listProjects: return listProjects(caller: caller)
        case SessionToolCatalog.hideProject: return hideProject(arguments)
        case SessionToolCatalog.showProject: return showProject(arguments)
        case SessionToolCatalog.listAccounts: return await listAccounts(arguments, caller: caller)
        default: return .error("Unknown tool: \(name)")
        }
    }

    func sessionToolCaller(_ id: UUID) -> SessionToolCaller? {
        if let session = store.sessions.first(where: { $0.id == id }) {
            return SessionToolCaller(
                id: id, hostTaskID: id, harness: session.harness, workspaceURL: session.workspaceURL,
                roots: [session.workspaceURL] + session.additionalRootURLs,
                projectID: project(for: session)?.id, title: session.title,
                depth: sessionToolDepth(of: id), permission: sessionToolPermission(of: session),
                deadline: .now + sessionToolWaitCeiling(for: session.harness))
        }
        if let run = sessionTools.run(id), let host = store.sessions.first(where: { $0.id == run.hostTaskID }) {
            return SessionToolCaller(
                id: id, hostTaskID: host.id, harness: run.harness, workspaceURL: run.workspaceURL,
                roots: [run.workspaceURL], projectID: project(for: host)?.id, title: host.title,
                depth: run.depth, permission: run.permission,
                deadline: .now + sessionToolWaitCeiling(for: run.harness))
        }
        return nil
    }

    /// The processes under which Yardlet's tool server for a task or subagent runs, whose descendants
    /// alone may call with its token (`AgentToolBroker.callerProcessCheck`): its own Claude Code process
    /// (with the task's terminals), the Codex App Servers that run Codex threads, or Yardlet itself for a
    /// harness whose one shared process Yardlet does not track. Nil for an ID that is no task or subagent
    /// here (a stand-in in QA), which the token alone admits; empty while the task has no process, so
    /// nothing may call for it then.
    func agentToolHarnessProcesses(for callerID: UUID) -> Set<Int32>? {
        let harness: HarnessKind
        if let session = store.sessions.first(where: { $0.id == callerID }) {
            harness = session.harness
        } else if let run = sessionTools.run(callerID) {
            harness = run.harness
        } else {
            return nil
        }
        let registered = TaskProcessRegistry.shared.registered
        switch HarnessCatalog.descriptor(for: harness)?.transport {
        case .claudeStreamJSON?:
            return Set(registered.filter { $0.value == .task(callerID) }.keys)
        case .codexAppServer?:
            return Set(registered.filter { if case .codexAppServer = $0.value { true } else { false } }.keys)
        default:
            return [ProcessInfo.processInfo.processIdentifier]
        }
    }

    /// How deep a task nests under tasks agents started: as `create_task` recorded it, and for a task the
    /// run of an agent's schedule started, one below the task that made the schedule.
    func sessionToolDepth(of taskID: UUID, seen: Set<UUID> = []) -> Int {
        let recorded = sessionTools.depth(of: taskID)
        guard let maker = scheduledTasks.schedules.first(where: { schedule in
            schedule.destination.mode == .newTask
                && schedule.state.runs.contains { $0.outcome == .started && $0.taskID == taskID }
        })?.agentTaskID, maker != taskID, !seen.contains(maker) else { return recorded }
        return max(recorded, sessionToolDepth(of: maker, seen: seen.union([taskID])) + 1)
    }

    /// A task's permission level as the composer shows it now (`TaskPermissionLevel`).
    func sessionToolPermission(of session: SessionRecord) -> TaskPermissionLevel {
        TaskPermissionLevel.level(of: session)
    }

    // MARK: - list_tasks

    private func listTasks(_ arguments: JSONValue, caller: SessionToolCaller) -> AgentToolResult {
        let scope = arguments["scope"]?.stringValue ?? "project"
        guard scope == "project" || scope == "all" else { return .error("scope must be \"project\" or \"all\".") }
        let limit = Self.integer(arguments["limit"]).map { min(max($0, 1), SessionToolPolicy.listMaximumLimit) }
            ?? SessionToolPolicy.listDefaultLimit
        var states: Set<String>?
        if let value = arguments["state"] {
            let words: [String?] = switch value {
            case let .array(values): values.map(\.stringValue)
            default: [value.stringValue]
            }
            let known: Set<String> = ["waiting", "unread", "active", "idle"]
            guard !words.isEmpty, words.allSatisfy({ $0.map(known.contains) == true }) else {
                return .error("state must be waiting, unread, active or idle, or a list of them.")
            }
            states = Set(words.compactMap { $0 })
        }
        var olderThan: Date?
        if let value = arguments["older_than"] {
            guard let date = value.stringValue.flatMap(Self.listDate) else {
                return .error("older_than must be an ISO 8601 date or date-time, such as 2026-10-04 or 2026-10-04T09:00:00Z.")
            }
            olderThan = date
        }
        let neighbors = Set(splits.split(containing: caller.hostTaskID)?.sessionIDs ?? [])
        let onScreen = sessionToolOnScreenIDs()
        var listed = sidebarSessions
        if let host = store.sessions.first(where: { $0.id == caller.hostTaskID }),
           !listed.contains(where: { $0.id == host.id }) {
            listed.append(host)
        }
        let entries = listed.filter { session in
            (scope == "all" || session.id == caller.hostTaskID || neighbors.contains(session.id)
                || (caller.projectID != nil && project(for: session)?.id == caller.projectID))
                && olderThan.map { max(session.updatedAt, providerActivityBySessionID[session.id] ?? .distantPast) < $0 } != false
        }.map { session in
            SessionToolText.entry(
                session, projectName: project(for: session)?.name, detail: taskAttentionDetails[session.id],
                isShellBusy: shellBusySessionIDs.contains(session.id), isSelf: session.id == caller.hostTaskID,
                inSameSplit: session.id != caller.hostTaskID && neighbors.contains(session.id),
                onScreen: onScreen.contains(session.id), lastActivity: providerActivityBySessionID[session.id])
        }.filter { states?.contains($0.state) != false }
        guard let page = SessionToolText.page(entries, limit: limit, cursor: arguments["cursor"]?.stringValue) else {
            return .error("That cursor is not from list_tasks. List again without cursor.")
        }
        let listing = SessionToolText.Listing(
            scope: scope,
            project: projects.project(id: caller.projectID)?.name,
            tasks: page.tasks,
            total: page.total,
            nextCursor: page.cursor,
            note: SessionToolText.untrustedNote)
        return .text(SessionToolText.json(listing))
    }

    /// `older_than`: a date-time, or a day, which starts at midnight in the person's time zone.
    static func listDate(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let date = try? Date(text, strategy: .iso8601) { return date }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = .current
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: text)
    }

    /// The tasks the window shows now: the selected task, or every pane of the split view on screen.
    func sessionToolOnScreenIDs() -> Set<UUID> {
        var ids = Set(splits.activeSplit?.sessionIDs ?? [])
        if let selected = store.selectedSessionID { ids.insert(selected) }
        return ids
    }

    // MARK: - read_task

    private func readTask(_ arguments: JSONValue, caller: SessionToolCaller) async -> AgentToolResult {
        guard let reference = arguments["task_id"]?.stringValue?.trimmingCharacters(in: .whitespaces),
              !reference.isEmpty else { return .error("task_id is required.") }
        var session: SessionRecord
        switch await sessionToolTask(reference, caller: caller) {
        case let .success(found): session = found
        case let .failure(error): return error.result("Not read")
        }
        let id = session.id
        // A task nothing has opened since Yardlet started reads its saved history first; no turn starts.
        if transcriptBySessionID[session.id]?.isEmpty != false, codexPresentationBySessionID[session.id] == nil {
            await refreshConversationStatus(for: session)
            session = store.sessions.first(where: { $0.id == id }) ?? session
        }
        let turns = Self.integer(arguments["turns"]) ?? SessionToolPolicy.readDefaultTurns
        let cursor = arguments["cursor"]?.stringValue
        guard let conversation = SessionToolText.conversation(
            sessionToolPresentation(of: session), workspaceURL: session.workspaceURL, turns: turns, cursor: cursor)
        else {
            let what = cursor?.hasPrefix(SessionToolText.listCursorPrefix) == true ? "is list_tasks' cursor, not read_task's"
                : "names no turn of this task: it is another task's, or its turn is no longer loaded"
            return .failure("Not read: that cursor \(what). Read task \(session.id.uuidString) again without cursor.",
                            .invalidArguments, retry: .withChanges)
        }
        let neighbors = Set(splits.split(containing: caller.hostTaskID)?.sessionIDs ?? [])
        var details = SessionToolText.entry(
            session, projectName: project(for: session)?.name, detail: taskAttentionDetails[session.id],
            isShellBusy: shellBusySessionIDs.contains(session.id), isSelf: session.id == caller.hostTaskID,
            inSameSplit: session.id != caller.hostTaskID && neighbors.contains(session.id),
            onScreen: sessionToolOnScreenIDs().contains(session.id),
            lastActivity: providerActivityBySessionID[session.id])
        if details.title.isEmpty { details.title = session.title }
        let children = store.sessions.filter { $0.parentTaskID == session.id }.map(\.id.uuidString)
        let servers = resourceMonitor.servers(of: session.id).map {
            ReadTaskDetails.Server(url: $0.url.absoluteString, process: $0.processName)
        }
        var head = SessionToolText.json(ReadTaskDetails(
            task: details, folder: session.workspaceURL.path(percentEncoded: false),
            createdAt: SessionToolText.iso(session.createdAt), childTaskIds: children.isEmpty ? nil : children,
            queuedMessages: followUps.queue(for: session.id).count, servers: servers.isEmpty ? nil : servers,
            account: accountAssignments.assignment(for: session.id)?.toolLine))
        head += "\n\nShowing \(conversation.shownTurns) of \(conversation.totalTurns) loaded turns."
        if let next = conversation.cursor { head += " Pass cursor \"\(next)\" for earlier turns." }
        head += " " + SessionToolText.untrustedNote
        let body = conversation.text.isEmpty ? "(No conversation yet.)" : conversation.text
        return .text(head + "\n\n" + body)
    }

    private struct ReadTaskDetails: Encodable {
        var task: SessionToolText.TaskEntry
        var folder: String
        var createdAt: String
        var childTaskIds: [String]?
        var queuedMessages: Int
        /// The servers the task's processes listen on now, as its header shows them.
        var servers: [Server]?
        /// The account an agent's start put it on, and why.
        var account: String?

        struct Server: Encodable {
            var url: String
            var process: String
        }
    }

    /// The conversation the task's timeline draws: the Codex thread once it has turns, else the
    /// shared transcript, as the phone remote reads it.
    func sessionToolPresentation(of session: SessionRecord) -> ConversationPresentation {
        if HarnessPresentationPolicy(harness: session.harness).usesCodexTimeline,
           let state = codexPresentationBySessionID[session.id], state.thread?.turns.isEmpty == false {
            return CodexConversationProjection.presentation(state, workspaceURL: session.workspaceURL,
                                                            historySelection: nil)
        }
        return TranscriptConversationProjection.presentation(
            from: transcriptBySessionID[session.id] ?? [], harness: session.harness, status: session.status,
            latestTurnIsComplete: session.completionState == .completed)
    }

    // MARK: - send_message_to_task

    private func sendMessageToTask(_ arguments: JSONValue, caller: SessionToolCaller) async -> AgentToolResult {
        guard let reference = arguments["task_id"]?.stringValue?.trimmingCharacters(in: .whitespaces),
              !reference.isEmpty else { return .error("Not sent: task_id is required.") }
        let message = (arguments["message"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return .error("Not sent: message is required.") }
        guard message.count <= SessionToolCatalog.maximumMessageLength else {
            return .error("Not sent: the message is longer than \(SessionToolCatalog.maximumMessageLength) characters.")
        }
        guard !message.hasPrefix("/") else {
            return .error("Not sent: slash commands are not sent to other tasks. Send the request in words instead.")
        }
        let target: SessionRecord
        switch await sessionToolTask(reference, caller: caller) {
        case let .success(found): target = found
        case let .failure(error): return error.result("Not sent")
        }
        guard target.id != caller.hostTaskID else {
            return .failure("Not sent: that is this task.", .invalidArguments, retry: .withChanges)
        }
        let quotes: [TaskMessage.Quote]
        switch personQuotes(arguments["person_quotes"], caller: caller) {
        case let .success(found): quotes = found
        case let .failure(error): return error.result("Not sent")
        }
        if let reason = await sessionToolMessageApproval(to: target, message: message, caller: caller) {
            return .failure("Not sent: \(reason)", .refused, retry: .no)
        }
        let sender = TaskMessage(senderID: caller.hostTaskID.uuidString, senderName: caller.title, body: message,
                                 quotes: quotes)
        let title = target.title.isEmpty ? "" : " (\(target.title))"
        switch await deliverTaskMessage(sender, to: target) {
        case .delivered:
            return .text("Delivered to task \(target.id.uuidString)\(title); it started a turn on the message.")
        case .steered:
            return .text("Delivered to task \(target.id.uuidString)\(title) while it works: it reads the message at its "
                + "next step, in the same turn. wait_tasks or read_task show what it did.")
        case .queued:
            return .text("Queued for task \(target.id.uuidString)\(title): it runs when that task's current turn "
                + "ends. wait_tasks or read_task show what it did.")
        case .afterStart:
            return .text("Queued for task \(target.id.uuidString)\(title): that task is queued, and this follows its "
                + "first message when it starts. wait_tasks waits for it.")
        case let .undelivered(reason):
            return .error("Not delivered to task \(target.id.uuidString)\(title): \(reason)")
        }
    }

    /// How a message from the caller reaches past what goes without asking.
    enum TaskMessageReach {
        /// Another project's task.
        case otherProject
        /// A task that runs without asking, while the caller asks.
        case raisesPermission
    }

    /// Whether a message into `target` needs the person: nil when it goes without asking (the
    /// caller's own project or split, or a caller that runs without asking).
    func sessionToolMessageReach(to target: SessionRecord, caller: SessionToolCaller) -> TaskMessageReach? {
        let neighbors = SessionToolPolicy.splitNeighborsShareProject
            && splits.split(containing: caller.hostTaskID)?.sessionIDs.contains(target.id) == true
        let sameProject = caller.projectID != nil && project(for: target)?.id == caller.projectID
        let raisesPermission = sessionToolPermission(of: target) == .elevated && caller.permission < .elevated
        guard (!sameProject && !neighbors) || raisesPermission, sessionToolAsksPerson(caller) else { return nil }
        return raisesPermission ? .raisesPermission : .otherProject
    }

    /// Asks the person when a message reaches past what goes without asking. Nil when it may go;
    /// otherwise why not.
    private func sessionToolMessageApproval(to target: SessionRecord, message: String,
                                            caller: SessionToolCaller) async -> String? {
        guard let reach = sessionToolMessageReach(to: target, caller: caller) else { return nil }
        let title = reach == .raisesPermission
            ? L10n.string("Send a message to a task that runs without asking")
            : L10n.string("Send a message to another project's task")
        let allowed = await askPerson(title: title, detail: sessionToolMessageDetail(to: target, message, caller: caller),
                                      caller: caller)
        return allowed ? nil : "the person did not approve sending it."
    }

    /// A card's lines for a message: from whom to which task, in which project, then the message.
    func sessionToolMessageDetail(to target: SessionRecord, _ message: String, caller: SessionToolCaller) -> String {
        L10n.format("%@ → %@", caller.title, target.title) + (project(for: target).map { " · \($0.name)" } ?? "")
            + "\n\n" + Self.cardPreview(message)
    }

    /// A message or prompt on a card: its first 600 characters, and "…" when there is more.
    static func cardPreview(_ text: String) -> String {
        String(text.prefix(600)) + (text.count > 600 ? "…" : "")
    }

    /// Delivers a message to a task the way the composer sends one, with the task's own model,
    /// permissions and account: an idle task starts a turn, and a running one gets it in that turn,
    /// as the composer's Steer sends one (Claude Code reads it at its next step, Codex `turn/steer`),
    /// so a task that waits on another hears from it without ending its turn first. A harness that
    /// takes nothing while its turn runs gets it once the turn ends.
    func deliverTaskMessage(_ message: TaskMessage, to target: SessionRecord) async -> TaskMessageDelivery {
        await deliverMessage(to: target) { message.text(for: $0) }
    }

    /// Delivers `text`, written for the task as it stands now, the way `deliverTaskMessage` does.
    func deliverMessage(to target: SessionRecord, text: (SessionRecord) -> String) async -> TaskMessageDelivery {
        guard let target = store.sessions.first(where: { $0.id == target.id }) else {
            return .undelivered("that task no longer exists.")
        }
        if composerDrafts.tasks.draft(for: target.id).editState != nil {
            return .undelivered("the person is editing a message in that task.")
        }
        if switchingAccounts.contains(target.id) || sessionMutations.contains(target.id) {
            return .undelivered("that task is changing (an account switch or an edit); try again shortly.")
        }
        switch sendRefusal(for: target) {
        case .heldElsewhere?: return .undelivered("another app holds that task's conversation.")
        case .folderMissing?: return .undelivered("that task's folder no longer exists.")
        case nil: break
        }
        if sessionTools.isArchivingSelf(target.id) {
            return .undelivered("that task is archiving itself; its conversation is ending.")
        }
        let text = text(target)
        // A child task that waits for room gets it after its first message, when it starts.
        if sessionTools.appendMessage(text, toQueued: target.id) { return .afterStart }
        let isRunning = target.status == .running || target.status == .waitingForApproval
        let previousError = errorBySessionID[target.id]
        let steers = FollowUpPolicy(harness: target.harness)?.steers == true
        if target.harness == .codex {
            await submitCodex(CodexComposerDraft(inputs: [.text(text)]), action: isRunning ? .steer : .automatic,
                              to: target)
        } else if isRunning {
            guard FollowUpPolicy(harness: target.harness) != nil else {
                return .undelivered("that task is working and its harness takes no queued messages; send it when "
                    + "the turn ends.")
            }
            await submitFollowUp(HarnessUserInput(text: text), action: steers ? .steer : .queue, to: target)
        } else {
            await send(HarnessUserInput(text: text), to: target)
        }
        if let error = errorBySessionID[target.id], error != previousError { return .undelivered(error) }
        guard isRunning else { return .delivered }
        return steers ? .steered : .queued
    }

    // MARK: - wait_tasks

    private func waitTasks(_ arguments: JSONValue, caller: SessionToolCaller) async -> AgentToolResult {
        guard case let .array(values)? = arguments["ids"] else { return .error("ids is required.") }
        let references = values.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespaces) }
        guard !references.isEmpty, references.count == values.count else {
            return .failure("ids must be task ids or agent ids.", .invalidArguments, retry: .withChanges)
        }
        guard references.count <= SessionToolCatalog.maximumWaitTargets else {
            return .error("At most \(SessionToolCatalog.maximumWaitTargets) ids.")
        }
        var ids: [UUID] = []
        for reference in references {
            if let id = UUID(uuidString: reference), sessionTools.run(id) != nil {
                ids.append(id)
                continue
            }
            switch await sessionToolTask(reference, caller: caller) {
            case let .success(task) where task.id == caller.hostTaskID:
                return .failure("\(reference) is this task, which cannot wait for itself.", .invalidArguments,
                                retry: .withChanges)
            case let .success(task): ids.append(task.id)
            case let .failure(error): return error.result()
            }
        }
        let requested = Self.integer(arguments["timeout_seconds"]).map { Duration.seconds(max(0, $0)) }
            ?? SessionToolPolicy.waitDefault
        _ = await waitForAny(ids, timeout: min(requested, caller.remaining))
        let states = ids.map { sessionToolOutcome(of: $0) }
        return .text(SessionToolText.json(states))
    }

    struct SessionToolOutcome: Encodable, Equatable {
        var id: String
        var kind: String
        var title: String?
        /// A task's link for a reply (`SessionToolText.link`); a subagent has none.
        var link: String?
        var state: String
        var ended: Bool
        var answer: String?
    }

    /// Where a task or a subagent stands, and its latest answer.
    func sessionToolOutcome(of id: UUID) -> SessionToolOutcome {
        if let run = sessionTools.run(id) {
            return SessionToolOutcome(
                id: id.uuidString, kind: "agent", title: run.harness.displayName, state: run.state.word,
                ended: run.state.isFinished, answer: run.answer.map(Self.answerExcerpt))
        }
        guard let session = store.sessions.first(where: { $0.id == id }) else {
            return SessionToolOutcome(id: id.uuidString, kind: "task", state: "gone", ended: true)
        }
        if sessionTools.isQueued(id) {
            return SessionToolOutcome(id: id.uuidString, kind: "task", title: session.title,
                                      link: SessionToolText.link(title: session.title, taskID: id), state: "queued", ended: false)
        }
        let state = TaskAttentionProjection.state(of: session, detail: taskAttentionDetails[id],
                                                  isShellBusy: shellBusySessionIDs.contains(id))
        let presentation = sessionToolPresentation(of: session)
        return SessionToolOutcome(
            id: id.uuidString, kind: "task", title: session.title,
            link: SessionToolText.link(title: session.title, taskID: id), state: SessionToolText.stateWord(state),
            ended: !Self.isWorking(session), answer: Self.latestAnswer(in: presentation).map(Self.answerExcerpt))
    }

    /// The longest a call from this harness waits (`SessionToolPolicy.waitCeiling`); tests shorten it.
    func sessionToolWaitCeiling(for harness: HarnessKind) -> Duration {
        sessionTools.waitCeilingOverride ?? SessionToolPolicy.waitCeiling(for: harness)
    }

    static func isWorking(_ session: SessionRecord) -> Bool {
        session.status == .running || session.status == .waitingForApproval
    }

    /// The last answer of the latest turn.
    static func latestAnswer(in presentation: ConversationPresentation) -> String? {
        guard let turn = presentation.turns.last else { return nil }
        for item in (turn.answers + turn.work).reversed() {
            if case let .answer(text, _) = item.kind, !text.isEmpty { return text }
        }
        return nil
    }

    static func answerExcerpt(_ text: String) -> String {
        text.count > 8_000 ? String(text.prefix(8_000)) + "\n[cut at 8000 characters; read_task reads more]" : text
    }

    /// Waits until one of the ids ends its turn or waits for the person, or the timeout passes.
    /// True when one did.
    @discardableResult
    func waitForAny(_ ids: [UUID], timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            for id in ids where sessionToolTargetSettled(id) { return true }
            guard clock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func sessionToolTargetSettled(_ id: UUID) -> Bool {
        if let run = sessionTools.run(id) { return run.state.isFinished || run.state == .waitingForApproval }
        guard let session = store.sessions.first(where: { $0.id == id }) else { return true }
        if sessionTools.isQueued(id) || sessionTools.starting.contains(id) { return false }
        if session.status == .waitingForApproval { return true }
        return !Self.isWorking(session) && followUps.queue(for: id).isEmpty
    }

    // MARK: - create_task

    private func createChildTask(_ arguments: JSONValue, caller: SessionToolCaller) async -> AgentToolResult {
        let prompt = (arguments["prompt"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return .error("Not created: prompt is required.") }
        guard prompt.count <= SessionToolCatalog.maximumMessageLength, !prompt.hasPrefix("/") else {
            return .error("Not created: the prompt must be words, not a slash command, and at most "
                + "\(SessionToolCatalog.maximumMessageLength) characters.")
        }
        let quotes: [TaskMessage.Quote]
        switch personQuotes(arguments["person_quotes"], caller: caller) {
        case let .success(found): quotes = found
        case let .failure(error): return error.result("Not created")
        }
        let harness: HarnessKind
        switch sessionToolHarness(arguments["harness"], default: caller.harness) {
        case let .success(value): harness = value
        case let .failure(error): return error.result("Not created")
        }
        if let refusal = sessionToolSpawnRefusal(caller: caller) {
            return .failure("Not created: \(refusal)", .refused, retry: .no)
        }
        let options: [String: String]
        switch Self.providerOptions(for: harness, model: arguments["model"]?.stringValue,
                                    effort: arguments["effort"]?.stringValue) {
        case let .success(value): options = sessionToolInheritedOptions(harness: harness, caller: caller, chosen: value)
        case let .failure(error): return error.result("Not created")
        }
        guard let runtime = runtimeSelections.selectedURL(for: harness) else {
            return .failure("Not created: \(harness.displayName) is not set up in Yardlet.", .refused, retry: .no)
        }
        let account: AccountStart
        switch await assignAccount(harness: harness, model: Self.modelOption(options, harness: harness),
                                   requested: arguments["account"]?.stringValue) {
        case let .success(value): account = value
        case let .failure(error): return error.result("Not created")
        }
        let chat = Self.bool(arguments["chat"]) == true
        if chat, !(arguments["project"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return .error("Not created: chat starts the task with no project, so it takes no project.")
        }
        let place: (folder: URL, project: Project?)
        if chat {
            // A chat's own new folder, as New Task's "No project" makes one (`ChatWorkspaces.makeFolder`).
            // It reaches no project, so it asks no one.
            do { place = (try ChatWorkspaces.makeFolder(in: projects.chatRoot), nil) } catch {
                return .error("Not created: Yardlet could not make the chat's folder: \(error.localizedDescription)")
            }
        } else {
            switch sessionToolPlace(arguments["project"]?.stringValue, caller: caller) {
            case let .success(value): place = value
            case let .failure(error): return error.result("Not created")
            }
        }
        let parentTaskID: UUID?
        switch await createdTaskParent(arguments, caller: caller) {
        case let .success(value): parentTaskID = value
        case let .failure(error): return error.result("Not created")
        }
        if !chat, sessionToolPlaceReachesPast(folder: place.folder, project: place.project, caller: caller),
           sessionToolAsksPerson(caller) {
            let detail = L10n.format("%@ → %@", caller.title,
                                     place.project?.name ?? place.folder.path(percentEncoded: false))
                + "\n\n" + Self.cardPreview(prompt)
            guard await askPerson(title: L10n.string("Create a task in another project"), detail: detail,
                                  caller: caller) else {
                return .failure("Not created: the person did not approve a task in another project.", .refused, retry: .no)
            }
        }
        // The task is made with its first message held, so it can wait for room in the sidebar.
        let child = await createSession(
            harness: harness, workspaceURL: place.folder, runtimeExecutableURL: runtime,
            title: SessionTitleProjection.provisionalTitle(from: prompt), initialPrompt: prompt,
            connection: account.connection, projectID: place.project?.id,
            providerOptions: options, selectsSession: false, parentTaskID: parentTaskID,
            holdsInitialPrompt: true)
        guard let child else {
            // A chat that never came to exist takes its still empty folder with it, as New Task's does.
            if chat, (try? FileManager.default.contentsOfDirectory(atPath: place.folder.path(percentEncoded: false)))?
                .isEmpty == true {
                try? FileManager.default.removeItem(at: place.folder)
            }
            return .error("Not created: \(bootstrapError ?? "Yardlet could not start the task.")")
        }
        sessionTools.setDepth(caller.depth + 1, of: child.id)
        sessionTools.noteStarted(child.id, by: caller.id)
        accountAssignments.record(account.assignment, for: child.id)
        let first = TaskMessage(senderID: caller.hostTaskID.uuidString, senderName: caller.title, body: prompt,
                                relation: .parent, quotes: quotes).text(in: .yardlet)
        let wait = Self.bool(arguments["wait"]) == true
        let notifies = Self.bool(arguments["notify"]) == true
        guard admitSessionToolStart(child.id, callerID: caller.id) else {
            sessionTools.enqueue(SessionToolCenter.QueuedStart(
                id: child.id, callerID: caller.id, firstMessage: first) { [weak self] start in
                await self?.startQueuedChildTask(start)
            })
            if notifies { watchForNotification(child.id, caller: caller) }
            let queued = "Queued task \(child.id.uuidString) (\(child.title)), \(createdTaskPlacement(parentTaskID, caller: caller)); it starts when "
                + "there is room. wait_tasks with this id waits for it.\n" + Self.createdTaskLinkLine(child) + account.assignment.toolLine
            guard wait else { return .text(queued) }
            let ended = await waitForAny([child.id], timeout: caller.remaining)
            return createdChildResult(child.id, ended: ended)
        }
        sessionTools.starting.insert(child.id)
        await startHeldTask(child, text: first)
        sessionTools.starting.remove(child.id)
        if let error = errorBySessionID[child.id] {
            return .error("Created task \(child.id.uuidString), but its first message failed: \(error)")
        }
        if notifies { watchForNotification(child.id, caller: caller) }
        guard wait else {
            return .text("Created task \(child.id.uuidString) (\(child.title)), \(createdTaskPlacement(parentTaskID, caller: caller)); its first "
                + "turn is running. wait_tasks or read_task show its answer.\n" + Self.createdTaskLinkLine(child)
                + account.assignment.toolLine)
        }
        let ended = await waitForAny([child.id], timeout: caller.remaining)
        return createdChildResult(child.id, ended: ended)
    }

    /// Where `create_task` nests the new task: under the caller, under the open task `parent_task_id`
    /// names, or under none with `topLevel`, as New Task starts one.
    private func createdTaskParent(_ arguments: JSONValue,
                                   caller: SessionToolCaller) async -> Result<UUID?, SessionToolError> {
        let reference = arguments["parent_task_id"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        if Self.bool(arguments["topLevel"]) == true {
            guard reference.isEmpty else {
                return .failure(SessionToolError(message: "give topLevel or parent_task_id, not both."))
            }
            return .success(nil)
        }
        guard !reference.isEmpty, reference != SessionToolCatalog.selfReference else { return .success(caller.hostTaskID) }
        switch await sessionToolTask(reference, caller: caller) {
        case let .success(parent): return .success(parent.id)
        case let .failure(error):
            return .failure(SessionToolError(message: error.message + " Omit parent_task_id to nest it under this task.",
                                             failure: error.failure))
        }
    }

    private func createdTaskPlacement(_ parentTaskID: UUID?, caller: SessionToolCaller) -> String {
        guard let parentTaskID else { return "as a top-level task" }
        return parentTaskID == caller.hostTaskID ? "nested under this task" : "nested under task \(parentTaskID.uuidString)"
    }

    /// The new task's link, on a line of its own, in what `create_task` answers without `wait`.
    private static func createdTaskLinkLine(_ task: SessionRecord) -> String {
        "Link: " + SessionToolText.link(title: task.title, taskID: task.id) + "\n"
    }

    /// What `create_task` with `wait` answers: the child's state and latest answer, and that it goes
    /// on when the call's time ran out first.
    private func createdChildResult(_ id: UUID, ended: Bool) -> AgentToolResult {
        let note = ended ? "" : sessionTools.isQueued(id)
            ? " It is queued and starts when there is room; wait_tasks with this id waits for it."
            : " It is still running; wait_tasks with this id waits again."
        let account = accountAssignments.assignment(for: id).map { "\n" + $0.toolLine } ?? ""
        return .text("Created task \(id.uuidString).\(note)\(account)\n" + SessionToolText.json(sessionToolOutcome(of: id)))
    }

    // MARK: - archive_task

    /// Archives the tasks the person approves, on one card for all of them, through the sidebar's
    /// own path (`archive(_:)`): the provider session where the provider keeps one, then the index,
    /// then a worktree no task uses any more. Each task is answered on its own. The caller's own
    /// task ("self", or its id) is archived as the Claude app's `archive_session` archives "self":
    /// this result goes back first, and the task is archived once its harness has it and its turn
    /// has stopped (`archiveSelfAfterResult`), with the child tasks that go with it
    /// (`sessionToolSelfArchiveCascade`).
    private func archiveTasks(_ arguments: JSONValue, caller: SessionToolCaller) async -> AgentToolResult {
        guard case let .array(values)? = arguments["task_ids"] else { return .error("Not archived: task_ids is required.") }
        let references = values.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespaces) }
        guard !references.isEmpty, references.count == values.count, !references.contains("") else {
            return .error("Not archived: task_ids must be task ids from list_tasks.")
        }
        var seen = Set<String>()
        let unique = references.filter { reference in
            let resolved = reference == SessionToolCatalog.selfReference ? caller.hostTaskID.uuidString : reference
            return seen.insert(resolved.uppercased()).inserted
        }
        guard unique.count <= SessionToolCatalog.maximumArchiveTargets else {
            return .error("Not archived: at most \(SessionToolCatalog.maximumArchiveTargets) task ids at once.")
        }
        // The harness's record of its session tool calls before this one answers: archiving this
        // task waits until the record has this call's result.
        let callsBefore = sessionToolCallRecords(named: SessionToolCatalog.archiveTask, in: caller.hostTaskID)
        var results: [ArchivedTaskResult] = []
        for reference in unique {
            switch await sessionToolTask(reference, caller: caller) {
            case let .success(session):
                results.append(ArchivedTaskResult(taskId: session.id.uuidString, title: session.title,
                                                  reason: sessionToolArchiveRefusal(session, caller: caller)))
            case let .failure(error) where error.failure?.kind == .archived:
                results.append(ArchivedTaskResult(taskId: reference, reason: "it is already archived.", retry: .no))
            case let .failure(error):
                results.append(ArchivedTaskResult(taskId: reference, reason: error.message,
                                                  retry: error.failure?.retry ?? .withChanges))
            }
        }
        let selfIndex = results.firstIndex { $0.taskId == caller.hostTaskID.uuidString && $0.title != nil }
        var cascade = SelfArchiveCascade()
        if let selfIndex, results[selfIndex].reason == nil {
            if sessionTools.isArchivingSelf(caller.hostTaskID) {
                results[selfIndex].reason = Self.alreadyArchivingSelf
            } else {
                (results[selfIndex].reason, cascade) = await sessionToolSelfArchiveCheck(caller: caller)
            }
        }
        var alsoArchived: [ChildTaskResult]?
        var keptChildTasks: [ChildTaskResult]?
        let candidates = results.indices.filter { results[$0].title != nil && results[$0].reason == nil }
        if !candidates.isEmpty {
            let targets = candidates.compactMap { index in store.sessions.first { $0.id.uuidString == results[index].taskId } }
            let archivesSelf = targets.contains { $0.id == caller.hostTaskID }
            // The child tasks that go with this task are on the card too, unless asked for by id.
            let joining = cascade.with.filter { child in !targets.contains { $0.id == child.id } }
            let count = targets.count + joining.count
            let title = archivesSelf && count == 1 ? L10n.string("Archive this task")
                : count == 1 ? L10n.string("Archive task") : L10n.format("Archive %lld tasks", Int64(count))
            func line(_ task: SessionRecord) -> String {
                "• " + task.title + (project(for: task).map { " · \($0.name)" } ?? "")
            }
            var detail = (targets.map { task in
                task.id == caller.hostTaskID ? L10n.format("%@ (this task)", line(task)) : line(task)
            } + joining.map { L10n.format("%@ (started by this task)", line($0)) }).joined(separator: "\n")
            if archivesSelf {
                detail += "\n\n" + L10n.string("This task's turn stops after this call, and its conversation ends.")
            }
            let allowed = sessionToolAsksPerson(caller)
                ? await askPerson(title: title, detail: detail, caller: caller) : true
            if allowed {
                // A task may have started a turn, or gone, while the card waited.
                var approved: [SessionRecord] = []
                var archivingSelf = false
                for index in candidates {
                    guard let task = store.sessions.first(where: { $0.id.uuidString == results[index].taskId }) else {
                        results[index].reason = "that task is no longer listed."
                        continue
                    }
                    if task.id == caller.hostTaskID {
                        let (refusal, now) = await sessionToolSelfArchiveCheck(caller: caller)
                        if let refusal {
                            results[index].reason = refusal
                            continue
                        }
                        // Only the children the card named go with it; one that joined since stays.
                        let named = Set((joining + targets).map(\.id))
                        cascade = SelfArchiveCascade(
                            with: now.with.filter { named.contains($0.id) },
                            kept: now.kept + now.with.filter { !named.contains($0.id) }.map { (task: $0, reason: nil) })
                        archivingSelf = true
                    } else if let refusal = sessionToolArchiveRefusal(task, caller: caller) {
                        results[index].reason = refusal
                    } else {
                        approved.append(task)
                    }
                }
                // An empty batch would still clear the window's worktree notice.
                for outcome in approved.isEmpty ? [] : await archive(approved) {
                    guard let index = results.firstIndex(where: { $0.taskId == outcome.sessionID.uuidString }) else { continue }
                    results[index].archived = outcome.failure == nil
                    results[index].reason = outcome.failure
                    results[index].worktree = outcome.worktreeNotice
                }
                if archivingSelf, let selfIndex {
                    // A child asked for by id was archived above, on its own.
                    let joiningNow = cascade.with.filter { child in store.sessions.contains { $0.id == child.id } }
                    results[selfIndex].archived = true
                    alsoArchived = joiningNow.isEmpty ? nil : joiningNow.map { ChildTaskResult(taskId: $0.id.uuidString, title: $0.title) }
                    keptChildTasks = cascade.kept.isEmpty ? nil : cascade.kept.map {
                        ChildTaskResult(taskId: $0.task.id.uuidString, title: $0.task.title, reason: $0.reason)
                    }
                    archiveSelfAfterResult(caller: caller, with: joiningNow.map(\.id), callsBefore: callsBefore)
                }
            } else {
                for index in candidates {
                    results[index].reason = "the person did not approve archiving it."
                    results[index].retry = .no
                }
            }
        }
        // What calling again can do for each task left as it was: a task that works, waits or changes
        // stops doing so by itself; what is the person's, or a subagent's place, does not change by asking.
        for index in results.indices where !results[index].archived && results[index].retry == nil {
            guard let reason = results[index].reason else { continue }
            results[index].retry = Self.lastingArchiveRefusals.contains(reason) ? .no : .later
        }
        let archivedCount = results.filter(\.archived).count
        let archivesSelf = selfIndex.map { results[$0].archived } == true
        var note: String?
        if archivesSelf {
            note = "This task is archived as soon as its harness has this result: its turn stops here and the "
                + "conversation ends, so do nothing more in it. The person can unarchive it from Archived tasks "
                + "in the sidebar."
        } else if archivedCount > 0 {
            note = "The person can unarchive them from Archived tasks in the sidebar."
        }
        let report = ArchiveTasksReport(
            archived: archivedCount, notArchived: results.count - archivedCount, tasks: results,
            alsoArchived: alsoArchived, keptChildTasks: keptChildTasks, note: note)
        let text = SessionToolText.json(report)
        return archivedCount > 0 ? .text(text) : .error(text)
    }

    private struct ArchiveTasksReport: Encodable {
        var archived: Int
        var notArchived: Int
        var tasks: [ArchivedTaskResult]
        /// The child tasks archived with this task.
        var alsoArchived: [ChildTaskResult]?
        /// The child tasks this task's archive leaves in the sidebar, at its top level.
        var keptChildTasks: [ChildTaskResult]?
        var note: String?
    }

    private struct ArchivedTaskResult: Encodable {
        var taskId: String
        var title: String?
        var archived = false
        /// Why it was not archived.
        var reason: String?
        /// What became of its worktree, when archiving kept it or could not remove it.
        var worktree: String?
        /// What calling again can do for a task it did not archive (`AgentToolFailure.Retry`).
        var retry: AgentToolFailure.Retry?
    }

    /// The refusals asking again does not change: the person's draft, and a subagent's or an archive's own place.
    static let lastingArchiveRefusals: Set<String> = [unsentDraftRefusal, subagentArchivesHostRefusal, alreadyArchivingSelf]
    static let unsentDraftRefusal = "the person has an unsent draft in it."
    static let subagentArchivesHostRefusal = "a subagent cannot archive the task it runs in."
    static let alreadyArchivingSelf = "this task is already being archived."

    private struct ChildTaskResult: Encodable {
        var taskId: String
        var title: String
        /// Why it stays, when something in it would be lost.
        var reason: String?
    }

    /// Why `archive_task` leaves a task as it is, or nil: it works or waits for the person, it is
    /// changing, or it holds the person's unsent draft, which archiving would drop. The caller's own
    /// task answers `sessionToolSelfArchiveRefusal` instead.
    func sessionToolArchiveRefusal(_ session: SessionRecord, caller: SessionToolCaller) -> String? {
        if session.id == caller.hostTaskID { return sessionToolSelfArchiveRefusal(session, caller: caller) }
        if let request = TaskAttentionProjection.waitingRequest(of: session, detail: taskAttentionDetails[session.id]) {
            return request == .input ? "it waits for the person's answer." : "it waits for the person's approval."
        }
        if sessionToolWaitsForPerson(in: session.id) { return "it waits for the person's approval." }
        if taskAttentionDetails[session.id]?.browserWait != nil { return "a tab of its browser waits for the person." }
        if sessionTools.isQueued(session.id) { return "it is queued and has not started." }
        if Self.isWorking(session) || !followUps.queue(for: session.id).isEmpty { return "it is running." }
        if shellBusySessionIDs.contains(session.id) { return "a command it started is still running." }
        if sessionTools.runs(hostedBy: session.id).contains(where: { !$0.state.isFinished }) {
            return "a subagent it started is still running."
        }
        if switchingAccounts.contains(session.id) || sessionMutations.contains(session.id)
            || unarchivingSessionIDs.contains(session.id) {
            return "that task is changing (an account switch or an edit); try again shortly."
        }
        if composerDrafts.tasks.existingDraft(for: session.id)?.snapshot.isEmpty == false {
            return Self.unsentDraftRefusal
        }
        return nil
    }

    // MARK: - archive_task "self"

    /// Why `archive_task` leaves the caller's own task as it is, or nil. The turn that asks is the
    /// task's own, so it does not hold the archive back, as the Claude app leaves the calling turn
    /// out of what holds back `archive_session` "self" (3.1623.3 `agentArchiveHoldFor`,
    /// `beyondOwnTurn`); what the stop or the archive would lose does: a request waiting for the
    /// person, a subagent or a command it started, messages waiting behind the turn, a change in
    /// progress, or the person's unsent draft. A subagent cannot archive the task it runs in.
    func sessionToolSelfArchiveRefusal(_ session: SessionRecord, caller: SessionToolCaller) -> String? {
        if caller.id != caller.hostTaskID { return Self.subagentArchivesHostRefusal }
        if let request = taskAttentionDetails[session.id]?.pendingRequest {
            return request == .input ? "it waits for the person's answer." : "it waits for the person's approval."
        }
        if sessionTools.runs(hostedBy: session.id).contains(where: { !$0.state.isFinished }) {
            return "a subagent it started is still running."
        }
        if shellBusySessionIDs.contains(session.id) { return "a command it started is still running." }
        if sessionToolHasBackgroundTasks(session.id) { return "a background command or agent it started is still running." }
        if !followUps.queue(for: session.id).isEmpty { return "messages wait to be sent after its turn." }
        if switchingAccounts.contains(session.id) || sessionMutations.contains(session.id)
            || unarchivingSessionIDs.contains(session.id) {
            return "that task is changing (an account switch or an edit); try again shortly."
        }
        if composerDrafts.tasks.existingDraft(for: session.id)?.snapshot.isEmpty == false {
            return Self.unsentDraftRefusal
        }
        return nil
    }

    /// The provider's background work its conversation shows running (Claude Code's background
    /// commands and agents), which closing the session would end.
    func sessionToolHasBackgroundTasks(_ taskID: UUID) -> Bool {
        !BackgroundTasksProjection(entries: transcriptBySessionID[taskID] ?? []).rows.isEmpty
    }

    /// Whether the caller's own task may be archived now, and with which child tasks: its refusal,
    /// a Codex thread's background terminals (which `thread/archive` ends), or a child that holds
    /// the archive back.
    func sessionToolSelfArchiveCheck(caller: SessionToolCaller) async -> (String?, SelfArchiveCascade) {
        guard let task = store.sessions.first(where: { $0.id == caller.hostTaskID }) else {
            return ("that task is no longer listed.", SelfArchiveCascade())
        }
        if let refusal = sessionToolSelfArchiveRefusal(task, caller: caller) { return (refusal, SelfArchiveCascade()) }
        if await codexBackgroundTerminals(of: task)?.isEmpty == false {
            return ("a background terminal it started is still running.", SelfArchiveCascade())
        }
        let cascade = sessionToolSelfArchiveCascade(of: task, caller: caller)
        return (cascade.hold, cascade)
    }

    /// The child tasks that go with the caller's own task when it is archived, and those that stay.
    struct SelfArchiveCascade {
        var with: [SessionRecord] = []
        var kept: [(task: SessionRecord, reason: String?)] = []
        /// Why a child that would go with it holds the archive back.
        var hold: String?
    }

    /// The task's child tasks (`create_task`'s) as the Claude app's side sessions go with an archived
    /// session (3.1623.3 `archiveCascadeOf` → `sideSessionGoesWithParent`): a child goes with its
    /// parent when it works in the parent's folder or worktree, or when it has settled (nothing holds
    /// it back from `archive_task`, it runs no background work, it is not pinned, and its own
    /// children in its folder have settled too); its children follow it the same way. One that would
    /// go with it but still works, or is pinned, holds the archive back, as the Claude app holds it
    /// for a side session that shares the worktree; any other stays in the sidebar, at the top level
    /// once its parent is archived. The Claude app also keeps a side session with an open pull
    /// request of its own, which Yardlet does not know for a task nobody opened.
    func sessionToolSelfArchiveCascade(of task: SessionRecord, caller: SessionToolCaller) -> SelfArchiveCascade {
        var cascade = SelfArchiveCascade()
        var visited: Set<UUID> = [task.id]
        var parents = [task]
        while !parents.isEmpty {
            let parent = parents.removeFirst()
            for child in sessionToolChildTasks(of: parent.id) where visited.insert(child.id).inserted {
                let sharesPlace = sessionToolSharesPlace(child, with: parent)
                guard sharesPlace || sessionToolChildHasSettled(child, caller: caller, visited: visited) else {
                    cascade.kept.append((task: child, reason: sessionToolArchiveRefusal(child, caller: caller)))
                    continue
                }
                if cascade.hold == nil, let reason = sessionToolArchiveRefusal(child, caller: caller)
                    ?? (sessionToolHasBackgroundTasks(child.id) ? "a background command or agent it started is still running." : nil)
                    ?? (child.isPinned ? "it is pinned." : nil) {
                    cascade.hold = "its child task \(child.id.uuidString) (\(child.title)) works in its folder and would be "
                        + "archived with it, but \(reason)"
                }
                cascade.with.append(child)
                parents.append(child)
            }
        }
        return cascade
    }

    func sessionToolChildTasks(of taskID: UUID) -> [SessionRecord] {
        store.sessions.filter { $0.parentTaskID == taskID && sessionTools.madeTask($0.id) }
    }

    private func sessionToolChildHasSettled(_ child: SessionRecord, caller: SessionToolCaller, visited: Set<UUID>) -> Bool {
        guard !child.isPinned, sessionToolArchiveRefusal(child, caller: caller) == nil,
              !sessionToolHasBackgroundTasks(child.id) else { return false }
        return sessionToolChildTasks(of: child.id).allSatisfy { grandchild in
            visited.contains(grandchild.id) || !sessionToolSharesPlace(grandchild, with: child)
                || sessionToolChildHasSettled(grandchild, caller: caller, visited: visited.union([child.id]))
        }
    }

    /// The same folder, or the same Yardlet worktree.
    func sessionToolSharesPlace(_ child: SessionRecord, with parent: SessionRecord) -> Bool {
        if child.workspaceURL.standardizedFileURL.pathComponents == parent.workspaceURL.standardizedFileURL.pathComponents {
            return true
        }
        let layout = worktrees.layout
        guard let worktree = layout.worktreeURL(containing: child.workspaceURL) else { return false }
        return layout.worktreeURL(containing: parent.workspaceURL) == worktree
    }

    /// One call to a Yardlet tool as the task's harness records it: the call's item, and whether the
    /// harness has its result yet.
    struct SessionToolCallRecord: Equatable {
        let id: String
        let hasResult: Bool
    }

    /// The task's calls to one of Yardlet's tools, in its harness's own record: Codex's `mcpToolCall`
    /// items for the `yardlet` server, completed at `item/completed`; Claude Code's
    /// `mcp__yardlet__<tool>` calls, completed by their `tool_result`, and another harness's call by
    /// the names `ConversationAgentRunProjection` reads.
    func sessionToolCallRecords(named tool: String, in taskID: UUID) -> [SessionToolCallRecord] {
        if let turns = codexPresentationBySessionID[taskID]?.thread?.turns, !turns.isEmpty {
            return turns.flatMap(\.items).compactMap { item in
                guard case let .mcpToolCall(call) = item.content, call.server == AgentToolEnvironment.serverName,
                      call.tool == tool else { return nil }
                return SessionToolCallRecord(id: item.id, hasResult: item.lifecycle == .completed || call.status != "inProgress")
            }
        }
        let names: Set<String> = ["mcp__\(AgentToolEnvironment.serverName)__\(tool)", tool]
        return (transcriptBySessionID[taskID] ?? []).compactMap { entry in
            guard case let .activity(activity, state) = entry.content,
                  [activity.kind, activity.title].contains(where: { names.contains($0) || $0.hasSuffix(": \(tool)") })
            else { return nil }
            return SessionToolCallRecord(id: activity.id, hasResult: state != .running)
        }
    }

    /// Archives the caller's own task after `archive_task` answered, in the order that leaves the
    /// provider's record whole. First the harness has the call's result: Claude Code prints the
    /// `tool_result` message, Codex completes the `mcpToolCall` item (its rollout has the output).
    /// Stopping sooner would record the call as cut off instead of answered. Then the turn stops as
    /// Stop stops it (`interrupt(_:)`: Claude Code's `interrupt` control request, which still ends
    /// the turn with a result; Codex's `turn/interrupt`, which ends it `interrupted` and records
    /// `turn_aborted`), before the next answer would start. Once that turn has ended, the task is
    /// archived through the sidebar's path with the children that go with it: Codex's
    /// `thread/archive` (which shuts a loaded thread down and moves its rollout), then the index, the
    /// session's process and a worktree no task uses. Claude Code 2.1.291 writes its transcript
    /// through a queue it drains every 100 ms and before it prints a turn's `result`
    /// (`flushBeforeResult`), so the stopped turn is on disk when its result arrives, although
    /// closing the session kills the CLI before its exit flush could run. The Claude app instead
    /// archives on the tick after the result and closes the session's process at once (3.1623.3
    /// `setImmediate` → `completeAgentArchive` → `teardownQuery` → `query.close()`), without waiting
    /// for the harness to record the result or a stop. Anything the stop or the archive would lose
    /// that arrives meanwhile (a draft, a queued message, a new turn) keeps the task, and the task
    /// says so.
    private func archiveSelfAfterResult(caller: SessionToolCaller, with children: [UUID],
                                        callsBefore: [SessionToolCallRecord]) {
        let taskID = caller.hostTaskID
        guard sessionTools.beginArchivingSelf(taskID) else { return }
        let override = sessionTools.selfArchiveWaitOverride
        let resultWait = override ?? SessionToolPolicy.selfArchiveResultWait
        let unseenWait = min(resultWait, SessionToolPolicy.selfArchiveUnseenCallWait)
        let stopWait = override ?? SessionToolPolicy.selfArchiveStopWait
        Task { [weak self] in
            guard let self else { return }
            defer { self.sessionTools.endArchivingSelf(taskID) }
            await self.waitForSessionToolResult(named: SessionToolCatalog.archiveTask, in: taskID, after: callsBefore,
                                                timeout: resultWait, unseenTimeout: unseenWait)
            guard let task = self.store.sessions.first(where: { $0.id == taskID }) else { return }
            guard self.sessionToolSelfArchiveRefusal(task, caller: caller) == nil else {
                return self.keepAfterSelfArchive(taskID)
            }
            if Self.isWorking(task) {
                await self.interrupt(task)
                // A turn that ended and started again is the person's next message.
                let ended = await self.waitForTurnToEnd(taskID, timeout: stopWait)
                guard let current = self.store.sessions.first(where: { $0.id == taskID }) else { return }
                if ended, Self.isWorking(current) { return self.keepAfterSelfArchive(taskID) }
            }
            guard let task = self.store.sessions.first(where: { $0.id == taskID }) else { return }
            guard self.sessionToolSelfArchiveRefusal(task, caller: caller) == nil else {
                return self.keepAfterSelfArchive(taskID)
            }
            // A child that started working or got a draft meanwhile stays.
            let joining = children.compactMap { id in self.store.sessions.first { $0.id == id } }
                .filter { self.sessionToolArchiveRefusal($0, caller: caller) == nil }
            await self.archive([task] + joining)
        }
    }

    /// Waits until the task's harness has the result of the session tool call that was in flight
    /// when `before` was read: a call that had no result then has one now. A call Yardlet never saw
    /// the harness start gets a shorter wait, and the turn's end ends the wait.
    func waitForSessionToolResult(named tool: String, in taskID: UUID, after before: [SessionToolCallRecord],
                                  timeout: Duration, unseenTimeout: Duration) async {
        let answeredBefore = Set(before.filter(\.hasResult).map(\.id))
        let clock = ContinuousClock()
        let start = clock.now
        while !Task.isCancelled {
            guard let task = store.sessions.first(where: { $0.id == taskID }), Self.isWorking(task) else { return }
            let calls = sessionToolCallRecords(named: tool, in: taskID).filter { !answeredBefore.contains($0.id) }
            if calls.contains(where: \.hasResult) { return }
            let waited = clock.now - start
            if waited >= timeout || (calls.isEmpty && waited >= unseenTimeout) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Waits for the task's turn to end; false when it still works at the timeout.
    func waitForTurnToEnd(_ taskID: UUID, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            guard let task = store.sessions.first(where: { $0.id == taskID }), Self.isWorking(task) else { return true }
            guard clock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The task changed while it stopped to be archived, so it stays, and its conversation says why.
    private func keepAfterSelfArchive(_ taskID: UUID) {
        reportTaskError(L10n.string("This task was not archived: something in it changed while it stopped."), in: taskID)
    }

    // MARK: - Shared checks

    struct SessionToolError: LocalizedError {
        let message: String
        /// What went wrong and what calling again can do, for the agent; nil leaves the message as it is.
        var failure: AgentToolFailure?
        var errorDescription: String? { message }

        /// The call's answer: what it did not do ("Not sent"), then why; without it, the reason alone.
        func result(_ outcome: String? = nil) -> AgentToolResult {
            let text = outcome.map { "\($0): \(message)" } ?? message.prefix(1).uppercased() + message.dropFirst()
            return failure.map { .failure(text, $0) } ?? .error(text)
        }
    }

    /// The open task a session tool's `task_id` names, or why it names none, read the same way for every
    /// tool: "self" is the calling task, and a reference that is no task id, an archived task, a subagent's
    /// id and an id Yardlet has no task for are told apart. Yardlet takes a task id only whole; a shortened
    /// one that begins one task's id is answered with that task's whole id. Reading the archived tasks starts
    /// no turn.
    func sessionToolTask(_ reference: String, caller: SessionToolCaller) async -> Result<SessionRecord, SessionToolError> {
        let reference = reference.trimmingCharacters(in: .whitespaces)
        let id = reference == SessionToolCatalog.selfReference ? caller.hostTaskID : UUID(uuidString: reference)
        guard let id else { return .failure(await sessionToolUnreadTaskReference(reference, caller: caller)) }
        if let task = store.sessions.first(where: { $0.id == id }) { return .success(task) }
        if store.archivedSessions == nil { try? await store.loadArchivedSessions() }
        if let archived = store.archivedSessions?.first(where: { $0.id == id }) {
            return .failure(SessionToolError(
                message: "task \(id.uuidString) (\(archived.session.title)) is archived. The person can unarchive it "
                    + "from Archived tasks in the sidebar.",
                failure: AgentToolFailure(.archived, retry: .no, details: ["taskId": .string(id.uuidString)])))
        }
        if sessionTools.run(id) != nil {
            return .failure(SessionToolError(
                message: "\(id.uuidString) is a subagent's id from run_agent, not a task's. wait_tasks gives its state "
                    + "and answer.", failure: AgentToolFailure(.invalidArguments, retry: .withChanges)))
        }
        return .failure(SessionToolError(
            message: "no task \(id.uuidString); list_tasks gives the task ids.",
            failure: AgentToolFailure(.notFound, retry: .withChanges, details: ["taskId": .string(id.uuidString)])))
    }

    /// Why a reference that is no task id names no task: a task suggestion's id from spawn_task, a task id
    /// cut short (as an agent may write one in prose), or anything else.
    private func sessionToolUnreadTaskReference(_ reference: String, caller: SessionToolCaller) async -> SessionToolError {
        if TaskSuggestionToolCatalog.isTaskID(reference) {
            if let started = taskSuggestions.resolution(of: reference, in: caller.hostTaskID)?.startedTaskID {
                return SessionToolError(
                    message: "\(reference) is a task suggestion's id. The task the person started from it is "
                        + "\(started.uuidString): call again with that id.",
                    failure: AgentToolFailure(.invalidArguments, retry: .withChanges,
                                              details: ["taskId": .string(started.uuidString)]))
            }
            return SessionToolError(
                message: "\(reference) is a task suggestion's id from spawn_task, not a task's: dismiss_task takes it, "
                    + "and a task the person starts from it has a task id of its own in list_tasks.",
                failure: AgentToolFailure(.invalidArguments, retry: .withChanges))
        }
        let start = reference.uppercased()
        if start.count >= 4, start.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            if store.archivedSessions == nil { try? await store.loadArchivedSessions() }
            let open = store.sessions.filter { $0.id.uuidString.hasPrefix(start) }
            let archived = (store.archivedSessions ?? []).map(\.session).filter { $0.id.uuidString.hasPrefix(start) }
            if open.count + archived.count == 1, let task = (open + archived).first {
                let state = archived.isEmpty ? "" : ", which is archived"
                return SessionToolError(
                    message: "\(reference) is not a whole task id, and Yardlet takes task ids whole. It begins the id of "
                        + "task \(task.id.uuidString) (\(task.title))\(state).",
                    failure: AgentToolFailure(.invalidArguments, retry: archived.isEmpty ? .withChanges : .no,
                                              details: ["taskId": .string(task.id.uuidString)]))
            }
            if open.count + archived.count > 1 {
                return SessionToolError(
                    message: "\(reference) is not a whole task id, and Yardlet takes task ids whole; it begins the ids of "
                        + "\(open.count + archived.count) tasks. list_tasks gives them whole.",
                    failure: AgentToolFailure(.invalidArguments, retry: .withChanges))
            }
        }
        return SessionToolError(
            message: "\(reference) is not a task id. A task id is a whole UUID as list_tasks gives it, or \"self\" for "
                + "this task.", failure: AgentToolFailure(.invalidArguments, retry: .withChanges))
    }

    func sessionToolHarness(_ value: JSONValue?, default fallback: HarnessKind) -> Result<HarnessKind, SessionToolError> {
        guard let raw = value?.stringValue?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return .success(fallback)
        }
        let harness = HarnessKind(rawValue: raw)
        guard HarnessCatalog.descriptor(for: harness) != nil else {
            return .failure(SessionToolError(message: "no harness \(raw). Use an id such as claude-code or codex.",
                                             failure: AgentToolFailure(.invalidArguments, retry: .withChanges)))
        }
        guard runtimeSelections.selectedURL(for: harness) != nil else {
            return .failure(SessionToolError(message: "\(harness.displayName) is not set up in Yardlet.",
                                             failure: AgentToolFailure(.refused, retry: .no)))
        }
        return .success(harness)
    }

    /// What a child or subagent on the caller's own harness starts with: the caller's model, effort
    /// and permission mode as its task keeps them, under what the call chose (decision of
    /// 2026-10-22: a child session inherits them unless the call says otherwise). A chosen model drops the
    /// caller's effort, which that model may not take. Another harness starts on its own defaults.
    func sessionToolInheritedOptions(harness: HarnessKind, caller: SessionToolCaller,
                                     chosen: [String: String]) -> [String: String] {
        guard let host = store.sessions.first(where: { $0.id == caller.hostTaskID }) else { return chosen }
        // Another harness reads none of the caller's options, but runs as freely as the caller does,
        // in its own words: a Codex task with full access starts a Claude child that does not ask.
        guard harness == caller.harness else {
            return Self.permissionOptions(for: harness, level: sessionToolPermission(of: host))
                .merging(chosen) { _, new in new }
        }
        return Self.inheritedOptions(host.providerOptions, harness: harness, chosen: chosen)
    }

    /// A harness's own option for a permission level: what runs without asking (Claude Code's
    /// Bypass permissions, Codex's Full access, Antigravity's bypass) or reads only (plan mode,
    /// Codex's read-only). The standard level leaves the harness's default.
    static func permissionOptions(for harness: HarnessKind, level: TaskPermissionLevel) -> [String: String] {
        switch (harness, level) {
        case (.claudeCode, .elevated): [ClaudeLaunchOption.permissionMode: ClaudePermissionMode.bypassPermissions]
        case (.claudeCode, .readOnly): [ClaudeLaunchOption.permissionMode: ClaudePermissionMode.plan]
        case (.codex, .elevated): [CodexRunLocation.storageKey: CodexRunLocation.dangerFullAccess.rawValue]
        case (.codex, .readOnly): [CodexRunLocation.storageKey: CodexRunLocation.readOnly.rawValue]
        case (.antigravityCLI, .elevated): [AntigravityPermissionMode.optionID: AntigravityPermissionMode.bypass]
        case (.antigravityCLI, .readOnly): [AntigravityPermissionMode.optionID: AntigravityPermissionMode.plan]
        default: [:]
        }
    }

    static func inheritedOptions(_ parent: [String: String], harness: HarnessKind,
                                 chosen: [String: String]) -> [String: String] {
        var inherited = parent
        // Whether a session's next message is suggested is the caller's own, not a choice to pass on.
        inherited[ClaudeLaunchOption.nextMessageSuggestions] = nil
        if harness == .claudeCode, chosen[ClaudeLaunchOption.model] != nil, chosen[ClaudeLaunchOption.effort] == nil {
            inherited[ClaudeLaunchOption.effort] = nil
        }
        if harness == .antigravityCLI, chosen[StructuredHeadlessOptionID.model] != nil,
           chosen[StructuredHeadlessOptionID.reasoningEffort] == nil {
            inherited[StructuredHeadlessOptionID.reasoningEffort] = nil
        }
        return inherited.merging(chosen) { _, new in new }
    }

    /// The model and effort a harness's new task keeps, under its model menu's own keys.
    static func providerOptions(for harness: HarnessKind, model: String?, effort: String?) -> Result<[String: String], SessionToolError> {
        let model = model?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let effort = effort?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        guard model != nil || effort != nil else { return .success([:]) }
        if harness == .codex, model == nil {
            return .failure(SessionToolError(message: "Codex takes an effort only with its model."))
        }
        let options = NewTaskModelChoice(model: model, effort: effort).providerOptions(for: harness)
        guard !options.isEmpty else {
            return .failure(SessionToolError(message: "Yardlet does not choose a model for \(harness.displayName) here."))
        }
        return .success(options)
    }

    /// Why the caller may not start another child or subagent at all, or nil. How many run at once is
    /// not a refusal: one beyond what fits waits for room (`admitSessionToolStart`).
    func sessionToolSpawnRefusal(caller: SessionToolCaller) -> String? {
        guard !sessionTools.isArchivingSelf(caller.hostTaskID) else {
            return "this task is archiving itself; its conversation is ending."
        }
        guard caller.depth < SessionToolPolicy.maximumDepth else {
            return "tasks and subagents started this way nest at most \(SessionToolPolicy.maximumDepth) deep."
        }
        return nil
    }

    // MARK: - Room to start

    /// The caller's children and subagents that run now: started, not waiting for room, not ended.
    func sessionToolRunningCount(of callerID: UUID) -> Int {
        sessionTools.started(by: callerID).filter { id in
            if sessionTools.isQueued(id) { return false }
            if sessionTools.starting.contains(id) { return true }
            if let run = sessionTools.run(id) { return run.state != .queued && !run.state.isFinished }
            return store.sessions.first(where: { $0.id == id }).map(Self.isWorking) ?? false
        }.count
    }

    /// Whether a new child or subagent of the caller starts now, behind what already waits: true to
    /// start it; false, and the caller queues it. Whatever else now has room starts too.
    func admitSessionToolStart(_ id: UUID, callerID: UUID) -> Bool {
        admitQueuedSessionToolStarts(newcomer: (id, callerID))
    }

    /// Starts what waits for room, in request order, as far as `SessionToolPolicy.admitted` lets it,
    /// and keeps doing so every 2 seconds while anything waits. A waiting child task the person
    /// started meanwhile is no longer waiting: its first message joins that turn now, as from its
    /// parent, where its harness takes messages while it works (else once that turn ends, in its
    /// turn). With a newcomer, true when it may start too.
    @discardableResult
    func admitQueuedSessionToolStarts(newcomer: (id: UUID, callerID: UUID)? = nil) -> Bool {
        for start in sessionTools.queue {
            if let run = sessionTools.run(start.id) {
                if run.state != .queued { sessionTools.dequeue(start.id) }
            } else if let child = store.sessions.first(where: { $0.id == start.id }) {
                if start.firstMessage != nil, Self.isWorking(child), FollowUpPolicy(harness: child.harness) != nil {
                    launchQueuedStart(start)
                }
            } else {
                sessionTools.dequeue(start.id)
            }
        }
        let waiting = sessionTools.queue.map { ($0.id, $0.callerID) } + (newcomer.map { [$0] } ?? [])
        guard !waiting.isEmpty else { return true }
        var running: [UUID: Int] = [:]
        for callerID in Set(waiting.map(\.1)) { running[callerID] = sessionToolRunningCount(of: callerID) }
        let spaced = sessionTools.lastStartAboveFloor.map { ContinuousClock.now - $0 >= SessionToolPolicy.startSpacing }
            ?? true
        let admitted = SessionToolPolicy.admitted(waiting, running: running, load: sessionTools.loadReader.read(),
                                                  mayStartAboveFloor: spaced)
        if admitted.aboveFloor { sessionTools.lastStartAboveFloor = .now }
        for id in admitted.ids where id != newcomer?.id {
            if let start = sessionTools.queue.first(where: { $0.id == id }) { launchQueuedStart(start) }
        }
        let admitsNewcomer = newcomer.map { admitted.ids.contains($0.id) } ?? true
        if !admitsNewcomer || !sessionTools.queue.isEmpty { keepAdmittingSessionToolStarts() }
        return admitsNewcomer
    }

    /// Takes one start out of the line and starts it; it counts as running while it starts.
    private func launchQueuedStart(_ start: SessionToolCenter.QueuedStart) {
        guard sessionTools.dequeue(start.id) != nil else { return }
        sessionTools.starting.insert(start.id)
        Task { [weak self] in
            await start.start(start)
            self?.sessionTools.starting.remove(start.id)
        }
    }

    private func keepAdmittingSessionToolStarts() {
        guard sessionTools.admissionLoop == nil else { return }
        sessionTools.admissionLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SessionToolPolicy.admissionInterval)
                guard let self, !Task.isCancelled else { return }
                self.admitQueuedSessionToolStarts()
                if self.sessionTools.queue.isEmpty { break }
            }
            self?.sessionTools.admissionLoop = nil
        }
    }

    /// A waiting child task's start once there is room: its first message, then what was sent to it
    /// while it waited, in order. One the person started meanwhile gets them as messages from its
    /// parent.
    func startQueuedChildTask(_ start: SessionToolCenter.QueuedStart) async {
        guard let first = start.firstMessage, let child = store.sessions.first(where: { $0.id == start.id }) else { return }
        if Self.isWorking(child) {
            // A harness that takes nothing while it works gets it once that turn ends: it waits again.
            if case .undelivered = await deliverMessage(to: child, text: { _ in first }) {
                sessionTools.enqueue(start)
                keepAdmittingSessionToolStarts()
                return
            }
        } else if await !startHeldTask(child, text: first) {
            return
        }
        for text in start.laterMessages {
            guard let current = store.sessions.first(where: { $0.id == start.id }) else { return }
            _ = await deliverMessage(to: current) { _ in text }
        }
    }

    /// The child tasks that waited for room when Yardlet last quit wait again, in their order.
    func restoreQueuedSessionToolStarts() {
        for kept in sessionTools.keptQueuedChildren() where !sessionTools.isQueued(kept.id) {
            guard store.sessions.contains(where: { $0.id == kept.id }) else { continue }
            sessionTools.noteStarted(kept.id, by: kept.callerID)
            sessionTools.enqueue(SessionToolCenter.QueuedStart(
                id: kept.id, callerID: kept.callerID, firstMessage: kept.firstMessage,
                laterMessages: kept.laterMessages) { [weak self] start in
                await self?.startQueuedChildTask(start)
            })
        }
        admitQueuedSessionToolStarts()
    }

    /// Whether a new task in `folder` reaches past the caller: another project, or, where neither is a
    /// project, a folder outside the caller's own (and `alsoWithin`), so a chat's child cannot start anywhere
    /// without a card. A chat, with no folder, reaches nothing.
    func sessionToolPlaceReachesPast(folder: URL?, project: Project?, caller: SessionToolCaller,
                                     alsoWithin: [URL] = []) -> Bool {
        guard let folder else { return false }
        if caller.projectID != nil, project?.id == caller.projectID { return false }
        return project?.id != caller.projectID || !(caller.roots + alsoWithin).contains { Self.folder(folder, isWithin: $0) }
    }

    /// Whether `folder` is `root` or inside it, after `..` and links are resolved.
    static func folder(_ folder: URL, isWithin root: URL) -> Bool {
        let inner = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let outer = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return inner.count >= outer.count && Array(inner.prefix(outer.count)) == outer
    }

    /// Where a child goes: a project by name or a folder by path, else the caller's folder.
    func sessionToolPlace(_ value: String?, caller: SessionToolCaller) -> Result<(folder: URL, project: Project?), SessionToolError> {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return .success((caller.workspaceURL, projects.project(id: caller.projectID)))
        }
        if value.hasPrefix("/") || value.hasPrefix("~") {
            let folder = URL(filePath: NSString(string: value).expandingTildeInPath, directoryHint: .isDirectory)
                .standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return .failure(SessionToolError(message: "no folder at \(value)."))
            }
            return .success((folder, projects.project(containingRoot: folder)))
        }
        let matches = projects.projects.filter { !$0.isHidden && $0.name.caseInsensitiveCompare(value) == .orderedSame }
        guard matches.count == 1, let project = matches.first else {
            return .failure(SessionToolError(message: matches.isEmpty
                ? "no project named \(value)." : "more than one project is named \(value); give its folder path."))
        }
        if project.id == caller.projectID { return .success((caller.workspaceURL, project)) }
        return .success((project.primaryRoot, project))
    }

    // MARK: - Approvals

    /// Asks the person in the caller's host task, on the request card every harness draws, and
    /// waits for the answer: true to go ahead. The task waits for approval meanwhile, so its dot,
    /// notification, Dock badge and the phone remote say so.
    /// Whether a session tool asks the person before reaching past the caller's own project, archiving
    /// or running a subagent outside its folders. A task that runs without asking (Claude Code's Bypass
    /// permissions, Codex's Full access, Antigravity's bypass) does these without a card, as the Claude
    /// app's session tools ask "except … in bypass permissions mode (it does not ask)"; every other level
    /// asks. A message that would raise another task's permission comes only from a lower level, so it
    /// still asks. The scheduled-task tools keep their own rule (`ScheduleToolApproval`).
    func sessionToolAsksPerson(_ caller: SessionToolCaller) -> Bool {
        caller.permission < .elevated
    }

    /// Whether a task's browser tools may open a file outside its folders, given its real path
    /// (docs/AGENT_BROWSER_TOOLS.md, `browser_navigate`): a task that runs without asking may, since its
    /// shell reads the file anyway; any other asks the person, as a session tool reaching past the task does.
    func allowsBrowserFile(_ path: String, callerID: UUID) async -> Bool {
        guard let caller = sessionToolCaller(callerID) else { return false }
        guard sessionToolAsksPerson(caller) else { return true }
        return await askPerson(title: L10n.string("Open a file outside this task's folders?"), detail: path, caller: caller)
    }

    func askPerson(title: String, detail: String, caller: SessionToolCaller) async -> Bool {
        let host = caller.hostTaskID
        let request = PermissionRequest(
            id: SessionToolApproval.idPrefix + UUID().uuidString.lowercased(), title: title, detail: detail,
            command: nil)
        return await sessionTools.ask(request, in: host,
                                      timeout: min(SessionToolPolicy.approvalTimeout, caller.remaining)) { [weak self] in
            self?.sessionToolApprovalsChanged(in: host)
        }
    }

    /// Whether a session tool waits on the person in this task: its own approval, or a request one
    /// of its subagents waits on.
    func sessionToolWaitsForPerson(in taskID: UUID) -> Bool {
        !sessionTools.approvals(for: taskID).isEmpty
            || sessionTools.runs(hostedBy: taskID).contains { !$0.pendingRequests.isEmpty }
    }

    /// The requests the session tools wait on in a task, drawn at the end of its running turn.
    func sessionToolRequests(in taskID: UUID) -> [ConversationRequest] {
        sessionTools.approvals(for: taskID).map(\.conversationRequest)
            + sessionTools.runs(hostedBy: taskID).flatMap(\.pendingRequests)
    }

    /// The requests Yardlet itself holds in a task, which no provider runtime holds: what its session
    /// tools wait on, and a question a restart cut off (`restartQuestion(in:)`). The conversation, the
    /// rail, notifications and the phone draw them at the end of the latest turn, answered by the
    /// same routes as the provider's own.
    func heldRequests(in taskID: UUID) -> [ConversationRequest] {
        sessionToolRequests(in: taskID) + (restartQuestion(in: taskID).map { [$0] } ?? [])
    }

    /// The task's state follows what its session tools wait on, as a provider's own request moves it.
    func sessionToolApprovalsChanged(in taskID: UUID) {
        refreshAttentionDetail(for: taskID)
        guard let session = store.sessions.first(where: { $0.id == taskID }) else { return }
        let waits = sessionToolWaitsForPerson(in: taskID)
        let providerWaits = !NotificationApprovalProjection.pendingRequests(
            harness: session.harness, transcript: transcriptBySessionID[taskID] ?? [],
            codex: codexPresentationBySessionID[taskID]).isEmpty
        let status: SessionStatus? = if waits, session.status == .running {
            .waitingForApproval
        } else if !waits, !providerWaits, session.status == .waitingForApproval {
            .running
        } else {
            nil
        }
        guard let status else { return }
        Task { [weak self] in
            await self?.accept(HarnessEventEnvelope(localSessionID: taskID, sequence: 0,
                                                    payload: .sessionStatusChanged(status)))
        }
    }

    /// Answers a session tool's approval, or forwards an answer to the subagent whose request it is.
    /// False when the request is neither.
    func answerSessionToolRequest(_ requestID: String, action: PermissionRequestAction?,
                                  answer: PermissionStructuredAnswer?, decision: PermissionDecision,
                                  in taskID: UUID) async -> Bool {
        if sessionTools.approval(requestID) != nil {
            sessionTools.answer(requestID, allow: decision == .allow)
            return true
        }
        guard let run = sessionTools.runs(hostedBy: taskID).first(where: { run in
            run.pendingRequests.contains { $0.id == requestID }
        }) else { return false }
        await respondToAgentRun(run, requestID: requestID, action: action, answer: answer, decision: decision)
        return true
    }

    func answerSessionToolCodexRequest(_ requestID: String, response: CodexServerRequestResponse,
                                       in taskID: UUID) async -> Bool {
        guard let run = sessionTools.runs(hostedBy: taskID).first(where: { run in
            run.codexState?.serverRequestsByID[requestID]?.resolution == .pending
        }) else { return false }
        await respondToAgentRunCodex(run, requestID: requestID, response: response)
        return true
    }

    /// The caller's turn stopped or the task went away: its subagents stop and what its session
    /// tools wait on is refused.
    func stopSessionToolWork(for taskID: UUID) async {
        sessionTools.refuseApprovals(in: taskID)
        for run in sessionTools.runs(hostedBy: taskID) where !run.state.isFinished {
            await stopAgentRun(run)
        }
    }

    // MARK: - Notifications the agent asked for

    /// When a child task's first turn, or a background subagent, ends, its caller gets a message
    /// from it saying so, delivered as any message between tasks is. Only a task can receive one.
    func watchForNotification(_ id: UUID, caller: SessionToolCaller) {
        guard caller.id == caller.hostTaskID else { return }
        Task { [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            let deadline = clock.now + SessionToolPolicy.notificationWatchLimit
            while clock.now < deadline {
                if let run = self.sessionTools.run(id) {
                    if run.state.isFinished { break }
                } else if let session = self.store.sessions.first(where: { $0.id == id }) {
                    if !Self.isWorking(session), self.followUps.queue(for: id).isEmpty,
                       !self.sessionTools.isQueued(id), !self.sessionTools.starting.contains(id) { break }
                } else {
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            guard let host = self.store.sessions.first(where: { $0.id == caller.hostTaskID }) else { return }
            let outcome = self.sessionToolOutcome(of: id)
            let name = outcome.kind == "agent"
                ? L10n.format("%@ agent", outcome.title ?? "") : (outcome.title ?? "")
            let body = "Finished (\(outcome.state)). Its id is \(id.uuidString)."
                + (outcome.answer.map { "\n\n" + $0 } ?? "")
            _ = await self.deliverTaskMessage(TaskMessage(senderID: id.uuidString, senderName: name, body: body),
                                              to: host)
        }
    }

    // MARK: - The person's words

    /// The words `person_quotes` names, each found in one of the person's own messages in the calling
    /// task, the latest that holds it, with when they sent it; an error names the first it cannot find.
    private func personQuotes(_ value: JSONValue?, caller: SessionToolCaller) -> Result<[TaskMessage.Quote], SessionToolError> {
        guard let value, value != .null else { return .success([]) }
        guard let items = value.arrayValue,
              items.allSatisfy({ $0.stringValue != nil }) else {
            return .failure(SessionToolError(message: "person_quotes must be a list of strings.",
                                             failure: AgentToolFailure(.invalidArguments, retry: .withChanges)))
        }
        let wanted = items.compactMap(\.stringValue)
            .map { $0.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard wanted.count <= SessionToolCatalog.maximumPersonQuotes else {
            return .failure(SessionToolError(message: "at most \(SessionToolCatalog.maximumPersonQuotes) person_quotes.",
                                             failure: AgentToolFailure(.invalidArguments, retry: .withChanges)))
        }
        guard !wanted.isEmpty else { return .success([]) }
        guard let session = store.sessions.first(where: { $0.id == caller.hostTaskID }) else {
            return .failure(SessionToolError(message: "this task's conversation is not open in Yardlet.",
                                             failure: AgentToolFailure(.refused, retry: .no)))
        }
        let messages = personMessages(in: session)
        let time = ISO8601DateFormatter()
        time.formatOptions = [.withInternetDateTime]
        time.timeZone = .current
        var quotes: [TaskMessage.Quote] = []
        for words in wanted {
            guard let message = messages.first(where: { $0.text.contains(words) }) else {
                let shown = words.count > 80 ? String(words.prefix(80)) + "…" : words
                // The words must be the person's own, exactly: other words are refused however often they are sent.
                return .failure(SessionToolError(message: "the person's messages in this task do not hold \"\(shown)\".",
                                                 failure: AgentToolFailure(.refused, retry: .withChanges)))
            }
            quotes.append(TaskMessage.Quote(text: words, sentAt: message.sentAt.map(time.string(from:))))
        }
        return .success(quotes)
    }

    /// What the person typed in a task, latest first, with when they sent it: not another task's
    /// message, a background command's notice or a schedule's.
    func personMessages(in session: SessionRecord) -> [(text: String, sentAt: Date?)] {
        var messages: [(text: String, sentAt: Date?)] = []
        for turn in sessionToolPresentation(of: session).turns {
            for item in turn.prompt + turn.work {
                guard case let .userMessage(text, _) = item.kind, item.taskMessage == nil,
                      item.backgroundTaskNotice == nil else { continue }
                let sentAt: Date? = if case let .transcript(entry) = item.source { entry.createdAt } else {
                    turn.timing.startedAt
                }
                messages.append((text.replacingOccurrences(of: "\r\n", with: "\n"), sentAt))
            }
        }
        return messages.reversed()
    }

    // MARK: - Arguments

    static func integer(_ value: JSONValue?) -> Int? {
        switch value {
        case let .integer(number)?: Int(clamping: number)
        case let .number(number)? where number.isFinite: Int(number)
        case let .string(text)?: Int(text)
        default: nil
        }
    }

    static func bool(_ value: JSONValue?) -> Bool? {
        switch value {
        case let .bool(flag)?: flag
        case let .string(text)?: text == "true" ? true : text == "false" ? false : nil
        default: nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
