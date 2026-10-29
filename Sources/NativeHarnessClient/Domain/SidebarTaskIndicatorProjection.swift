import Foundation

/// A task's state at the end of its sidebar row, drawn as the Claude app's Code session list draws
/// it: one small mark at the row's end (`status-dot`, 6 pt), named in the Claude app's words. The
/// states and their order came from the Codex app's task row (`codex.localTaskRow.*`). The cases
/// run from the most urgent; a collapsed project or a split view shows its most urgent task's.
enum SidebarTaskStatus: Equatable, Sendable {
    /// A command, file change or permission waits: the Claude app's "Awaiting input".
    case awaitingApproval
    /// The task asked a question: the Claude app's "Awaiting answer".
    case needsInput
    /// A tab of the task's browser waits on the person (`TaskAttentionDetail.browserWait`).
    case waitingInBrowser
    /// The latest turn failed: the Claude app's warning mark, with the Codex app's words, since the
    /// Claude app names each kind of error on its own.
    case failed(message: String?)
    /// A plan limit stopped the latest turn: the Claude app's usage gauge, named as the limit card.
    case usageLimit(HarnessRateLimit)
    /// A turn is running: the Claude app's blinking gray dot, "Running".
    case running
    /// A lost connection cut the latest turn off and it continues once the network is back, in the
    /// word Yardlet's and the Codex app's reconnect lines use, "Reconnecting".
    case reconnecting
    /// A finished result is unread: the Claude app's blue dot, "Unread response".
    case unread

    /// 0 is the most urgent.
    var urgency: Int {
        switch self {
        case .awaitingApproval: 0
        case .needsInput: 1
        case .waitingInBrowser: 2
        case .failed: 3
        case .usageLimit: 4
        case .running: 5
        case .reconnecting: 6
        case .unread: 7
        }
    }

    /// The name the mark's help and assistive technologies read, in the Claude app's words where it
    /// has them (`tM90hqjWj0`, `L+gTSub4gg`, `nDyaq/M7Oj`, `74N95hPFV6`).
    var accessibilityName: String {
        switch self {
        case .awaitingApproval: L10n.string("Awaiting input")
        case .needsInput: L10n.string("Awaiting answer")
        case .waitingInBrowser: L10n.string("Waiting in the browser")
        case .failed: L10n.string("Task encountered a system error")
        case let .usageLimit(limit): ProviderNoticeText.limitHeadline(limit)
        case .running: L10n.string("Running")
        case .reconnecting: L10n.string("Reconnecting")
        case .unread: L10n.string("Unread response")
        }
    }

    /// The line a row's help adds: the name, and the error or the limit's reset when known.
    var help: String {
        switch self {
        case let .failed(message?):
            let summary = TranscriptRecoveryProjection.errorSummary(message)
            return summary.isEmpty ? accessibilityName : accessibilityName + "\n" + summary
        case let .usageLimit(limit):
            return [accessibilityName, ProviderNoticeText.limitReset(limit)].compactMap { $0 }.joined(separator: "\n")
        default:
            return accessibilityName
        }
    }
}

/// One mark at the end of a sidebar row. The row draws `SidebarTaskIndicatorProjection
/// .trailingItems` in order, so a new mark is one more case there, placed by that function.
enum SidebarRowTrailingItem: Equatable, Sendable {
    /// A cloud-hosted session.
    case cloud
    /// The Codex worktree mark: the task runs in a linked worktree.
    case worktree
    /// The task's pull request while it still needs something (`TaskPullRequestRowMark`).
    case pullRequest(TaskPullRequestRowMark)
    /// Task resource usage: the row's tasks keep using a lot of CPU.
    case cpu(Int)
    case status(SidebarTaskStatus)
}

enum SidebarTaskIndicatorProjection {
    /// The state a task row shows. A request waiting on the person comes first; then a turn still
    /// working (a bash-mode command counts, whatever the provider status); then how the latest turn
    /// ended, a plan limit before another failure; then an unread result.
    static func status(
        of session: SessionRecord,
        detail: TaskAttentionDetail? = nil,
        isShellBusy: Bool = false
    ) -> SidebarTaskStatus? {
        if let request = TaskAttentionProjection.waitingRequest(of: session, detail: detail) {
            return request == .input ? .needsInput : .awaitingApproval
        }
        if detail?.browserWait != nil { return .waitingInBrowser }
        if session.status == .running || isShellBusy { return .running }
        if detail?.isReconnecting == true { return .reconnecting }
        if let limit = detail?.usageLimit { return .usageLimit(limit) }
        if session.status == .failed || session.completionState == .failed {
            return .failed(message: detail?.errorMessage)
        }
        if session.hasUnreadUpdate { return .unread }
        return nil
    }

    /// A row holding several tasks (a collapsed project, a split view) shows the most urgent.
    static func summary(of sessions: [SessionRecord], details: [UUID: TaskAttentionDetail] = [:],
                        shellBusy: Set<UUID> = []) -> SidebarTaskStatus? {
        sessions
            .compactMap { status(of: $0, detail: details[$0.id], isShellBusy: shellBusy.contains($0.id)) }
            .min { $0.urgency < $1.urgency }
    }

    /// Everything a row shows at its end, in order: the cloud mark, the worktree mark, the pull request, the CPU,
    /// then the state.
    static func trailingItems(
        isCloud: Bool = false,
        isWorktree: Bool = false,
        pullRequest: TaskPullRequestRowMark? = nil,
        cpuPercent: Int? = nil,
        status: SidebarTaskStatus?
    ) -> [SidebarRowTrailingItem] {
        var items: [SidebarRowTrailingItem] = []
        if isCloud { items.append(.cloud) }
        if isWorktree { items.append(.worktree) }
        if let pullRequest { items.append(.pullRequest(pullRequest)) }
        if let cpuPercent { items.append(.cpu(cpuPercent)) }
        if let status { items.append(.status(status)) }
        return items
    }

    /// The CPU a row shows for its tasks: the sum of those whose processes keep using a lot of CPU
    /// (`busyCPU`, in percent), or nil when none does. A task row passes its own task; a collapsed
    /// project or a split view passes the tasks it holds, as it shows their state.
    static func cpuPercent(for taskIDs: some Sequence<UUID>, busyCPU: [UUID: Int]) -> Int? {
        guard !busyCPU.isEmpty else { return nil }
        var total: Int?
        for id in taskIDs {
            if let percent = busyCPU[id] { total = (total ?? 0) + percent }
        }
        return total
    }
}
