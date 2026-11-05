import XCTest
@testable import NativeHarnessClient

/// The accounts list shows each account's last completed reading the moment it opens, and a check
/// running behind it replaces the reading when its answer arrives.
@MainActor final class AccountSnapshotCacheTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    func testTheCacheHoldsOnlyWhatTheListShowsAndRestoresItAtLaunch() throws {
        let root = try directory()
        let home = try accountHome(in: root, email: "first@example.test")
        let connection = claude(home)
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let first = store(root)
        try first.save(connection)
        first.publish(signedIn(email: "first@example.test", checkedAt: checkedAt, usage: [
            quota("five-hour", used: 0.16, resetsAt: Date(timeIntervalSince1970: 1_800_010_000)),
            quota("seven-day", used: 0.06, resetsAt: nil),
            AccountUsageMetric(id: "local", label: "Last turn", usedFraction: nil, detail: "120 tokens",
                resetsAt: nil, evidence: .localSession)
        ]), for: connection)
        first.publishDefaults([HarnessAccountSnapshot(id: "codex", harness: .codex, providerID: "openai-codex",
            state: .signedIn, accountLabel: "codex@example.test", accountPlan: "ChatGPT Pro",
            detail: "Signed in through the official App Server", credentialOwner: "Codex auth.json",
            checkedAt: checkedAt, usage: [quota("primary", used: 0.01, resetsAt: nil)],
            canLogin: false, canLogout: true)])

        let cacheURL = root.appending(path: ProviderConnectionStore.snapshotCacheFileName)
        StateFileWriter.shared.flush()
        let attributes = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let text = try String(contentsOf: cacheURL, encoding: .utf8)
        for hidden in [home.path, "Signed in through", "auth.json", "credential", "120 tokens", "canLogout"] {
            XCTAssertFalse(text.contains(hidden), "The cache must not hold \(hidden)")
        }
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(Set(file.keys), ["version", "entries"])
        let entries = try XCTUnwrap(file["entries"] as? [String: [String: Any]])
        XCTAssertEqual(Set(entries.keys), [connection.id, "native:codex"])
        XCTAssertEqual(Set(try XCTUnwrap(entries[connection.id]).keys),
            ["harness", "state", "accountLabel", "accountOrganization", "accountPlan", "checkedAt", "usage"])
        XCTAssertEqual(Set(try XCTUnwrap(entries["native:codex"]).keys),
            ["harness", "providerID", "state", "accountLabel", "accountPlan", "checkedAt", "usage"])
        let rows = try XCTUnwrap(entries[connection.id]?["usage"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2, "A task's own token counts are not an account reading")
        for row in rows {
            XCTAssertTrue(Set(row.keys).isSubset(of: ["id", "label", "usedFraction", "detail", "resetsAt", "evidence"]))
        }

        // The next launch shows both readings before any check runs.
        let relaunched = store(root)
        let restored = try XCTUnwrap(relaunched.snapshots[connection.id])
        XCTAssertEqual(restored.state, .signedIn)
        XCTAssertEqual(restored.accountLabel, "first@example.test")
        XCTAssertEqual(restored.accountOrganization, "Example Org")
        XCTAssertEqual(restored.accountPlan, "Claude Max plan")
        XCTAssertEqual(restored.checkedAt, checkedAt)
        XCTAssertEqual(restored.usage.map(\.usedFraction), [0.16, 0.06])
        XCTAssertEqual(restored.usage.first?.resetsAt, Date(timeIntervalSince1970: 1_800_010_000))
        XCTAssertFalse(restored.canLogin || restored.canLogout, "A remembered reading offers no account action")
        XCTAssertEqual(relaunched.defaultSnapshots[.codex]?.accountLabel, "codex@example.test")
        XCTAssertEqual(relaunched.defaultSnapshots[.codex]?.accountPlan, "ChatGPT Pro")

        let choice = try XCTUnwrap(relaunched.choices(for: [.claudeCode]).first { $0.connection == connection })
        XCTAssertEqual(relaunched.readingStatus(for: choice), .remembered)
        XCTAssertFalse(relaunched.isChecking(choice))
        let group = try XCTUnwrap(AccountGroupProjection.groups(from: [choice]).first)
        XCTAssertTrue(group.identity.isIdentified)
        XCTAssertEqual(group.identity.displayLabel, "first@example.test")
        XCTAssertEqual(group.usageBlocks.first?.metrics.count, 2)
        let freshness = AccountFreshnessProjection.freshness(of: [choice],
            status: relaunched.readingStatus(for:), isChecking: relaunched.isChecking)
        XCTAssertEqual(freshness, AccountFreshness(checkedAt: checkedAt, status: .remembered, isChecking: false))
    }

