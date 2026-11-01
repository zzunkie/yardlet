import Foundation

/// Which account a task Yardlet starts for an agent runs on (docs/NATIVE_SESSION_STORAGE.md, "Choosing an additional account"): a child task
/// (`create_task`), a subagent (`run_agent`) or a suggestion the person starts, and where a
/// schedule's run goes when its own account is nearly spent. The candidates are
/// the harness's accounts in automatic assignment that are signed in
/// (`ProviderConnectionStore.isInAutomaticAssignment`); this picks one of them from the plan limits
/// Yardlet already reads, and the tasks already running on each. Pure, so the rule is tested
/// without a harness or an account.
///
/// The rule, in order:
/// 1. Each window that applies (every window without a model, and a model's own window when the
///    task's model is that model or is not known) gives its share left, or all of it once its reset
///    has passed. Divided by the share of the window's time still to run, that is its pace: 1 spends
///    the window evenly to its reset, more is room that a reset soon would otherwise waste. The
///    account's headroom is its smallest pace, divided by one more than the tasks running on it, so
///    several tasks started at once spread over the accounts.
/// 2. An account with any window at or under `nearlySpentFraction` left (and not yet reset) is
///    nearly spent; it is chosen only when every account is, the one that frees up first.
/// 3. An account with no reading comes after the ones with room and before the nearly spent.
/// Ties go to the account new tasks start on, then the list's order.
enum AccountRouting {
    /// The line the account list and a limit card mark as nearly spent (`AccountLimitWindow.isNearlySpent`).
    static let nearlySpentFraction = 0.10
    /// The smallest share of a window's time counted, so a window about to reset does not divide by nothing.
    static let minimumTimeFraction = 0.01

    struct Window: Equatable, Sendable {
        let label: String
        let usedFraction: Double
        let resetsAt: Date?
        /// The share left now: all of it once the reset has passed.
        let left: Double
        /// `left` divided by the share of the window's time still to run.
        let pace: Double

        var isNearlySpent: Bool { left <= AccountRouting.nearlySpentFraction }
    }

    struct Headroom: Equatable, Sendable {
        /// The windows that apply, the lowest pace first.
        let windows: [Window]

        var pace: Double { windows.first?.pace ?? 1 }
        /// The window that decides: the nearly spent one that resets last, else the lowest pace.
        var deciding: Window? {
            let spent = windows.filter(\.isNearlySpent)
            guard !spent.isEmpty else { return windows.first }
            return spent.max { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
        }
        var isNearlySpent: Bool { windows.contains(where: \.isNearlySpent) }
        /// When every nearly spent window has reset; nil when one of them gave no reset.
        var freesUpAt: Date? {
            let spent = windows.filter(\.isNearlySpent)
            guard !spent.isEmpty, spent.allSatisfy({ $0.resetsAt != nil }) else { return nil }
            return spent.compactMap(\.resetsAt).max()
        }
    }

    struct Candidate {
        let choice: AccountChoice
        /// Tasks and subagents running or waiting to start on the account now.
        let runningTasks: Int
        /// The account new tasks of the harness start on.
        let isNewTaskAccount: Bool
    }

    enum Basis: String, Codable, Equatable, Sendable {
        /// It had the most headroom.
        case headroom
        /// No account with room had a reading; it had none either.
        case noReading
        /// Every account was nearly spent; it frees up first.
        case nearlySpent
    }

    struct Pick {
        let choice: AccountChoice
        let headroom: Headroom?
        let basis: Basis
        let runningTasks: Int
    }

