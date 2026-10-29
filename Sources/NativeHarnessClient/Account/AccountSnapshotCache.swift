import Foundation

/// The last successful account reading per connection, kept so the accounts list can show it the
/// moment it opens while a new check runs. An entry holds only what the list displays: whether the
/// login was signed in, the account name the runtime reported, its organization (which separates
/// two accounts that share an address), the plan line, the limit rows, how many resets of them it
/// holds and when they expire, and when they were read. No credential, token, config path, reset ID
/// or CLI output is stored.
struct AccountSnapshotCache {
    struct Entry: Codable, Equatable, Sendable {
        let harness: HarnessKind
        let providerID: String?
        /// `signedIn` or `signedOut`: the answers a completed check gives about the login.
        let state: AccountAuthState
        let accountLabel: String?
        let accountOrganization: String?
        let accountPlan: String?
        let checkedAt: Date
        let usage: [AccountUsageMetric]
        let usageResets: AccountUsageResets?

        /// A check that completed is remembered; one that needs attention, found no runtime or
        /// could not finish has nothing to remember.
        init?(_ snapshot: HarnessAccountSnapshot) {
            guard snapshot.state == .signedIn || snapshot.state == .signedOut else { return nil }
            harness = snapshot.harness
            providerID = snapshot.providerID
            state = snapshot.state
            accountLabel = snapshot.state == .signedIn ? snapshot.accountLabel : nil
            accountOrganization = snapshot.state == .signedIn ? snapshot.accountOrganization : nil
            accountPlan = snapshot.state == .signedIn ? snapshot.accountPlan : nil
            checkedAt = snapshot.checkedAt
            usage = snapshot.state == .signedIn ? snapshot.usage.filter { $0.evidence != .localSession } : []
            // A use reads the account again first, so the reset it takes needs no remembered ID.
            usageResets = snapshot.state == .signedIn ? snapshot.usageResets.map { resets in
                AccountUsageResets(availableCount: resets.availableCount,
                    resets: resets.resets.map { AccountUsageResets.Reset(title: $0.title, expiresAt: $0.expiresAt) },
                    purchaseURL: resets.purchaseURL, restores: resets.restores)
            } : nil
        }

        /// The remembered reading as a snapshot to display. It offers no sign-in or sign-out
        /// action: those follow the next check, not a remembered one.
        func snapshot(id: String) -> HarnessAccountSnapshot {
            HarnessAccountSnapshot(
                id: id, harness: harness, providerID: providerID, state: state,
                accountLabel: accountLabel, accountOrganization: accountOrganization,
                accountPlan: accountPlan,
                detail: L10n.string(state == .signedIn
                    ? "The selected runtime reports usable authentication."
                    : "No usable runtime-owned account was found."),
                credentialOwner: HarnessCatalog.descriptor(for: harness)
                    .map { L10n.format("%@ credential store", $0.displayName) } ?? "",
                checkedAt: checkedAt, usage: usage, usageResets: usageResets, canLogin: false, canLogout: false
            )
        }
    }

    private struct File: Codable {
        var version = 1
        var entries: [String: Entry]
    }

    /// The key a default (native) login is remembered under; the same as its account choice's ID.
    static func defaultKey(for harness: HarnessKind) -> String { "native:\(harness.rawValue)" }

    let fileURL: URL?
    private(set) var entries: [String: Entry] = [:]

    /// A missing or unreadable file starts empty; the next successful check writes a new one.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data), file.version == 1 else { return }
        entries = file.entries
    }

    mutating func remember(_ snapshot: HarnessAccountSnapshot, key: String) {
        guard let entry = Entry(snapshot), entries[key] != entry else { return }
        entries[key] = entry
        write()
    }

    mutating func forget(_ key: String) {
        guard entries.removeValue(forKey: key) != nil else { return }
        write()
    }

    /// Drops entries for saved connections that no longer exist and default logins of removed
    /// harnesses.
    mutating func retain(keys: Set<String>) {
        let retired = Set(HarnessCatalog.retired.map(Self.defaultKey(for:)))
        let stale = entries.keys.filter { retired.contains($0) || (!keys.contains($0) && !$0.hasPrefix("native:")) }
        guard !stale.isEmpty else { return }
        for key in stale { entries.removeValue(forKey: key) }
        write()
    }

    private func write() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try encoder.encode(File(entries: entries)).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // A reading that cannot be remembered is still shown; the next launch checks again.
        }
    }
}

/// How current the reading an account row shows is.
enum AccountReadingStatus: Equatable, Sendable {
    /// Read by a check in this run.
    case current
    /// Remembered from an earlier run and not yet checked again.
    case remembered
    /// The latest check could not complete; the row keeps the last reading it had.
    case checkFailed
}

/// How current an account block's reading is, from the connections listed under it.
struct AccountFreshness: Equatable, Sendable {
    let checkedAt: Date?
    let status: AccountReadingStatus?
    let isChecking: Bool
}

/// The short "checked N minutes ago" line under an account.
enum AccountFreshnessProjection {
    /// The newest reading under the account. It reads as not checked only when no connection
    /// under it has a current reading; a block still waiting for its first answer has no time.
    static func freshness(
        of choices: [AccountChoice],
        status: (AccountChoice) -> AccountReadingStatus?,
        isChecking: (AccountChoice) -> Bool
    ) -> AccountFreshness {
        let statuses = choices.compactMap(status)
        let combined: AccountReadingStatus? = if statuses.isEmpty { nil }
            else if statuses.contains(.current) { .current }
            else if statuses.contains(.checkFailed) { .checkFailed }
            else { .remembered }
        return AccountFreshness(
            checkedAt: choices.compactMap { $0.snapshot?.checkedAt }.max(),
            status: combined,
            isChecking: choices.contains(where: isChecking)
        )
    }

    static func text(_ freshness: AccountFreshness, now: Date = Date()) -> String? {
        text(checkedAt: freshness.checkedAt, status: freshness.status, isChecking: freshness.isChecking, now: now)
    }

    static func text(checkedAt: Date?, status: AccountReadingStatus?, isChecking: Bool, now: Date = Date()) -> String? {
        // Without a reading the usage column already says the account is being checked.
        guard let checkedAt else { return nil }
        let age = now.timeIntervalSince(checkedAt)
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .numeric
        formatter.unitsStyle = .abbreviated
        let relative = age < 60 ? nil : formatter.localizedString(for: checkedAt, relativeTo: now)
        if status == .checkFailed, !isChecking {
            return relative.map { L10n.format("Couldn't refresh · updated %@", $0) }
                ?? L10n.string("Couldn't refresh · updated just now")
        }
        return relative.map { L10n.format("Updated %@", $0) } ?? L10n.string("Updated just now")
    }
}
