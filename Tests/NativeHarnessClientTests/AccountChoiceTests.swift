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

    /// A name read from a config file, on a login its CLI could not vouch for, does not stand as the
    /// account a task starts on. The list keeps it beside the status, so rows stay grouped by account.
    func testANameFromAConfigFileIsNoAccountUntilTheCLIVouchesForIt() throws {
        let choice = AccountChoice(harness: .claudeCode, connection: nil, snapshot: snapshot(.claudeCode, state: .unknown))
        XCTAssertEqual(choice.composerTitle, L10n.string("Status not verified"))
        XCTAssertEqual(choice.title, "owner@example.test")
        XCTAssertEqual(choice.status, L10n.string("Status not verified"))
        XCTAssertEqual(ProviderConnectionDisplay(choice: choice).accessibilityTitle, "owner@example.test")
        XCTAssertEqual(AccountChoice(harness: .claudeCode, connection: nil, snapshot: snapshot(.claudeCode)).composerTitle,
                       "owner@example.test")
    }

    /// A sign-in can finish before a login's first reading, so the tasks waiting for it hear of it too,
    /// told that the login was not known before.
    func testASignInIsAnnouncedEvenAheadOfTheFirstReading() {
        let store = ProviderConnectionStore()
        var announced: [Bool] = []
        store.onSignedIn = { _, _, isFirstReading in announced.append(isFirstReading) }
        store.publishDefaults([snapshot(.claudeCode)])
        XCTAssertEqual(announced, [true])
        store.publishDefaults([snapshot(.claudeCode)])
        XCTAssertEqual(announced, [true], "Still signed in is no sign-in")
        store.publishDefaults([snapshot(.claudeCode, state: .signedOut, email: nil)])
        store.publishDefaults([snapshot(.claudeCode)])
        XCTAssertEqual(announced, [true, false])
    }

    private nonisolated static func login(_ harness: HarnessKind, state: AccountAuthState) -> HarnessAccountSnapshot {
        HarnessAccountSnapshot(id: harness.rawValue, harness: harness, providerID: nil, state: state, accountLabel: nil,
            detail: "Provider observation", credentialOwner: harness.displayName, checkedAt: Date(), usage: [],
            canLogin: state != .signedIn, canLogout: state == .signedIn)
    }

    /// What a harness's own login check answers is what `createTask` hears from the fixture below.
    private actor Reading {
        var state: AccountAuthState
        init(_ state: AccountAuthState) { self.state = state }
        func set(_ state: AccountAuthState) { self.state = state }
    }

    private func signInFixture(_ harness: HarnessKind, connections: ProviderConnectionStore)
        throws -> (model: AppModel, adapter: SuggestionRecordingAdapter, draft: NewTaskDraft) {
        let root = FileManager.default.temporaryDirectory.appending(path: "sign-in-start-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let defaults = SuggestionVolatileDefaults()
        let runtimes = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false)
        runtimes.select(URL(filePath: "/usr/bin/true"), for: harness)
        let adapter = SuggestionRecordingAdapter()
        let model = AppModel(store: SessionStore(repository: InMemorySessionRepository()), runtimeSelections: runtimes,
            registry: HarnessRegistry { _, _ in adapter }, connections: connections, preferences: defaults,
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
            chatWorkspaceHome: root.appending(path: "home", directoryHint: .isDirectory), sessionTitleResolver: { _ in nil },
            sessionTitleRetryCount: 0, restoresIndexOnLaunch: false)
        addTeardownBlock { await model.shutdown() }
        let draft = NewTaskDraft()
        draft.text = "Explain the build"
        draft.harness = harness
        draft.workspaceURL = root
        return (model, adapter, draft)
    }

    private func loginStore(answering reading: Reading, harness: HarnessKind) -> ProviderConnectionStore {
        ProviderConnectionStore(defaultLoader: { _, _ in
            await Self.login(harness, state: reading.state)
        })
    }

    private func start(_ fixture: (model: AppModel, adapter: SuggestionRecordingAdapter, draft: NewTaskDraft)) async throws
        -> SessionRecord? {
        let submission = try XCTUnwrap(fixture.draft.beginSubmission(runtimeURL: URL(filePath: "/usr/bin/true")))
        defer { fixture.draft.complete(submission, succeeded: false) }
        return try await fixture.model.createTask(submission)
    }

    /// A login read as signed out stops a new task before it exists, so the person stays on the
    /// new-task screen with their draft. A reading the CLI no longer agrees with stops nothing, and
    /// neither does one that does not speak for how the harness runs.
    func testANewTaskStopsOnlyOnALoginThatIsStillSignedOut() async throws {
        for harness in [HarnessKind.claudeCode, .codex, .antigravityCLI] {
            let reading = Reading(.signedOut)
            let store = loginStore(answering: reading, harness: harness)
            store.publishDefaults([snapshot(harness, state: .signedOut, email: nil)])
            let fixture = try signInFixture(harness, connections: store)
            do {
                _ = try await start(fixture)
                XCTFail("\(harness) started signed out")
            } catch {
                XCTAssertTrue(error is HarnessSignInRequired, "\(harness): \(error)")
            }
            XCTAssertTrue(fixture.model.store.sessions.isEmpty, "\(harness) made no task")

            // Signed in from Terminal since the last reading: the start reads the login again.
            await reading.set(.signedIn)
            let created = try await start(fixture)
            XCTAssertNotNil(created, "\(harness) starts on the login as it is now")
        }

        // OpenCode runs on a key in its environment with no connection saved.
        let store = loginStore(answering: Reading(.signedOut), harness: .openCode)
        store.publishDefaults([snapshot(.openCode, state: .signedOut, email: nil)])
        let created = try await start(try signInFixture(.openCode, connections: store))
        XCTAssertNotNil(created)

        // A check that could not finish vouches for nothing either way.
        let unverified = loginStore(answering: Reading(.unknown), harness: .claudeCode)
        unverified.publishDefaults([snapshot(.claudeCode, state: .unknown, email: nil)])
        let started = try await start(try signInFixture(.claudeCode, connections: unverified))
        XCTAssertNotNil(started)
    }

    /// In a first run's first seconds the check under way gets a moment; one that takes longer holds
    /// nothing up.
    func testANewTaskWaitsAMomentForAFirstReading() async throws {
        func answeringStore() -> (ProviderConnectionStore, AsyncStream<AccountAuthState>.Continuation) {
            let (answers, answer) = AsyncStream<AccountAuthState>.makeStream()
            return (ProviderConnectionStore(defaultLoader: { _, _ in
                var iterator = answers.makeAsyncIterator()
                return await Self.login(.claudeCode, state: iterator.next() ?? .unknown)
            }), answer)
        }
        let (store, answer) = answeringStore()
        let fixture = try signInFixture(.claudeCode, connections: store)
        fixture.model.firstReadingWait = testWaitLimit
        let runtimes = fixture.model.runtimeSelections
        let launch = Task { await store.check(defaultsOf: [.claudeCode], savedOf: [], runtimeSelections: runtimes) }
        try await waitUntil { store.isCheckingDefault(.claudeCode) }
        let starting = Task { [fixture] in try await self.start(fixture) }
        // The first check's answer, then the same again when the start reads the login once more.
        answer.yield(.signedOut)
        answer.yield(.signedOut)
        await launch.value
        do {
            _ = try await starting.value
            XCTFail("Started on a login the first check read as signed out")
        } catch {
            XCTAssertTrue(error is HarnessSignInRequired, "\(error)")
        }
        XCTAssertTrue(fixture.model.store.sessions.isEmpty)

        let (slowStore, slowAnswer) = answeringStore()
        let slowFixture = try signInFixture(.claudeCode, connections: slowStore)
        slowFixture.model.firstReadingWait = .milliseconds(30)
        let slowRuntimes = slowFixture.model.runtimeSelections
        let slowLaunch = Task { await slowStore.check(defaultsOf: [.claudeCode], savedOf: [], runtimeSelections: slowRuntimes) }
        try await waitUntil { slowStore.isCheckingDefault(.claudeCode) }
        let created = try await start(slowFixture)
        XCTAssertNotNil(created, "A check that takes longer stops nothing")
        slowAnswer.yield(.signedIn)
        await slowLaunch.value
    }

    /// A Codex thread opens with no login and what a task reads from one keeps working, so it is the
    /// turn that stops. After the sign-in the failed task is ready again.
    func testACodexTurnStopsAtASignedOutReadingAndItsTaskIsReadyAfterTheSignIn() async throws {
        let store = loginStore(answering: Reading(.signedOut), harness: .codex)
        store.publishDefaults([snapshot(.codex, state: .signedOut, email: nil)])
        let fixture = try signInFixture(.codex, connections: store)
        let model = fixture.model
        let made = await model.createSession(harness: .codex, workspaceURL: fixture.draft.workspaceURL!,
                                             runtimeExecutableURL: URL(filePath: "/usr/bin/true"), title: "Failed")
        let task = try XCTUnwrap(made, model.bootstrapError ?? "Missing task")
        XCTAssertTrue(model.isAttached(task.id), "The thread opened without a login")
        await model.send("Hello", to: task)
        let prompts = await fixture.adapter.prompts
        XCTAssertTrue(prompts.isEmpty, "No turn started")
        XCTAssertEqual(model.errorBySessionID[task.id], ProviderSignIn.prompt)
        XCTAssertEqual(model.store.sessions.first { $0.id == task.id }?.status, .failed)

        await model.continueTasks(afterSignInOf: .codex, connection: nil, isFirstReading: true)
        XCTAssertNil(model.errorBySessionID[task.id])
        XCTAssertEqual(model.store.sessions.first { $0.id == task.id }?.status, .ready)
    }

    /// A sign-in ends each idle CLI on the login, since one that found none keeps running on that
    /// answer. A login's first reading says nothing about them, so they run on. A new version of the
    /// CLI ends each idle one too, since a process keeps the version it started from.
    func testOnlyASignInAfterAKnownReadingOrANewCLIVersionEndsIdleCLIs() async throws {
        let fixture = try signInFixture(.claudeCode, connections: ProviderConnectionStore())
        let model = fixture.model
        let made = await model.createSession(harness: .claudeCode, workspaceURL: fixture.draft.workspaceURL!,
                                             runtimeExecutableURL: URL(filePath: "/usr/bin/true"), title: "Idle")
        let task = try XCTUnwrap(made, model.bootstrapError ?? "Missing task")
        XCTAssertTrue(model.isAttached(task.id))
        await model.continueTasks(afterSignInOf: .claudeCode, connection: nil, isFirstReading: true)
        XCTAssertTrue(model.isAttached(task.id))
        await model.continueTasks(afterSignInOf: .claudeCode, connection: nil)
        XCTAssertFalse(model.isAttached(task.id))

        let next = await model.createSession(harness: .claudeCode, workspaceURL: fixture.draft.workspaceURL!,
                                             runtimeExecutableURL: URL(filePath: "/usr/bin/true"), title: "Idle too")
        let other = try XCTUnwrap(next, model.bootstrapError ?? "Missing task")
        XCTAssertTrue(model.isAttached(other.id))
        await model.harnessRuntimeChanged(.claudeCode)
        XCTAssertFalse(model.isAttached(other.id))
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
