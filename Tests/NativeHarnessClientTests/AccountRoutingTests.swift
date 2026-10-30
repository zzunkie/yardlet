import Foundation
import XCTest
@testable import NativeHarnessClient

/// Automatic account assignment (docs/NATIVE_SESSION_STORAGE.md, "Choosing an additional account"): which accounts it may use by default and after
/// the person's answer, and the rule that picks one of them from the plan limits, their resets and
/// the tasks already running.
@MainActor final class AccountRoutingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    /// Room that a reset soon would waste counts for more: 60% left of a week that resets tomorrow beats
    /// 80% left of one that resets in six days. Tasks already running on an account spread the next ones.
    func testThePaceOfEachWindowDecidesAndRunningTasksSpreadTheStarts() throws {
        let soon = choice("soon", windows: [session(used: 0), weekly(used: 0.4, resetsIn: 1)])
        let later = choice("later", windows: [session(used: 0), weekly(used: 0.2, resetsIn: 6)])
        let pick = try XCTUnwrap(AccountRouting.pick([candidate(soon), candidate(later)], model: nil, now: now))
        XCTAssertEqual(pick.choice.id, "soon")
        XCTAssertEqual(pick.basis, .headroom)

        let busy = try XCTUnwrap(AccountRouting.pick([candidate(soon, running: 2), candidate(later)], model: nil, now: now))
        XCTAssertEqual(busy.choice.id, "later", "Two tasks already on it divide its headroom by three")

        let reset = choice("reset", windows: [session(used: 1, resetsIn: -0.01), weekly(used: 0.1, resetsIn: 6)])
        XCTAssertEqual(AccountRouting.pick([candidate(reset), candidate(later)], model: nil, now: now)?.choice.id, "reset",
                       "A window whose reset has passed is full again, whatever the last reading said")
    }

    /// An account with a window at or under 10% left is chosen only when every account is, and then the
    /// one that frees up first; an account without a reading comes before the nearly spent.
    func testNearlySpentAccountsComeLastAndTheOneThatFreesUpFirstWins() throws {
        let spentSoon = choice("spent-soon", windows: [session(used: 0.95, resetsIn: 3 / 24), weekly(used: 0.1, resetsIn: 5)])
        let spentLong = choice("spent-long", windows: [session(used: 0.2), weekly(used: 0.92, resetsIn: 2)])
        let tight = choice("tight", windows: [session(used: 0.6), weekly(used: 0.5, resetsIn: 3)])
        XCTAssertEqual(AccountRouting.pick([candidate(spentSoon), candidate(spentLong), candidate(tight)],
                                           model: nil, now: now)?.choice.id, "tight")

        let unread = AccountChoice(harness: .claudeCode, connection: connection("unread"),
                                   snapshot: snapshot("unread", windows: []))
        XCTAssertEqual(AccountRouting.pick([candidate(spentSoon), candidate(unread)], model: nil, now: now)?.basis,
                       .noReading)

        let last = try XCTUnwrap(AccountRouting.pick([candidate(spentLong), candidate(spentSoon)], model: nil, now: now))
        XCTAssertEqual(last.choice.id, "spent-soon")
        XCTAssertEqual(last.basis, .nearlySpent)
        let assignment = AccountAssignment(choice: last.choice, origin: .automatic, pick: last, at: now)
        XCTAssertEqual(assignment.freesUpAt, now.addingTimeInterval(3 * 3600))
        XCTAssertEqual(assignment.usedFraction, 0.95, "The reason names the window that is nearly spent")
    }

    /// A limit of one model counts for a task on that model, and for one whose model is not known.
    func testAModelsOwnLimitCountsOnlyForThatModel() {
        let fableSpent = choice("fable-spent", windows: [session(used: 0), weekly(used: 0, resetsIn: 6),
                                                         weekly(used: 1, resetsIn: 6, model: "Fable")])
        let half = choice("half", windows: [session(used: 0.5), weekly(used: 0.5, resetsIn: 6)])
        let candidates = [candidate(fableSpent), candidate(half)]
        XCTAssertEqual(AccountRouting.pick(candidates, model: "claude-fable-5-1", now: now)?.choice.id, "half")
        XCTAssertEqual(AccountRouting.pick(candidates, model: "opus", now: now)?.choice.id, "fable-spent")
        XCTAssertEqual(AccountRouting.pick(candidates, model: nil, now: now)?.choice.id, "half")
    }

    /// By default automatic assignment uses the default login and the accounts that keep their
    /// conversations with it; a login with its own history stays out until the person includes it, and an
    /// answer equal to the default is forgotten.
    func testAccountsSharingTheDefaultLoginsHistoryAreInByDefaultAndThePersonDecidesTheRest() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "account-routing-\(UUID().uuidString)")
        roots.append(root)
        let native = root.appending(path: "native")
        try FileManager.default.createDirectory(at: native.appending(path: "projects"), withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("account-routing")))
        let store = ProviderConnectionStore(defaults: defaults)
        store.defaultLoginEnvironment = ["CLAUDE_CONFIG_DIR": native.path]
        func account(_ name: String, harness: HarnessKind = .claudeCode, linked: Bool) throws -> AccountChoice {
            let home = root.appending(path: name)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            if linked {
                try FileManager.default.createSymbolicLink(at: home.appending(path: "projects"),
                                                           withDestinationURL: native.appending(path: "projects"))
            } else {
                try FileManager.default.createDirectory(at: home.appending(path: "projects"), withIntermediateDirectories: true)
            }
            let connection = ProviderConnection(id: name, name: name, harness: harness, providerID: nil,
                                                homePath: home.path, credentialSelector: nil)
            try store.save(connection)
            return AccountChoice(harness: harness, connection: connection, snapshot: nil)
        }
        let shared = try account("shared", linked: true)
        let separate = try account("separate", linked: false)
        let codex = try account("codex-other", harness: .codex, linked: false)
        XCTAssertTrue(store.isInAutomaticAssignment(AccountChoice(harness: .claudeCode, connection: nil, snapshot: nil)))
        XCTAssertTrue(store.isInAutomaticAssignment(AccountChoice(harness: .codex, connection: nil, snapshot: nil)),
                      "The default login is always in by default")
        XCTAssertTrue(store.isInAutomaticAssignment(shared))
        XCTAssertFalse(store.isInAutomaticAssignment(separate))
        XCTAssertFalse(store.isInAutomaticAssignment(codex), "Another CODEX_HOME keeps its own history")

        store.setInAutomaticAssignment(true, for: codex)
        store.setInAutomaticAssignment(false, for: shared)
        XCTAssertTrue(store.isInAutomaticAssignment(codex))
        XCTAssertFalse(store.isInAutomaticAssignment(shared))
        let reopened = ProviderConnectionStore(defaults: defaults)
        XCTAssertEqual(reopened.automaticAssignment, ["codex-other": true, "shared": false])

        store.setInAutomaticAssignment(true, for: shared)
        store.setInAutomaticAssignment(false, for: codex)
        XCTAssertNil(defaults.object(forKey: ProviderConnectionStore.automaticAssignmentKey),
                     "Answers equal to the default leave nothing behind")
    }

    // MARK: - Fixtures

    private func session(used: Double, resetsIn days: Double? = nil) -> AccountUsageMetric {
        metric("session", label: "5 hour limit", used: used, resetsIn: days ?? 4.5 / 24, minutes: 300)
    }

    private func weekly(used: Double, resetsIn days: Double, model: String? = nil) -> AccountUsageMetric {
        metric("weekly:\(model ?? "")", label: model.map { "\($0) · 7 day limit" } ?? "7 day limit", used: used,
               resetsIn: days, minutes: 10_080, model: model)
    }

    private func metric(_ id: String, label: String, used: Double, resetsIn days: Double, minutes: Double,
                        model: String? = nil) -> AccountUsageMetric {
        AccountUsageMetric(id: id, label: label, usedFraction: used, detail: "", resetsAt: now.addingTimeInterval(days * 86_400),
                           evidence: .exactQuota, windowMinutes: minutes, model: model)
    }

    private func connection(_ id: String) -> ProviderConnection {
        ProviderConnection(id: id, name: id, harness: .claudeCode, providerID: nil, homePath: "/tmp/\(id)",
                           credentialSelector: nil)
    }

    private func snapshot(_ id: String, windows: [AccountUsageMetric]) -> HarnessAccountSnapshot {
        HarnessAccountSnapshot(id: id, harness: .claudeCode, providerID: nil, state: .signedIn,
                               accountLabel: "\(id)@example.test", detail: "", credentialOwner: "", checkedAt: now,
                               usage: windows, canLogin: false, canLogout: false)
    }

    private func choice(_ id: String, windows: [AccountUsageMetric]) -> AccountChoice {
        AccountChoice(harness: .claudeCode, connection: connection(id), snapshot: snapshot(id, windows: windows))
    }

    private func candidate(_ choice: AccountChoice, running: Int = 0) -> AccountRouting.Candidate {
        AccountRouting.Candidate(choice: choice, runningTasks: running, isNewTaskAccount: false)
    }
}
