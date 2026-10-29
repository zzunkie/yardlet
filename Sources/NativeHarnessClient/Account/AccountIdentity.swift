import Foundation

/// One account as the user owns it: a model provider plus whatever identity that
/// provider reported. Quota belongs here rather than to a harness, so the same
/// ChatGPT account driven by two harnesses shows one usage block.
///
/// The value is derived only from what a harness already published. It reads no
/// credential, and it never moves a binding: saved connections and new-task
/// selection stay per harness connection.
struct AccountIdentity: Hashable, Sendable {
    /// Normalized provider key ("openai-codex", "anthropic", …), or a
    /// harness-scoped token when the runtime names no provider.
    let provider: String
    /// Stable identifier inside that provider. When the runtime exposes no
    /// account identification this is the connection itself, so one connection
    /// remains exactly one account.
    let accountKey: String
    let displayLabel: String
    let planLabel: String?
    /// False when the runtime exposed no account identification. Such an account
    /// keeps an explicit unknown identity instead of borrowing another's label.
    let isIdentified: Bool

    var id: String { provider + "\u{1F}" + accountKey }

    /// The provider name for the account row. Unidentified harness-scoped keys
    /// have no provider to name, so the caller falls back to harness language.
    var providerDisplayName: String? {
        guard !provider.hasPrefix(AccountIdentityProjection.harnessScopePrefix) else { return nil }
        return ProviderConnection.providerDisplayName(provider)
    }
}

enum AccountIdentityProjection {
    static let harnessScopePrefix = "harness:"
    private static let connectionScopePrefix = "connection:"

    /// Collapses spelling differences between runtimes that name the same provider.
    /// ChatGPT OAuth and an OpenAI API key stay distinct: they are separate
    /// authentication routes with separate limits.
    static func normalizedProvider(_ providerID: String?) -> String? {
        guard let value = providerID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-"),
              !value.isEmpty,
              value.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil else { return nil }
        switch value {
        case "chatgpt", "openai-chatgpt": return "openai-codex"
        case "claude", "claude.ai", "claude-ai": return "anthropic"
        case "copilot": return "github-copilot"
        case "gemini", "google-gemini": return "google"
        default: return value
        }
    }

    /// The provider a harness supplies when neither its snapshot nor its saved
    /// connection names one. Only single-service harnesses have one; every
    /// multi-provider runtime stays harness-scoped so unrelated CLIs never merge.
    static func defaultProvider(for harness: HarnessKind) -> String? {
        switch harness {
        case .codex: "openai-codex"
        case .claudeCode: "anthropic"
        default: nil
        }
    }

    /// The account-identifying value a snapshot exposes, if any. Runtimes publish an
    /// account label only when they actually read one.
    static func accountKey(snapshot: HarnessAccountSnapshot?) -> String? {
        accountKey(label: snapshot?.accountLabel, organization: snapshot?.accountOrganization)
    }

    static func accountKey(label: String?, organization: String?) -> String? {
        guard let label = label?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !label.isEmpty else { return nil }
        if let organization = organization?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !organization.isEmpty {
            return label + "\u{1F}org:" + organization
        }
        return label
    }

    /// The organization an account belongs to when it is not the person's own. claude.ai names a
    /// personal account's organization "<email>'s Organization", which only repeats the address; a
    /// team's ("Example Team") tells one address's two accounts apart.
    static func sharedOrganization(_ organization: String?, of email: String?) -> String? {
        guard let organization = organization?.trimmingCharacters(in: .whitespacesAndNewlines), !organization.isEmpty
        else { return nil }
        if let email, organization.caseInsensitiveCompare("\(email)'s Organization") == .orderedSame { return nil }
        return organization
    }

