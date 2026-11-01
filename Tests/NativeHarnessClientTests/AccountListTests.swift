import Foundation
import XCTest
@testable import NativeHarnessClient

/// The one account list in each of its modes: which accounts it shows, in what order, which row is
/// marked, what choosing or connecting a row does, and what it checks.
@MainActor final class AccountListTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    // MARK: New task

    func testTheNewTaskListOffersTheHarnessesDefaultAndSavedAccountsAndSignInWhereNeeded() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        let mode = AccountListMode.newTask(.claudeCode)
        let choices = AccountListProjection.choices(mode, store: store)
        XCTAssertEqual(choices.map(\.connection), [fixture.a, fixture.b, fixture.c, fixture.other, fixture.signedOut],
            "A signed-out default is not offered next to saved accounts; saved accounts keep their order")
        XCTAssertEqual(AccountListProjection.harnesses(mode), [.claudeCode])

        store.selection[.claudeCode] = fixture.b.id
        XCTAssertEqual(choices.filter { AccountListProjection.isSelected($0, mode: mode, store: store) }.map(\.connection),
            [fixture.b], "The next task's account is marked")
        let signedOut = try XCTUnwrap(choices.last)
        XCTAssertTrue(AccountListProjection.canChoose(signedOut, mode: mode),
            "A new task may still start on a CLI-owned login the check did not see")
        XCTAssertTrue(AccountListProjection.offersConnect(signedOut, mode: mode))
        XCTAssertFalse(AccountListProjection.offersConnect(choices[0], mode: mode))

        let scope = AccountListProjection.checkScope(mode, choices: choices)
        XCTAssertEqual(scope.defaults, [.claudeCode])
        XCTAssertEqual(scope.saved, [.claudeCode])
        XCTAssertNil(scope.connectionIDs)
        XCTAssertNil(AccountListProjection.emptyText(mode, choices: choices))

        let codex = AccountListProjection.choices(.newTask(.codex), store: store)
        XCTAssertEqual(codex.count, 1)
        XCTAssertNil(codex[0].connection, "The default login is a choice without registering it")
        XCTAssertTrue(AccountListProjection.isSelected(codex[0], mode: .newTask(.codex), store: store))
    }

    // MARK: Moving a task

    func testATasksListOffersOnlyAccountsSharingItsHistoryWithTheMostLimitLeftFirst() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        for mode in [AccountListMode.switchTask(fixture.task), .continueAfterLimit(fixture.task)] {
            let choices = AccountListProjection.choices(mode, store: store)
            XCTAssertEqual(choices.map(\.connection), [fixture.b, fixture.c, fixture.a, fixture.signedOut],
                "\(mode): sorted by the limit left, unchecked last; an account with its own history is not offered")
            XCTAssertTrue(choices.allSatisfy { TaskAccountSwitch.allows($0.connection!, for: fixture.task)
                || $0.connection == fixture.task.connection })
            XCTAssertEqual(choices.filter { AccountListProjection.isSelected($0, mode: mode, store: store) }
                .map(\.connection), [fixture.a], "The task's own account is marked")
            XCTAssertEqual(choices.filter { AccountListProjection.canChoose($0, mode: mode) }.map(\.connection),
                [fixture.b, fixture.c], "Not the task's own account, and not one the last check found signed out")
            XCTAssertTrue(choices.allSatisfy { !AccountListProjection.offersConnect($0, mode: mode) },
                "Moving a task never starts a sign-in")
            let scope = AccountListProjection.checkScope(mode, choices: choices)
            XCTAssertEqual(scope.defaults, [], "A task never moves to the default login")
            XCTAssertEqual(scope.saved, [.claudeCode])
            XCTAssertEqual(scope.connectionIDs, Set([fixture.a, fixture.b, fixture.c, fixture.signedOut].map(\.id)))
            XCTAssertNil(AccountListProjection.emptyText(mode, choices: choices))
            XCTAssertEqual(mode.session, fixture.task)
        }
        // The limit card offers the same accounts, without the task's own.
        XCTAssertEqual(fixture.model.usageLimitAccounts(for: fixture.task), [fixture.b, fixture.c, fixture.signedOut])
        let options = fixture.model.usageLimitAccountOptions(for: fixture.task)
        XCTAssertEqual(options.others, [fixture.b, fixture.c, fixture.signedOut])
        XCTAssertTrue(options.store === store)
        XCTAssertEqual(options.session.id, fixture.task.id)
    }

    func testATaskWithNoOtherAccountSaysSo() throws {
        let fixture = try makeFixture()
        let alone = SessionRecord(harness: .claudeCode, workspaceURL: fixture.root,
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Alone", connection: fixture.other)
        let choices = AccountListProjection.choices(.switchTask(alone), store: fixture.store)
        XCTAssertEqual(choices.map(\.connection), [fixture.other])
        XCTAssertEqual(AccountListProjection.emptyText(.switchTask(alone), choices: choices),
            L10n.string("No other account shares this task's conversation history."))
        XCTAssertTrue(fixture.model.usageLimitAccounts(for: alone).isEmpty)
    }

    // MARK: Settings

    func testSettingsListsEveryFilteredHarnessGroupedByAccountAndSearchable() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        let shared = ProviderConnection(id: "opencode-codex", name: "Laptop", harness: .openCode,
            providerID: "openai-codex", homePath: "/tmp/opencode-shared", credentialSelector: nil)
        try store.save(shared)
        store.publish(signedIn("codex@example.test", harness: .openCode, provider: "openai-codex", left: 0.7),
            for: shared)
        let harnesses: [HarnessKind] = [.codex, .openCode, .claudeCode]
        let all = AccountListProjection.choices(.manage, store: store, manageHarnesses: harnesses)
        let groups = AccountListProjection.groups(all)
        XCTAssertEqual(groups.first?.identity.displayLabel, "codex@example.test")
        XCTAssertEqual(groups.first?.harnesses, [.codex, .openCode],
            "One ChatGPT account through two harnesses is one account with two connections")
        XCTAssertEqual(Set(all.compactMap(\.connection)), Set([shared, fixture.a, fixture.b, fixture.c, fixture.other,
            fixture.signedOut]))

        let found = AccountListProjection.choices(.manage, store: store, manageHarnesses: harnesses, search: "PERSONAL")
        XCTAssertEqual(found.map(\.connection), [fixture.b])
        let none = AccountListProjection.choices(.manage, store: store, manageHarnesses: harnesses, search: "nobody")
        XCTAssertEqual(AccountListProjection.emptyText(.manage, choices: none, search: "nobody"),
            L10n.string("No matching accounts."))
        XCTAssertEqual(AccountListProjection.emptyText(.manage, choices: [], search: ""),
            L10n.string("Connect a harness to use an account."))

        store.selection[.claudeCode] = fixture.c.id
        XCTAssertEqual(all.filter { AccountListProjection.isSelected($0, mode: .manage, store: store) }
            .map(\.id), [AccountChoice.nativeID(for: .codex), AccountChoice.nativeID(for: .openCode), fixture.c.id]
            .filter { id in all.contains { $0.id == id } },
            "Each harness marks the account its next task starts on")
        let scope = AccountListProjection.checkScope(.manage, choices: all, manageHarnesses: harnesses)
        XCTAssertEqual(scope.defaults, harnesses)
        XCTAssertEqual(scope.saved, harnesses)

        // A default login signs out, or out and in with another account, where the Harnesses page
        // signs it out; saved accounts leave through their own items, and only Settings offers either.
        let codex = store.choice(for: .codex, connection: nil)
        XCTAssertEqual(AccountListProjection.defaultLoginActions(codex, mode: .manage),
                       [.signInWithAnotherAccount, .signOut])
        XCTAssertEqual(AccountListProjection.defaultLoginActions(codex, mode: .newTask(.codex)), [])
        XCTAssertTrue(all.filter { $0.connection != nil }
            .allSatisfy { AccountListProjection.defaultLoginActions($0, mode: .manage).isEmpty })
        XCTAssertEqual(AccountListProjection.defaultLoginActions(store.choice(for: .claudeCode, connection: nil),
            mode: .manage), [], "A signed-out default login offers its sign-in instead")
        // A login the harness keeps in one place, with no address to show, still signs out; a
        // harness that connects model providers disconnects one, since adding another needs no sign-out.
        store.publishDefaults([
            HarnessAccountSnapshot(id: "antigravity-cli", harness: .antigravityCLI, providerID: nil, state: .signedIn,
                accountLabel: nil, detail: "", credentialOwner: "", checkedAt: Date(), usage: [], canLogin: false,
                canLogout: true),
            signedIn("codex@example.test", harness: .openCode, provider: "openai-codex", left: 0.7)
        ])
        let antigravity = store.choice(for: .antigravityCLI, connection: nil)
        XCTAssertTrue(AccountListProjection.accountLine(antigravity).contains(L10n.string("Unknown account")))
        XCTAssertEqual(AccountListProjection.defaultLoginActions(antigravity, mode: .manage),
                       [.signInWithAnotherAccount, .signOut])
        XCTAssertEqual(AccountListProjection.defaultLoginActions(store.choice(for: .openCode, connection: nil),
            mode: .manage), [.signOut])
    }

    // MARK: One row

    func testEveryModeDescribesAnAccountTheSameWay() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        let modes: [AccountListMode] = [.newTask(.claudeCode), .switchTask(fixture.task),
                                        .continueAfterLimit(fixture.task), .manage]
        var lines: Set<String> = []
        var freshness: Set<String> = []
        for mode in modes {
            let choice = try XCTUnwrap(AccountListProjection.choices(mode, store: store,
                manageHarnesses: [.claudeCode]).first { $0.connection == fixture.b })
            XCTAssertEqual(choice.title, "personal@example.test")
            lines.insert(AccountListProjection.accountLine(choice))
            let reading = AccountFreshnessProjection.freshness(of: [choice], status: store.readingStatus(for:),
                isChecking: store.isChecking)
            freshness.insert(AccountFreshnessProjection.text(reading) ?? "")
            XCTAssertEqual(AccountGroupProjection.usageBlocks(for: [choice]).first?.metrics.count, 2)
        }
        XCTAssertEqual(lines, ["Claude Code · Claude Max plan"], "The row's second line is the same in every mode")
        XCTAssertEqual(freshness, [L10n.string("Updated just now")])
    }

    func testSortingByTheLimitLeftKeepsTiesAndPutsUncheckedLast() {
        func choice(_ id: String, left: Double?) -> AccountChoice {
            let connection = ProviderConnection(id: id, name: id, harness: .claudeCode, providerID: nil,
                homePath: "/tmp/\(id)", credentialSelector: nil)
            return AccountChoice(harness: .claudeCode, connection: connection,
                snapshot: left.map { signedIn("\(id)@example.test", left: $0) })
        }
        let sorted = AccountListProjection.sortedByRemainingLimit([
            choice("unchecked", left: nil), choice("low", left: 0.1), choice("first-tie", left: 0.5),
            choice("high", left: 0.9), choice("second-tie", left: 0.5)
        ])
        XCTAssertEqual(sorted.map(\.id), ["high", "first-tie", "second-tie", "low", "unchecked"])
    }

    // MARK: Fixture

    private struct Fixture {
        let root: URL
        let store: ProviderConnectionStore
        let model: AppModel
        let a, b, c, other, signedOut: ProviderConnection
        let task: SessionRecord
    }

    /// Claude accounts a, b, c and a signed-out one share one history folder; `other` keeps its
    /// own. Codex's default login is signed in; Claude's is signed out. A Claude task runs under a.
    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "account-list-\(UUID().uuidString)")
        let projects = root.appending(path: "shared/projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        roots.append(root)
        let store = ProviderConnectionStore()
        func account(_ name: String, sharesHistory: Bool = true) throws -> ProviderConnection {
            let home = root.appending(path: name)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            if sharesHistory {
                try FileManager.default.createSymbolicLink(at: home.appending(path: "projects"),
                    withDestinationURL: projects)
            } else {
                try FileManager.default.createDirectory(at: home.appending(path: "projects"),
                    withIntermediateDirectories: true)
            }
            let connection = ProviderConnection(id: name, name: "\(name)@example.test", harness: .claudeCode,
                providerID: nil, homePath: home.path, credentialSelector: nil)
            try store.save(connection)
            return connection
        }
        let a = try account("developer"), b = try account("personal"), c = try account("jordan")
        let other = try account("elsewhere", sharesHistory: false)
        let signedOut = try account("old")
        store.publish(signedIn("developer@example.test", left: 0.1), for: a)
        store.publish(signedIn("personal@example.test", left: 0.8), for: b)
        store.publish(signedIn("jordan@example.test", left: 0.3), for: c)
        store.publish(signedIn("elsewhere@example.test", left: 0.95), for: other)
        store.publish(HarnessAccountSnapshot(id: "old", harness: .claudeCode, providerID: nil, state: .signedOut,
            accountLabel: nil, detail: "", credentialOwner: "", checkedAt: Date(), usage: [], canLogin: true,
            canLogout: false), for: signedOut)
        store.publishDefaults([
            HarnessAccountSnapshot(id: "claude-code", harness: .claudeCode, providerID: nil, state: .signedOut,
                accountLabel: nil, detail: "", credentialOwner: "", checkedAt: Date(), usage: [], canLogin: true,
                canLogout: false),
            signedIn("codex@example.test", harness: .codex, provider: "openai-codex", left: 0.7)
        ])
        let task = SessionRecord(harness: .claudeCode, workspaceURL: root,
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Limit", connection: a)
        let model = AppModel(store: SessionStore(sessions: [task]),
            runtimeSelections: RuntimeSelectionStore(discoversRuntimes: false), connections: store,
            restoresIndexOnLaunch: false)
        return Fixture(root: root, store: store, model: model, a: a, b: b, c: c, other: other,
            signedOut: signedOut, task: task)
    }
}

private func signedIn(_ email: String, harness: HarnessKind = .claudeCode, provider: String? = nil,
                      left: Double) -> HarnessAccountSnapshot {
    HarnessAccountSnapshot(id: harness.rawValue, harness: harness, providerID: provider, state: .signedIn,
        accountLabel: email, accountPlan: harness == .claudeCode ? "Claude Max plan" : "ChatGPT Pro", detail: "",
        credentialOwner: harness.displayName, checkedAt: Date(), usage: [
            AccountUsageMetric(id: "session", label: "5 hour limit", usedFraction: 1 - left,
                detail: "\(Int(left * 100))% remaining", resetsAt: nil, evidence: .exactQuota),
            AccountUsageMetric(id: "weekly", label: "7 day limit", usedFraction: max(0, 0.9 - left),
                detail: "\(Int((1 - max(0, 0.9 - left)) * 100))% remaining", resetsAt: nil, evidence: .exactQuota)
        ], canLogin: false, canLogout: true)
}
