import Foundation

enum AccountAuthState: String, Codable, Sendable {
    case signedIn
    case signedOut
    case actionRequired
    case unavailable
    case unknown

    var displayName: String {
        switch self {
        case .signedIn: L10n.string("Signed in")
        case .signedOut: L10n.string("Signed out")
        case .actionRequired: L10n.string("Action required")
        case .unavailable: L10n.string("Runtime unavailable")
        case .unknown: L10n.string("Unknown")
        }
    }
}

enum UsageEvidenceKind: String, Codable, Sendable {
    case exactQuota
    case accountUsage
    case localSession
    case notExposed

    var displayName: String {
        switch self {
        case .exactQuota: L10n.string("Provider quota")
        case .accountUsage: L10n.string("Account usage")
        case .localSession: L10n.string("Local session usage")
        case .notExposed: L10n.string("Usage not exposed by CLI")
        }
    }
}

struct AccountUsageMetric: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let label: String
    let usedFraction: Double?
    let detail: String
    let resetsAt: Date?
    let evidence: UsageEvidenceKind
    /// How long the limit's window runs, when the provider said; readings remembered before it was
    /// kept have none until the next check.
    var windowMinutes: Double? = nil
    /// The one model a limit covers (Claude's per-model weekly limit); nil covers every model.
    var model: String? = nil
}

/// The banked resets of an account's plan limits, as its harness reported them beside the limits
/// (Codex: `rateLimitResetCredits` in `account/rateLimits/read`). Using one restores the limits the
/// reset covers at once; only the person uses one, after confirming it.
struct AccountUsageResets: Codable, Equatable, Sendable {
    struct Reset: Codable, Equatable, Sendable {
        /// The harness's opaque name for the reset, which a use passes back. Not remembered between
        /// launches.
        var id: String?
        /// The harness's own name for it ("Full reset"), when it gave one.
        var title: String?
        var expiresAt: Date?
    }

    var availableCount: Int
    /// The available resets the harness listed, soonest to expire first. It may list fewer than it
    /// counts.
    var resets: [Reset] = []
    /// Where the provider sells an immediate reset, for a plan it sells one to. Yardlet only opens
    /// the page; paying happens there.
    var purchaseURL: URL? = nil
    /// The usage rows (`AccountUsageMetric.id`) a reset restores; empty when the harness did not say.
    var restores: [String] = []

    /// The reset a use takes: the one that expires first.
    var next: Reset? { resets.first }
}

/// What the harness answered when the person used a reset.
enum AccountUsageResetOutcome: Equatable, Sendable {
    /// A reset was used and the limits it covers were restored. An attempt the harness had already
    /// completed (a retry after an answer that did not arrive) counts the same.
    case reset
    /// No limit was close enough to its cap for a reset to restore anything; none was used.
    case nothingToReset
    /// The account had no reset left.
    case noResets
}

/// The words for an account's resets, the same beside its limits, on a limit card and in the Usage
/// lines.
enum UsageResetText {
    static func available(_ count: Int) -> String {
        count == 1 ? L10n.string("1 reset available") : L10n.format("%lld resets available", Int64(count))
    }

    static func left(afterUse resets: AccountUsageResets) -> String {
        let left = max(0, resets.availableCount - 1)
        if left == 0 { return L10n.string("No resets left after this one") }
        return left == 1 ? L10n.string("1 reset left after this one")
            : L10n.format("%lld resets left after this one", Int64(left))
    }

    static func answer(_ state: UsageResetState) -> String? {
        switch state {
        case .using: return nil
        case let .answered(.reset, left):
            guard let left else { return L10n.string("Usage limits reset.") }
            if left == 0 { return L10n.string("Usage limits reset. No resets left.") }
            return left == 1 ? L10n.string("Usage limits reset. 1 reset left.")
                : L10n.format("Usage limits reset. %lld resets left.", Int64(left))
        case .answered(.nothingToReset, _):
            return L10n.string("Your usage doesn't need a reset right now. No reset was used.")
        case .answered(.noResets, _):
            return L10n.string("No resets are available.")
        case let .failed(message):
            return L10n.format("Couldn't reset usage: %@", message)
        }
    }

