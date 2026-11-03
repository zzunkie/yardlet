import Foundation

/// The tokens a set of model requests used, by kind, and what they would cost at the provider's
/// public API prices. Read from the harnesses' own transcripts on this Mac (Claude Code's
/// `message.usage`, Codex's `token_count`); nothing is sent anywhere.
struct TokenUsageAmount: Equatable, Sendable {
    /// Input the model read fresh: neither written to nor read from the prompt cache.
    var freshInput: Int64 = 0
    /// Input written to the prompt cache (Claude's 5-minute and 1-hour writes together).
    var cacheWrite: Int64 = 0
    /// Input read from the prompt cache.
    var cacheRead: Int64 = 0
    var output: Int64 = 0
    var requests: Int = 0
    /// The API-equivalent cost in US dollars of each kind; empty when no request had a known price.
    var kindCost: [TokenUsageKind: Double] = [:]

    var cost: Double? { kindCost.isEmpty ? nil : kindCost.values.reduce(0, +) }

    var total: Int64 { freshInput + cacheWrite + cacheRead + output }

    mutating func add(_ other: TokenUsageAmount) {
        freshInput += other.freshInput
        cacheWrite += other.cacheWrite
        cacheRead += other.cacheRead
        output += other.output
        requests += other.requests
        kindCost.merge(other.kindCost, uniquingKeysWith: +)
    }

    /// The share of input read from the cache.
    var cacheReadShare: Double? {
        let input = freshInput + cacheWrite + cacheRead
        return input > 0 ? Double(cacheRead) / Double(input) : nil
    }
}

/// The four kinds of token in the order of their price per token, cheapest first, which the
/// share bar draws light to dark.
enum TokenUsageKind: CaseIterable, Identifiable, Sendable {
    case cacheRead, freshInput, cacheWrite, output

    var id: Self { self }

    var title: String {
        switch self {
        case .cacheRead: L10n.string("Cache reads")
        case .freshInput: L10n.string("New input")
        case .cacheWrite: L10n.string("Cache writes")
        case .output: L10n.string("Output")
        }
    }

    func tokens(in amount: TokenUsageAmount) -> Int64 {
        switch self {
        case .cacheRead: amount.cacheRead
        case .freshInput: amount.freshInput
        case .cacheWrite: amount.cacheWrite
        case .output: amount.output
        }
    }
}

/// One day of usage, local time.
struct TokenUsageDay: Identifiable, Equatable, Sendable {
    let start: Date
    var amount: TokenUsageAmount
    var id: Date { start }
}

/// One line of a breakdown: a model, a project, a task or an account.
struct TokenUsageRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    var detail: String? = nil
    var harness: HarnessKind? = nil
    var amount: TokenUsageAmount
}

/// What a breakdown groups by.
enum TokenUsageGrouping: String, CaseIterable, Identifiable, Sendable {
    case model, project, task, account

    var id: Self { self }

    var title: String {
        switch self {
        case .model: L10n.string("Model")
        case .project: L10n.string("Project")
        case .task: L10n.string("Task")
        case .account: L10n.string("Account")
        }
    }
}

/// The span the page sums over.
enum TokenUsageRange: String, CaseIterable, Identifiable, Sendable {
    case today, week, month

    var id: Self { self }

    var title: String {
        switch self {
        case .today: L10n.string("Today")
        case .week: L10n.string("7 days")
        case .month: L10n.string("30 days")
        }
    }

    var days: Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        }
    }
}

/// An account's plan limits beside the pace it has used them at lately.
struct TokenUsageLimitLine: Identifiable, Equatable, Sendable {
    let id: String
    /// The account as the usage lines name it: its address, with the organization for a team.
    let account: String
    /// The address alone, where a line has little room.
    let address: String
    let harness: HarnessKind
    var windows: [AccountUsageMetric]
    /// When each window (by metric id) runs out at the pace of the last hour, where that comes
    /// before it resets. Measured from the limit's own readings, never from token counts.
    var runsOutAt: [String: Date] = [:]
}

/// What the usage page and the Home band draw: the last 30 days, the limits with their pace, and each
/// range's counts by model, project, task or account, named for the reader.
struct TokenUsageOverview {
    /// The last 30 days, oldest first; the last is today.
    var days: [TokenUsageDay]
    var limits: [TokenUsageLimitLine]
    /// When the transcripts were last read.
    var updatedAt: Date
    /// The rows of a range grouped one way, largest first.
    var rows: (TokenUsageRange, TokenUsageGrouping) -> [TokenUsageRow] = { _, _ in [] }

    var today: TokenUsageAmount { days.last?.amount ?? TokenUsageAmount() }

    func amount(over range: TokenUsageRange) -> TokenUsageAmount {
        days.suffix(range.days).reduce(into: TokenUsageAmount()) { $0.add($1.amount) }
    }
}

/// The numbers in the reader's language: tokens as 52.1억 or 5.21B, dollars without cents from
/// $100.
enum TokenUsageFormat {
    static func tokens(_ value: Int64) -> String {
        Double(value).formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }

    static func cost(_ value: Double?) -> String {
        guard let value else { return "—" }
        let digits = value >= 100 ? 0 : 2
        return "$" + value.formatted(.number.precision(.fractionLength(digits)))
    }

    /// How long until something, as "1 hr 30 min" or "2 days 5 hr": two units at most.
    static func duration(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(60, interval)) ?? ""
    }

    /// "54.8억 tokens today · $2,124 API equivalent", as the Home band and the usage menus put it.
    static func today(_ amount: TokenUsageAmount) -> String {
        var parts = [L10n.format("%@ tokens today", tokens(amount.total))]
        if let cost = amount.cost { parts.append(L10n.format("%@ API equivalent", self.cost(cost))) }
        return parts.joined(separator: " · ")
    }

    static func percent(_ share: Double) -> String {
        let percent = share * 100
        if percent > 0, percent < 1 { return "<1%" }
        return percent.formatted(.number.precision(.fractionLength(0))) + "%"
    }
}
