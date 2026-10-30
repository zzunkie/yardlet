import Foundation

/// The daily routing evaluation: once a day while Yardlet is open and no task
/// works, while the person has it on, the models they use judge the tasks the ledger recorded since
/// the last run, and the routing they settle on joins Yardlet instructions.
extension AppModel {
    /// Harnesses that can judge: those Yardlet can run read only. Each judge also needs its harness to
    /// keep none of it in its own history (`startAgentRun`).
    static let routingJudgeHarnesses: [HarnessKind] = [.claudeCode, .codex, .antigravityCLI]
    /// A judge's account needs at least this share of its plan left.
    static let routingJudgeMinimumRemaining = 0.2
    /// How often Yardlet looks whether the day's evaluation is due.
    static let routingEvaluationCheckInterval: Duration = .seconds(1800)

    func startRoutingEvaluationLoop() {
        routingEvaluationLoop?.cancel()
        routingEvaluationLoop = Task { [weak self] in
            // The first look waits a while, so opening Yardlet is not met by judges at work.
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.routingEvaluationCheckInterval)
                await self?.runRoutingEvaluationIfDue()
            }
        }
    }

    static func routingEvaluationIsDue(_ state: RoutingEvaluationState, now: Date,
                                       calendar: Calendar = .current) -> Bool {
        guard let last = state.lastRunAt else { return true }
        return !calendar.isDate(last, inSameDayAs: now)
    }

    /// Runs the day's evaluation when it is on and due, nothing works, and the ledger has new lines.
    func runRoutingEvaluationIfDue(now: Date = Date()) async {
        guard let evaluation = routingEvaluation, evaluation.isEnabled, !routingEvaluationIsRunning,
              Self.routingEvaluationIsDue(evaluation.state, now: now),
              !store.sessions.contains(where: Self.isWorking) else { return }
        routingEvaluationIsRunning = true
        defer { routingEvaluationIsRunning = false }
        let all = await evaluation.entries()
        let fresh = all.filter { line in evaluation.state.evaluatedThrough.map { line.endedAt > $0 } ?? true }
        guard !fresh.isEmpty else { return }

        var titles: [UUID: String] = [:]
        for session in store.sessions { titles[session.id] = session.title }
        let tasks = Array(RoutingTaskSummary.summaries(from: fresh, titles: titles, excerpts: [:])
            .suffix(RoutingJudgePrompt.taskLimit))
        var excerpts: [UUID: String] = [:]
        for task in tasks {
            guard var session = store.sessions.first(where: { $0.id == task.taskID }) else { continue }
            // A task nothing has opened in this run reads its saved history; no turn starts.
            if transcriptBySessionID[session.id]?.isEmpty != false, codexPresentationBySessionID[session.id] == nil {
                await refreshConversationStatus(for: session)
                session = store.sessions.first(where: { $0.id == task.taskID }) ?? session
            }
            if let text = SessionToolText.conversation(sessionToolPresentation(of: session),
                                                       workspaceURL: session.workspaceURL, turns: 2, cursor: nil)?.text,
               !text.isEmpty {
                excerpts[task.taskID] = RoutingJudgePrompt.excerpt(text)
            }
        }
        let shown = tasks.map { task in
            var task = task
            task.excerpt = excerpts[task.taskID]
            return task
        }

        let (judges, skipped) = routingJudges(from: all)
        var verdicts: [(judge: RoutingJudge, verdict: RoutingJudgeVerdict)] = []
        var notJudged = skipped
        let prompt = RoutingJudgePrompt.text(tasks: shown, judges: judges, current: evaluation.state.routing,
                                             noteLanguage: Self.routingNoteLanguage)
        // One at a time, so the evaluation never holds several plans at once.
        for judge in judges {
            guard evaluation.isEnabled, !Task.isCancelled else { return }
            let outcome = await runEvaluationJudge(judge, prompt: prompt, folder: evaluation.judgeFolder)
            if let answer = outcome.answer, let verdict = RoutingJudgeVerdict.parse(answer) {
                verdicts.append((judge, verdict))
            } else {
                notJudged.append((judge, outcome.failure ?? L10n.string("its answer could not be read")))
            }
        }
        let result = RoutingEvaluationAggregation.evaluate(
            tasks: shown, verdicts: verdicts, skipped: notJudged, current: evaluation.state.routing, at: now)
        // With no verdict the routing stays; the report says why, and the next day tries again.
        await evaluation.finish(result, evaluatedThrough: verdicts.isEmpty ? nil : fresh.map(\.endedAt).max(), at: now)
    }

    /// The judges: each read-only harness the ledger shows the person using and Yardlet can start,
    /// asked for the model the person used most on it, unless its account is nearly out.
    func routingJudges(from entries: [RoutingLedgerEntry]) -> (judges: [RoutingJudge], skipped: [(judge: RoutingJudge, reason: String)]) {
        var judges: [RoutingJudge] = []
        var skipped: [(judge: RoutingJudge, reason: String)] = []
        for harness in Self.routingJudgeHarnesses {
            let lines = entries.filter { $0.harness == harness.rawValue }
            guard !lines.isEmpty, runtimeSelections.selectedURL(for: harness) != nil else { continue }
            // "default" names no model; the judge then runs the harness's own default.
            let models = Dictionary(lines.compactMap(\.model).filter { $0 != "default" }.map { ($0, 1) },
                                    uniquingKeysWith: +)
            let judge = RoutingJudge(harness: harness, model: models.max { $0.value < $1.value }?.key)
            let connection = connections.selected(for: harness)
            let remaining = connection.flatMap(connections.remainingFraction(for:))
                ?? connections.defaultSnapshots[harness].flatMap(ProviderConnectionStore.remainingFraction)
            if let remaining, remaining < Self.routingJudgeMinimumRemaining {
                skipped.append((judge, L10n.format("its plan has %d%% left", Int(remaining * 100))))
            } else {
                judges.append(judge)
            }
        }
        return (judges, skipped)
    }

    /// The language judges write notes in: the person's.
    static var routingNoteLanguage: String {
        let code = Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? "en" } ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }
}
