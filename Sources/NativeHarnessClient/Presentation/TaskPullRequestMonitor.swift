import Foundation
import Observation

/// The pull request each task on screen made, on the main actor, for the title bar and the sidebar
/// rows to read with `pullRequest(for:)`.
///
/// Only tasks on screen are looked up: the one in the title bar (`show(_:)`) and the sidebar rows in
/// view (`showRow(_:)`, `hideRow(_:)`). A Claude Code task's transcript is read for its newest
/// `pr-link`, which shows the number at once; GitHub is then asked through the person's `gh` for the
/// state, checks and review — by the link, or for a task without one by its folder's branch
/// (`TaskPullRequestSources.branchToAsk`). Reads and `gh` run off the main actor, at most
/// `policy.maximumConcurrentQueries` commands at once, and tasks naming the same pull request or the
/// same branch share one question. GitHub is asked when a task comes into view and then at most every
/// few minutes while it stays (`TaskPullRequestRefreshPolicy`); a hidden task is never asked, and
/// nothing is asked while Yardlet is not the active app. Answers are kept in memory only.
@MainActor
@Observable
final class TaskPullRequestMonitor {
    /// Each task's answer is observed on its own: a row's badge or the title bar redraws when its
    /// own task's answer changes, not whenever any task in view hears back from GitHub.
    @ObservationIgnored let pullRequests = TaskStateTable<TaskPullRequest>()

