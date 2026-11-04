import Foundation

// What a task's session rail reads beyond its conversation: the `run_agent` subagents and child
// tasks of its Agents card (`SessionRailAgents`), a Codex child thread or a kept subagent to read in
// the side panel, and the background work its Background tasks card lists, shows and stops — a
// Claude Code task's output file and a Codex thread's background terminals. Reading starts no
// turn and attaches nothing; stopping goes through the runtime the task is attached to.

extension AppModel {
    /// The `run_agent` subagents the app holds for the task, as its Agents card reads them.
    func railAgentRuns(hostedBy taskID: UUID) -> [SessionRailAgents.Run] {
        sessionTools.runs(hostedBy: taskID).map(SessionRailAgents.Run.init)
    }

    /// The task's child tasks, as its Agents card reads them, each with what it waits on the person for:
    /// every task nested under it, whether `create_task` made it, a suggestion's chip started it or it
    /// came nested from the Claude app, as the sidebar nests them. (Archiving with the task stays with
    /// the ones the session tools made, `sessionToolChildTasks`.)
    func railChildTasks(of taskID: UUID) -> [SessionRailAgents.Child] {
        store.sessions.filter { $0.parentTaskID == taskID }.map { child in
            SessionRailAgents.Child(child, wait: railChildWait(child), isQueued: sessionTools.isQueued(child.id))
        }
    }

    /// What a child task waits on the person for, from its own conversation as `read_task` reads it:
    /// the requests at the end of its latest turn and its session tools' requests, and the questions
    /// a Codex turn asked that no reply answered, which wait after that turn ended (the Codex app's
    /// `request_user_input_async`). Nil when it waits on nothing; the conversation is read only for a
    /// task whose state or Codex turn says it waits.
    func railChildWait(_ child: SessionRecord) -> SessionRailAgents.Wait? {
        let attention = TaskAttentionProjection.waitingRequest(of: child, detail: taskAttentionDetails[child.id])
        let waitsOnRequest = attention != nil || sessionToolWaitsForPerson(in: child.id)
        var questions: [CodexAsyncQuestion] = []
        if child.harness == .codex, followUps.queue(for: child.id).isEmpty,
           let turn = codexPresentationBySessionID[child.id]?.thread?.turns.last {
            questions = turn.status.isTerminal ? CodexConversationProjection.questionsToAnswer(in: turn)
                : CodexConversationProjection.pendingQuestions(in: turn)
        }
        guard waitsOnRequest || !questions.isEmpty else { return nil }
        let pending = waitsOnRequest
            ? (sessionToolPresentation(of: child) { $0.indices.suffix(1) }.turns.last?.requests ?? []) : []
        return SessionRailAgents.Wait(requests: pending + heldRequests(in: child.id), questions: questions,
                                      attention: attention)
    }

    /// A finished subagent of an earlier launch, as it was kept with its task.
    func keptAgentRun(_ id: UUID, hostTaskID: UUID) -> KeptAgentRun? {
        sessionTools.keptRun(id, hostTaskID: hostTaskID)
    }

    /// A Codex child thread of the task, read for the side panel as a detached task's thread is read
    /// (`thread/read` and its newest turns): nothing loads or resumes it, no turn starts.
    func readCodexChildThread(_ threadID: String, of session: SessionRecord) async throws -> CodexTaskState {
        guard session.harness == .codex, !threadID.isEmpty else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("The child conversation could not be read."))
        }
        let reader: (any CodexThreadReading)?
        if let attached = attachedRuntime(for: session.id)?.adapter as? any CodexThreadReading {
            reader = attached
        } else {
            reader = await detachedCodexThreadReader(for: session)
        }
        guard let reader else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("The child conversation could not be read."))
        }
        return try await reader.readThreadPresentation(threadID: threadID, newestTurns: CodexThreadPaging.newestTurns)
    }

    // MARK: - Background tasks

    /// The newest part of a Claude Code background task's output, from the file the CLI writes it to.
    func readClaudeTaskOutput(_ activity: HarnessActivity, of session: SessionRecord) async -> ClaudeTaskOutputReader.Output? {
        guard session.harness == .claudeCode, let taskID = activity.subtask?.taskID,
              let sessionID = session.providerSessionID else { return nil }
        return await Task.detached(priority: .utility) {
            ClaudeTaskOutputReader().read(taskID: taskID, sessionID: sessionID)
        }.value
    }

    /// The commands the task's Codex thread keeps running after its turns; nil where the task is not
    /// attached to a runtime that lists them.
    func codexBackgroundTerminals(of session: SessionRecord) async -> [CodexBackgroundTerminal]? {
        guard session.harness == .codex, let runtime = attachedRuntime(for: session.id),
              let controller = runtime.adapter as? any CodexBackgroundTerminalControlling else { return nil }
        return try? await controller.backgroundTerminals(in: runtime.handle)
    }

    func stopCodexBackgroundTerminal(_ processID: String, of session: SessionRecord) async throws {
        guard let runtime = attachedRuntime(for: session.id),
              let controller = runtime.adapter as? any CodexBackgroundTerminalControlling else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("Task control is unavailable."))
        }
        try await controller.terminateBackgroundTerminal(processID: processID, in: runtime.handle)
    }

    /// The Codex app's "Stop all background terminals".
    func stopAllCodexBackgroundTerminals(of session: SessionRecord) async throws {
        guard let runtime = attachedRuntime(for: session.id),
              let controller = runtime.adapter as? any CodexBackgroundTerminalControlling else {
            throw HarnessAdapterError.capabilityUnavailable(L10n.string("Task control is unavailable."))
        }
        try await controller.cleanBackgroundTerminals(in: runtime.handle)
    }
}
