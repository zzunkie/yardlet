import Foundation
@testable import NativeHarnessClient

/// A month of usage shaped like a heavy Claude Code user's on a Mac (the last eight days' API
/// cost per day and the token and cost mix by kind follow a real local count), with a little
/// Codex beside it, three accounts' limits and one window running out before it resets.
enum TokenUsageFixture {
    /// Claude Code's API-equivalent cost per day, oldest first; the last is today so far.
    private static let claudeCost: [Double] = [
        1420, 1980, 2310, 870, 640, 1750, 2480, 2890, 1960, 2140, 1120, 760, 1530, 2650, 3120,
        2240, 1870, 980, 1340, 2760, 2410, 1690, 3606, 1898, 2255, 1231, 1267, 2073, 3021, 2050
    ]
    private static let codexCost: [Double] = [
        0, 0, 12, 40, 0, 35, 22, 0, 64, 51, 18, 0, 0, 44, 70, 38, 0, 12, 90, 66, 25, 0, 58, 83, 61, 24,
        0, 47, 112, 74
    ]

    /// Claude Code (Opus 5.5) per dollar: tokens and requests, and how a dollar splits by kind.
    private static func claude(_ dollars: Double) -> TokenUsageAmount {
        let tokens = dollars * 2_645_000
        return TokenUsageAmount(
            freshInput: Int64(tokens * 0.000_006), cacheWrite: Int64(tokens * 0.019_17),
            cacheRead: Int64(tokens * 0.978_5), output: Int64(tokens * 0.002_37),
            requests: Int(dollars * 7.15),
            kindCost: [.cacheRead: dollars * 0.518, .cacheWrite: dollars * 0.357, .output: dollars * 0.125,
                       .freshInput: dollars * 0.000_06])
    }

    /// Codex (GPT-6 Astra) per dollar.
    private static func codex(_ dollars: Double) -> TokenUsageAmount {
        let tokens = dollars * 727_000
        return TokenUsageAmount(
            freshInput: Int64(tokens * 0.029), cacheWrite: 0, cacheRead: Int64(tokens * 0.969),
            output: Int64(tokens * 0.002_4), requests: Int(dollars * 3.5),
            kindCost: [.cacheRead: dollars * 0.70, .freshInput: dollars * 0.21, .output: dollars * 0.09])
    }

    private static func sum(_ amounts: [TokenUsageAmount]) -> TokenUsageAmount {
        amounts.reduce(into: TokenUsageAmount()) { sum, amount in
            sum.freshInput += amount.freshInput
            sum.cacheWrite += amount.cacheWrite
            sum.cacheRead += amount.cacheRead
            sum.output += amount.output
            sum.requests += amount.requests
            sum.kindCost.merge(amount.kindCost, uniquingKeysWith: +)
        }
    }

    private static func scaled(_ amount: TokenUsageAmount, _ share: Double) -> TokenUsageAmount {
        TokenUsageAmount(
            freshInput: Int64(Double(amount.freshInput) * share), cacheWrite: Int64(Double(amount.cacheWrite) * share),
            cacheRead: Int64(Double(amount.cacheRead) * share), output: Int64(Double(amount.output) * share),
            requests: Int(Double(amount.requests) * share), kindCost: amount.kindCost.mapValues { $0 * share })
    }

