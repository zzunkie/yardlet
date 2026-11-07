import Foundation

/// One selectable runtime-owned identity. Native choices keep a nil binding;
/// showing an existing login must never migrate or duplicate its credentials.
struct AccountChoice: Identifiable, Equatable {
    let harness: HarnessKind
    let connection: ProviderConnection?
    let snapshot: HarnessAccountSnapshot?
    /// The account this choice reported when it was last checked, until it reports again.
    var knownLabel: String? = nil

    var id: String { connection?.id ?? Self.nativeID(for: harness) }
    static func nativeID(for harness: HarnessKind) -> String { "native:\(harness.rawValue)" }
    /// Prefers the account display name so a harness connection is labelled by the
    /// account it uses. The binding it selects stays the harness connection. While the
    /// account is checked again, the one it last reported stands in.
    var title: String {
        if let label = snapshot?.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        return (snapshot?.state == .signedOut ? nil : knownLabel) ?? identity.displayLabel
    }
    /// The organization beside the address in an account row: a team's name, or "Personal" for
    /// the address's own (`AccountIdentityProjection.organizationTitle`).
    var organizationTitle: String? {
        AccountIdentityProjection.organizationTitle(snapshot?.accountOrganization, of: snapshot?.accountLabel)
    }
    /// How a composer's account control names the account a new task starts on: the account,
    /// or what keeps it from being chosen, or that it is still being checked.
    var composerTitle: String {
        guard canSelect else { return status }
        if snapshot == nil, knownLabel == nil, connection == nil { return L10n.string("Checking account…") }
        return title
    }
    /// How this row names itself under an account block: the connection the user
    /// saved, instead of repeating the account name from the block header. A saved
    /// name that is the account name itself falls back to the harness, as the default row does.
    var connectionTitle: String {
        guard let name = connection?.name,
              name.caseInsensitiveCompare(identity.displayLabel) != .orderedSame else { return harness.displayName }
        return name
    }
    /// The folder a saved connection keeps its login in, as short as tells it apart: a folder named
    /// by a UUID (Session Switch names its account folders so) by its first eight characters. Nil
    /// for the default login.
    var folderName: String? {
        guard let path = connection?.homePath, !path.isEmpty else { return nil }
        let name = URL(filePath: path).lastPathComponent
        return UUID(uuidString: name) != nil ? String(name.prefix(8)) : name
    }
    var subtitle: String {
        let provider = connection?.providerID ?? snapshot?.providerID
        guard let provider else { return harness.displayName }
        return "\(harness.displayName) · \(ProviderConnection.providerDisplayName(provider))"
    }
    var quotas: [AccountUsageMetric] { snapshot?.usage.filter { $0.evidence == .exactQuota } ?? [] }
    var needsProvider: Bool { harness == .pi && snapshot?.state == .unknown && snapshot?.providerID == nil && connection?.providerID == nil }
    // A missing saved login does not rule out CLI-owned API keys or external providers.
    // Preserve runtime authentication semantics; only unavailable bindings block selection.
    var canSelect: Bool { snapshot?.state != .unavailable && snapshot?.state != .actionRequired }
    var needsLogin: Bool { needsProvider || snapshot?.state == .signedOut || snapshot?.state == .actionRequired }
    var status: String {
        guard let snapshot else { return L10n.string("Checking account…") }
        switch snapshot.state {
        case .signedIn: return L10n.string("Connected")
        case .signedOut:
            return L10n.string(AccountConnectionPresentation.usesProviderLanguage(harness) ? "No saved connection" : "Not signed in")
        case .unavailable: return L10n.string("Runtime unavailable")
        case .actionRequired: return L10n.string("Account needs attention")
        case .unknown:
            if harness == .pi, snapshot.providerID == nil { return L10n.string("Choose provider") }
            return L10n.string("Status not verified")
        }
    }
    var usageUnavailableText: String {
        guard let snapshot else { return L10n.string("Checking account…") }
        if snapshot.state != .signedIn { return status }
        return L10n.string("Quota not reported")
    }
}

enum AccountChoiceProjection {
    static func choices(harnesses: [HarnessKind], connections: [ProviderConnection],
                        defaults: [HarnessKind: HarnessAccountSnapshot], snapshots: [String: HarnessAccountSnapshot],
                        knownLabels: [String: String] = [:]) -> [AccountChoice] {
        harnesses.flatMap { harness in
            let stored = connections.filter { $0.harness == harness }
            // A default login the runtime reports as signed out is not an account to choose once
            // saved accounts exist for this harness (Session Switch account folders leave `~/.claude`
            // without a login, for example). It stays, with its sign-in, when every saved account has
            // been read and none is signed in, so the list always holds something a task can start on.
            let native = defaults[harness]?.state != .signedOut
                || stored.allSatisfy { snapshots[$0.id].map { $0.state != .signedIn } ?? false }
                ? [AccountChoice(harness: harness, connection: nil, snapshot: defaults[harness],
                                 knownLabel: knownLabels[AccountChoice.nativeID(for: harness)])] : []
            return native + stored.map {
                AccountChoice(harness: harness, connection: $0, snapshot: snapshots[$0.id], knownLabel: knownLabels[$0.id])
            }
        }
    }
}

/// The account chip's words, projected from the host's current saved readings without starting a check.
struct ProviderConnectionDisplay {
    let title: String
    let accessibilityTitle: String

    init(choice: AccountChoice?, automatic: Bool = false) {
        title = automatic ? L10n.string("Automatic") : choice?.composerTitle ?? L10n.string("Account unavailable")
        accessibilityTitle = automatic ? L10n.string("Automatic") : choice?.title ?? L10n.string("Account unavailable")
    }
}