    /// Nil until the app starts the lookups (`start(_:)`): tests and visual fixtures that do not
    /// start them read nothing and never start `gh`.
    @ObservationIgnored private(set) var sources: TaskPullRequestSources?
    @ObservationIgnored var policy = TaskPullRequestRefreshPolicy()
    /// How often tasks in view are looked at. A look reads only what their transcript appended and
    /// their branch; GitHub is asked only when `policy` says so.
    @ObservationIgnored var lookInterval: Duration = .seconds(30)
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }

    /// The task(s) in the title bar.
    @ObservationIgnored private var focused: [UUID: TaskPullRequestTarget] = [:]
    /// Sidebar rows in view.
    @ObservationIgnored private var rows: [UUID: TaskPullRequestTarget] = [:]
    /// The tasks each new-task screen on view lists or reads (`showHome(_:screen:)`), asked about as
    /// a sidebar row is.
    @ObservationIgnored private var homes: [UUID: [UUID: TaskPullRequestTarget]] = [:]
    @ObservationIgnored private var records: [UUID: Record] = [:]
    /// Questions being asked now, by what they ask about.
    @ObservationIgnored private var asking: Set<Subject> = []
    /// GitHub's last answer about each subject and when it was asked, for a task that comes to name
    /// the same after the question ended: it takes that answer instead of asking again.
    @ObservationIgnored private var lastAnswers: [Subject: (askedAt: Date, answer: GitHubPullRequestClient.Answer)] = [:]
    @ObservationIgnored private var runningQueries = 0
    @ObservationIgnored private var queryWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private(set) var isApplicationActive = true
    /// Every `gh` question asked, for tests to count.
    @ObservationIgnored private(set) var questionCount = 0

    /// What a task's sources last said and when GitHub was last asked about it.
    private struct Record {
        var scan: ClaudePullRequestLinkScan?
        var link: TaskPullRequestLink?
        var subject: Subject?
        var lastAsked: Date?
    }

    /// What GitHub is asked about: a pull request by its link, or a folder's branch.
    private enum Subject: Hashable {
        case link(String)
        case branch(folder: String, branch: String)
    }

    func pullRequest(for taskID: UUID) -> TaskPullRequest? {
        pullRequests[taskID]
    }

    /// Puts a pull request in place without reading or asking anything, for visual fixtures and
    /// rendering tests.
    func setPullRequest(_ pullRequest: TaskPullRequest?, for taskID: UUID) {
        pullRequests[taskID] = pullRequest
    }

    /// Starts the lookups: the tasks already on screen are looked at now.
    @discardableResult
    func start(_ sources: TaskPullRequestSources) -> Task<Void, Never> {
        self.sources = sources
        updateLoop()
        return look(at: shownTargets.map { ($0, .shown) })
    }

    /// The tasks now in the title bar. One that has just come into view, or whose turn has just
    /// ended, is looked at now; the rest at the next look.
    @discardableResult
    func show(_ shown: [TaskPullRequestTarget]) -> Task<Void, Never> {
        let looks = changes(from: shownTarget, to: shown)
        focused = Dictionary(shown.map { ($0.taskID, $0) }) { first, _ in first }
        updateLoop()
        return look(at: looks)
    }

    /// A sidebar row came into view, or the task it shows changed.
    @discardableResult
    func showRow(_ target: TaskPullRequestTarget) -> Task<Void, Never> {
        let looks = changes(from: shownTarget, to: [target])
        rows[target.taskID] = target
        updateLoop()
        return look(at: looks)
    }

    /// A sidebar row left the view. Its task is not looked up again until it comes back.
    func hideRow(_ taskID: UUID) {
        rows[taskID] = nil
        updateLoop()
    }

    /// The tasks a new-task screen now shows or reads for its lists (`NewTaskHomeListsProjection
    /// .pullRequestCandidates`). Each screen (a split view can show several) keeps its own set; an
    /// empty set is the screen leaving the view.
    @discardableResult
    func showHome(_ shown: [TaskPullRequestTarget], screen: UUID) -> Task<Void, Never> {
        let looks = changes(from: shownTarget, to: shown)
        homes[screen] = shown.isEmpty ? nil : Dictionary(shown.map { ($0.taskID, $0) }) { first, _ in first }
        updateLoop()
        return look(at: looks)
    }

    private var homeTargets: [UUID: TaskPullRequestTarget] {
        homes.values.reduce(into: [:]) { merged, targets in merged.merge(targets) { first, _ in first } }
    }

    /// What the title bar, a sidebar row or a new-task screen shows of the task now.
    private func shownTarget(_ taskID: UUID) -> TaskPullRequestTarget? {
        focused[taskID] ?? rows[taskID] ?? homes.values.lazy.compactMap { $0[taskID] }.first
    }

    private var shownTargets: [TaskPullRequestTarget] {
        let homeTargets = homeTargets.values.filter { focused[$0.taskID] == nil && rows[$0.taskID] == nil }
        return Array(focused.values) + rows.values.filter { focused[$0.taskID] == nil } + homeTargets
    }

    /// Which of `shown` to look at now: the ones not on screen before, and the ones whose turn has
    /// just ended or whose folder or conversation changed.
    private func changes(
        from before: (UUID) -> TaskPullRequestTarget?, to shown: [TaskPullRequestTarget]
    ) -> [(TaskPullRequestTarget, TaskPullRequestRefreshPolicy.Occasion)] {
        shown.compactMap { target in
            guard let previous = before(target.taskID) else { return (target, .shown) }
            if previous.isWorking && !target.isWorking || previous.workspaceURL != target.workspaceURL
                || previous.claudeConversation != target.claudeConversation {
                return (target, .stillShown)
            }
            return nil
        }
    }

    /// Looks are paused while Yardlet is not the active app, and the tasks in view are looked at
    /// again when it becomes active.
    func setApplicationActive(_ active: Bool) {
        guard active != isApplicationActive else { return }
        isApplicationActive = active
        updateLoop()
        if active { Task { await lookAtShownTasks() } }
    }

    /// Looks at every task in view once now.
    func lookAtShownTasks() async {
        await look(at: shownTargets.map { ($0, .stillShown) }).value
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func updateLoop() {
        let wanted = sources != nil && isApplicationActive && !(focused.isEmpty && rows.isEmpty && homes.isEmpty)
        if !wanted {
            stop()
        } else if loop == nil {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    guard let interval = self?.lookInterval else { return }
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled, let self else { return }
                    await self.lookAtShownTasks()
                }
            }
        }
    }

    private func look(at looks: [(TaskPullRequestTarget, TaskPullRequestRefreshPolicy.Occasion)]) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self, !looks.isEmpty else { return }
            await withTaskGroup(of: Void.self) { group in
                for (target, occasion) in looks {
                    group.addTask { await self.look(at: target, occasion: occasion) }
                }
            }
        }
    }

    private func isShown(_ target: TaskPullRequestTarget) -> Bool {
        let current = shownTarget(target.taskID)
        return current.map {
            $0.workspaceURL == target.workspaceURL && $0.claudeConversation == target.claudeConversation
        } == true
    }

    /// Reads the task's transcript link and branch, shows what the link names, and asks GitHub when
    /// the policy says so.
    func look(at target: TaskPullRequestTarget, occasion: TaskPullRequestRefreshPolicy.Occasion) async {
        guard let sources, isApplicationActive || occasion == .shown else { return }
        let id = target.taskID
        let previousScan = records[id]?.scan
        let read = await Task.detached(priority: .utility) {
            let scan = target.claudeConversation.flatMap { sources.scanLink($0, previousScan) }
            return (scan: scan, branch: scan?.link == nil ? sources.gitHubBranch(target.workspaceURL) : nil)
        }.value
        // Still in view, in the same folder and conversation.
        guard isShown(target) else { return }
        var record = records[id] ?? Record()
        record.scan = read.scan
        record.link = read.scan?.link
        let folder = ProjectSidebarPresentation.normalizedPath(for: target.workspaceURL)
        let subject: Subject? = record.link.map { .link($0.url.absoluteString) }
            ?? read.branch.map { .branch(folder: folder, branch: $0) }

        // What the transcript names shows at once; GitHub's last word on the same one stays.
        if let link = record.link {
            let named = TaskPullRequest(link: link)
            if let shown = pullRequests[id], shown.isSamePullRequest(as: named), shown.source == .transcriptLink {
                // Unchanged.
            } else {
                pullRequests[id] = named
            }
        } else if subject == nil {
            if pullRequests[id] != nil { pullRequests[id] = nil }
        } else if case let .branch(_, branch) = subject, let shown = pullRequests[id], shown.source != .branch(branch) {
            // Another branch, or a link that is gone: what was shown is not this branch's.
            pullRequests[id] = nil
        }

        var subjectChanged = record.subject != subject
        record.subject = subject
        if subjectChanged { record.lastAsked = nil }
        if subjectChanged, let subject, let last = lastAnswers[subject] {
            // GitHub was already asked about the same, for another task or before: that question counts.
            record.lastAsked = last.askedAt
            subjectChanged = false
            apply(last.answer, about: subject, link: record.link, to: id)
        }
        records[id] = record
        guard let subject else { return }
        let settled = pullRequests[id]?.isSettled == true
        guard policy.shouldAsk(lastAsked: record.lastAsked, now: now(), occasion: occasion,
                               isFocused: focused[id] != nil, subjectChanged: subjectChanged,
                               settled: settled) else { return }
        records[id]?.lastAsked = now()
        // Another task already asks the same: its answer is shared when it comes.
        guard asking.insert(subject).inserted else { return }
        defer { asking.remove(subject) }

        await acquireQuerySlot()
        defer { releaseQuerySlot() }
        guard isApplicationActive || occasion == .shown else { return }
        questionCount += 1
        let answer: GitHubPullRequestClient.Answer
        switch subject {
        case let .link(text):
            guard let url = URL(string: text) else { return }
            answer = await sources.gitHub.pullRequest(at: url, in: target.workspaceURL)
        case let .branch(_, branch):
            answer = await sources.gitHub.pullRequest(forBranch: branch, in: target.workspaceURL)
        }
        // Every task that names the same now takes the answer; one that names something else drops it.
        let askedAt = records[id]?.lastAsked ?? now()
        lastAnswers[subject] = (askedAt, answer)
        for (taskID, other) in records where other.subject == subject {
            if taskID != id { records[taskID]?.lastAsked = askedAt }
            apply(answer, about: subject, link: other.link, to: taskID)
        }
    }

    private func apply(_ answer: GitHubPullRequestClient.Answer, about subject: Subject, link: TaskPullRequestLink?,
                       to id: UUID) {
        switch answer {
        case var .found(pullRequest):
            if case .link = subject, let link {
                guard pullRequest.number == link.number else { return }
                pullRequest = TaskPullRequest(number: link.number, url: link.url,
                                              repository: link.repository ?? pullRequest.repository,
                                              source: .transcriptLink, state: pullRequest.state,
                                              checks: pullRequest.checks, review: pullRequest.review)
            }
            if pullRequests[id] != pullRequest { pullRequests[id] = pullRequest }
        case .none:
            if case .branch = subject, pullRequests[id] != nil { pullRequests[id] = nil }
        case .unavailable:
            // Without `gh`, signed out, offline: the link's number stays, without a state.
            break
        }
    }

    private func acquireQuerySlot() async {
        if runningQueries < max(1, policy.maximumConcurrentQueries) {
            runningQueries += 1
            return
        }
        await withCheckedContinuation { queryWaiters.append($0) }
    }

    private func releaseQuerySlot() {
        if queryWaiters.isEmpty {
            runningQueries -= 1
        } else {
            // The slot passes straight to the next question.
            queryWaiters.removeFirst().resume()
        }
    }
}