    func testARememberedReadingShowsAtOnceAndARefreshReplacesIt() async throws {
        let root = try directory()
        let home = try accountHome(in: root, email: "first@example.test")
        let connection = claude(home)
        let earlier = Date().addingTimeInterval(-2 * 3_600)
        let first = store(root)
        try first.save(connection)
        first.publish(signedIn(email: "first@example.test", checkedAt: earlier,
            usage: [quota("five-hour", used: 0.9, resetsAt: nil)]), for: connection)

        let relaunched = store(root)
        XCTAssertEqual(relaunched.snapshots[connection.id]?.usage.map(\.usedFraction), [0.9])
        XCTAssertEqual(relaunched.readingStatus[connection.id], .remembered)

        await relaunched.check(defaultsOf: [], savedOf: [.claudeCode], runtimeSelections: try runtime(fakeClaude(in: root)))
        let replaced = try XCTUnwrap(relaunched.snapshots[connection.id])
        XCTAssertEqual(replaced.state, .signedIn)
        XCTAssertEqual(replaced.accountLabel, "first@example.test")
        XCTAssertEqual(replaced.usage.map(\.usedFraction), [0.25, 0.4])
        XCTAssertGreaterThan(replaced.checkedAt, earlier)
        XCTAssertEqual(relaunched.readingStatus[connection.id], .current)
        XCTAssertTrue(relaunched.checkingKeys.isEmpty)
        XCTAssertEqual(store(root).snapshots[connection.id]?.usage.map(\.usedFraction), [0.25, 0.4],
            "The new reading is the one the next launch shows")
    }

    func testASignedOutOrUnfinishedCheckIsShownAsItIs() async throws {
        let root = try directory()
        let signedOutHome = try accountHome(in: root, email: "out@example.test")
        let brokenHome = try accountHome(in: root, email: "broken@example.test")
        let attentionHome = try accountHome(in: root, email: "gone@example.test")
        let signedOut = claude(signedOutHome)
        let broken = claude(brokenHome)
        let attention = claude(attentionHome)
        let earlier = Date().addingTimeInterval(-600)
        let first = store(root)
        for (connection, email) in [(signedOut, "out@example.test"), (broken, "broken@example.test"),
                                    (attention, "gone@example.test")] {
            try first.save(connection)
            first.publish(signedIn(email: email, checkedAt: earlier, usage: [quota("five-hour", used: 0.5, resetsAt: nil)]),
                for: connection)
        }
        try Data().write(to: signedOutHome.appending(path: ".signed-out"))
        try Data().write(to: brokenHome.appending(path: ".broken"))
        // A folder that disappeared is a binding that needs attention.
        try FileManager.default.removeItem(at: attentionHome)

        let relaunched = store(root)
        await relaunched.check(defaultsOf: [], savedOf: [.claudeCode], runtimeSelections: try runtime(fakeClaude(in: root)))

        let out = try XCTUnwrap(relaunched.snapshots[signedOut.id])
        XCTAssertEqual(out.state, .signedOut, "A signed-out answer replaces the remembered sign-in")
        XCTAssertNil(out.accountLabel)
        XCTAssertTrue(out.usage.allSatisfy { $0.evidence != .exactQuota })
        XCTAssertEqual(relaunched.readingStatus[signedOut.id], .current)

        let kept = try XCTUnwrap(relaunched.snapshots[broken.id])
        XCTAssertEqual(kept.accountLabel, "broken@example.test", "An unfinished check keeps the last reading")
        XCTAssertEqual(kept.checkedAt.timeIntervalSince1970, earlier.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(relaunched.readingStatus[broken.id], .checkFailed)
        let choice = AccountChoice(harness: .claudeCode, connection: broken, snapshot: kept)
        let freshness = AccountFreshnessProjection.freshness(of: [choice],
            status: relaunched.readingStatus(for:), isChecking: relaunched.isChecking)
        let now = Date()
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .numeric
        formatter.unitsStyle = .abbreviated
        XCTAssertEqual(AccountFreshnessProjection.text(freshness, now: now),
            L10n.format("Couldn't refresh · updated %@", formatter.localizedString(for: kept.checkedAt, relativeTo: now)))

        XCTAssertEqual(relaunched.snapshots[attention.id]?.state, .actionRequired)

        let next = store(root)
        XCTAssertEqual(next.snapshots[signedOut.id]?.state, .signedOut, "The launch after shows the sign-out")
        XCTAssertEqual(next.snapshots[broken.id]?.accountLabel, "broken@example.test")
        XCTAssertNil(next.snapshots[attention.id], "Needing attention forgets the remembered reading")
    }

    func testARememberedSignedOutDefaultStaysOutOfTheListUntilACheckSaysOtherwise() throws {
        let root = try directory()
        let connection = claude(try accountHome(in: root, email: "first@example.test"))
        let first = store(root)
        try first.save(connection)
        first.publishDefaults([HarnessAccountSnapshot(id: "claude-code", harness: .claudeCode, providerID: nil,
            state: .signedOut, accountLabel: nil, detail: "", credentialOwner: "", checkedAt: Date(), usage: [],
            canLogin: true, canLogout: false)])
        XCTAssertEqual(first.choices(for: [.claudeCode]).map(\.connection), [connection])

        let relaunched = store(root)
        XCTAssertEqual(relaunched.choices(for: [.claudeCode]).map(\.connection), [connection],
            "The default login the last check found signed out does not flash in as an unknown account")
    }

    func testFreshnessWording() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(AccountFreshnessProjection.text(checkedAt: nil, status: nil, isChecking: true, now: now))
        XCTAssertEqual(AccountFreshnessProjection.text(checkedAt: now.addingTimeInterval(-20), status: .current,
            isChecking: false, now: now), L10n.string("Updated just now"))
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .numeric
        formatter.unitsStyle = .abbreviated
        let fiveMinutes = now.addingTimeInterval(-300)
        XCTAssertEqual(AccountFreshnessProjection.text(checkedAt: fiveMinutes, status: .remembered, isChecking: true,
            now: now), L10n.format("Updated %@", formatter.localizedString(for: fiveMinutes, relativeTo: now)))
        XCTAssertEqual(AccountFreshnessProjection.text(checkedAt: fiveMinutes, status: .checkFailed, isChecking: true,
            now: now), L10n.format("Updated %@", formatter.localizedString(for: fiveMinutes, relativeTo: now)),
            "While a new check runs the line shows the time, not the last failure")
        // The Claude app's Korean usage wording for "Updated just now" and "Updated {minutes} min ago".
        XCTAssertEqual(L10n.string("Updated %@", languageCode: "ko"), "%@에 업데이트됨")
        XCTAssertEqual(L10n.string("Updated just now", languageCode: "ko"), "방금 업데이트됨")

        let current = AccountChoice(harness: .codex, connection: nil, snapshot: signedIn(email: "a@example.test",
            checkedAt: now, usage: []))
        let failed = AccountChoice(harness: .claudeCode, connection: nil, snapshot: signedIn(email: "a@example.test",
            checkedAt: now.addingTimeInterval(-60), usage: []))
        let statuses: [String: AccountReadingStatus] = [current.id: .current, failed.id: .checkFailed]
        XCTAssertEqual(AccountFreshnessProjection.freshness(of: [failed, current], status: { statuses[$0.id] },
            isChecking: { _ in false }), AccountFreshness(checkedAt: now, status: .current, isChecking: false))
        XCTAssertEqual(AccountFreshnessProjection.freshness(of: [failed], status: { statuses[$0.id] },
            isChecking: { $0.id == failed.id }).isChecking, true)
    }

