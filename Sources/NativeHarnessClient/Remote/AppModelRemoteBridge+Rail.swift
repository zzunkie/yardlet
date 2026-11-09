import Foundation
import Observation
import YardletRemote

/// The shown task's rail facts, read through the same projections as its own window (§15.34).
extension AppModelRemoteBridge {
    func setWatchedRailTasks(_ taskIDs: Set<String>) {
        watchedRails = Set(taskIDs.compactMap(UUID.init(uuidString:)))
        for id in Set(railCache.keys).union(railTimers.keys) where !watchedRails.contains(id) {
            railTimers.removeValue(forKey: id)?.cancel()
            railCache[id] = nil
            railAgentCalls[id] = nil
            railHasTerminals.remove(id)
            railWatches.remove(id)
            model?.pullRequestDetails.hideRemote(taskID: id)
        }
        for id in watchedRails where railTimers[id] == nil {
            railTimers[id] = Task { [weak self] in
                while !Task.isCancelled {
                    guard self != nil else { return }
                    let running = self?.listedSession(id)?.status == .running || self?.railHasTerminals.contains(id) == true
                    try? await Task.sleep(for: running ? .seconds(5) : .seconds(30))
                    guard !Task.isCancelled else { return }
                    self?.changeHandler?(.taskRail(id.uuidString))
                }
            }
        }
    }

