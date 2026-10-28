import Foundation
import YardletAgentTools

// `run_agent` (docs/AGENT_BROWSER_TOOLS.md, "Session tools"): a prompt run as a subagent on a harness, inside the calling
// turn, as Claude Code's Agent tool or Codex's `spawn_agent` runs one on its own harness. Yardlet
// starts one harness session headless through the same adapters its tasks use — the account
// automatic assignment picks or the call names, its default permission mode or read only when the caller is read only (never
// more than the caller), the caller's folder, the Yardlet MCP server so it can nest once more —
// sends the prompt, and answers the call with its final answer. It has no sidebar row. Its
// requests wait in the calling task's conversation; its conversation is kept with that task, and
// the harness keeps none of its own where it has a way not to (`HarnessHistoryFreeSessionConfiguring`).
//
// A subagent differs from a child task (`create_task`): a child is a task of the sidebar the person
// can go on with; a subagent lives for one prompt and cannot be talked to afterwards.

extension AppModel {
    func runAgent(_ arguments: JSONValue, caller: SessionToolCaller) async -> AgentToolResult {
        let prompt = (arguments["prompt"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return .error("Not started: prompt is required.") }
        guard prompt.count <= SessionToolCatalog.maximumMessageLength, !prompt.hasPrefix("/") else {
            return .error("Not started: the prompt must be words, not a slash command, and at most "
                + "\(SessionToolCatalog.maximumMessageLength) characters.")
        }
        guard arguments["harness"]?.stringValue?.isEmpty == false else {
            return .error("Not started: harness is required.")
        }
        let harness: HarnessKind
        switch sessionToolHarness(arguments["harness"], default: caller.harness) {
        case let .success(value): harness = value
        case let .failure(error): return .error("Not started: \(error.message)")
        }
        if let refusal = sessionToolSpawnRefusal(caller: caller) { return .error("Not started: \(refusal)") }
        var options: [String: String]
        switch Self.providerOptions(for: harness, model: arguments["model"]?.stringValue,
                                    effort: arguments["effort"]?.stringValue) {
        case let .success(value): options = sessionToolInheritedOptions(harness: harness, caller: caller, chosen: value)
        case let .failure(error): return .error("Not started: \(error.message)")
        }
        let permission: TaskPermissionLevel = caller.permission == .readOnly ? .readOnly : .standard
        if permission == .readOnly {
            guard let readOnly = Self.readOnlyOptions(for: harness) else {
                return .error("Not started: this task is read only, and Yardlet cannot run "
                    + "\(harness.displayName) read only.")
            }
            options.merge(readOnly) { _, new in new }
        }
        let folder: URL
        switch agentRunFolder(arguments["folder"]?.stringValue, caller: caller) {
        case let .success(value): folder = value
        case let .failure(error): return .error("Not started: \(error.message)")
        }
        if !caller.roots.contains(where: { Self.folder(folder, isInside: $0) }), sessionToolAsksPerson(caller) {
            let detail = L10n.format("%@ → %@", caller.title, folder.path(percentEncoded: false))
                + "\n\n" + String(prompt.prefix(600))
            guard await askPerson(title: L10n.string("Run a subagent outside this task's folders"), detail: detail,
                                  caller: caller) else {
                return .error("Not started: the person did not approve a subagent in that folder.")
            }
        }
        let account: AccountStart
        switch await assignAccount(harness: harness, model: Self.modelOption(options, harness: harness),
                                   requested: arguments["account"]?.stringValue) {
        case let .success(value): account = value
        case let .failure(error): return .error("Not started: \(error.message)")
        }
        let model = arguments["model"]?.stringValue?.trimmingCharacters(in: .whitespaces)
        let run = AgentRun(callerID: caller.id, hostTaskID: caller.hostTaskID, harness: harness,
                           model: model?.isEmpty == false ? model : nil, prompt: prompt, workspaceURL: folder,
                           depth: caller.depth + 1, permission: permission)
        run.accountStart = account
        let background = Self.bool(arguments["background"]) == true
        run.notifiesCaller = background && Self.bool(arguments["notify"]) == true
        run.state = .queued
        sessionTools.add(run)
        sessionTools.noteStarted(run.id, by: caller.id)
        guard admitSessionToolStart(run.id, callerID: caller.id) else {
            // It waits for room and starts on its own; a foreground call waits for it within its time.
            sessionTools.enqueue(SessionToolCenter.QueuedStart(id: run.id, callerID: caller.id, firstMessage: nil) {
                [weak self, weak run] _ in
                guard let self, let run, run.state == .queued else { return }
                run.state = .starting
                run.startedAt = Date()
                do { try await self.startAgentRun(run, options: options) } catch {
                    self.finishAgentRun(run, state: .failed(error.localizedDescription))
                }
            })
            if run.notifiesCaller { watchForNotification(run.id, caller: caller) }
            if background {
                return .text("Queued agent \(run.id.uuidString) on \(harness.displayName); it starts when there is "
                    + "room. wait_tasks with this id waits for it.\n" + account.assignment.toolLine)
            }
            return .text(await agentRunAnswer(run, caller: caller))
        }
        run.state = .starting
        do {
            try await startAgentRun(run, options: options)
        } catch {
            finishAgentRun(run, state: .failed(error.localizedDescription))
            return .error("Not started: \(error.localizedDescription)")
        }
        if run.notifiesCaller { watchForNotification(run.id, caller: caller) }
        if background {
            return .text("Started agent \(run.id.uuidString) on \(harness.displayName). wait_tasks with this id "
                + "returns its answer.\n" + account.assignment.toolLine)
        }
        return .text(await agentRunAnswer(run, caller: caller))
    }

    /// A foreground `run_agent`'s answer: it waits while the agent waits for room and while it works,
    /// within the call's time, then says where it stands.
    private func agentRunAnswer(_ run: AgentRun, caller: SessionToolCaller) async -> String {
        while !run.state.isFinished, caller.remaining > .zero, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return Self.agentRunResultText(run)
    }

    /// The options that run a harness read only: Claude Code's and Antigravity's Plan; Codex's
    /// Read-only run location is chosen once its thread exists (`startAgentRun`). Nil where Yardlet
    /// has no read-only setting for the harness.
    static func readOnlyOptions(for harness: HarnessKind) -> [String: String]? {
        switch harness {
        case .claudeCode: [ClaudeLaunchOption.permissionMode: ClaudePermissionMode.plan]
        case .antigravityCLI: [AntigravityPermissionMode.optionID: AntigravityPermissionMode.plan]
        case .codex: [:]
        default: nil
        }
    }

    /// What `run_agent` answers: the agent's ID, its state and its final answer.
    static func agentRunResultText(_ run: AgentRun) -> String {
        var text = "\(ConversationAgentRunProjection.agentIDLabel)\(run.id.uuidString)\n"
            + "harness: \(run.harness.rawValue)" + (run.model.map { " · model: \($0)" } ?? "")
            + " · state: \(run.state.word)"
            + (run.accountStart.map { "\n" + $0.assignment.toolLine } ?? "")
        if case let .failed(reason) = run.state { text += " · \(reason)" }
        if run.state == .queued {
            text += "\nIt is queued and starts when there is room; wait_tasks with this id waits for it."
        } else if !run.state.isFinished {
            text += "\nIt is still running; wait_tasks with this id returns its answer."
        }
        if let answer = run.answer { text += "\n\n" + Self.answerExcerpt(answer) }
        return text
    }

    private func agentRunFolder(_ value: String?, caller: SessionToolCaller) -> Result<URL, SessionToolError> {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return .success(caller.workspaceURL)
        }
        let expanded = NSString(string: value).expandingTildeInPath
        let folder = (expanded.hasPrefix("/") ? URL(filePath: expanded, directoryHint: .isDirectory)
            : caller.workspaceURL.appending(path: expanded, directoryHint: .isDirectory)).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(SessionToolError(message: "no folder at \(value)."))
        }
        return .success(folder)
    }

    static func folder(_ folder: URL, isInside root: URL) -> Bool {
        let path = folder.standardizedFileURL.path(percentEncoded: false)
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        let base = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let candidate = path.hasSuffix("/") ? path : path + "/"
        return candidate.hasPrefix(base)
    }

    // MARK: - Running

    private func startAgentRun(_ run: AgentRun, options: [String: String]) async throws {
        guard let runtime = runtimeSelections.selectedURL(for: run.harness) else {
            throw SessionToolError(message: "\(run.harness.displayName) is not set up in Yardlet.")
        }
        // A judge has no assignment and runs on the account new tasks start on.
        let connection = run.accountStart.map(\.connection) ?? connections.selected(for: run.harness)
        try connection?.validate(for: run.harness)
        let adapter = await registry.adapter(for: run.harness, executableURL: runtime,
                                             environmentScope: .native, connection: connection)
        _ = try await adapter.probeRuntime()
        if let launch = adapter as? any HarnessLaunchOptionConfiguring {
            // No one types into a subagent, so it is not asked to suggest a next message.
            var launchOptions = options
            if run.harness == .claudeCode { launchOptions[ClaudeLaunchOption.nextMessageSuggestions] = ClaudeLaunchOption.off }
            await launch.setLaunchOptions(launchOptions, for: run.id)
        }
        // The subagent gets the Yardlet MCP server too, under its own token, so it may nest once more.
        if !run.isEvaluationJudge, let configurable = adapter as? any HarnessAgentToolConfiguring,
           AgentToolInjectionRoute.route(for: run.harness) != nil {
            // Its connectors are scoped as a task of that harness and account in that folder would be.
            let scope = connectorScope(for: SessionRecord(
                id: run.id, harness: run.harness, workspaceURL: run.workspaceURL, runtimeExecutableURL: runtime,
                title: run.label, connection: connection))
            let server = agentTools?.agentToolServer(for: run.id, workspaceRoots: [run.workspaceURL],
                                                     connectorScope: scope)
            await configurable.setAgentToolServer(server, for: run.id)
        }
        // Its conversation is kept with the calling task, so the harness keeps none of its own
        // where it can: nothing in its app's list or an import list.
        if let history = adapter as? any HarnessHistoryFreeSessionConfiguring {
            run.keepsNoProviderHistory = await history.keepNoHistory(for: run.id)
        }
        // A subagent is a launch Yardlet makes, so it carries Yardlet instructions by its harness's route too:
        // those of the project its folder belongs to, else of the task it works for.
        // A judge gets none: the routing it judges must not steer it.
        if !run.isEvaluationJudge {
            let projectID = projects.project(containingRoot: run.workspaceURL)?.id
                ?? store.sessions.first(where: { $0.id == run.hostTaskID }).flatMap { projects.project(for: $0)?.id }
            await configureYardletInstructions(on: adapter, harness: run.harness, projectID: projectID, for: run.id)
        }
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(localSessionID: run.id, workspaceURL: run.workspaceURL, initialPrompt: nil))
        run.adapter = adapter
        run.handle = handle
        if run.harness == .codex, run.permission == .readOnly {
            guard let provider = adapter as? any CodexCapabilityProviding else {
                throw SessionToolError(message: "this task is read only, and this Codex runtime cannot run read only.")
            }
            try await provider.selectRunLocation(.readOnly, for: handle)
        } else if run.harness == .codex, case let location = CodexRunLocation.restored(from: options),
                  location != .automatic, let provider = adapter as? any CodexCapabilityProviding {
            // A Codex subagent of a Codex task runs with the task's permission, as its model.
            try await provider.selectRunLocation(location, for: handle)
        }
        if let selection = CodexModelSelection.restored(from: options),
           let provider = adapter as? any CodexCapabilityProviding {
            _ = try await provider.selectModel(selection, for: handle)
        } else if !options.isEmpty, run.harness != .claudeCode, let provider = adapter as? any ProviderCapabilityProviding {
            for (key, value) in options.sorted(by: { $0.key < $1.key }) {
                _ = try? await provider.setProviderOption(id: key, value: value, in: handle)
            }
        }
        let events = await adapter.events(for: handle)
        run.consumers.append(Task { [weak self, weak run] in
            for await envelope in events {
                guard let self, let run else { return }
                self.acceptAgentRun(envelope.payload, in: run)
            }
        })
        if let codex = adapter as? any CodexPresentationProviding {
            let states = try await codex.presentationStates(for: handle)
            run.consumers.append(Task { [weak self, weak run] in
                for await state in states {
                    guard let self, let run else { return }
                    self.acceptAgentRun(state, in: run)
                }
            })
        }
        run.state = .running
        run.hasStartedTurn = true
        // Its conversation opens with the prompt, as a task's opens with the person's message.
        if run.harness != .codex {
            run.builder.appendUser(run.prompt)
            run.entries = run.builder.entries
        }
        let draft = CodexComposerDraft(inputs: [.text(run.prompt)])
        if run.harness == .codex {
            try await CodexFollowUpDelivery(adapter: adapter, handle: handle).start(draft, contextualize: { $0 })
        } else {
            try await adapter.send(HarnessUserInput(text: run.prompt), to: handle)
        }
    }

    /// A shared-transcript harness's event: its conversation, its requests and the end of its turn.
    func acceptAgentRun(_ payload: HarnessEventPayload, in run: AgentRun) {
        guard !run.state.isFinished else { return }
        if run.codexState == nil || run.harness != .codex {
            run.builder.apply(payload)
            run.entries = run.builder.entries
        }
        switch payload {
        case let .sessionStatusChanged(status):
            switch status {
            case .running:
                run.sawWork = true
                if run.state == .waitingForApproval { run.state = .running }
            case .waitingForApproval:
                run.sawWork = true
                run.state = .waitingForApproval
            case .ready, .completed:
                if run.sawWork, run.harness != .codex { finishAgentRun(run, state: .completed) }
            case .failed:
                if run.sawWork || run.harness != .codex {
                    finishAgentRun(run, state: .failed(run.lastError ?? "the harness reported a failure"))
                }
            }
        case .assistantDelta, .assistantMessageCompleted, .activityStarted, .activityUpdated, .activityCompleted,
             .reasoningDelta, .reasoningCompleted, .progressUpdateCompleted:
            run.sawWork = true
        case .permissionRequested:
            run.sawWork = true
            run.state = .waitingForApproval
            // No one answers a judge's requests; it was told to need none.
            if run.isEvaluationJudge { Task { await stopAgentRun(run) } }
        case .turnCompleted:
            if run.harness != .codex { finishAgentRun(run, state: .completed) }
        case let .error(message, recoverable, _):
            run.lastError = message
            if !recoverable, run.harness != .codex { finishAgentRun(run, state: .failed(message)) }
        default:
            break
        }
        if run.harness != .codex { run.answer = Self.latestAnswer(in: run.presentation()) }
        sessionToolApprovalsChanged(in: run.hostTaskID)
    }

    /// A Codex thread's state: its conversation and requests, and the end of its turn.
    func acceptAgentRun(_ state: CodexTaskState, in run: AgentRun) {
        guard !run.state.isFinished else { return }
        run.codexState = state
        if state.activeTurnID != nil { run.sawWork = true }
        let waits = !run.pendingRequests.isEmpty
        if run.state == .running || run.state == .waitingForApproval {
            run.state = waits ? .waitingForApproval : .running
        }
        if waits, run.isEvaluationJudge { Task { await stopAgentRun(run) } }
        run.answer = Self.latestAnswer(in: run.presentation())
        if run.sawWork, state.activeTurnID == nil, let last = state.thread?.turns.last {
            switch last.status {
            case .completed: finishAgentRun(run, state: .completed)
            case .failed: finishAgentRun(run, state: .failed(last.error?["message"]?.stringValue ?? "the turn failed"))
            case .interrupted: finishAgentRun(run, state: .stopped)
            default: break
            }
        }
        sessionToolApprovalsChanged(in: run.hostTaskID)
    }

    func respondToAgentRun(_ run: AgentRun, requestID: String, action: PermissionRequestAction?,
                           answer: PermissionStructuredAnswer?, decision: PermissionDecision) async {
        guard let adapter = run.adapter, let handle = run.handle else { return }
        do {
            if let answer, let responder = adapter as? any HarnessStructuredPermissionResponding {
                try await responder.respond(to: requestID, answer: answer, in: handle)
            } else if let action, let responder = adapter as? any HarnessPermissionActionResponding {
                try await responder.respond(to: requestID, selectedActionID: action.id, in: handle)
            } else {
                try await adapter.respond(to: requestID, decision: decision, in: handle)
            }
            run.builder.resolvePermission(id: requestID, decision: decision)
            run.entries = run.builder.entries
            if run.state == .waitingForApproval, run.pendingRequests.isEmpty { run.state = .running }
        } catch {
            run.lastError = error.localizedDescription
        }
        sessionToolApprovalsChanged(in: run.hostTaskID)
        withdrawAnsweredApprovalNotifications(for: run.hostTaskID)
    }

    func respondToAgentRunCodex(_ run: AgentRun, requestID: String, response: CodexServerRequestResponse) async {
        guard let provider = run.adapter as? any CodexPresentationProviding, let handle = run.handle else { return }
        do {
            try await provider.respond(to: requestID, response: response, in: handle)
            if var state = run.codexState, let request = state.serverRequestsByID[requestID],
               let result = response.result(for: request.method),
               CodexTaskReducer().resolveServerRequest(id: requestID, response: result, in: &state) {
                run.codexState = state
            }
        } catch {
            run.lastError = error.localizedDescription
        }
        sessionToolApprovalsChanged(in: run.hostTaskID)
        withdrawAnsweredApprovalNotifications(for: run.hostTaskID)
    }

    /// Stops a subagent's turn, as the stop button stops a task's.
    func stopAgentRun(_ run: AgentRun) async {
        guard !run.state.isFinished else { return }
        if let adapter = run.adapter, let handle = run.handle { try? await adapter.interrupt(handle) }
        finishAgentRun(run, state: .stopped)
    }

    /// The subagent ended: its session closes, its token stops working, and its conversation is
    /// kept with its host task.
    func finishAgentRun(_ run: AgentRun, state: AgentRun.State) {
        guard !run.state.isFinished else { return }
        sessionTools.dequeue(run.id)
        let started = run.state != .queued
        run.state = state
        run.answer = Self.latestAnswer(in: run.presentation()) ?? run.answer
        for consumer in run.consumers { consumer.cancel() }
        run.consumers = []
        agentTools?.releaseAgentTools(for: run.id)
        if let adapter = run.adapter, let handle = run.handle {
            Task { await adapter.close(handle) }
        }
        if !run.isEvaluationJudge {
            sessionTools.keep(run)
            // One stopped while it waited for room did no work to weigh.
            if started { recordAgentRunForRoutingEvaluation(run, state: state) }
        }
        sessionToolApprovalsChanged(in: run.hostTaskID)
        // Its browser tab, if it drove one, is no longer one a turn is using.
        BrowserAgentUse.shared.endTurn(session: run.id)
    }

    // MARK: - Routing evaluation judges

    /// Runs one judge of the routing evaluation: the harness read only in an empty folder, the prompt
    /// once, its final answer back. Nil answer with the reason when it fails, stops or runs out of time.
    func runEvaluationJudge(_ judge: RoutingJudge, prompt: String, folder: URL,
                            timeout: Duration = .seconds(900)) async -> (answer: String?, failure: String?) {
        guard let readOnly = Self.readOnlyOptions(for: judge.harness) else {
            return (nil, L10n.string("it cannot run read only"))
        }
        var options = (try? Self.providerOptions(for: judge.harness, model: judge.model, effort: nil).get()) ?? [:]
        options.merge(readOnly) { _, new in new }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let run = AgentRun(callerID: Self.routingEvaluationHostID, hostTaskID: Self.routingEvaluationHostID,
                           harness: judge.harness, model: judge.model, prompt: prompt, workspaceURL: folder,
                           depth: SessionToolPolicy.maximumDepth, permission: .readOnly)
        run.isEvaluationJudge = true
        do {
            try await startAgentRun(run, options: options)
        } catch {
            finishAgentRun(run, state: .failed(error.localizedDescription))
            return (nil, error.localizedDescription)
        }
        let deadline = ContinuousClock.now + timeout
        while !run.state.isFinished, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
        }
        if !run.state.isFinished {
            await stopAgentRun(run)
            return (nil, L10n.string("it ran out of time"))
        }
        switch run.state {
        case .completed: return run.answer.map { ($0, nil) } ?? (nil, L10n.string("it gave no answer"))
        case let .failed(reason): return (nil, reason)
        default: return (nil, L10n.string("it asked for a permission and was stopped"))
        }
    }

    /// The host judges report to: no sidebar task has it, so nothing waits in a conversation.
    static let routingEvaluationHostID = UUID(uuidString: "5E1F0A11-0000-4000-8000-000000000E7A")!
}
