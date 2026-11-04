import Foundation
import YardletRemote

extension RemoteHostModel {
    /// Reads only the task on screen. Concurrent invalidations coalesce into one further read.
    func readTaskRail(_ taskID: String) async {
        guard offersTaskRail, isConnected, selection == .task(taskID) else { return }
        guard readingTaskRails.insert(taskID).inserted else {
            dirtyTaskRails.insert(taskID)
            return
        }
        defer { readingTaskRails.remove(taskID) }
        repeat {
            dirtyTaskRails.remove(taskID)
            let answer: RemoteResponse = await withCheckedContinuation { continuation in
                requestInOrder(.taskRail(taskID: taskID)) { continuation.resume(returning: $0) }
            }
            guard selection == .task(taskID), offersTaskRail else { return }
            if answer.ok, taskRailFacts[taskID] != answer.rail { taskRailFacts[taskID] = answer.rail }
        } while dirtyTaskRails.contains(taskID) && isConnected
    }

    /// The ring and rail share the same context facts and the existing settings projection.
    func railComposerOptions(_ taskID: String) -> ComposerSessionOptions? {
        guard taskSettings[taskID] != nil || taskRailFacts[taskID] != nil else { return nil }
        var options = RemoteTaskSettingsProjection.options(taskSettings[taskID] ?? [], task: task(taskID))
        if let facts = taskRailFacts[taskID] { RemoteRailProjection.applyContext(facts, to: &options) }
        return options
    }

    func performRailAction(_ taskID: String, action: String, targetID: String? = nil, confirmed: Bool = false) {
        let key = taskID + ":" + action + ":" + (targetID ?? "")
        guard runningRailActions.insert(key).inserted else { return }
        Task {
            defer { runningRailActions.remove(key) }
            if await perform(.railAction(taskID: taskID, action: action, targetID: targetID, confirmed: confirmed)) {
                await readTaskRail(taskID)
            }
        }
    }



}

/// Host facts enter the same local projections; no disk or provider reads happen here.
enum RemoteRailProjection {
    static func outputRows(_ outputs: [RemoteOutput]) -> [SessionRailContent.Output] {
        outputs.map { output in
            SessionRailContent.Output(url: URL(filePath: output.path), writtenAt: output.writtenAt.map(date))
        }
    }

    static func stopAction(_ kind: String) -> String {
        switch kind {
        case "childTask": "stopChild"
        case "harnessSubtask": "stopBackground"
        default: "stopAgent"
        }
    }

