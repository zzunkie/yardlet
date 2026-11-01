import Foundation

/// The account a task runs on, as the rail's Settings and Usage cards show it: its name and the
/// limit windows its last check read (`AccountChoice.quotas`), five-hour and weekly first.
struct SessionRailAccount: Equatable, Sendable {
    var name: String
    var windows: [AccountLimitWindow]
    var checkedAt: Date?

    init(name: String, windows: [AccountLimitWindow] = [], checkedAt: Date? = nil) {
        self.name = name
        self.windows = windows
        self.checkedAt = checkedAt
    }

    /// The account of a choice, with its windows: the five-hour and weekly ones when the check named
    /// them, otherwise every window it read.
    init(choice: AccountChoice) {
        let metrics = choice.quotas
        let named = [MenuBarMenuProjection.LimitWindowKind.fiveHour, .weekly].compactMap { kind in
            metrics.first { MenuBarMenuProjection.windowKind(of: $0) == kind }
        }
        self.init(name: choice.title, windows: (named.isEmpty ? metrics : named).map(AccountLimitWindow.init(metric:)),
                  checkedAt: choice.snapshot?.checkedAt)
    }
}

/// What Git says about the task's folder for the rail, read off the main actor.
struct SessionRailGitInfo: Equatable, Sendable {
    var branch: String?
    /// The branch's page on GitHub, when the folder has a GitHub remote.
    var branchURL: URL?
    var changes: GitChangeSummary?

    /// Reads the folder's branch and GitHub remote from Git's files, and its uncommitted work with Git.
    static func read(folder: URL, knownBranch: String?) async -> SessionRailGitInfo {
        let files = await Task.detached(priority: .utility) { () -> (String?, URL?) in
            let branch = GitWorktreeOriginResolver.currentBranch(folder) ?? knownBranch
            let repository = GitWorktreeOriginResolver.remoteURLs(folder).lazy.compactMap(GitHubRemote.webURL).first
            return (branch, both(repository, branch).flatMap { GitHubRemote.branchURL(repository: $0, branch: $1) })
        }.value
        let changes = try? await GitDiffService().changeSummary(workspaceURL: folder)
        return SessionRailGitInfo(branch: files.0, branchURL: files.1, changes: changes)
    }
}

private func both<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}

/// What one task's rail shows, card by card. A card is nil where its harness or the task has nothing
/// for it, so it is left out rather than drawn empty.
/// Which harness reports what is decided before this — in `ComposerSessionOptionsProjection` (the
/// composer's controls, context window and connectors), the transcript's own entries (background
/// tasks, plans) and Codex's typed state — so the rail reads the same values the composer does.
struct SessionRailContent: Equatable {
    struct Environment: Equatable {
        /// The worktree's name when the task runs in one, nil for the folder itself.
        var worktreeName: String?
        var folderName: String
        var folderURL: URL
        var additionalRoots: [String]
        var branch: String?
        var branchURL: URL?
        var instructionSources: TaskInstructionSources
        var harness: HarnessKind

        /// Where the task runs, the Claude app's folded line.
        var locationTitle: String { worktreeName == nil ? L10n.string("Local") : L10n.string("Worktree") }
    }

    struct Settings: Equatable {
        var model: ComposerModelSlot?
        var mode: ComposerModeSlot?
        var permission: ComposerPermissionSlot?
        var accountName: String?