    func taskRail(taskID: String) async -> Result<RemoteRailFacts, RemoteError> {
        guard let model, let session = session(taskID) else { return .failure(RemoteError(.notFound)) }
        let key = "\(session.workspaceURL.path)|\(session.status)|\(session.completionState)"
        if railCache[session.id]?.key != key {
            let sources = model.instructionSources(for: session)
            let git = await SessionRailGitInfo.read(folder: session.workspaceURL, knownBranch: session.branch)
            railCache[session.id] = (key, git, sources)
        }
        let terminals = session.harness == .codex ? await model.codexBackgroundTerminals(of: session) ?? [] : []
        guard let current = self.session(taskID) else { return .failure(RemoteError(.notFound)) }
        if !terminals.isEmpty { railHasTerminals.insert(current.id) } else { railHasTerminals.remove(current.id) }
        if watchedRails.contains(current.id), let pr = model.pullRequests.pullRequest(for: current.id) {
            model.pullRequestDetails.showRemote(taskID: current.id, pullRequest: pr, folder: current.workspaceURL)
        } else { model.pullRequestDetails.hideRemote(taskID: current.id) }
        let agentCalls = railAgentCalls[current.id] ?? SessionRailAgents.Calls()
        if watchedRails.contains(current.id) { railAgentCalls[current.id] = agentCalls }
        let read = { [self] in
            guard let latest = self.session(taskID) else { return RemoteRailFacts() }
            return Self.railFacts(session: latest, model: model, git: railCache[latest.id]?.git,
                                  terminals: terminals, instructionSources: railCache[latest.id]?.sources,
                                  agentCalls: agentCalls)
        }
        let facts: RemoteRailFacts
        if railWatches.insert(current.id).inserted {
            facts = withObservationTracking(read) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.railWatches.remove(current.id)
                    if self.watchedRails.contains(current.id) { self.changeHandler?(.taskRail(taskID)) }
                }
            }
        } else { facts = read() }
        return .success(facts)
    }

    static func railFacts(session: SessionRecord, model: AppModel, git: SessionRailGitInfo?,
                          terminals: [CodexBackgroundTerminal] = [], instructionSources: TaskInstructionSources? = nil,
                          agentCalls: SessionRailAgents.Calls = SessionRailAgents.Calls()) -> RemoteRailFacts {
        let entries = model.transcript(for: session.id).railEntries
        let codex = model.codexRailStateBySessionID[session.id]
        let tokenUsage = codex?.thread?.turns.last(where: { $0.tokenUsage != nil })?.tokenUsage
            ?? model.restoredCodexTokenUsageBySessionID[session.id]
        let options = ComposerSessionOptionsProjection.make(
            harness: session.harness, session: session, codexCapabilities: model.composerCodexCapabilities(for: session),
            providerCapabilities: model.composerProviderCapabilities(for: session),
            providerUsage: model.providerUsageBySessionID[session.id], codexTokenUsage: tokenUsage,
            entries: entries, isAttached: model.isAttached(session.id))
        let account = model.connections.choices(for: [session.harness], includingMoving: true)
            .first { $0.connection?.id == session.connection?.id }.map(SessionRailAccount.init(choice:))
        let roots = [session.workspaceURL] + session.additionalRoots.map { URL(filePath: $0) }
        var sources = instructionSources ?? TaskInstructionSources(origin: .detected, paths: [])
        sources.paths = sources.paths.filter { path in roots.contains { RemoteFileReader.relativePath(path, in: $0) != nil } }
        let content = SessionRailContent.make(
            session: session, projectName: model.project(for: session)?.name ?? session.workspaceURL.lastPathComponent,
            instructionSources: sources, git: git, options: options, connectors: nil, account: account,
            entries: entries, codexPlan: codex?.thread?.turns.last(where: { $0.plan != nil })?.plan,
            pullRequest: model.pullRequests.pullRequest(for: session.id),
            pullRequestState: model.pullRequestDetails.state(for: session.id),
            autoFix: model.pullRequestDetails.autoFix.record(for: session.id),
            autoFixPrompt: .current(), codexState: codex,
            agentRuns: model.railAgentRuns(hostedBy: session.id), agentCalls: agentCalls,
            childTasks: model.railChildTasks(of: session.id),
            backgroundTerminals: terminals)
        var result = RemoteRailFacts()
        result.compactOffered = options.compact != nil
        result.compactAvailable = model.isAttached(session.id) && session.status != .running && session.status != .waitingForApproval
        result.folderName = content.environment.folderName
        result.worktreeName = content.environment.worktreeName
        result.additionalRoots = content.environment.additionalRoots
        result.branch = content.environment.branch
        result.branchURL = content.environment.branchURL
        result.instructionPaths = sources.paths
        result.instructionOrigin = sources.origin == .provider ? "provider" : "detected"
        result.accountName = content.settings?.accountName
        result.accountWindows = account?.windows.map {
            .init(id: $0.id, name: $0.name, remainingPercent: $0.remainingPercent,
                  resetsAt: milliseconds($0.resetsAt), evidence: $0.evidence.rawValue)
        } ?? []
        result.accountCheckedAt = milliseconds(account?.checkedAt)
        result.contextUsage = options.contextUsage.map {
            .init(inputTokens: $0.inputTokens, cachedInputTokens: $0.cachedInputTokens, outputTokens: $0.outputTokens,
                  reasoningTokens: $0.reasoningTokens, totalCostUSD: $0.totalCostUSD,
                  contextWindowTokens: $0.contextWindowTokens, contextUsedTokens: $0.contextUsedTokens)
        }
        result.contextWindowModel = options.contextUsage?.contextWindowModel
        result.contextBreakdown = options.contextUsage?.contextBreakdown.map {
            .init(categories: $0.categories.map { .init(name: $0.name, tokens: $0.tokens, kind: $0.kind.rawValue) },
                  windowTokens: $0.windowTokens, autoCompactThresholdTokens: $0.autoCompactThresholdTokens,
                  isAutoCompactEnabled: $0.isAutoCompactEnabled, autoCompactSource: $0.autoCompactSource)
        }
        result.reportsContextWindow = options.reportsContextWindow
        result.usageBreakdowns = options.usageBreakdowns.map {
            .init(title: $0.title, total: $0.total, counts: $0.counts.map { .init(label: $0.label, tokens: $0.tokens) },
                  cacheHitFraction: $0.cacheHitFraction)
        }
        result.plan = content.progress?.plan.steps.map { .init(id: $0.id, text: $0.text, status: String(describing: $0.status)) } ?? []
        result.planExplanation = content.progress?.plan.explanation
        result.changes = content.changes?.summary.map {
            .init(changedFiles: $0.changedFiles, additions: $0.additions, deletions: $0.deletions, untrackedFiles: $0.untrackedFiles)
        }
        result.pullRequest = content.changes?.pullRequest.map {
            .init(number: $0.number, url: $0.url, repository: $0.repository,
                  state: $0.state?.rawValue, checks: $0.checks?.rawValue, review: $0.review?.rawValue)
        }
        result.agents = content.agents?.agents.map { agent in
            let kind: String
            let target: String?
            switch agent.kind {
            case let .childTask(id): kind = "childTask"; target = id.uuidString
            case let .yardletAgent(id, _): kind = "yardletAgent"; target = id?.uuidString
            case let .codexThread(id): kind = "codexThread"; target = id
            case let .harnessSubtask(activity): kind = "harnessSubtask"; target = activity.id
            }
            var row = RemoteRailFacts.Agent(id: agent.id, kind: kind, targetID: target, title: Self.safeRailText(agent.title, roots: roots),
                         harnessLabel: agent.harnessLabel, model: agent.model, status: String(describing: agent.status),
                         startedAt: milliseconds(agent.startedAt), depth: agent.depth, canStop: agent.canStop)
            if agent.status == .waiting { row.waitingFor = agent.waitingFor == .input ? "input" : "approval" }
            return row
        } ?? []
        result.background = content.backgroundTasks?.rows.map { row in
            .init(id: row.id, kind: row.activity.kind, title: Self.safeRailText(row.title, roots: roots), state: "running",
                  taskID: row.activity.subtask?.taskID, taskType: row.activity.subtask?.taskType,
                  startedAt: milliseconds(row.startedAt)!)
        } ?? []
        result.terminals = terminals.map {
            .init(processID: $0.processID, itemID: $0.itemID, command: Self.safeRailText($0.command, roots: roots),
                  workspacePath: session.workspaceURL.path)
        }
        if let state = content.changes?.pullRequestState {
            result.pullRequestLoading = state.isLoading
            result.pullRequestDetail = state.detail.map { detail in
                .init(number: detail.number, url: detail.url, title: detail.title, state: detail.state.rawValue,
                      headBranch: detail.headBranch, baseBranch: detail.baseBranch, headSHA: detail.headSHA,
                      mergeable: detail.mergeable, mergeState: detail.mergeState.rawValue, review: detail.review?.rawValue,
                      reviews: detail.reviews.map { .init(author: $0.author, decision: $0.decision.rawValue, submittedAt: milliseconds($0.submittedAt)) },
                      autoMerge: detail.autoMerge?.rawValue,
                      checks: detail.checks.map { .init(id: $0.id, name: $0.name, workflow: $0.workflow, bucket: $0.bucket.rawValue,
                                                       state: $0.state, link: $0.link, startedAt: milliseconds($0.startedAt), completedAt: milliseconds($0.completedAt)) })
            }
            result.logs = state.logs.mapValues {
                switch $0 {
                case .loading: .init(state: "loading", text: nil)
                case let .loaded(text): .init(state: "loaded", text: Self.safeRailText(text, roots: roots))
                case let .failed(text): .init(state: "failed", text: Self.safeRailText(text, roots: roots))
                }
            }
            result.mergeMethods = state.mergeMethods?.allowed.map(\.rawValue)
            result.pendingMerge = state.pendingMerge.map(mergeName)
            result.runningAction = state.runningAction
            result.actionError = state.actionError.map { Self.safeRailText($0, roots: roots) }
        }
        result.autoFixOn = content.changes?.autoFix?.isOn
        result.asksAboutAutoFix = content.changes?.asksAboutAutoFix ?? false
        return result
    }

    /// Rail text is descriptive, never a transport for command environment values or unrelated paths.
    static func safeRailText(_ text: String, roots: [URL]) -> String {
        var result = RemoteSummary.masked(text)
        result = railAssignment.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "•••")
        for match in railPath.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let path = String(result[range])
            if !roots.contains(where: { PathRules.current.isInside(path, folder: PathRules.current.path(of: $0)) }) {
                result.replaceSubrange(range, with: "…/" + URL(filePath: path).lastPathComponent)
            }
        }
        return result
    }

    private static let railAssignment = try! NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|[^\s]+)"#)
    private static let railPath = try! NSRegularExpression(pattern: #"(?<![:/A-Za-z0-9])/(?:[^\s"'<>`]+)"#)

    private static func milliseconds(_ date: Date?) -> Int64? { date.map { Int64($0.timeIntervalSince1970 * 1000) } }
    private static func mergeName(_ kind: PullRequestMergeRequest.Kind) -> String {
        switch kind {
        case let .merge(method): "merge:" + method.rawValue
        case let .enableAuto(method): "enableAuto:" + method.rawValue
        case .disableAuto: "disableAuto"
        }
    }

    func railDraft(taskID: String, confirmed: Bool) async -> Result<String, RemoteError> {
        guard confirmed else { return .failure(RemoteError(.notAllowed, "Confirm preparing the fix first")) }
        guard let model, let session = session(taskID),
              let state = model.pullRequestDetails.state(for: session.id), let detail = state.detail,
              !detail.failedChecks.isEmpty else { return .failure(RemoteError(.notFound)) }
        let logs = state.logs.compactMapValues { value -> String? in
            if case let .loaded(text) = value { return text }; return nil
        }
        return .success(Self.safeRailText(PullRequestAutoFixPolicy.draft(for: detail, logs: logs), roots: [session.workspaceURL] + session.additionalRoots.map { URL(filePath: $0) }))
    }

    func railAction(taskID: String, action: String, targetID: String?, confirmed: Bool) async -> RemoteError? {
        guard let model, let session = session(taskID) else { return RemoteError(.notFound) }
        do {
            switch action {
            case "stopAgent":
                guard let id = targetID.flatMap(UUID.init(uuidString:)), let run = model.sessionTools.run(id),
                      run.hostTaskID == session.id else { return RemoteError(.notFound) }
                await model.stopAgentRun(run)
            case "stopChild":
                guard let id = targetID.flatMap(UUID.init(uuidString:)), model.railChildTasks(of: session.id).contains(where: { $0.id == id }),
                      let child = listedSession(id) else { return RemoteError(.notFound) }
                await model.interrupt(child)
            case "stopBackground":
                guard let id = targetID, model.transcript(for: session.id).railEntries.contains(where: {
                    if case let .activity(activity, .running) = $0.content { return activity.id == id && activity.subtask?.taskID != nil }
                    return false
                }) else { return RemoteError(.notFound) }
                try await model.stopClaudeSubtask(activityID: id, from: session)
            case "stopTerminal":
                guard let id = targetID, await model.codexBackgroundTerminals(of: session)?.contains(where: { $0.processID == id }) == true else { return RemoteError(.notFound) }
                try await model.stopCodexBackgroundTerminal(id, of: session)
            case "stopAllTerminals":
                guard confirmed else { return RemoteError(.notAllowed, "Confirm stopping all terminals first") }
                try await model.stopAllCodexBackgroundTerminals(of: session)
            case "loadLog", "closeLog":
                guard let check = model.pullRequestDetails.state(for: session.id)?.detail?.checks.first(where: { $0.id == targetID }) else { return RemoteError(.notFound) }
                if action == "loadLog" { await model.pullRequestDetails.loadLog(taskID: session.id, check: check) }
                else { model.pullRequestDetails.closeLog(taskID: session.id, check: check) }
            case "refreshPR": await model.pullRequestDetails.refresh(session.id)
            case "requestMerge":
                guard let value = targetID else { return RemoteError(.badRequest) }
                let parts = value.split(separator: ":").map(String.init)
                let kind: PullRequestMergeRequest.Kind
                if value == "disableAuto" { kind = .disableAuto }
                else if parts.count == 2, let method = PullRequestDetail.MergeMethod(rawValue: parts[1]),
                        (model.pullRequestDetails.state(for: session.id)?.mergeMethods ?? .all).allowed.contains(method) {
                    if parts[0] == "merge" { kind = .merge(method) }
                    else if parts[0] == "enableAuto" { kind = .enableAuto(method) }
                    else { return RemoteError(.badRequest) }
                } else { return RemoteError(.notAllowed) }
                model.pullRequestDetails.requestMerge(taskID: session.id, kind)
            case "cancelMerge": model.pullRequestDetails.cancelMerge(taskID: session.id)
            case "confirmMerge":
                guard confirmed, let state = model.pullRequestDetails.state(for: session.id),
                      let pending = state.pendingMerge, let sha = state.detail?.headSHA,
                      targetID == Self.mergeName(pending) + "|" + sha else {
                    return RemoteError(.notAllowed, "Read and confirm the current merge and head first")
                }
                await model.pullRequestDetails.confirmMerge(taskID: session.id)
            case "rerunFailed":
                guard let checks = model.pullRequestDetails.state(for: session.id)?.detail?.failedChecks else { return RemoteError(.notFound) }
                await model.pullRequestDetails.rerunFailed(taskID: session.id, checks: checks)
            case "setAutoFix":
                guard confirmed, targetID == "true" || targetID == "false" else { return RemoteError(.notAllowed) }
                model.pullRequestDetails.setAutoFix(targetID == "true", taskID: session.id)
            default: return RemoteError(.unsupportedCommand)
            }
            changeHandler?(.taskRail(taskID))
            return nil
        } catch { return RemoteError(.unavailable, "The task action could not finish") }
    }
}