    static func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }

    static func mergeKey(_ kind: PullRequestMergeRequest.Kind) -> String {
        switch kind {
        case let .merge(method): "merge:" + method.rawValue
        case let .enableAuto(method): "enableAuto:" + method.rawValue
        case .disableAuto: "disableAuto"
        }
    }

    static func mergeKind(_ key: String) -> PullRequestMergeRequest.Kind? {
        if key == "disableAuto" { return .disableAuto }
        let parts = key.split(separator: ":").map(String.init)
        guard parts.count == 2, let method = PullRequestDetail.MergeMethod(rawValue: parts[1]) else { return nil }
        switch parts[0] {
        case "merge": return .merge(method)
        case "enableAuto": return .enableAuto(method)
        default: return nil
        }
    }

    static func pullRequestState(_ facts: RemoteRailFacts) -> PullRequestDetailCenter.TaskState? {
        guard let pr = facts.pullRequest else { return nil }
        let detail = facts.pullRequestDetail.map { value in
            PullRequestDetail(number: value.number, url: value.url, title: value.title,
                state: TaskPullRequest.State(rawValue: value.state) ?? .open,
                headBranch: value.headBranch, baseBranch: value.baseBranch, headSHA: value.headSHA,
                mergeable: value.mergeable, mergeState: PullRequestDetail.MergeState(rawValue: value.mergeState) ?? .unknown,
                review: value.review.flatMap(TaskPullRequest.Review.init(rawValue:)),
                reviews: value.reviews.compactMap {
                    guard let decision = PullRequestDetail.Review.Decision(rawValue: $0.decision) else { return nil }
                    return PullRequestDetail.Review(author: $0.author, decision: decision, submittedAt: $0.submittedAt.map(date))
                }, autoMerge: value.autoMerge.flatMap(PullRequestDetail.MergeMethod.init(rawValue:)),
                checks: value.checks.map {
                    PullRequestDetail.Check(id: $0.id, name: $0.name, workflow: $0.workflow,
                        bucket: PullRequestDetail.Check.Bucket(rawValue: $0.bucket) ?? .pending, state: $0.state,
                        link: $0.link, startedAt: $0.startedAt.map(date), completedAt: $0.completedAt.map(date))
                })
        }
        return PullRequestDetailCenter.TaskState(url: pr.url, folder: URL(filePath: "/"), repository: pr.repository,
            detail: detail, isLoading: facts.pullRequestLoading,
            mergeMethods: facts.mergeMethods.map { PullRequestMergeMethods(squash: $0.contains("SQUASH"),
                merge: $0.contains("MERGE"), rebase: $0.contains("REBASE")) },
            logs: facts.logs.mapValues { value in
                switch value.state {
                case "loaded": .loaded(value.text ?? "")
                case "failed": .failed(value.text ?? "")
                default: .loading
                }
            }, pendingMerge: facts.pendingMerge.flatMap(mergeKind), runningAction: facts.runningAction,
            actionError: facts.actionError)
    }

    static func applyContext(_ facts: RemoteRailFacts, to options: inout ComposerSessionOptions) {
        options.contextUsage = facts.contextUsage.map {
            HarnessProtocolUsage(inputTokens: $0.inputTokens, cachedInputTokens: $0.cachedInputTokens,
                outputTokens: $0.outputTokens, reasoningTokens: $0.reasoningTokens, totalCostUSD: $0.totalCostUSD,
                contextWindowTokens: $0.contextWindowTokens, contextUsedTokens: $0.contextUsedTokens, extensionValues: [:])
        }
        options.contextUsage?.contextWindowModel = facts.contextWindowModel
        options.contextUsage?.contextBreakdown = facts.contextBreakdown.map {
            HarnessContextBreakdown(categories: $0.categories.compactMap {
                guard let kind = HarnessContextBreakdown.Category.Kind(rawValue: $0.kind) else { return nil }
                return HarnessContextBreakdown.Category(name: $0.name, tokens: $0.tokens, kind: kind)
            }, windowTokens: $0.windowTokens, autoCompactThresholdTokens: $0.autoCompactThresholdTokens,
            isAutoCompactEnabled: $0.isAutoCompactEnabled, autoCompactSource: $0.autoCompactSource)
        }
        options.reportsContextWindow = facts.reportsContextWindow
        options.usageBreakdowns = facts.usageBreakdowns.map {
            ComposerUsageBreakdown(title: $0.title, total: $0.total,
                counts: $0.counts.map { ComposerUsageBreakdown.Count(label: $0.label, tokens: $0.tokens) },
                cacheHitFraction: $0.cacheHitFraction)
        }
    }

    static func content(session: SessionRecord, projectName: String, options: ComposerSessionOptions?,
                        outputs: [RemoteOutput], hostName: String?, facts: RemoteRailFacts?) -> SessionRailContent {
        var options = options ?? ComposerSessionOptions(harnessName: session.harness.displayName,
            input: HarnessComposerInputPolicy(harness: session.harness), submission: .providerInput)
        if let facts { applyContext(facts, to: &options) }
        let entries = (facts?.background ?? []).map {
            TranscriptEntry(id: RemoteTurnProjection.uuid("rail-background:" + $0.id), createdAt: date($0.startedAt), content: .activity(
                HarnessActivity(id: $0.id, kind: $0.kind, title: $0.title, isBackground: true,
                    subtask: HarnessSubtaskReference(taskID: $0.taskID, taskType: $0.taskType)),
                state: TranscriptActivityState(rawValue: $0.state) ?? .running))
        }
        let account = facts?.accountName.map { name in
            SessionRailAccount(name: name, windows: (facts?.accountWindows ?? []).map {
                AccountLimitWindow(id: $0.id, name: $0.name, remainingPercent: $0.remainingPercent,
                    resetsAt: $0.resetsAt.map(date), evidence: UsageEvidenceKind(rawValue: $0.evidence) ?? .notExposed)
            }, checkedAt: facts?.accountCheckedAt.map(date))
        }
        let git = facts.map { facts in
            SessionRailGitInfo(branch: facts.branch, branchURL: facts.branchURL, changes: facts.changes.map {
                GitChangeSummary(changedFiles: $0.changedFiles, additions: $0.additions,
                                 deletions: $0.deletions, untrackedFiles: $0.untrackedFiles)
            })
        }
        let plan = facts.flatMap { facts -> CodexPlanState? in
            guard !facts.plan.isEmpty else { return nil }
            return CodexPlanState(explanation: facts.planExplanation, steps: facts.plan.map {
                let status: CodexPlanStepStatus = switch $0.status {
                case "pending": .pending
                case "inProgress": .inProgress
                case "completed": .completed
                default: .unknown($0.status)
                }
                return CodexPlanStep(id: $0.id, text: $0.text, status: status)
            })
        }
        let pullRequest = facts?.pullRequest.map {
            TaskPullRequest(number: $0.number, url: $0.url, repository: $0.repository,
                state: $0.state.flatMap(TaskPullRequest.State.init(rawValue:)),
                checks: $0.checks.flatMap(TaskPullRequest.Checks.init(rawValue:)),
                review: $0.review.flatMap(TaskPullRequest.Review.init(rawValue:)))
        }
        var content = SessionRailContent.make(session: session, projectName: projectName,
            instructionSources: TaskInstructionSources(origin: facts?.instructionOrigin == "provider" ? .provider : .detected,
                                                       paths: facts?.instructionPaths ?? []),
            git: git, options: options, connectors: nil, account: account, entries: entries,
            codexPlan: plan, pullRequest: pullRequest, pullRequestState: facts.flatMap(pullRequestState),
            autoFix: facts?.autoFixOn.map { PullRequestAutoFixRecord(choice: $0 ? .on : .off) },
            backgroundTerminals: (facts?.terminals ?? []).map {
                CodexBackgroundTerminal(processID: $0.processID, itemID: $0.itemID,
                                        command: $0.command, workspacePath: $0.workspacePath)
            })
        content.changes?.asksAboutAutoFix = facts?.asksAboutAutoFix == true
        content.environment.folderURL = nil
        content.environment.hostName = hostName
        content.environment.worktreeName = facts?.worktreeName
        content.environment.folderName = facts?.folderName ?? projectName
        content.environment.additionalRoots = facts?.additionalRoots ?? []
        content.outputs = outputRows(outputs)
        if let facts, !facts.agents.isEmpty {
            content.agents = SessionRailAgents(agents: facts.agents.compactMap(agent))
        }
        return content
    }

    static func agent(_ value: RemoteRailFacts.Agent) -> SessionRailAgents.Agent? {
        let kind: SessionRailAgents.Agent.Kind
        switch value.kind {
        case "childTask":
            guard let id = value.targetID.flatMap(UUID.init(uuidString:)) else { return nil }
            kind = .childTask(id)
        case "codexThread": kind = .codexThread(value.targetID ?? value.id)
        case "yardletAgent": kind = .yardletAgent(agentID: value.targetID.flatMap(UUID.init(uuidString:)), prompt: value.title)
        case "harnessSubtask": kind = .harnessSubtask(HarnessActivity(id: value.targetID ?? value.id,
            kind: "Agent", title: value.title))
        default: return nil
        }
        let status: SessionRailAgents.Agent.Status = switch value.status {
        case "pending": .pending
        case "running": .running
        case "waiting": .waiting
        case "completed": .completed
        case "failed": .failed
        case "stopped": .stopped
        default: .idle
        }
        return SessionRailAgents.Agent(id: value.id, kind: kind, title: value.title,
            harnessLabel: value.harnessLabel, model: value.model, status: status, startedAt: value.startedAt.map(date),
            depth: value.depth, canStop: value.canStop, waitingFor: value.waitingFor == "input" ? .input : .approval)
    }
}