    /// The windows of `usage` that apply to a task on `model`, with their pace at `now`; nil when the
    /// reading has no plan limit.
    static func headroom(of usage: [AccountUsageMetric], model: String?, now: Date) -> Headroom? {
        let windows = usage.filter { $0.evidence == .exactQuota && applies($0, to: model) }
            .compactMap { metric -> Window? in
                guard let used = metric.usedFraction, used.isFinite else { return nil }
                let hasReset = metric.resetsAt.map { $0 <= now } ?? false
                let left = hasReset ? 1 : min(max(1 - used, 0), 1)
                var timeLeft = 1.0
                if !hasReset, let resetsAt = metric.resetsAt, let minutes = metric.windowMinutes, minutes > 0 {
                    timeLeft = min(max(resetsAt.timeIntervalSince(now) / (minutes * 60), minimumTimeFraction), 1)
                }
                return Window(label: metric.label, usedFraction: hasReset ? 0 : min(max(used, 0), 1),
                              resetsAt: hasReset ? nil : metric.resetsAt, left: left, pace: left / timeLeft)
            }
            .sorted { $0.pace < $1.pace }
        return windows.isEmpty ? nil : Headroom(windows: windows)
    }

    /// A window for one model applies to a task on that model, and to one whose model is not known
    /// (it may run the harness's default, which could be that model).
    static func applies(_ metric: AccountUsageMetric, to model: String?) -> Bool {
        guard let scoped = metric.model?.trimmingCharacters(in: .whitespaces).lowercased(), !scoped.isEmpty else {
            return true
        }
        guard let model = model?.trimmingCharacters(in: .whitespaces).lowercased(), !model.isEmpty else { return true }
        return model.contains(scoped) || scoped.contains(model)
    }

    /// The account a task on `model` starts on, or nil when there is no candidate.
    static func pick(_ candidates: [Candidate], model: String?, now: Date) -> Pick? {
        struct Read {
            let offset: Int
            let candidate: Candidate
            let headroom: Headroom?
        }
        let read = candidates.enumerated().map { offset, candidate in
            Read(offset: offset, candidate: candidate,
                 headroom: candidate.choice.snapshot.flatMap { headroom(of: $0.usage, model: model, now: now) })
        }
        func earlier(_ lhs: Read, _ rhs: Read) -> Bool {
            if lhs.candidate.isNewTaskAccount != rhs.candidate.isNewTaskAccount { return lhs.candidate.isNewTaskAccount }
            return lhs.offset < rhs.offset
        }
        func pick(_ read: Read, _ basis: Basis) -> Pick {
            Pick(choice: read.candidate.choice, headroom: read.headroom, basis: basis,
                 runningTasks: read.candidate.runningTasks)
        }
        let roomy = read.filter { $0.headroom.map { !$0.isNearlySpent } ?? false }
        if let best = roomy.max(by: { lhs, rhs in
            let left = score(lhs.headroom, running: lhs.candidate.runningTasks)
            let right = score(rhs.headroom, running: rhs.candidate.runningTasks)
            return left == right ? earlier(rhs, lhs) : left < right
        }) {
            return pick(best, .headroom)
        }
        if let first = read.filter({ $0.headroom == nil }).min(by: { lhs, rhs in
            lhs.candidate.runningTasks == rhs.candidate.runningTasks
                ? earlier(lhs, rhs) : lhs.candidate.runningTasks < rhs.candidate.runningTasks
        }) {
            return pick(first, .noReading)
        }
        return read.filter { $0.headroom?.isNearlySpent == true }.min { lhs, rhs in
            let left = lhs.headroom?.freesUpAt ?? .distantFuture
            let right = rhs.headroom?.freesUpAt ?? .distantFuture
            if left != right { return left < right }
            let leftPace = lhs.headroom?.pace ?? 0, rightPace = rhs.headroom?.pace ?? 0
            return leftPace == rightPace ? earlier(lhs, rhs) : leftPace > rightPace
        }.map { pick($0, .nearlySpent) }
    }

    private static func score(_ headroom: Headroom?, running: Int) -> Double {
        (headroom?.pace ?? 0) / Double(1 + max(running, 0))
    }
}

/// Which account a task an agent started runs on, and why, as the tool result, `read_task` and the
/// task's hover card say it. A schedule's run that went to another account than its own, because that
/// one was nearly spent, keeps one too, and its line in the run history says so (`switchLine`).
struct AccountAssignment: Codable, Equatable, Sendable {
    enum Origin: String, Codable, Sendable {
        /// Yardlet picked it (`AccountRouting.pick`).
        case automatic
        /// The agent named it in the call.
        case agent
        /// No account was in automatic assignment and signed in: the account new tasks start on.
        case newTaskAccount
    }

