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

    func testUsageFailureRechecksTheLoginAndKeepsOnlyItsLastKnownQuota() async throws {
        for clearsLogin in [false, true] {
            let root = try directory()
            let home = try accountHome(in: root, email: "fixture@example.test")
            let connection = claude(home)
            let accounts = store(root)
            try accounts.save(connection)
            let lastQuotaCheck = Date().addingTimeInterval(-600)
            accounts.publish(signedIn(email: "fixture@example.test", checkedAt: lastQuotaCheck,
                usage: [quota("session", used: 0.75, resetsAt: nil)]), for: connection)
            try Data().write(to: home.appending(path: ".usage-error"))
            if clearsLogin { try Data().write(to: home.appending(path: ".clear-on-usage")) }
            await accounts.check(defaultsOf: [], savedOf: [.claudeCode], policy: .refresh,
                                 runtimeSelections: try runtime(fakeClaude(in: root)))
            let calls = try String(contentsOf: home.appending(path: "calls"), encoding: .utf8)
            XCTAssertEqual(calls.split(whereSeparator: \.isNewline), ["auth", "-p", "auth"])
            let reading = try XCTUnwrap(accounts.snapshots[connection.id])
            XCTAssertEqual(reading.state, clearsLogin ? .signedOut : .signedIn)
            XCTAssertEqual(reading.usage.compactMap(\.usedFraction), clearsLogin ? [] : [0.75])
            XCTAssertEqual(reading.canLogin, clearsLogin)
            if !clearsLogin { XCTAssertEqual(reading.checkedAt, lastQuotaCheck) }
            XCTAssertEqual(store(root).snapshots[connection.id]?.loginExpiresAt, reading.loginExpiresAt)
            XCTAssertEqual(reading.loginExpiresAt != nil, !clearsLogin)
        }
    }

    func testColdUsageFailureCanRetryAndAnAccountWithoutLimitsFinishesNormally() async throws {
        let root = try directory()
        let home = try accountHome(in: root, email: "fixture@example.test")
        let account = claude(home)
        let accounts = store(root)
        try accounts.save(account)
        let runtime = try runtime(fakeClaude(in: root))
        let error = home.appending(path: ".usage-error")
        try Data().write(to: error)
        await accounts.check(defaultsOf: [], savedOf: [.claudeCode], runtimeSelections: runtime)
        XCTAssertEqual(accounts.snapshots[account.id]?.state, .signedIn)
        XCTAssertEqual(accounts.snapshots[account.id]?.usageProbeFailed, true)
        XCTAssertEqual(accounts.readingStatus[account.id], .checkFailed)
        XCTAssertFalse(accounts.isFresh(account.id))
        let calls = home.appending(path: "calls")
        XCTAssertEqual(try String(contentsOf: calls, encoding: .utf8), "auth\n-p\nauth\n")

        try FileManager.default.removeItem(at: error)
        try Data().write(to: home.appending(path: ".no-limits"))
        await accounts.check(defaultsOf: [], savedOf: [.claudeCode], runtimeSelections: runtime)
        let reading = try XCTUnwrap(accounts.snapshots[account.id])
        XCTAssertEqual(reading.state, .signedIn)
        XCTAssertEqual(reading.usageProbeFailed, false)
        XCTAssertTrue(reading.usage.isEmpty)
        XCTAssertEqual(accounts.readingStatus[account.id], .current)
        XCTAssertTrue(accounts.isFresh(account.id))
        XCTAssertEqual(try String(contentsOf: calls, encoding: .utf8), "auth\n-p\nauth\nauth\n-p\n")
    }

    func testLoginExpiryWarningStartsAtTenDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(ClaudeUsageProbe.date("2030-01-01T12:00:00Z"))
        let reading = signedIn(email: "fixture@example.test", checkedAt: now, usage: [])
        XCTAssertNil(reading.expiryWarning(now: now))
        for (seconds, warning) in [(864_001, nil), (864_000, L10n.format("Sign-in expires in %lld days", Int64(10))),
                                    (86_400, L10n.string("Sign-in expires tomorrow")),
                                    (1, L10n.string("Sign-in expires today")), (0, L10n.string("Sign-in expired"))] {
            let reading = signedIn(email: "fixture@example.test", checkedAt: now, usage: [],
                loginExpiresAt: now.addingTimeInterval(TimeInterval(seconds)))
            XCTAssertEqual(reading.expiryWarning(now: now, calendar: calendar), warning)
        }
        let parsed = HarnessAccountBroker.claudeStatusFields(from: #"{"loginExpiresAt":"2030-01-01T12:00:00.125Z"}"#)
        XCTAssertEqual(parsed.loginExpiresAt, now.addingTimeInterval(0.125))
        XCTAssertNil(HarnessAccountBroker.claudeStatusFields(from: #"{"loginExpiresAt":"invalid"}"#).loginExpiresAt)

        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let beforeDST = try XCTUnwrap(ClaudeUsageProbe.date("2025-03-05T23:30:00-08:00"))
        let expiry = signedIn(email: "fixture@example.test", checkedAt: beforeDST, usage: [],
            loginExpiresAt: beforeDST.addingTimeInterval(10 * 86_400))
        XCTAssertEqual(expiry.expiryWarning(now: beforeDST, calendar: calendar),
            L10n.format("Sign-in expires in %lld days", Int64(10)))
    }

    func testCheckLogRetainsTransitionsAndHourlyHealthyReadings() throws {
        let file = try directory().appending(path: "checks.log")
        AccountCheckLog.fileURL = file
        defer { AccountCheckLog.fileURL = nil }
        let start = Date(timeIntervalSince1970: 0)
        var entry = AccountCheckLog.Entry(harness: "claude", account: "default", configHome: "default",
            state: AccountAuthState.signedIn.rawValue, exitCode: 0)
        func record(_ seconds: Int) {
            entry.milliseconds = seconds
            AccountCheckLog.record(entry, at: start.addingTimeInterval(TimeInterval(seconds)))
        }
        record(0)
        record(3599)
        record(3600)
        entry.loginExpiresAt = start
        record(3601)
        entry.usageProbeFailed = true
        record(3602)
        record(3603)
        entry.usageProbeFailed = false
        record(3604)
        entry.state = AccountAuthState.signedOut.rawValue
        record(3605)
        entry.state = AccountAuthState.signedIn.rawValue
        record(3606)
        record(3607)
        entry = AccountCheckLog.Entry(event: "turn-refused", harness: "codex", account: "default", configHome: "default")
        record(3608)
        entry = AccountCheckLog.Entry(harness: "claude", account: "default", configHome: "default",
            state: AccountAuthState.signedIn.rawValue, exitCode: 0, loginExpiresAt: start, usageProbeFailed: false)
        record(3609)
        let lines = try String(contentsOf: file, encoding: .utf8).split(whereSeparator: \.isNewline).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(lines.compactMap { $0["milliseconds"] as? Int }, [0, 3600, 3601, 3602, 3603, 3604, 3605, 3606, 3608])
        XCTAssertNil(lines.last?["usageProbeFailed"])
        XCTAssertEqual(lines[2]["loginExpiresAt"] as? String, "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(lines[3]["usageProbeFailed"] as? Bool, true)
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

    private func signedIn(email: String, checkedAt: Date, usage: [AccountUsageMetric], loginExpiresAt: Date? = nil) -> HarnessAccountSnapshot {
        HarnessAccountSnapshot(id: "claude-code", harness: .claudeCode, providerID: nil, state: .signedIn,
            accountLabel: email, accountOrganization: "Example Org", accountPlan: "Claude Max plan", loginExpiresAt: loginExpiresAt,
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
        echo "$1" >> "$CLAUDE_CONFIG_DIR/calls"
        if [ "$1" = "auth" ]; then
          if [ -f "$CLAUDE_CONFIG_DIR/.broken" ]; then echo 'unexpected failure'; exit 1; fi
          if [ -f "$CLAUDE_CONFIG_DIR/.signed-out" ]; then echo '{"loggedIn":false}'; exit 0; fi
          printf '{"loggedIn":true,"email":"%s","orgName":"Example Org","subscriptionType":"max","loginExpiresAt":"2030-01-01T12:00:00Z"}\n' "$(cat "$CLAUDE_CONFIG_DIR/.email")"
          exit 0
        fi
        read first; read second
        if [ -f "$CLAUDE_CONFIG_DIR/.no-limits" ]; then
          echo '{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"rate_limits_available":false}}}'
          exit 0
        fi
        if [ -f "$CLAUDE_CONFIG_DIR/.usage-error" ]; then
          [ -f "$CLAUDE_CONFIG_DIR/.clear-on-usage" ] && touch "$CLAUDE_CONFIG_DIR/.signed-out"
          echo '{"type":"control_response","response":{"subtype":"error","request_id":"usage"}}'
          exit 0
        fi
        echo '{"type":"control_response","response":{"subtype":"success","request_id":"init","response":{}}}'
        echo '{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"rate_limits_available":true,"rate_limits":{"limits":[{"kind":"session","group":"session","percent":25},{"kind":"weekly_all","group":"weekly","percent":40}]}}}}'
        sleep 30
        """#.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
