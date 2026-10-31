import Foundation

/// The routing ledger's lines: written only while the person has the
/// evaluation on, from what Yardlet already holds when a turn or a subagent ends.
extension AppModel {
    /// A task's turn ended (it was running or waiting and now is not).
    func recordTurnForRoutingEvaluation(_ sessionID: UUID, status: SessionStatus, at endedAt: Date) {
        guard let evaluation = routingEvaluation, evaluation.isEnabled,
              let session = store.sessions.first(where: { $0.id == sessionID }) else { return }
        let outcome: RoutingLedgerEntry.Outcome
        if stoppedByPerson.contains(sessionID) {
            outcome = .stopped
        } else if taskAttentionDetails[sessionID]?.usageLimit != nil {
            outcome = .usageLimit
        } else {
            outcome = status == .failed ? .failed : .completed
        }
        let origin: RoutingLedgerEntry.Origin = scheduledTasks.schedule(startedTask: sessionID) != nil ? .schedule
            : session.startedFromTaskID != nil ? .childTask : .person
        let selection = routingModelSelection(for: session)
        let entry = RoutingLedgerEntry(
            kind: .turn, taskID: sessionID, parentTaskID: session.startedFromTaskID, origin: origin,
            harness: session.harness.rawValue, model: selection.model, effort: selection.effort,
            account: session.connection?.id, projectID: session.projectID,
            workspacePath: session.workspaceURL.path(percentEncoded: false),
            startedAt: submissionStartedAt[sessionID], endedAt: endedAt, outcome: outcome,
            tokens: routingTokens(for: session))
        recordWithGitState(entry, workspaceURL: session.workspaceURL, in: evaluation)
    }

    /// A `run_agent` subagent ended.
    func recordAgentRunForRoutingEvaluation(_ run: AgentRun, state: AgentRun.State, at endedAt: Date = Date()) {
        guard let evaluation = routingEvaluation, evaluation.isEnabled else { return }
        let outcome: RoutingLedgerEntry.Outcome = switch state {
        case .stopped: .stopped
        case .failed: .failed
        default: .completed
        }
        let tokens = run.codexState?.thread?.turns.last?.tokenUsage.map { Self.routingTokens($0.last) }
        let entry = RoutingLedgerEntry(
            kind: .agentRun, taskID: run.hostTaskID, runID: run.id, parentTaskID: run.callerID, origin: .agentRun,
            harness: run.harness.rawValue, model: run.model, effort: nil,
            account: (run.accountStart.map(\.connection) ?? connections.selected(for: run.harness))?.id,
            projectID: store.sessions.first { $0.id == run.hostTaskID }?.projectID,
            workspacePath: run.workspaceURL.path(percentEncoded: false),
            startedAt: run.startedAt, endedAt: endedAt, outcome: outcome, tokens: tokens)
        recordWithGitState(entry, workspaceURL: run.workspaceURL, in: evaluation)
    }

    /// The model and effort the task's controls show now, else what the task itself chose.
    func routingModelSelection(for session: SessionRecord) -> (model: String?, effort: String?) {
        if session.harness == .codex {
            let selection = codexCapabilitiesBySessionID[session.id]?.modelCatalog.selection
                ?? CodexModelSelection.restored(from: session.providerOptions)
                ?? modelCatalogs.codexThreads[session.id]
            return (selection?.model, selection?.reasoningEffort)
        }
        let selectors = composerProviderCapabilities(for: session)?.selectors ?? []
        let chosen = session.providerOptions["model"].flatMap { $0 == "default" ? nil : $0 }
        return (RoutingModelReading.model(in: selectors) ?? chosen, RoutingModelReading.effort(in: selectors))
    }

    private func routingTokens(for session: SessionRecord) -> RoutingLedgerEntry.Tokens? {
        if let last = codexPresentationBySessionID[session.id]?.thread?.turns.last?.tokenUsage?.last {
            return Self.routingTokens(last)
        }
        guard let usage = providerUsageBySessionID[session.id] else { return nil }
        return RoutingLedgerEntry.Tokens(input: usage.inputTokens.map(Int64.init),
                                         cachedInput: usage.cachedInputTokens.map(Int64.init),
                                         output: usage.outputTokens.map(Int64.init))
    }

    private static func routingTokens(_ usage: CodexTokenUsageBreakdown) -> RoutingLedgerEntry.Tokens {
        RoutingLedgerEntry.Tokens(input: usage.inputTokens, cachedInput: usage.cachedInputTokens, output: usage.outputTokens)
    }

    /// Adds the folder's commit and uncommitted changes (none outside a repository), then writes.
    private func recordWithGitState(_ entry: RoutingLedgerEntry, workspaceURL: URL, in evaluation: RoutingEvaluationStore) {
        Task {
            var entry = entry
            let git = GitDiffService()
            entry.head = try? await git.recentCommits(workspaceURL: workspaceURL, limit: 1).first?.id
            if let summary = try? await git.changeSummary(workspaceURL: workspaceURL) {
                entry.changes = RoutingLedgerEntry.Changes(files: summary.fileCount, additions: summary.additions,
                                                           deletions: summary.deletions)
            }
            await evaluation.record(entry)
        }
    }
}