    /// `AccountChoice.id` of the account.
    let accountID: String
    let accountName: String
    let origin: Origin
    let basis: AccountRouting.Basis?
    /// The window that decided: its name, how much of it was used and when it resets.
    let windowLabel: String?
    let usedFraction: Double?
    let resetsAt: Date?
    let freesUpAt: Date?
    let runningTasks: Int
    let assignedAt: Date
    /// The account it was set to go to, which was nearly spent (`AppModel.accountReplacing`).
    let replacedAccountName: String?

    init(choice: AccountChoice, origin: Origin, pick: AccountRouting.Pick? = nil,
         headroom: AccountRouting.Headroom? = nil, runningTasks: Int = 0, replacing: AccountChoice? = nil,
         at date: Date = Date()) {
        accountID = choice.id
        accountName = choice.title
        self.origin = origin
        replacedAccountName = replacing?.title
        basis = pick?.basis
        let decided = pick?.headroom ?? headroom
        let window = decided?.deciding
        windowLabel = window?.label
        usedFraction = window?.usedFraction
        resetsAt = window?.resetsAt
        freesUpAt = pick?.basis == .nearlySpent ? decided?.freesUpAt : nil
        self.runningTasks = pick?.runningTasks ?? runningTasks
        assignedAt = date
    }

    /// The tool result's line, in the tools' English: "Account: name (chosen automatically: 5 hour
    /// limit 12% used, resets 2026-10-26T15:00:00+09:00)".
    var toolLine: String {
        var why: [String] = []
        if let replacedAccountName { why.append("switched from \(replacedAccountName), nearly out of its limit") }
        switch origin {
        case .automatic:
            why.append(basis == .nearlySpent ? "chosen automatically: every account is nearly out, this one frees up first"
                : basis == .noReading ? "chosen automatically: no usage reading" : "chosen automatically")
        case .agent: why.append("as asked")
        case .newTaskAccount: why.append("the account new tasks start on; no other account is in automatic assignment")
        }
        if let windowLabel, let usedFraction {
            var window = "\(windowLabel) \(Int((usedFraction * 100).rounded()))% used"
            if let resetsAt { window += ", resets \(Self.iso(resetsAt))" }
            why.append(window)
        }
        if let freesUpAt { why.append("frees up \(Self.iso(freesUpAt))") }
        if runningTasks > 0 { why.append("\(runningTasks) running on it") }
        return "Account: \(accountName) (\(why.joined(separator: "; ")))"
    }

    /// The person's words for why, after the account's name: "Chosen automatically · 5 hour limit
    /// 12% used · Resets 3:00 PM".
    func reasonLine(now: Date = Date()) -> String {
        var parts: [String] = if let replacedAccountName {
            [L10n.format("Switched from %@: nearly out of its limit", replacedAccountName)]
        } else {
            switch origin {
            case .automatic: [L10n.string("Chosen automatically")]
            case .agent: [L10n.string("Chosen by the agent")]
            case .newTaskAccount: [L10n.string("Account for new tasks")]
            }
        }
        if let windowLabel, let usedFraction {
            parts.append(L10n.format("%@ %lld%% used", windowLabel, Int64((usedFraction * 100).rounded())))
            if let resetsAt { parts.append(L10n.format("Resets %@", ProviderNoticeText.resetTime(resetsAt, now: now))) }
        }
        if basis == .nearlySpent, let freesUpAt {
            parts.append(L10n.format("Frees up %@", ProviderNoticeText.resetTime(freesUpAt, now: now)))
        }
        return parts.joined(separator: " · ")
    }

    /// A schedule's run history line for a run that went to another account: "Switched to name: other
    /// was nearly out of its limit".
    var switchLine: String? {
        replacedAccountName.map { L10n.format("Switched to %@: %@ was nearly out of its limit", accountName, $0) }
    }

    static func iso(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .current))
    }
}