    // MARK: - Helpers

    private func store(_ root: URL) -> ProviderConnectionStore {
        ProviderConnectionStore(fileURL: root.appending(path: "provider-connections.json"),
            snapshotCacheURL: root.appending(path: ProviderConnectionStore.snapshotCacheFileName))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "account-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func accountHome(in root: URL, email: String) throws -> URL {
        let home = root.appending(path: "home-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(email.utf8).write(to: home.appending(path: ".email"))
        return home
    }

    private func claude(_ home: URL) -> ProviderConnection {
        ProviderConnection(id: home.lastPathComponent, name: home.lastPathComponent, harness: .claudeCode,
            providerID: nil, homePath: home.path, credentialSelector: nil)
    }

    private func signedIn(email: String, checkedAt: Date, usage: [AccountUsageMetric]) -> HarnessAccountSnapshot {
        HarnessAccountSnapshot(id: "claude-code", harness: .claudeCode, providerID: nil, state: .signedIn,
            accountLabel: email, accountOrganization: "Example Org", accountPlan: "Claude Max plan",
            detail: "Signed in through the official CLI", credentialOwner: "Claude Code credential store",
            checkedAt: checkedAt, usage: usage, canLogin: false, canLogout: true)
    }

    private func quota(_ id: String, used: Double, resetsAt: Date?) -> AccountUsageMetric {
        AccountUsageMetric(id: id, label: id, usedFraction: used, detail: "\(Int((1 - used) * 100))% remaining",
            resetsAt: resetsAt, evidence: .exactQuota)
    }

    private func runtime(_ cli: URL) throws -> RuntimeSelectionStore {
        let suite = testDefaultsSuite("yardlet-account-cache")
        let runtime = RuntimeSelectionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)),
            discoversRuntimes: false, loadsPersistedSelections: false)
        runtime.select(cli, for: .claudeCode)
        return runtime
    }

    /// Answers `auth status` from marker files in the account folder and the usage probe's two
    /// control requests; nothing else.
    private func fakeClaude(in root: URL) throws -> URL {
        let url = root.appending(path: "claude")
        try Data(#"""
        #!/bin/sh
        if [ "$1" = "auth" ]; then
          if [ -f "$CLAUDE_CONFIG_DIR/.broken" ]; then echo 'unexpected failure'; exit 1; fi
          if [ -f "$CLAUDE_CONFIG_DIR/.signed-out" ]; then echo '{"loggedIn":false}'; exit 0; fi
          printf '{"loggedIn":true,"email":"%s","orgName":"Example Org","subscriptionType":"max"}\n' "$(cat "$CLAUDE_CONFIG_DIR/.email")"
          exit 0
        fi
        read first; read second
        echo '{"type":"control_response","response":{"subtype":"success","request_id":"init","response":{}}}'
        echo '{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"rate_limits_available":true,"rate_limits":{"limits":[{"kind":"session","group":"session","percent":25},{"kind":"weekly_all","group":"weekly","percent":40}]}}}}'
        sleep 30
        """#.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
