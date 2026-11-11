import Foundation

/// A compaction Yardlet made of an idle Claude Code task (`AppModel.compactWhileIdle`), from its start
/// until the task's next turn starts.
struct IdleCompactionRun: Equatable {
    /// Its turn is open in the conversation: the CLI reported the compaction starting.
    var opened = false
    /// The CLI ended it. What it reports after that still belongs to it; a turn starting does not.
    var ended = false
}

// Claude Code's idle compaction for Yardlet's Claude Code tasks (Settings › General › Idle compaction,
// `IdleCompactionPreference`; docs/PROVIDER_CONNECTIONS.md, "Compacting idle Claude Code tasks"). The CLI
// compacts a long conversation while its session is idle, about 54 minutes after its last request and so
// before its 1-hour prompt cache expires, but only in sessions it counts as attended, which Yardlet's are
// not. Each task's turn end arms one timer from what the CLI reported of that request; anything sent, or a
// turn starting, cancels it; when it fires, the CLI's own conditions (`IdleCompaction.skip`) and the task's
// being idle decide, and the compaction goes as the composer's "Compact session" sends it, `/compact`.
// Nothing scans tasks or reads their history on a timer.
extension AppModel {
    /// A Claude Code task's turn ended: its timer is armed from the request the turn ended on, in place of
    /// any armed before. A task with no runtime, or none that reports its cache, gets none; a `run_agent`
    /// run is no task of the list and never ends a turn here.
    func armIdleCompaction(for id: UUID) {
        cancelIdleCompaction(for: id)
        guard IdleCompactionPreference.isOn(in: preferences),
              store.sessions.first(where: { $0.id == id })?.harness == .claudeCode,
              let compacting = adaptersBySessionID[id] as? any HarnessIdleCompacting else { return }
        idleCompactionTimers[id] = Task { [weak self] in
            let armed = await compacting.promptCache(for: id)
            guard let armed, let due = IdleCompaction.fireDate(for: armed) else {
                // Nothing to arm; a timer armed since cancelled this one first.
                if !Task.isCancelled { self?.idleCompactionTimers[id] = nil }
                return
            }
            // The continuous clock keeps counting while the Mac sleeps, so a timer it slept through fires late.
            try? await Task.sleep(for: .seconds(max(0, due.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.idleCompactionTimers[id] = nil
            await self.fireIdleCompaction(id, armed: armed, due: due)
        }
    }

    func cancelIdleCompaction(for id: UUID) {
        idleCompactionTimers.removeValue(forKey: id)?.cancel()
    }

    /// A turn of the task's starts, Yardlet's send or the provider's own: a compaction it made before is
    /// over, and the timer armed after the last turn is no longer due.
    func idleCompactionTurnStarted(_ id: UUID) {
        cancelIdleCompaction(for: id)
        idleCompactionRuns.removeValue(forKey: id)
    }

    /// What an event of a task compacting while idle shows: the compaction marked as Yardlet's, opening a
    /// turn of its own with no request, as Claude Code adds none, so the answer of the turn before stays
    /// that turn's last word. The output the CLI prints for the command is left out, as it is no message of
    /// the person's. Nil for an event of any other task, or of another turn; a nil payload shows nothing.
    func idleCompactionEvent(_ payload: HarnessEventPayload,
                             for id: UUID) -> (payload: HarnessEventPayload?, opensTurn: Bool)? {
        guard var run = idleCompactionRuns[id], !run.ended else { return nil }
        switch payload {
        case var .contextCompaction(compaction):
            compaction.whileIdle = true
            let opensTurn = !run.opened
            run.opened = true
            idleCompactionRuns[id] = run
            // Its saved records read back as this, not as the `/compact` that ran it.
            if let compactionID = compaction.providerID {
                Task { try? await store.recordIdleCompaction(id: id, compactionID: compactionID) }
            }
            return (.contextCompaction(compaction), opensTurn)
        case let .activityCompleted(activity) where activity.id.hasPrefix(ClaudeEventProjector.commandOutputPrefix):
            return (nil, false)
        default:
            return nil
        }
    }

    func fireIdleCompaction(_ id: UUID, armed: ClaudePromptCacheState, due: Date) async {
        guard IdleCompactionPreference.isOn(in: preferences) else { return }
        if let held = idleCompactionHold(id) { return recordIdleCompaction(id, held) }
        guard let compacting = adaptersBySessionID[id] as? any HarnessIdleCompacting else { return }
        let facts = await compacting.idleCompactionFacts(for: id)
        if let skip = IdleCompaction.skip(armed: armed, due: due, now: Date(), facts: facts) {
            return recordIdleCompaction(id, skip.rawValue)
        }
        // The CLI's answers took a moment: the task must still be idle, and the switch on.
        guard IdleCompactionPreference.isOn(in: preferences) else { return }
        if let held = idleCompactionHold(id) { return recordIdleCompaction(id, held) }
        await compactWhileIdle(id)
    }

    /// Why the task is not one to compact now, or nil: it has its runtime and nothing in it waits or works
    /// (`accountMoveBlocker`: its turn, a question or approval, a message or shell output on its way, a
    /// shell command, background commands or agents, `run_agent` runs, an edit, another change), and no
    /// move to another account is waiting or under way. A move that comes due while a compaction runs
    /// waits for it in turn, as it waits for any turn (`canMoveAutomatically`).
    private func idleCompactionHold(_ id: UUID) -> String? {
        guard let task = store.sessions.first(where: { $0.id == id }), task.harness == .claudeCode,
              handlesBySessionID[id] != nil, adaptersBySessionID[id] is any HarnessIdleCompacting else { return "no_runtime" }
        if continuations.accountSwitchesAfterTurn[id] != nil || switchingAccounts.contains(id) { return "account_move" }
        if idleCompactionRuns[id]?.ended == false || accountMoveBlocker(of: task) != nil { return "busy" }
        return nil
    }

    /// `/compact`, as the composer's Compact session sends it, without the person's part: no request in
    /// the conversation, nothing of the composer's attached context, and the task's row keeps its place.
    /// The task runs while it compacts, so what is sent meanwhile waits for it as for any turn, and keeps
    /// what its last turn left (its completion, its suggested next message).
    private func compactWhileIdle(_ id: UUID) async {
        guard let adapter = adaptersBySessionID[id], let handle = handlesBySessionID[id] else { return }
        idleCompactionRuns[id] = IdleCompactionRun()
        submissionStartedAt[id] = Date()
        try? await store.updateSession(id: id, status: .running, updatesRecency: false)
        do {
            try await adapter.send(HarnessUserInput(text: "/compact"), to: handle)
            recordIdleCompaction(id, "started")
        } catch {
            guard idleCompactionRuns[id]?.opened == false else { return }
            idleCompactionRuns.removeValue(forKey: id)
            if store.sessions.first(where: { $0.id == id })?.status == .running {
                try? await store.updateSession(id: id, status: .ready, updatesRecency: false)
            }
            recordIdleCompaction(id, "not_sent")
        }
    }

    /// What the timer did, in the task coordination log, as Claude Code records its outcome.
    private func recordIdleCompaction(_ id: UUID, _ outcome: String) {
        coordinationLog.record(.init(event: "idle-compaction", task: id.uuidString,
                                     harness: HarnessKind.claudeCode.rawValue, reason: outcome))
    }
}
