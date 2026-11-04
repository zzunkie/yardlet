import Foundation
import Observation

/// The full status of the pull requests the session rails show, and auto-fix.
///
/// A task's Changes card asks for its pull request while it is on screen (`show`/`hide`): once when it
/// comes into view, then every 30 s while checks run and every 180 s otherwise; a merged or closed
/// pull request is not asked again. A task whose auto-fix the person turned on is looked at every
/// `autoFixInterval` while Yardlet runs, on screen or not, and gets one message per new failure
/// (`PullRequestAutoFixPolicy`). Everything goes through the person's own `gh`; writes — re-running
/// failed jobs, merging, auto-merge — run only from the person's press, and a merge only once they
/// confirmed it. Answers are kept in memory only; auto-fix's records are `PullRequestAutoFixStore`'s.
@MainActor
@Observable
final class PullRequestDetailCenter {
    struct TaskState: Equatable {
        enum Log: Equatable {
            case loading
            case loaded(String)
            case failed(String)
        }

        var url: URL
        var folder: URL
        var repository: String?
        var detail: PullRequestDetail?
        var problem: PullRequestCLIProblem?
        var isLoading = false
        var lastAsked: Date?
        var mergeMethods: PullRequestMergeMethods?
        /// Failed logs the person opened, by check.
        var logs: [String: Log] = [:]
        /// A merge waiting for the person's confirmation.
        var pendingMerge: PullRequestMergeRequest.Kind?
        /// A write running now: a re-run's run ID, or "merge".
        var runningAction: String?
        var actionError: String?
    }