    static func overview(now: Date = Date()) -> TokenUsageOverview {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let days = claudeCost.indices.map { index in
            TokenUsageDay(start: calendar.date(byAdding: .day, value: index - (claudeCost.count - 1), to: today)!,
                          amount: sum([claude(claudeCost[index]), codex(codexCost[index])]))
        }
        var breakdowns: [TokenUsageRange: [TokenUsageGrouping: [TokenUsageRow]]] = [:]
        for range in TokenUsageRange.allCases {
            let claudeTotal = sum(claudeCost.suffix(range.days).map(claude))
            let codexTotal = sum(codexCost.suffix(range.days).map(codex))
            let all = sum([claudeTotal, codexTotal])
            func row(_ id: String, _ title: String, detail: String? = nil, harness: HarnessKind? = nil,
                     _ amount: TokenUsageAmount) -> TokenUsageRow {
                TokenUsageRow(id: id, title: title, detail: detail, harness: harness, amount: amount)
            }
            breakdowns[range] = [
                .model: [
                    row("opus", "Claude Opus 5.5", harness: .claudeCode, scaled(claudeTotal, 0.987)),
                    row("astra", "GPT-6 Astra", harness: .codex, scaled(codexTotal, 0.94)),
                    row("fable", "Claude Fable 5.1", harness: .claudeCode, scaled(claudeTotal, 0.012)),
                    row("sol", "GPT-6.1 Sol", harness: .codex, scaled(codexTotal, 0.06)),
                    row("haiku", "Claude Haiku 5.5", harness: .claudeCode, scaled(claudeTotal, 0.000_5))
                ],
                .project: [
                    ("yardlet", 0.34), ("example-web", 0.19), ("design-kit", 0.14), ("web-app", 0.12),
                    ("ledger-app", 0.08), ("field-notes", 0.05), (L10n.string("Chats"), 0.04), ("old-notes", 0.02),
                    ("docs-site", 0.012), ("sandbox", 0.008)
                ].map { name, share in row(name, name, scaled(all, share)) },
                .task: [
                    ("Refactor sidebar rows", "yardlet", HarnessKind.claudeCode, 0.071),
                    ("Approve schema migration", "yardlet", .claudeCode, 0.052),
                    ("Blog list first-load speed", "example-web", .codex, 0.044),
                    ("Tidy the weekly report", "design-kit", .claudeCode, 0.039),
                    ("Retry payment webhooks", "example-web", .codex, 0.031),
                    ("Summarize release notes", "yardlet", .claudeCode, 0.027),
                    ("Polish the onboarding copy", "design-kit", .claudeCode, 0.022),
                    ("Tidy the vehicle rates API", "web-app", .claudeCode, 0.019)
                ].map { title, project, harness, share in
                    row(title, title, detail: project, harness: harness, scaled(all, share))
                },
                .account: [
                    row("team", "jordan@example.com (Example Team)", harness: .claudeCode, scaled(claudeTotal, 0.58)),
                    row("dev", "jordan.dev@example.com", harness: .claudeCode, scaled(claudeTotal, 0.42)),
                    row("codex", "jordan@example.com", harness: .codex, codexTotal)
                ]
            ]
        }
        func window(_ id: String, hours: Double, used: Double, resetsIn: TimeInterval) -> AccountUsageMetric {
            let label = hours < 24 ? L10n.format("%.0f hour limit", hours) : L10n.format("%.0f day limit", hours / 24)
            return AccountUsageMetric(id: id, label: label, usedFraction: used,
                                      detail: L10n.format("%.0f%% remaining", (1 - used) * 100),
                                      resetsAt: now.addingTimeInterval(resetsIn), evidence: .exactQuota,
                                      windowMinutes: hours * 60)
        }
        let limits = [
            TokenUsageLimitLine(
                id: "team", account: "jordan@example.com (Example Team)", address: "jordan@example.com",
                harness: .claudeCode,
                windows: [window("five", hours: 5, used: 0.62, resetsIn: 2 * 3600 + 50 * 60),
                          window("week", hours: 168, used: 0.41, resetsIn: 4 * 86_400)],
                runsOutAt: ["five": now.addingTimeInterval(90 * 60)]),
            TokenUsageLimitLine(
                id: "dev", account: "jordan.dev@example.com", address: "jordan.dev@example.com",
                harness: .claudeCode,
                windows: [window("five", hours: 5, used: 0.08, resetsIn: 4 * 3600),
                          window("week", hours: 168, used: 0.29, resetsIn: 3 * 86_400)]),
            TokenUsageLimitLine(
                id: "codex", account: "jordan@example.com", address: "jordan@example.com", harness: .codex,
                windows: [window("week", hours: 168, used: 0.89, resetsIn: 2 * 86_400 + 5 * 3600)],
                runsOutAt: ["week": now.addingTimeInterval(20 * 3600)])
        ]
        let rows = breakdowns
        return TokenUsageOverview(days: days, limits: limits, updatedAt: now.addingTimeInterval(-40),
                                  rows: { rows[$0]?[$1] ?? [] })
    }
}
