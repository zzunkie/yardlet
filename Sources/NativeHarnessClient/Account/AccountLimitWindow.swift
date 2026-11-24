import Foundation

/// One window of an account's plan limit, the one shape every place that shows limits reads:
/// the account list (an `AccountUsageMetric` from a check), Codex's `/status` (the
/// `CodexAccountRateLimits` it reads) and a limit card (the `HarnessRateLimit` a session reported).
/// `LimitWindowRow` draws it the same way in each; only the words around it are the place's own.
struct AccountLimitWindow: Identifiable, Equatable, Sendable {
    let id: String
    /// The window's name in the words of the place that shows it: `5 hour limit` in the account
    /// list and on a limit card, `5h limit` in Codex's `/status`.
    let name: String
    /// The share of the window left, 0 to 100; nil when the provider gave no figure.
    let remainingPercent: Double?
    let resetsAt: Date?
    let evidence: UsageEvidenceKind
}

extension AccountLimitWindow {
    /// A window an account check read, as the account list names it.
    init(metric: AccountUsageMetric) {
        self.init(id: metric.id, name: metric.label,
                  remainingPercent: metric.usedFraction.map { Self.remaining(usedPercent: $0 * 100) },
                  resetsAt: metric.resetsAt, evidence: metric.evidence)
    }

    /// The windows of one Codex limit, shortest first, named as the Codex app's `/status` names
    /// them (`5h limit`, `7d limit`, …). As in the app, a window without a length is not listed.
    static func windows(_ snapshot: CodexRateLimitSnapshot,
                        words: CodexStatusProjection.Words = CodexStatusProjection.Words()) -> [AccountLimitWindow] {
        let bucket = snapshot.limitID ?? "codex"
        return [("primary", snapshot.primary), ("secondary", snapshot.secondary)]
            .compactMap { key, window in window.map { (key, $0) } }
            .filter { ($0.1.windowDurationMinutes ?? 0) > 0 }
            .sorted { ($0.1.windowDurationMinutes ?? 0) < ($1.1.windowDurationMinutes ?? 0) }
            .map { key, window in
                AccountLimitWindow(
                    id: "\(bucket):\(key)",
                    name: CodexStatusProjection.windowLabel(minutes: window.windowDurationMinutes, words: words),
                    remainingPercent: remaining(usedPercent: window.usedPercent),
                    resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    evidence: .exactQuota)
            }
    }

    /// The windows a session's own limit report measured, the session window first, named as the
    /// account list names the same windows after a check. A refused window the report gave no
    /// figure for is spent; paid extra usage is not a window.
    static func windows(reportedBy limit: HarnessRateLimit) -> [AccountLimitWindow] {
        limit.measuredWindows.compactMap { reading -> (minutes: Double, reading: HarnessRateLimit.WindowUsage)? in
            reading.window.minutes.map { ($0, reading) }
        }
        .sorted { left, right in
            if left.minutes != right.minutes { return left.minutes < right.minutes }
            if (left.reading.model == nil) != (right.reading.model == nil) { return left.reading.model == nil }
            return (left.reading.model ?? "") < (right.reading.model ?? "")
        }
        .map { minutes, reading in
            AccountLimitWindow(
                id: "\(reading.window.rawValue):\(reading.model ?? "")",
                name: accountName(minutes: minutes, model: reading.model),
                remainingPercent: remaining(usedPercent: reading.usedFraction * 100),
                resetsAt: reading.resetsAt, evidence: .exactQuota)
        }
    }

    /// The account list's name for a window of `minutes`, with the one model it covers.
    static func accountName(minutes: Double, model: String?) -> String {
        let window = HarnessAccountBroker.usageWindowLabel(minutes: minutes, fallback: L10n.string("Usage"))
        return model.map { "\($0) · \(window)" } ?? window
    }

    /// The account list's words for the share left, as its checks write it.
    var accountRemainingText: String {
        L10n.format("%.0f%% remaining", remainingPercent ?? 0)
    }

    /// The share of the window used, 0 to 100; nil when the provider gave no figure.
    var usedPercent: Double? {
        remainingPercent.map { min(max(100 - $0, 0), 100) }
    }

    /// Ten percent or less left, which the account list and a limit card mark.
    var isNearlySpent: Bool { (remainingPercent ?? 100) <= 10 }

    private static func remaining(usedPercent: Double) -> Double {
        guard usedPercent.isFinite else { return 0 }
        return min(max(100 - usedPercent, 0), 100)
    }
}

extension HarnessRateLimit {
    /// Every window this report measured, with the limiting window's own reading in place of (or
    /// beside) the one the measured list had for it. A refused window without a figure is full.
    var measuredWindows: [WindowUsage] {
        var readings = windows
        if let window, let used = usedFraction ?? (status == .rejected ? 1 : nil) {
            let reading = WindowUsage(window: window, model: model, usedFraction: used, resetsAt: resetsAt)
            if let index = readings.firstIndex(where: { $0.window == window && $0.model == model }) {
                readings[index] = reading
            } else {
                readings.append(reading)
            }
        }
        return readings
    }
}

extension HarnessRateLimit.Window {
    /// How long the window runs: the five-hour session, or a week for the weekly limits. Paid
    /// extra usage has no window.
    var minutes: Double? {
        switch self {
        case .session: 300
        case .weekly, .model: 10_080
        case .overage: nil
        }
    }
}
