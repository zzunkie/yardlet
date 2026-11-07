import XCTest
@testable import NativeHarnessClient

@MainActor final class AccountChoiceTests: XCTestCase {
    private func snapshot(_ harness: HarnessKind, state: AccountAuthState = .signedIn, email: String? = "owner@example.test",
                          provider: String? = nil, usage: [AccountUsageMetric] = []) -> HarnessAccountSnapshot {
        HarnessAccountSnapshot(id: harness.rawValue, harness: harness, providerID: provider, state: state,
            accountLabel: email, detail: "Provider observation", credentialOwner: harness.displayName,
            checkedAt: Date(), usage: usage, canLogin: state != .signedIn, canLogout: state == .signedIn)
    }

    func testExistingLoginsAreChoicesWithoutCreatingConnectionsOrMergingHarnesses() {
        let store = ProviderConnectionStore()
        store.publishDefaults([snapshot(.codex), snapshot(.claudeCode)])
        let choices = store.choices(for: [.codex, .claudeCode])
        XCTAssertEqual(choices.count, 2)
        XCTAssertEqual(choices.map(\.title), ["owner@example.test", "owner@example.test"])
        XCTAssertNotEqual(choices[0].id, choices[1].id)
        XCTAssertTrue(choices.allSatisfy { $0.connection == nil })
        XCTAssertTrue(store.connections.isEmpty, "Displaying a native login does not register or copy an account")
        store.choose(choices[0])
        XCTAssertNil(store.selection[.codex], "The original native storage binding remains nil")
    }

    /// A first run with Claude history and no Claude Code login: the row and the new-task chip say
    /// so, and a task can always be given an account while no saved one is signed in.
    func testASignedOutDefaultLoginSaysSoAndStaysUntilASavedAccountIsSignedIn() throws {
        let store = ProviderConnectionStore()
        store.publishDefaults([snapshot(.claudeCode, state: .signedOut, email: nil)])
        var choice = try XCTUnwrap(store.choices(for: [.claudeCode]).first)
        XCTAssertEqual(choice.title, L10n.string("Not signed in"))
        XCTAssertEqual(choice.composerTitle, L10n.string("Not signed in"))
        XCTAssertEqual(choice.status, L10n.string("Not signed in"))
        XCTAssertTrue(AccountListProjection.offersConnect(choice, mode: .newTask(.claudeCode)))

        let saved = ProviderConnection(id: "second", name: "Second", harness: .claudeCode, providerID: nil,
                                       homePath: "/tmp/second", credentialSelector: nil)
        try store.save(saved)
        store.publish(snapshot(.claudeCode, state: .unknown, email: nil), for: saved)
        XCTAssertEqual(store.choices(for: [.claudeCode]).count, 2, "A saved account that could not be read leaves the default its row")
        store.publish(snapshot(.claudeCode), for: saved)
        choice = try XCTUnwrap(store.choices(for: [.claudeCode]).first)
        XCTAssertEqual(choice.connection, saved, "A saved account signed in is the one left to choose")
        XCTAssertEqual(store.selection[.claudeCode], saved.id, "And new tasks start on it at once")
    }