    /// How an account row names the organization beside the address, so one address's personal
    /// and team accounts read apart: a team's name, or "Personal" for the address's own
    /// organization. Nil when the account reported no organization.
    static func organizationTitle(_ organization: String?, of email: String?) -> String? {
        guard let organization = organization?.trimmingCharacters(in: .whitespacesAndNewlines), !organization.isEmpty
        else { return nil }
        return sharedOrganization(organization, of: email) ?? L10n.string("Personal")
    }

    static func identity(
        harness: HarnessKind,
        connection: ProviderConnection?,
        snapshot: HarnessAccountSnapshot?,
        fallbackScope: String
    ) -> AccountIdentity {
        let provider = normalizedProvider(connection?.providerID)
            ?? normalizedProvider(snapshot?.providerID)
            ?? defaultProvider(for: harness)
        let label = snapshot?.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let provider, let accountKey = accountKey(snapshot: snapshot) {
            return AccountIdentity(
                provider: provider,
                accountKey: accountKey,
                displayLabel: label.flatMap { $0.isEmpty ? nil : $0 }
                    ?? connection?.name
                    ?? L10n.string("Current connection"),
                planLabel: snapshot?.accountPlan,
                isIdentified: true
            )
        }
        // No provider-reported identity: this connection is the account. Keep its
        // own scope so two unidentified runtimes never share one usage block.
        return AccountIdentity(
            provider: harnessScopePrefix + harness.rawValue,
            accountKey: connectionScopePrefix + fallbackScope,
            displayLabel: label.flatMap { $0.isEmpty ? nil : $0 }
                ?? connection?.name
                ?? L10n.string("Current connection"),
            planLabel: nil,
            isIdentified: false
        )
    }
}

extension HarnessAccountSnapshot {
    /// The account this snapshot belongs to, using only values the runtime already
    /// published. Storage keeps the harness connection; this is display truth.
    var accountIdentity: AccountIdentity {
        AccountIdentityProjection.identity(
            harness: harness,
            connection: nil,
            snapshot: self,
            fallbackScope: id
        )
    }
}

extension AccountChoice {
    var identity: AccountIdentity {
        AccountIdentityProjection.identity(
            harness: harness,
            connection: connection,
            snapshot: snapshot,
            fallbackScope: id
        )
    }
}

/// One usage reading under an account. Harnesses that report the same values
/// collapse into a single block; genuinely different limit sets stay separate but
/// remain under the account rather than moving back onto a harness row.
struct AccountUsageBlock: Identifiable, Equatable, Sendable {
    let id: String
    let harnesses: [HarnessKind]
    /// The connections that reported this reading, as their rows under the account name them.
    var sources: [String] = []
    /// True when every quota-reporting harness under the account reported this
    /// same reading, so the block needs no harness qualifier.
    let coversWholeAccount: Bool
    let metrics: [AccountUsageMetric]
    let checkedAt: Date?
    /// The connection under the account whose harness reported resets of these limits.
    var resetChoiceID: String? = nil

    var title: String? {
        coversWholeAccount ? nil : (sources.isEmpty ? harnesses.map(\.displayName) : sources).joined(separator: ", ")
    }
}

/// An account row plus the harness connections that authenticate with it.
struct AccountGroup: Identifiable, Equatable {
    let identity: AccountIdentity
    let choices: [AccountChoice]
    let usageBlocks: [AccountUsageBlock]

    var id: String { identity.id }

    /// The connection under the account whose harness reported resets of `block`'s limits.
    func resetChoice(for block: AccountUsageBlock) -> AccountChoice? {
        block.resetChoiceID.flatMap { id in choices.first { $0.id == id } }
    }

    var harnesses: [HarnessKind] {
        var seen: Set<HarnessKind> = []
        return choices.compactMap { seen.insert($0.harness).inserted ? $0.harness : nil }
    }

    /// Shown when no harness under this account reports quota. A connected harness
    /// without published quota is not the same as a missing connection.
    var usageUnavailableText: String {
        if let connected = choices.first(where: { $0.snapshot?.state == .signedIn }) {
            return connected.usageUnavailableText
        }
        return choices.first?.usageUnavailableText ?? L10n.string("Quota not reported")
    }