        var summary: String? {
            let mode: String? = switch self.mode {
            case let .selector(selector, _, _)?: ProviderCapabilityAccessibility.selectedChoiceName(for: selector)
            case .planIndicator?: L10n.string("Plan mode indicator")
            case nil: nil
            }
            let parts = [model.map(\.menu.title), mode, permission?.title].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    struct Progress: Equatable {
        var plan: ConversationPlan

        var total: Int { plan.steps.count }
        var done: Int { plan.steps.filter { $0.status == .completed }.count }

        /// The step being worked on: the one in progress, otherwise — once a step is done — the first
        /// one still pending (the Claude app's `nD`).
        var currentStepID: String? {
            if let step = plan.steps.first(where: { $0.status == .inProgress }) { return step.id }
            guard done > 0 else { return nil }
            return plan.steps.first { $0.status == .pending }?.id
        }

        /// "2 of 5" (`hd07WZo2x3`).
        var summary: String { L10n.format("%lld of %lld", Int64(done), Int64(total)) }
    }

    struct Changes: Equatable {
        var summary: GitChangeSummary?
        var pullRequest: TaskPullRequest?
        var pullRequestState: PullRequestDetailCenter.TaskState?
        /// The task's auto-fix record, and whether the card asks the person about it now.
        var autoFix: PullRequestAutoFixRecord?
        var asksAboutAutoFix = false

        var detail: PullRequestDetail? { pullRequestState?.detail }

        var rollup: String? {
            if let pullRequest { return "#\(pullRequest.number)" }
            guard let summary, !summary.isEmpty else { return nil }
            return summary.fileCount == 1 ? L10n.string("1 file") : L10n.format("%lld files", Int64(summary.fileCount))
        }
    }

    var environment: Environment
    var settings: Settings?
    var context: ComposerContextSummary?
    var contextUsage: HarnessProtocolUsage?
    var usageBreakdowns: [ComposerUsageBreakdown] = []
    var usage: SessionRailAccount?
    var connectors: ComposerConnectorList?
    var progress: Progress?
    var changes: Changes?
    var agents: SessionRailAgents?
    /// The task's suggestions (`spawn_task`) nobody has started, sent here or dismissed, in the order
    /// it made them: its chips, kept in sight however far the conversation scrolls.
    var suggestions: [ConversationTaskSuggestion] = []
    var backgroundTasks: BackgroundTasksProjection?
    /// Codex's background terminals, listed with the background tasks.
    var backgroundTerminals: [CodexBackgroundTerminal] = []
    /// The session jobs a Claude Code task's CLI holds, listed with the background tasks as the Claude
    /// app lists its loops there.
    var sessionJobs: [ClaudeSessionJob] = []
    var preview: SessionRailPreview?
    /// Files the task wrote, newest first (`outputs(entries:codexChanges:workspaceURL:)`).
    var outputs: [Output] = []

    /// A file the task wrote: Claude Code's `Write`, a harness's whole-file change, Codex's added file.
    struct Output: Identifiable, Equatable {
        let url: URL
        let writtenAt: Date?
        var id: String { url.path(percentEncoded: false) }
        var name: String { url.lastPathComponent }
    }

    /// The Claude app's Outputs card keeps the newest 50 and, for a file inside the task's folder,
    /// only documents and media (`Rv`, `kv`): source files the task edits are its changes, not its
    /// outputs. A file outside the folder (a report it saved elsewhere) always counts.
    static let outputLimit = 50
    static let documentExtensions: Set<String> = [
        "md", "markdown", "txt", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "csv",
        "tsv", "html", "htm", "rtf", "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "mp4", "mov", "webm", "mp3",
        "wav", "m4a", "zip"
    ]

    /// - Parameters:
    ///   - options: the task composer's options, from `ComposerSessionOptionsProjection.make` with the
    ///     same inputs the composer has.
    ///   - connectors: the composer's connector list for the task (`ComposerConnectorList.make`).
    ///   - codexPlan: a Codex task's latest plan (`turn/plan/updated`).
    ///   - suggestionResolution: what became of each of the task's suggestions, as its chips read it;
    ///     nil where nothing can start one (the rail then lists none).
    static func make(
        session: SessionRecord,
        projectName: String,
        instructionSources: TaskInstructionSources,
        git: SessionRailGitInfo?,
        options: ComposerSessionOptions,
        connectors: ComposerConnectorList?,
        account: SessionRailAccount?,
        entries: [TranscriptEntry],
        codexPlan: CodexPlanState?,
        pullRequest: TaskPullRequest?,
        pullRequestState: PullRequestDetailCenter.TaskState?,
        autoFix: PullRequestAutoFixRecord? = nil,
        autoFixPrompt: PullRequestAutoFixPrompt = .ask,
        codexChanges: [CodexChangeHandoff] = [],
        codexState: CodexTaskState? = nil,
        agentRuns: [SessionRailAgents.Run] = [],
        childTasks: [SessionRailAgents.Child] = [],
        backgroundTerminals: [CodexBackgroundTerminal] = [],
        sessionJobs: [ClaudeSessionJob] = [],
        preview: SessionRailPreview? = nil,
        suggestionResolution: ((String) -> TaskSuggestionResolution?)? = nil
    ) -> SessionRailContent {
        let environment = Environment(
            worktreeName: session.originWorkspacePath == nil ? nil : (session.worktreeName ?? session.branch),
            folderName: projectName,
            folderURL: session.workspaceURL,
            additionalRoots: session.additionalRoots,
            branch: git?.branch ?? session.branch,
            branchURL: git?.branchURL,
            instructionSources: instructionSources,
            harness: session.harness)

        let settings = Settings(model: options.model.flatMap { $0.menu.isEmpty ? nil : $0 }, mode: options.mode,
                                permission: options.permission, accountName: account?.name ?? session.connection?.name)
        let hasSettings = settings.model != nil || settings.mode != nil || settings.permission != nil
            || settings.accountName != nil

        let plan = codexPlan.map(Self.plan) ?? Self.latestPlan(in: entries)
        // Agents have their own card; this one keeps the shells, monitors and the like.
        let background = BackgroundTasksProjection(entries: entries, includesAgents: false)
        let changes = Changes(
            summary: git?.changes, pullRequest: pullRequest, pullRequestState: pullRequestState, autoFix: autoFix,
            asksAboutAutoFix: pullRequest != nil && PullRequestAutoFixPolicy.asks(
                record: autoFix, prompt: autoFixPrompt, detail: pullRequestState?.detail))
        let hasChanges = pullRequest != nil || git?.changes?.isEmpty == false

        return SessionRailContent(
            environment: environment,
            settings: hasSettings ? settings : nil,
            context: ComposerContextSummary.make(usage: options.contextUsage,
                                                 reportsContextWindow: options.reportsContextWindow),
            contextUsage: options.contextUsage,
            usageBreakdowns: options.usageBreakdowns,
            usage: account.flatMap { $0.windows.isEmpty ? nil : $0 },
            // A list with nothing in it is no card (Claude's: "when there is at least one connector").
            connectors: connectors.flatMap { $0.rows.isEmpty ? nil : $0 },
            progress: plan.flatMap { $0.steps.isEmpty ? nil : Progress(plan: $0) },
            changes: hasChanges ? changes : nil,
            agents: SessionRailAgents.make(harness: session.harness, entries: entries, codexState: codexState,
                                           runs: agentRuns, children: childTasks),
            suggestions: suggestionResolution.map { resolution in
                ConversationTaskSuggestionProjection.suggestions(in: entries, codexState: codexState)
                    .filter { resolution($0.id) == nil }
            } ?? [],
            backgroundTasks: background.isShown ? background : nil,
            backgroundTerminals: backgroundTerminals,
            sessionJobs: sessionJobs,
            preview: preview,
            outputs: outputs(entries: entries, codexChanges: codexChanges, workspaceURL: session.workspaceURL))
    }

    /// Whether the rail, the composer or its line of background tasks reads the entry: a plan, a
    /// request that waits, and the calls that are a provider's subtasks and agents, Yardlet's
    /// subagents, task suggestions or files written whole. Whatever `make` and the composer read of a
    /// transcript is among these, so a long conversation gives them its few such entries
    /// (`TranscriptTurns.railEntries`) instead of all of them.
    static func reads(_ entry: TranscriptEntry) -> Bool {
        switch entry.content {
        case .plan, .permission(_, .pending):
            return true
        case let .activity(activity, state):
            if activity.subtask != nil || SessionRailAgents.claudeAgentTools.contains(activity.kind)
                || ConversationAgentRunProjection.subagent(from: activity, phase: .running, isApproved: false) != nil {
                return true
            }
            guard state == .completed else { return false }
            if let diff = activity.diff, diff.oldText == nil, diff.newText != nil, !diff.path.isEmpty { return true }
            return ConversationTaskSuggestionProjection.suggestion(from: activity) != nil
        default:
            return false
        }
    }

    /// The files the task wrote, newest first, each once: completed calls that wrote a whole file
    /// (Claude Code's `Write`, an ACP or Pi diff with no old text) and Codex's added files.
    static func outputs(entries: [TranscriptEntry], codexChanges: [CodexChangeHandoff],
                        workspaceURL: URL) -> [Output] {
        let root = workspaceURL.standardizedFileURL.path(percentEncoded: false)
        let folder = root.hasSuffix("/") ? root : root + "/"
        var seen = Set<String>()
        var result: [Output] = []
        func add(_ url: URL, at date: Date?) {
            let url = url.standardizedFileURL
            let path = url.path(percentEncoded: false)
            guard result.count < outputLimit, seen.insert(path).inserted else { return }
            if path.hasPrefix(folder), !documentExtensions.contains(url.pathExtension.lowercased()) { return }
            result.append(Output(url: url, writtenAt: date))
        }
        for entry in entries.reversed() {
            guard case let .activity(activity, .completed) = entry.content, let diff = activity.diff,
                  diff.oldText == nil, diff.newText != nil, !diff.path.isEmpty else { continue }
            let url = diff.path.hasPrefix("/") ? URL(filePath: diff.path)
                : workspaceURL.appending(path: diff.path)
            add(url, at: entry.createdAt)
        }
        for change in codexChanges.reversed() where change.status == "add" {
            if let url = change.verifiedURL { add(url, at: nil) }
        }
        return result
    }

    /// Whether the card has something to show.
    func has(_ kind: SessionRailCardKind) -> Bool {
        switch kind {
        case .environment: true
        case .settings: settings != nil
        case .context: context != nil
        case .usage: usage != nil
        case .connectors: connectors != nil
        case .progress: progress != nil
        case .changes: changes != nil
        case .suggestions: !suggestions.isEmpty
        case .agents: agents != nil
        case .backgroundTasks: backgroundTasks != nil || !backgroundTerminals.isEmpty || !sessionJobs.isEmpty
        case .preview: preview != nil
        case .outputs: !outputs.isEmpty
        // Not drawn yet: no harness's goal or servers reach the rail.
        case .goal, .servers: false
        }
    }

    /// The cards the rail draws, in the person's order: those with something to show and not hidden.
    func cards(_ preferences: SessionRailPreferences) -> [SessionRailCardKind] {
        preferences.resolvedOrder.filter { has($0) && !preferences.isHidden($0) }
    }

    /// What a folded card's header says on its right (the Claude app's rollups).
    func rollup(_ kind: SessionRailCardKind) -> String? {
        switch kind {
        case .environment:
            return environment.worktreeName ?? environment.locationTitle
        case .settings:
            return settings?.summary
        case .context:
            return context?.percent.map { "\($0)%" }
        case .usage:
            // Both the session and the weekly window when the account has both, as the card shows them.
            let measured = (usage?.windows ?? []).filter { $0.remainingPercent != nil }
            if measured.count > 1 {
                return measured.prefix(2).map { window in
                    "\(Self.shortWindowName(window.name)) \(Int64(window.remainingPercent!.rounded()))%"
                }.joined(separator: " · ")
            }
            guard let window = usage?.windows.first, let left = window.remainingPercent else { return nil }
            return L10n.format("%lld%% left", Int64(left.rounded()))
        case .connectors:
            guard let connectors else { return nil }
            let reconnect = connectors.needsReconnectionCount
            if reconnect > 0 {
                return reconnect == 1 ? L10n.string("1 needs reconnection")
                    : L10n.format("%lld need reconnection", Int64(reconnect))
            }
            let connected = connectors.rows.filter { $0.state == .connected }.count
            return L10n.format("%lld connected", Int64(connected))
        case .progress:
            return progress?.summary
        case .changes:
            return changes?.rollup
        case .suggestions:
            return suggestions.isEmpty ? nil : String(suggestions.count)
        case .agents:
            guard let agents else { return nil }
            let waiting = agents.agents.filter { $0.status == .waiting }
            if !waiting.isEmpty {
                return L10n.string(waiting.allSatisfy { $0.waitingFor == .input } ? "Needs input" : "Needs approval")
            }
            let active = agents.activeCount
            return active > 0 ? L10n.format("%lld running", Int64(active))
                : L10n.format("%lld agents", Int64(agents.agents.count))
        case .backgroundTasks:
            let count = (backgroundTasks?.rows.count ?? 0) + backgroundTerminals.count
            let parts = [count == 0 ? nil : L10n.format("%lld running", Int64(count)),
                         sessionJobs.isEmpty ? nil : L10n.format("%lld scheduled", Int64(sessionJobs.count))]
            let rollup = parts.compactMap { $0 }.joined(separator: " · ")
            return rollup.isEmpty ? nil : rollup
        case .preview:
            return preview?.title
        case .outputs:
            return outputs.isEmpty ? nil : String(outputs.count)
        case .goal, .servers:
            return nil
        }
    }

    /// The small meter beside a folded card's rollup: the context window's share used, or what is
    /// left of the account's only window (two windows say both in words instead).
    func meter(_ kind: SessionRailCardKind) -> Double? {
        switch kind {
        case .context: context?.fraction
        case .usage:
            (usage?.windows ?? []).filter({ $0.remainingPercent != nil }).count > 1
                ? nil : usage?.windows.first?.remainingPercent.map { $0 / 100 }
        default: nil
        }
    }

    /// A window's name without its "limit" word, for a folded header: `5 hour limit` → `5 hour`,
    /// the Korean "limit" word likewise, `5h limit` → `5h`.
    static func shortWindowName(_ name: String) -> String {
        var short = name.trimmingCharacters(in: .whitespaces)
        for suffix in [" limit", " Limit", " 한도", "한도"] where short.hasSuffix(suffix) {
            short = String(short.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return short.isEmpty ? name : short
    }

    /// The latest plan the conversation holds: Claude Code's task list (`TodoWrite`, `Task*`), an ACP
    /// or Pi plan, read as steps.
    static func latestPlan(in entries: [TranscriptEntry]) -> ConversationPlan? {
        for entry in entries.reversed() {
            if case let .plan(text) = entry.content {
                let plan = ConversationPlan.parse(text, stepIDPrefix: entry.id.uuidString)
                return plan.steps.isEmpty ? nil : plan
            }
        }
        return nil
    }

    static func plan(_ plan: CodexPlanState) -> ConversationPlan {
        ConversationPlan(explanation: plan.explanation, steps: plan.steps.map { step in
            let status: ConversationPlan.StepStatus = switch step.status {
            case .pending: .pending
            case .inProgress: .inProgress
            case .completed: .completed
            case let .unknown(value): .unknown(value)
            }
            return ConversationPlan.Step(id: step.id, text: step.text, status: status)
        })
    }
}