    @ObservationIgnored let states = TaskStateTable<TaskState>()
    @ObservationIgnored let autoFix: PullRequestAutoFixStore
    /// Nil until the app starts it: tests and fixtures without a client never start `gh`.
    @ObservationIgnored private(set) var client: GitHubPullRequestDetailClient?
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }
    @ObservationIgnored var shownInterval: TimeInterval = 180
    @ObservationIgnored var runningChecksInterval: TimeInterval = 30
    @ObservationIgnored var autoFixInterval: TimeInterval = 120
    @ObservationIgnored var tickInterval: Duration = .seconds(15)
    /// Whether the task can take auto-fix's message now: no turn running, nobody waited for, no
    /// message being edited. The app sets it.
    @ObservationIgnored var isTaskIdle: @MainActor (UUID) -> Bool = { _ in false }
    /// Sends auto-fix's message to the task as its next turn; true when it went.
    @ObservationIgnored var deliver: (@MainActor (UUID, String) async -> Bool)?
    /// The last `gh` commands started, for tests to read.
    @ObservationIgnored private(set) var commands: [[String]] = []

    @ObservationIgnored private var shown: Set<UUID> = []
    @ObservationIgnored private var remoteShown: Set<UUID> = []
    @ObservationIgnored private var asking: Set<UUID> = []
    @ObservationIgnored private var delivering: Set<UUID> = []
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(autoFix: PullRequestAutoFixStore = PullRequestAutoFixStore(defaults: nil)) {
        self.autoFix = autoFix
    }

    func state(for taskID: UUID) -> TaskState? { states[taskID] }

    /// Puts a state in place without asking anything, for visual fixtures and rendering tests.
    func setState(_ state: TaskState?, for taskID: UUID) { states[taskID] = state }

    /// Starts asking: what is on screen now, and auto-fix's tasks. Without `looking`, only what is
    /// asked for directly runs (tests drive every look).
    func start(_ client: GitHubPullRequestDetailClient, looking: Bool = true) {
        self.client = client
        isLooking = looking
        updateLoop()
        if looking { Task { await tick() } }
    }

    @ObservationIgnored private var isLooking = true

    /// Yardlet is quitting: nothing more is asked.
    func stop() {
        loop?.cancel()
        loop = nil
        client = nil
    }

    // MARK: - On screen

    /// The task's Changes card came into view with this pull request, or it changed.
    func show(taskID: UUID, pullRequest: TaskPullRequest, folder: URL) {
        let previous = states[taskID]
        shown.insert(taskID)
        if previous?.url != pullRequest.url || previous?.folder != folder {
            states[taskID] = TaskState(url: pullRequest.url, folder: folder, repository: pullRequest.repository)
        }
        autoFix.follow(pullRequest.url, folder: folder, for: taskID)
        updateLoop()
        if previous?.url != pullRequest.url || previous?.lastAsked == nil
            || now().timeIntervalSince(previous?.lastAsked ?? .distantPast) >= 60 {
            Task { await refresh(taskID) }
        }
    }

    /// Remote rails have their own visibility lease; closing one does not hide a local rail.
    func showRemote(taskID: UUID, pullRequest: TaskPullRequest, folder: URL) {
        let localWasShown = shown.contains(taskID)
        remoteShown.insert(taskID)
        show(taskID: taskID, pullRequest: pullRequest, folder: folder)
        if !localWasShown { shown.remove(taskID) }
    }

    func hideRemote(taskID: UUID) {
        remoteShown.remove(taskID)
        updateLoop()
    }

    /// The card left the screen, or the task has no pull request any more.
    func hide(taskID: UUID) {
        shown.remove(taskID)
        updateLoop()
    }

    /// The task has no pull request: what was shown goes.
    func clear(taskID: UUID) {
        shown.remove(taskID)
        if states[taskID] != nil { states[taskID] = nil }
        updateLoop()
    }

    /// Asks GitHub about the task's pull request now.
    func refresh(_ taskID: UUID) async {
        guard let client, var state = states[taskID] ?? autoFixState(taskID), asking.insert(taskID).inserted else {
            return
        }
        defer { asking.remove(taskID) }
        state.isLoading = true
        state.lastAsked = now()
        states[taskID] = state
        record(["pr", "view", state.url.absoluteString])
        let answer = await client.detail(of: state.url, in: state.folder)
        guard var current = states[taskID], current.url == state.url else { return }
        current.isLoading = false
        current.lastAsked = state.lastAsked
        switch answer {
        case let .success(detail):
            current.detail = detail
            current.problem = nil
        case let .failure(problem):
            current.problem = problem
        }
        if current.mergeMethods == nil, current.detail?.isOpen == true {
            record(["repo", "view"])
            current.mergeMethods = await client.mergeMethods(repository: current.repository, in: current.folder)
                ?? .all
        }
        if states[taskID] != current { states[taskID] = current }
        await evaluateAutoFix(taskID)
    }

    // MARK: - Checks

    /// "Show failure details" on a failed check: the failed steps' log, its last lines.
    func loadLog(taskID: UUID, check: PullRequestDetail.Check) async {
        guard let client, let runID = check.runID, var state = states[taskID] else { return }
        state.logs[check.id] = .loading
        states[taskID] = state
        record(["run", "view", runID, "--log-failed"])
        let result = await client.failedLog(runID: runID, in: state.folder)
        guard var current = states[taskID] else { return }
        switch result {
        case let .success(text): current.logs[check.id] = .loaded(text)
        case let .failure(problem): current.logs[check.id] = .failed(problem.message)
        }
        states[taskID] = current
    }

    func closeLog(taskID: UUID, check: PullRequestDetail.Check) {
        guard var state = states[taskID], state.logs[check.id] != nil else { return }
        state.logs[check.id] = nil
        states[taskID] = state
    }

    /// "Re-run failed jobs": the person pressed it. Each failed check's run once.
    func rerunFailed(taskID: UUID, checks: [PullRequestDetail.Check]) async {
        guard let client, var state = states[taskID], state.runningAction == nil else { return }
        let runs = Array(Set(checks.compactMap(\.runID))).sorted()
        guard !runs.isEmpty else { return }
        state.runningAction = "rerun"
        state.actionError = nil
        states[taskID] = state
        var error: String?
        for run in runs {
            record(["run", "rerun", run, "--failed"])
            if case let .failure(problem) = await client.rerunFailedJobs(runID: run, in: state.folder) {
                error = problem.message
            }
        }
        if var current = states[taskID] {
            current.runningAction = nil
            current.actionError = error
            states[taskID] = current
        }
        await refresh(taskID)
    }

    // MARK: - Merging

    /// "Merge" or "Auto-merge" in the card's menu: nothing runs until `confirmMerge`.
    func requestMerge(taskID: UUID, _ kind: PullRequestMergeRequest.Kind) {
        guard var state = states[taskID], state.detail?.isOpen == true else { return }
        state.pendingMerge = kind
        state.actionError = nil
        states[taskID] = state
    }

    func cancelMerge(taskID: UUID) {
        guard var state = states[taskID], state.pendingMerge != nil else { return }
        state.pendingMerge = nil
        states[taskID] = state
    }

    /// The person confirmed the merge they asked for; it names the head commit they saw.
    func confirmMerge(taskID: UUID) async {
        guard let client, var state = states[taskID], let kind = state.pendingMerge, let detail = state.detail,
              state.runningAction == nil else { return }
        state.pendingMerge = nil
        state.runningAction = "merge"
        state.actionError = nil
        states[taskID] = state
        let request = PullRequestMergeRequest(url: detail.url, kind: kind, headSHA: detail.headSHA)
        record(request.arguments)
        let result = await client.merge(request, in: state.folder)
        if var current = states[taskID] {
            current.runningAction = nil
            if case let .failure(problem) = result { current.actionError = problem.message }
            states[taskID] = current
        }
        await refresh(taskID)
    }

    // MARK: - Auto-fix

    /// The task's switch, or its answer to the question.
    func setAutoFix(_ on: Bool, taskID: UUID) {
        let state = states[taskID]
        autoFix.setChoice(on ? .on : .off, for: taskID, pullRequestURL: state?.url, folder: state?.folder)
        updateLoop()
        if on { Task { await evaluateAutoFix(taskID) } }
    }

    /// A turn ended or the task stopped waiting: a failure that waited for it may go now.
    func taskBecameIdle(_ taskID: UUID) {
        guard autoFix.record(for: taskID)?.isOn == true else { return }
        Task { await evaluateAutoFix(taskID) }
    }

    func forget(_ taskID: UUID) {
        shown.remove(taskID)
        states[taskID] = nil
        autoFix.forget(taskID)
        updateLoop()
    }

    /// What auto-fix decides for the task now (`PullRequestAutoFixPolicy.decide`).
    func autoFixDecision(for taskID: UUID) -> PullRequestAutoFixDecision {
        PullRequestAutoFixPolicy.decide(record: autoFix.record(for: taskID), detail: states[taskID]?.detail,
                                        taskIsIdle: isTaskIdle(taskID))
    }

    /// Sends a new failure's message when auto-fix is on for the task and the task can take it.
    /// Never sends for a task the person did not turn auto-fix on for.
    func evaluateAutoFix(_ taskID: UUID) async {
        guard case let .send(key, message) = autoFixDecision(for: taskID), let deliver,
              delivering.insert(taskID).inserted else { return }
        defer { delivering.remove(taskID) }
        if await deliver(taskID, message) {
            autoFix.recordSent(key, at: now(), for: taskID)
        }
    }

    /// A state for an auto-fix task not on screen, from its record.
    private func autoFixState(_ taskID: UUID) -> TaskState? {
        guard let record = autoFix.record(for: taskID), record.isOn, let url = record.pullRequestURL,
              let path = record.folderPath else { return nil }
        let state = TaskState(url: url, folder: URL(filePath: path, directoryHint: .isDirectory),
                              repository: TaskPullRequest.repository(in: url))
        states[taskID] = state
        return state
    }

    // MARK: - Asking again

    /// Whether the task is due to be asked again, and why it is watched.
    func isDue(_ taskID: UUID) -> Bool {
        let state = states[taskID]
        if let detail = state?.detail, !detail.isOpen { return false }
        guard let lastAsked = state?.lastAsked else { return true }
        let elapsed = now().timeIntervalSince(lastAsked)
        if shown.contains(taskID) || remoteShown.contains(taskID) {
            let interval = state?.detail?.count(.pending) ?? 0 > 0 ? runningChecksInterval : shownInterval
            if elapsed >= interval { return true }
        }
        return autoFix.record(for: taskID)?.isOn == true && elapsed >= autoFixInterval
    }

    func tick() async {
        let watched = shown.union(remoteShown).union(autoFix.enabledTaskIDs)
        for taskID in watched where isDue(taskID) {
            await refresh(taskID)
        }
    }

    private func updateLoop() {
        let wanted = client != nil && isLooking && !(shown.isEmpty && remoteShown.isEmpty && autoFix.enabledTaskIDs.isEmpty)
        if !wanted {
            loop?.cancel()
            loop = nil
        } else if loop == nil {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    guard let interval = self?.tickInterval else { return }
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled, let self else { return }
                    await self.tick()
                }
            }
        }
    }

    private func record(_ command: [String]) {
        commands.append(command)
        if commands.count > 50 { commands.removeFirst(commands.count - 50) }
    }
}