    /// "Full reset · Expires Oct 30, 3:59 AM".
    static func reset(_ reset: AccountUsageResets.Reset) -> String {
        let title = reset.title ?? L10n.string("Usage reset")
        guard let expiresAt = reset.expiresAt else { return title }
        return title + " · " + L10n.format("Expires %@", expiresAt.formatted(date: .abbreviated, time: .shortened))
    }
}

enum AccountUsageResetError: LocalizedError, Equatable {
    /// The account's harness offers no call that uses a reset.
    case unsupported
    /// The harness answered with an outcome Yardlet does not know; whether a reset was used is
    /// unknown, so the attempt can be sent again as it was.
    case unrecognizedAnswer

    var errorDescription: String? {
        switch self {
        case .unsupported: L10n.string("This account's harness can't use a reset from Yardlet.")
        case .unrecognizedAnswer: L10n.string("The harness gave an answer Yardlet doesn't know.")
        }
    }
}

/// A stable, provider-labelled row for the account-wide usage surface. Rate-limit
/// windows stay attached to their harness card; only provider-reported account
/// history is promoted into this overview so the UI cannot imply that lifetime
/// usage is a quota fraction.
struct AccountUsageOverviewRow: Identifiable, Equatable, Sendable {
    let sourceID: String
    let harness: HarnessKind
    let metric: AccountUsageMetric

    var id: String { "\(sourceID):\(metric.id)" }
}

enum AccountUsageOverviewProjection {
    static func rows(from snapshots: [HarnessAccountSnapshot]) -> [AccountUsageOverviewRow] {
        snapshots
            .flatMap { snapshot in
                snapshot.usage
                    .filter { $0.evidence == .accountUsage }
                    .map {
                        AccountUsageOverviewRow(
                            sourceID: snapshot.id,
                            harness: snapshot.harness,
                            metric: $0
                        )
                    }
            }
            .sorted {
                let leftHarness = $0.harness.displayName
                let rightHarness = $1.harness.displayName
                if leftHarness != rightHarness { return leftHarness < rightHarness }
                if $0.metric.label != $1.metric.label {
                    return $0.metric.label < $1.metric.label
                }
                return $0.id < $1.id
            }
    }
}

/// A read-only projection of the exact usage that the selected task's runtime
/// reported. This is intentionally separate from account quota/history rows:
/// task-local token counts must never be presented as subscription quota.
struct LocalSessionUsageOverview: Equatable, Sendable {
    let sessionID: UUID
    let taskTitle: String
    let harness: HarnessKind
    let metrics: [AccountUsageMetric]
}

enum LocalSessionUsageProjection {
    static func overview(
        session: SessionRecord?,
        state: CodexTaskState?
    ) -> LocalSessionUsageOverview? {
        guard let session,
              session.harness == .codex,
              let usage = state?.thread?.turns.reversed().compactMap(\.tokenUsage).first,
              !usageMetrics(for: usage).isEmpty else {
            return nil
        }
        return LocalSessionUsageOverview(
            sessionID: session.id,
            taskTitle: session.title,
            harness: session.harness,
            metrics: usageMetrics(for: usage)
        )
    }

    private static func usageMetrics(for usage: CodexThreadTokenUsage) -> [AccountUsageMetric] {
        var metrics = [
            metric(id: "local-last-total", label: "Last turn", value: usage.last.totalTokens),
            metric(id: "local-cumulative-total", label: "Cumulative", value: usage.total.totalTokens),
            metric(id: "local-last-input", label: "Input", value: usage.last.inputTokens),
            metric(id: "local-last-cached-input", label: "Cached input", value: usage.last.cachedInputTokens)
        ]
        if let cacheHitFraction = usage.last.cacheHitFraction {
            metrics.append(AccountUsageMetric(
                id: "local-last-cache-hit",
                label: L10n.string("Cache hit"),
                usedFraction: nil,
                detail: L10n.format("%.1f%% of input", cacheHitFraction * 100),
                resetsAt: nil,
                evidence: .localSession
            ))
        }
        metrics.append(contentsOf: [
            metric(id: "local-last-cache-write", label: "Cache write", value: usage.last.cacheWriteInputTokens),
            metric(id: "local-last-output", label: "Output", value: usage.last.outputTokens),
            metric(id: "local-last-reasoning", label: "Reasoning", value: usage.last.reasoningOutputTokens)
        ])
        if let contextWindow = usage.modelContextWindow {
            metrics.append(
                metric(id: "local-context-window", label: "Context window", value: contextWindow)
            )
        }
        return metrics
    }