    /// The account of a login with no address comes from the config file, and only the account.
    func testAClaudeConfigFileNamesItsAccountWithoutTheCLI() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "claude-config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNil(HarnessAccountBroker.claudeConfigIdentity(file: file))
        try Data(#"{"oauthAccount":{"emailAddress":"owner@example.test","organizationName":"Example Team"}}"#.utf8).write(to: file)
        let identity = try XCTUnwrap(HarnessAccountBroker.claudeConfigIdentity(file: file))
        XCTAssertEqual(identity.displayLabel, "owner@example.test")
        XCTAssertEqual(identity.groupingOrganization, "Example Team")
        try Data(#"{"projects":{}}"#.utf8).write(to: file)
        XCTAssertNil(HarnessAccountBroker.claudeConfigIdentity(file: file))
    }

    func testDefaultAndAdditionalAccountRemainInOneScopedListAndSelectionDoesNotChangeOtherHarness() throws {
        let store = ProviderConnectionStore()
        let additional = ProviderConnection(id: "pi-second", name: "Second", harness: .pi, providerID: "anthropic", homePath: "/tmp/pi-second", credentialSelector: nil)
        try store.save(additional)
        store.publishDefaults([snapshot(.pi, provider: "anthropic"), snapshot(.codex)])
        store.publish(snapshot(.pi, provider: "anthropic"), for: additional)
        store.selection[.codex] = "unchanged"
        let choices = store.choices(for: [.pi])
        XCTAssertEqual(choices.count, 2)
        store.choose(choices[1])
        XCTAssertEqual(store.selected(for: .pi), additional)
        XCTAssertEqual(store.selection[.codex], "unchanged")
        store.choose(choices[0])
        XCTAssertNil(store.selected(for: .pi))
        XCTAssertEqual(store.connections, [additional])
    }

    func testSignedOutDefaultGivesWayToTheSavedAccountWithTheMostLimitLeft() throws {
        let store = ProviderConnectionStore()
        func weekly(_ used: Double) -> [AccountUsageMetric] {
            [AccountUsageMetric(id: "week", label: "7 day limit", usedFraction: used, detail: "", resetsAt: nil, evidence: .exactQuota)]
        }
        let accounts = [("personal", 0.98), ("work", 1.0), ("spare", 0.0)].map {
            ProviderConnection(id: $0.0, name: "\($0.0)@example.test", harness: .claudeCode, providerID: nil,
                homePath: "/tmp/\($0.0)", credentialSelector: nil)
        }
        for (account, used) in zip(accounts, [0.98, 1.0, 0.0]) {
            try store.save(account)
            store.publish(snapshot(.claudeCode, email: account.name, usage: weekly(used)), for: account)
        }
        store.publishDefaults([snapshot(.claudeCode, state: .signedOut, email: nil)])
        XCTAssertEqual(store.choices(for: [.claudeCode]).map(\.connection), accounts,
            "A default without a login is not offered next to saved accounts")
        store.replaceSignedOutDefaultSelection(for: .claudeCode)
        XCTAssertEqual(store.selected(for: .claudeCode), accounts[2])
        store.selection[.claudeCode] = accounts[0].id
        store.replaceSignedOutDefaultSelection(for: .claudeCode)
        XCTAssertEqual(store.selected(for: .claudeCode), accounts[0], "An explicit choice is kept")

        let signedIn = ProviderConnectionStore()
        try signedIn.save(accounts[0])
        signedIn.publishDefaults([snapshot(.claudeCode)])
        signedIn.replaceSignedOutDefaultSelection(for: .claudeCode)
        XCTAssertNil(signedIn.selection[.claudeCode], "A signed-in default stays the choice")
        XCTAssertEqual(signedIn.choices(for: [.claudeCode]).count, 2)
    }

    func testSavedConnectionNamedAfterItsAccountIsLabelledByItsHarness() {
        let named = ProviderConnection(id: "a", name: "owner@example.test", harness: .claudeCode, providerID: nil,
            homePath: "/tmp/a", credentialSelector: nil)
        XCTAssertEqual(AccountChoice(harness: .claudeCode, connection: named, snapshot: snapshot(.claudeCode)).connectionTitle,
            HarnessKind.claudeCode.displayName)
        let laptop = ProviderConnection(id: "b", name: "Laptop", harness: .claudeCode, providerID: nil,
            homePath: "/tmp/b", credentialSelector: nil)
        XCTAssertEqual(AccountChoice(harness: .claudeCode, connection: laptop, snapshot: snapshot(.claudeCode)).connectionTitle, "Laptop")
    }

    func testQuotaAbsenceDoesNotTurnAnAuthenticatedAccountIntoALoginProblem() {
        let choice = AccountChoice(harness: .claudeCode, connection: nil, snapshot: snapshot(.claudeCode))
        XCTAssertTrue(choice.canSelect)
        XCTAssertFalse(choice.needsLogin)
        XCTAssertTrue(choice.quotas.isEmpty)
        XCTAssertEqual(choice.usageUnavailableText, L10n.string("Quota not reported"))
        let tokenHistory = AccountUsageMetric(id: "lifetime", label: "Tokens", usedFraction: nil, detail: "42 tokens", resetsAt: nil, evidence: .accountUsage)
        let codex = AccountChoice(harness: .codex, connection: nil, snapshot: snapshot(.codex, usage: [tokenHistory]))
        XCTAssertTrue(codex.quotas.isEmpty, "Token history must not appear as remaining allowance")
    }

    func testUnavailableBindingsCannotBeSelectedButCLIAuthenticationRemainsUsable() throws {
        let store = ProviderConnectionStore()
        for state in [AccountAuthState.actionRequired, .unavailable] {
            let connection = ProviderConnection(id: state.rawValue, name: "Blocked", harness: .codex, providerID: nil, homePath: "/tmp/blocked", credentialSelector: nil)
            try store.save(connection)
            store.publish(snapshot(.codex, state: state), for: connection)
            let choice = try XCTUnwrap(store.choices(for: [.codex]).first { $0.connection?.id == connection.id })
            XCTAssertFalse(choice.canSelect)
            store.choose(choice)
            XCTAssertNil(store.selection[.codex])
        }
        let pi = AccountChoice(harness: .pi, connection: nil, snapshot: snapshot(.pi, state: .unknown, email: nil))
        XCTAssertTrue(pi.needsProvider)
        XCTAssertTrue(pi.canSelect, "Provider defaults and environment keys remain owned by the CLI")
        let apiEnvironment = AccountChoice(harness: .openCode, connection: nil, snapshot: snapshot(.openCode, state: .signedOut, email: nil))
        XCTAssertTrue(apiEnvironment.canSelect, "No saved OAuth does not prove that CLI API-key authentication is unavailable")
        XCTAssertEqual(apiEnvironment.status, L10n.string("No saved connection"))
        let hermes = AccountChoice(harness: .hermes, connection: nil, snapshot: snapshot(.hermes, state: .unknown, email: nil))
        XCTAssertTrue(hermes.canSelect, "A CLI without account introspection is not necessarily signed out")
        XCTAssertEqual(hermes.status, L10n.string("Status not verified"))
    }
}