extension AppModel {
    /// The tasks whose pull request a header shows: the selected one, or in a split view each pane's,
    /// whose headers show their own.
    func pullRequestTargets() -> [TaskPullRequestTarget] {
        guard let split = splits.activeSplit else {
            return store.selectedSession.map { [TaskPullRequestTarget(session: $0)] } ?? []
        }
        return split.sessionIDs.compactMap { id in store.sessions.first { $0.id == id } }
            .map { TaskPullRequestTarget(session: $0) }
    }

    /// Starts looking up the pull requests of the tasks on screen, with the person's own `gh`.
    func startPullRequestLookups() {
        guard !usesVisualFixture, pullRequests.sources == nil else { return }
        pullRequests.show(pullRequestTargets())
        pullRequests.start(.live(scanLink: { conversation, previous in
            try? ClaudeSubagentTranscriptReader(configDirectory: conversation.configDirectory)
                .pullRequestLinkScan(sessionID: conversation.providerSessionID, previous: previous)
        }))
        // The rails' pull request cards and auto-fix ask the same `gh`.
        pullRequestDetails.isTaskIdle = { [weak self] id in self?.canTakeAutoFix(id) ?? false }
        pullRequestDetails.deliver = { [weak self] id, message in await self?.deliverAutoFix(message, to: id) ?? false }
        pullRequestDetails.start(GitHubPullRequestDetailClient(cli: LocalGitHubCLI()))
    }

