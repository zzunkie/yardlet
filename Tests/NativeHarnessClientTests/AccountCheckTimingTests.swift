import Foundation
import XCTest
@testable import NativeHarnessClient

/// How long opening the accounts list takes to show values and to finish its checks, and how many
/// CLI processes it starts, with three saved Claude accounts and a signed-out default, all
/// remembered from an earlier launch. Each scenario prints an `ACCOUNT-TIMING` line.
///
/// The suite reads through simulated CLIs (`auth status` 0.6 s, usage 0.9 s, counted as the
/// processes they stand for), so its assertions hold the scheduler's promises on a loaded machine:
/// a check already running is joined, and a reading confirmed within the last minute is kept.
/// `YARDLET_ACCOUNT_TIMING=1` also runs the same scenarios against a fake Claude CLI with the same
/// latencies, to measure how long the real scheduler takes.
@MainActor final class AccountCheckTimingTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    func testOpeningTheAccountsSectionShowsRememberedValuesAndJoinsRunningChecks() async throws {
        try await measureOpening(reader: .simulated, strict: true)
    }

    func testReopeningTheNewTaskAccountListKeepsFreshReadings() async throws {
        try await measureReopening(reader: .simulated, strict: true)
    }

    func testMeasureAgainstAFakeClaudeCLI() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["YARDLET_ACCOUNT_TIMING"] == "1",
            "Set YARDLET_ACCOUNT_TIMING=1 to time the checks against a fake Claude CLI")
        try await measureOpening(reader: .fakeCLI, strict: false)
        try await measureReopening(reader: .fakeCLI, strict: false)
    }

    private func measureOpening(reader: Reader, strict: Bool) async throws {
        for scenario in ["cold", "during-picker", "after-picker"] {
            let fixture = try makeFixture(reader)
            let store = fixture.store
            var picker: Task<Void, Never>?
            if scenario != "cold" {
                picker = Task { await self.pickerChecks(store, fixture.runtime) }
                if scenario == "after-picker" {
                    await picker?.value
                    try await Task.sleep(for: .milliseconds(200))
                } else {
                    try await Task.sleep(for: .milliseconds(150))
                }
            }
            let before = await fixture.launches()
            let start = ContinuousClock.now
            // Every row shows a reading the moment the list opens.
            let shownAtOpen = store.choices(for: [.claudeCode]).filter { $0.snapshot != nil }.count
            // What Settings › Harness Accounts runs when it opens.
            await store.check(defaultsOf: nil, savedOf: nil, runtimeSelections: fixture.runtime)
            let elapsed = ContinuousClock.now - start
            await picker?.value
            let rows = store.choices(for: [.claudeCode])
            let total = await fixture.launches()
            let launches = total - before
            print("ACCOUNT-TIMING \(reader) \(scenario): rows=\(rows.count) shownAtOpen=\(shownAtOpen) "
                + "checksDone=\(elapsed.formatted(.units(allowed: [.milliseconds]))) "
                + "launchesForOpen=\(launches) totalLaunches=\(total) "
                + "current=\(rows.filter { store.readingStatus(for: $0) == .current }.count)")
            XCTAssertEqual(shownAtOpen, 3, scenario)
            guard strict else { continue }
            XCTAssertEqual(rows.filter { store.readingStatus(for: $0) == .current }.count, 3, scenario)
            XCTAssertTrue(store.checkingKeys.isEmpty, scenario)
            switch scenario {
            case "cold":
                XCTAssertEqual(launches, 7, "One default and three saved accounts (status and usage each)")
            case "during-picker":
                XCTAssertEqual(total, 7, "The list and the chip share every check")
            default:
                XCTAssertEqual(launches, 0, "Readings the chip confirmed a moment ago are kept")
            }
        }
    }

    private func measureReopening(reader: Reader, strict: Bool) async throws {
        let fixture = try makeFixture(reader)
        let store = fixture.store
        let scope = AccountListProjection.checkScope(.newTask(.claudeCode),
            choices: AccountListProjection.choices(.newTask(.claudeCode), store: store))
        for round in 1...2 {
            let before = await fixture.launches()
            let start = ContinuousClock.now
            // What the list runs when the chip's popover opens.
            await store.check(defaultsOf: scope.defaults, savedOf: scope.saved, runtimeSelections: fixture.runtime)
            let launches = await fixture.launches() - before
            print("ACCOUNT-TIMING \(reader) popover-open-\(round): checksDone="
                + "\((ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds]))) launches=\(launches)")
            if strict { XCTAssertEqual(launches, round == 1 ? 7 : 0) }
            try await Task.sleep(for: .milliseconds(500))
        }
        // The refresh button checks again even though the readings are fresh.
        let before = await fixture.launches()
        await store.check(defaultsOf: scope.defaults, savedOf: scope.saved, policy: .refresh,
            runtimeSelections: fixture.runtime)
        if strict {
            let launches = await fixture.launches() - before
            XCTAssertEqual(launches, 7)
        }
    }

    /// What the new-task account chip runs when the home composer shows.
    private func pickerChecks(_ store: ProviderConnectionStore, _ runtime: RuntimeSelectionStore) async {
        await store.check(defaultsOf: [.claudeCode], savedOf: [], runtimeSelections: runtime)
        if store.selection[.claudeCode] == nil, store.defaultSnapshots[.claudeCode]?.state == .signedOut,
           !store.connections(for: .claudeCode).isEmpty {
            await store.check(defaultsOf: [], savedOf: [.claudeCode], runtimeSelections: runtime)
        }
    }

    private enum Reader: String, CustomStringConvertible {
        case simulated, fakeCLI
        var description: String { rawValue }
    }

    private struct Fixture {
        let store: ProviderConnectionStore
        let runtime: RuntimeSelectionStore
        let log: URL
        let simulated: SimulatedProcesses?
        /// CLI processes started so far: the fake CLI's own log, or what the simulated reads stand for.
        func launches() async -> Int {
            if let simulated { return await simulated.count }
            return ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count
        }
    }

    /// Three saved Claude accounts and a signed-out default, all remembered from two hours ago.
    private func makeFixture(_ reader: Reader) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "account-timing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        let files = (root.appending(path: "provider-connections.json"),
                     root.appending(path: ProviderConnectionStore.snapshotCacheFileName))
        let earlier = ProviderConnectionStore(fileURL: files.0, snapshotCacheURL: files.1)
        for email in ["developer@example.test", "jordan@example.test", "personal@example.test"] {
            let home = root.appending(path: email)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try Data(email.utf8).write(to: home.appending(path: ".fake-email"))
            let connection = ProviderConnection(id: email, name: email, harness: .claudeCode, providerID: nil,
                homePath: home.path, credentialSelector: nil)
            try earlier.save(connection)
            earlier.publish(HarnessAccountSnapshot(id: email, harness: .claudeCode, providerID: nil, state: .signedIn,
                accountLabel: email, detail: "", credentialOwner: "", checkedAt: Date().addingTimeInterval(-7_200),
                usage: [AccountUsageMetric(id: "s", label: "5 hour limit", usedFraction: 0.5, detail: "50% remaining",
                    resetsAt: nil, evidence: .exactQuota)], canLogin: false, canLogout: true), for: connection)
        }
        earlier.publishDefaults([HarnessAccountSnapshot(id: "claude-code", harness: .claudeCode, providerID: nil,
            state: .signedOut, accountLabel: nil, detail: "", credentialOwner: "",
            checkedAt: Date().addingTimeInterval(-7_200), usage: [], canLogin: true, canLogout: false)])
        // Answers only for account folders inside this fixture; any other folder is signed out.
        let cli = root.appending(path: "claude")
        let log = root.appending(path: "launches.log")
        try Data("""
        #!/bin/sh
        root='\(root.path)'
        echo "$1" >> "$root/launches.log"
        email=''
        case "$CLAUDE_CONFIG_DIR" in "$root"/*) email=$(cat "$CLAUDE_CONFIG_DIR/.fake-email" 2>/dev/null) ;; esac
        if [ "$1" = "auth" ]; then
          sleep 0.6
          if [ -z "$email" ]; then echo '{"loggedIn":false}'; exit 0; fi
          printf '{"loggedIn":true,"email":"%s","subscriptionType":"max"}\\n' "$email"
          exit 0
        fi
        read first; read second
        sleep 0.9
        echo '{"type":"control_response","response":{"subtype":"success","request_id":"init","response":{}}}'
        echo '{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"rate_limits_available":true,"rate_limits":{"limits":[{"kind":"session","group":"session","percent":25},{"kind":"weekly_all","group":"weekly","percent":40}]}}}}'
        sleep 30
        """.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let suite = testDefaultsSuite("yardlet-account-timing")
        let runtime = RuntimeSelectionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)),
            discoversRuntimes: false, loadsPersistedSelections: false)
        runtime.select(cli, for: .claudeCode)
        guard reader == .simulated else {
            return Fixture(store: ProviderConnectionStore(fileURL: files.0, snapshotCacheURL: files.1),
                runtime: runtime, log: log, simulated: nil)
        }
        // The same answers and latencies without processes: a default login's `auth status`, and a
        // saved account's `auth status` followed by its usage probe.
        let simulated = SimulatedProcesses()
        let store = ProviderConnectionStore(fileURL: files.0, snapshotCacheURL: files.1,
            defaultLoader: { descriptor, executable in
                guard descriptor.id == .claudeCode, executable != nil else { return .unavailable(for: descriptor) }
                await simulated.start(1)
                try? await Task.sleep(for: .milliseconds(600))
                return HarnessAccountSnapshot(id: "claude-code", harness: .claudeCode, providerID: nil,
                    state: .signedOut, accountLabel: nil, detail: "", credentialOwner: "", checkedAt: Date(),
                    usage: [], canLogin: true, canLogout: false)
            },
            connectionLoader: { connection, _ in
                await simulated.start(2)
                try? await Task.sleep(for: .milliseconds(1_500))
                return HarnessAccountSnapshot(id: connection.id, harness: .claudeCode, providerID: nil,
                    state: .signedIn, accountLabel: connection.name, detail: "", credentialOwner: "",
                    checkedAt: Date(), usage: [AccountUsageMetric(id: "s", label: "5 hour limit", usedFraction: 0.25,
                        detail: "75% remaining", resetsAt: nil, evidence: .exactQuota)],
                    canLogin: false, canLogout: true)
            })
        return Fixture(store: store, runtime: runtime, log: log, simulated: simulated)
    }
}

private actor SimulatedProcesses {
    private(set) var count = 0
    func start(_ processes: Int) { count += processes }
}