    func memberTitle(_ choice: AccountChoice) -> String {
        AccountGroupProjection.memberTitle(choice, among: choices)
    }
}

enum AccountGroupProjection {
    /// Groups selectable connections by account, preserving the order in which each
    /// account first appears so harness filtering and search keep their ordering.
    static func groups(from choices: [AccountChoice]) -> [AccountGroup] {
        var order: [String] = []
        var members: [String: [AccountChoice]] = [:]
        var identities: [String: AccountIdentity] = [:]
        for choice in choices {
            let identity = choice.identity
            if members[identity.id] == nil {
                order.append(identity.id)
                identities[identity.id] = identity
            } else if identities[identity.id]?.planLabel == nil, identity.planLabel != nil {
                identities[identity.id] = identity
            }
            members[identity.id, default: []].append(choice)
        }
        return order.compactMap { key in
            guard let identity = identities[key], let group = members[key] else { return nil }
            return AccountGroup(
                identity: identity,
                choices: group,
                usageBlocks: usageBlocks(for: group)
            )
        }
    }

    /// How a row under an account names its connection: as `connectionTitle` does, with its folder
    /// when another connection of the account would read the same (one account signed in through
    /// two folders).
    static func memberTitle(_ choice: AccountChoice, among choices: [AccountChoice]) -> String {
        let title = choice.connectionTitle
        guard choices.filter({ $0.connectionTitle == title }).count > 1 else { return title }
        return title + " · " + (choice.folderName.map { L10n.format("Folder %@", $0) } ?? L10n.string("Default login"))
    }

    /// Two harnesses reading the same account usually read the same limits. Compare
    /// the reported values rather than runtime-assigned metric ids so one account
    /// shows one block, and keep distinct readings visible instead of hiding one.
    static func usageBlocks(for choices: [AccountChoice]) -> [AccountUsageBlock] {
        var order: [String] = []
        var harnesses: [String: [HarnessKind]] = [:]
        var sources: [String: [String]] = [:]
        var metrics: [String: [AccountUsageMetric]] = [:]
        var checkedAt: [String: Date] = [:]
        var resetChoiceIDs: [String: String] = [:]
        for choice in choices {
            let quotas = choice.quotas
            guard !quotas.isEmpty else { continue }
            let key = usageKey(quotas)
            if metrics[key] == nil {
                order.append(key)
                metrics[key] = quotas
            }
            if resetChoiceIDs[key] == nil, choice.snapshot?.usageResets != nil { resetChoiceIDs[key] = choice.id }
            if !(harnesses[key]?.contains(choice.harness) ?? false) {
                harnesses[key, default: []].append(choice.harness)
            }
            let source = memberTitle(choice, among: choices)
            if !(sources[key]?.contains(source) ?? false) { sources[key, default: []].append(source) }
            if let date = choice.snapshot?.checkedAt, date > (checkedAt[key] ?? .distantPast) {
                checkedAt[key] = date
            }
        }
        let coversWholeAccount = order.count == 1
        return order.compactMap { key in
            guard let values = metrics[key] else { return nil }
            return AccountUsageBlock(
                id: key,
                harnesses: harnesses[key] ?? [],
                sources: sources[key] ?? [],
                coversWholeAccount: coversWholeAccount,
                metrics: values,
                checkedAt: checkedAt[key],
                resetChoiceID: resetChoiceIDs[key]
            )
        }
    }

    private static func usageKey(_ metrics: [AccountUsageMetric]) -> String {
        metrics.map { metric in
            [
                metric.label,
                metric.detail,
                metric.usedFraction.map { String(format: "%.6f", $0) } ?? "",
                metric.resetsAt.map { String(Int64($0.timeIntervalSince1970.rounded())) } ?? ""
            ].joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
    }
}