    /// Auto-fix's message may go to the task now: no turn running, nobody waited for, no message
    /// being edited, no account switch or edit under way, and no other app holding the conversation.
    func canTakeAutoFix(_ taskID: UUID) -> Bool {
        guard let session = store.sessions.first(where: { $0.id == taskID }) else { return false }
        return session.status != .running && session.status != .waitingForApproval
            && composerDrafts.tasks.draft(for: taskID).editState == nil
            && !switchingAccounts.contains(taskID) && !sessionMutations.contains(taskID)
            && !isHeldElsewhere(session)
    }

    /// Sends auto-fix's message as the task's next turn, the way a message from another task goes
    /// (`deliverTaskMessage`) to an idle task, or after its continue while it waits for a usage limit
    /// to reset (`usageLimitHold`). True when it went without a new error.
    func deliverAutoFix(_ message: String, to taskID: UUID) async -> Bool {
        guard canTakeAutoFix(taskID), let session = store.sessions.first(where: { $0.id == taskID }) else {
            return false
        }
        if continuations.holdUntilUsageLimitResets(HarnessUserInput(text: message), for: taskID) != nil { return true }
        let previousError = errorBySessionID[taskID]
        if session.harness == .codex {
            await submitCodex(CodexComposerDraft(inputs: [.text(message)]), action: .automatic, to: session)
        } else {
            await send(HarnessUserInput(text: message), to: session)
        }
        let error = errorBySessionID[taskID]
        return error == nil || error == previousError
    }
}