    private static func metric(
        id: String,
        label: String,
        value: Int64
    ) -> AccountUsageMetric {
        AccountUsageMetric(
            id: id,
            label: L10n.string(label),
            usedFraction: nil,
            detail: L10n.format("%lld tokens", value),
            resetsAt: nil,
            evidence: .localSession
        )
    }
}

struct HarnessAccountSnapshot: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let harness: HarnessKind
    let providerID: String?
    let state: AccountAuthState
    let accountLabel: String?
    /// The organization a runtime reported alongside the account label, when it
    /// publishes one. Two organizations sharing an address are separate accounts.
    let accountOrganization: String?
    /// A display-ready plan or subscription line the runtime reported. Optional so
    /// older stored snapshots keep decoding unchanged.
    let accountPlan: String?
    let detail: String
    let credentialOwner: String
    let checkedAt: Date
    let usage: [AccountUsageMetric]
    /// The resets of the plan limits the account holds, when its harness reports them.
    let usageResets: AccountUsageResets?
    let canLogin: Bool
    let canLogout: Bool

    init(
        id: String,
        harness: HarnessKind,
        providerID: String?,
        state: AccountAuthState,
        accountLabel: String?,
        accountOrganization: String? = nil,
        accountPlan: String? = nil,
        detail: String,
        credentialOwner: String,
        checkedAt: Date,
        usage: [AccountUsageMetric],
        usageResets: AccountUsageResets? = nil,
        canLogin: Bool,
        canLogout: Bool
    ) {
        self.id = id
        self.harness = harness
        self.providerID = providerID
        self.state = state
        self.accountLabel = accountLabel
        self.accountOrganization = accountOrganization
        self.accountPlan = accountPlan
        self.detail = detail
        self.credentialOwner = credentialOwner
        self.checkedAt = checkedAt
        self.usage = usage
        self.usageResets = usageResets
        self.canLogin = canLogin
        self.canLogout = canLogout
    }

    /// The same reading with other usage rows, as when a session reported its limits between
    /// checks. When the account was last checked stays as it was.
    func replacingUsage(_ usage: [AccountUsageMetric]) -> HarnessAccountSnapshot {
        HarnessAccountSnapshot(id: id, harness: harness, providerID: providerID, state: state,
            accountLabel: accountLabel, accountOrganization: accountOrganization, accountPlan: accountPlan,
            detail: detail, credentialOwner: credentialOwner, checkedAt: checkedAt, usage: usage,
            usageResets: usageResets, canLogin: canLogin, canLogout: canLogout)
    }

    static func unavailable(for descriptor: HarnessDescriptor) -> HarnessAccountSnapshot {
        HarnessAccountSnapshot(
            id: descriptor.id == .pi ? "pi:openai-codex" : descriptor.id.rawValue,
            harness: descriptor.id,
            providerID: descriptor.id == .pi ? "openai-codex" : nil,
            state: .unavailable,
            accountLabel: nil,
            detail: L10n.string("Choose or install a runtime first."),
            credentialOwner: descriptor.displayName,
            checkedAt: Date(),
            usage: [],
            canLogin: false,
            canLogout: false
        )
    }
}

/// Keeps product-account language separate from multi-provider harness configuration.
/// Multi-provider harnesses own independent provider credentials, so `signedIn`/`signedOut`
/// remain transport states while the UI presents them as connected/not connected.
enum AccountConnectionPresentation {
    static func usesProviderLanguage(_ harness: HarnessKind) -> Bool {
        harness == .openCode || harness == .pi || harness == .hermes
    }

    static func status(for snapshot: HarnessAccountSnapshot) -> String {
        guard usesProviderLanguage(snapshot.harness) else {
            return snapshot.state.displayName
        }
        switch snapshot.state {
        case .signedIn:
            return L10n.string("Provider connected")
        case .signedOut:
            return L10n.string("Provider not connected")
        case .actionRequired:
            return L10n.string("Provider action required")
        case .unavailable:
            return snapshot.state.displayName
        case .unknown:
            return L10n.string("Provider status unknown")
        }
    }

    static func connectAction(for harness: HarnessKind) -> String {
        usesProviderLanguage(harness)
            ? L10n.string("Connect provider")
            : L10n.string("Sign in")
    }

    static func disconnectAction(for harness: HarnessKind) -> String {
        usesProviderLanguage(harness)
            ? L10n.string("Disconnect provider")
            : L10n.string("Sign out")
    }

    static func providerBadge(for harness: HarnessKind) -> String {
        L10n.string("Runtime-owned")
    }

    static func providerTitle(for harness: HarnessKind) -> String {
        switch harness {
        case .hermes:
            L10n.string("Hermes provider setup")
        default:
            L10n.string("Provider settings")
        }
    }

    static func providerDescription(for harness: HarnessKind) -> String {
        switch harness {
        case .hermes:
            L10n.string(
                "Choose a provider in Hermes. Authentication and billing remain owned by that provider."
            )
        default:
            L10n.string(
                "Choose a model provider and account using this harness’s own authentication."
            )
        }
    }
}

/// Combines the visible account-card fields into one stable VoiceOver value without exposing
/// credential material or changing the runtime-owned login boundary.
enum AccountAccessibilityProjection {
    static func value(for snapshot: HarnessAccountSnapshot?) -> String {
        guard let snapshot else {
            return L10n.string("Checking account status…")
        }
        var parts = [AccountConnectionPresentation.status(for: snapshot)]
        if let accountLabel = snapshot.accountLabel,
           !accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(accountLabel)
        }
        parts.append(snapshot.detail)
        if let providerID = snapshot.providerID, !providerID.isEmpty {
            parts.append(providerID)
        }
        if !snapshot.credentialOwner.isEmpty {
            parts.append(L10n.format("Stored by: %@", snapshot.credentialOwner))
        }
        return parts
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: ", ")
    }
}

/// Collapses a quota or account-history metric into one localized VoiceOver value. The visual
/// progress bar is deliberately not the only source of meaning: evidence, textual detail, and a
/// reset time (when exposed by the runtime) stay available without exposing account credentials.
enum AccountUsageAccessibilityProjection {
    static func value(for metric: AccountUsageMetric) -> String {
        var parts = [metric.evidence.displayName, metric.detail]
        if let resetsAt = metric.resetsAt {
            parts.append(L10n.format(
                "Resets %@",
                resetsAt.formatted(date: .abbreviated, time: .shortened)
            ))
        }
        return parts
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: ", ")
    }
}

enum AccountConnectionOperation: Equatable, Sendable {
    case connect
    case disconnect
}

enum AccountConnectionInteraction: Equatable, Sendable {
    /// The runtime can complete through a browser/device handoff. Yardlet keeps the
    /// terminal mounted as a hidden transport and exposes it only as diagnostics.
    case guided
    /// The runtime owns a picker or prompt that cannot be represented safely from a
    /// stable machine-readable contract. Yardlet asks the user to reveal that UI.
    case terminalRequired
}

enum AccountConnectionPhase: Equatable, Sendable {
    case preparing
    case browserHandoff
    case inputRequired
    case completed
    case failed
    case cancelled
}

struct AccountInteractiveCommand: Sendable {
    let executableURL: URL
    let arguments: [String]
    let initialInput: String?
    let initialInputTrigger: String?
    let usesPseudoTerminal: Bool
    let environment: [String: String]
    let startupMessage: String?
    let operation: AccountConnectionOperation
    let interaction: AccountConnectionInteraction

    init(
        executableURL: URL,
        arguments: [String],
        initialInput: String?,
        initialInputTrigger: String? = nil,
        usesPseudoTerminal: Bool = false,
        environment: [String: String] = [:],
        startupMessage: String? = nil,
        operation: AccountConnectionOperation = .connect,
        interaction: AccountConnectionInteraction = .guided
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.initialInput = initialInput
        self.initialInputTrigger = initialInputTrigger
        self.usesPseudoTerminal = usesPseudoTerminal
        self.environment = environment
        self.startupMessage = startupMessage
        self.operation = operation
        self.interaction = interaction
    }
}
