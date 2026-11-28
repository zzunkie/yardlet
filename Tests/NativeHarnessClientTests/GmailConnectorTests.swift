import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Google account sign-in, authenticated Workspace discovery and calls through each harness.
@MainActor
final class GmailConnectorTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private func makeCenter(
        google: FakeGoogle = FakeGoogle(),
        agent: (any OAuthUserAgent)? = FakeUserAgent(),
        credentials: InMemoryConnectorCredentialStore = InMemoryConnectorCredentialStore(),
        repository: any ConnectorRepository = InMemoryConnectorRepository(),
        now: @escaping @Sendable () -> Date = { Date() },
        configure: (inout ConnectorCenter.Environment) -> Void = { _ in }
    ) -> ConnectorCenter {
        var environment = ConnectorCenter.Environment(
            repository: repository, credentials: credentials, http: google, userAgent: agent,
            sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9", now: now)
        environment.googleWorkspaceTransport = google
        environment.google = FakeGoogle.endpoints
        configure(&environment)
        return ConnectorCenter(environment: environment)
    }

    /// A center with the Google app saved and one account signed in as `account`.
    private func signedIn(
        _ account: String = "person@example.test",
        google: FakeGoogle = FakeGoogle(),
        agent: FakeUserAgent = FakeUserAgent(),
        credentials: InMemoryConnectorCredentialStore = InMemoryConnectorCredentialStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> (ConnectorCenter, ConnectorRecord) {
        let center = makeCenter(google: google, agent: agent, credentials: credentials, now: now)
        try await center.saveGoogleApp(clientID: FakeGoogle.clientID, secret: FakeGoogle.clientSecret)
        google.signInAs = account
        let record = try XCTUnwrap(center.addGmailAccount())
        await center.waitForConnection(record.id)
        XCTAssertNil(center.failures[record.id])
        let connected = try XCTUnwrap(center.record(record.id))
        XCTAssertEqual(connected.status, .connected)
        return (center, connected)
    }

    private func call(_ center: ConnectorCenter, _ name: String, _ arguments: [String: ToolJSON] = [:],
                      folders: [URL] = []) async throws -> AgentToolResult {
        try XCTUnwrapAsync(await center.callNamingTheOnlyAccount(name, arguments,
                                                                 for: ConnectorToolContext(workspaceRoots: folders)))
    }

    private func json(_ result: AgentToolResult, file: StaticString = #filePath, line: UInt = #line) throws -> ToolJSON {
        XCTAssertFalse(result.isError, result.text, file: file, line: line)
        return try JSONDecoder().decode(ToolJSON.self, from: Data(result.text.utf8))
    }

    // MARK: - The Google OAuth app

    func testTheGoogleAppIsInTheSecureStoreAndOnlyItsClientIDInTheFile() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "gmail-home-\(UUID().uuidString)")
        directories.append(home)
        let repository = FileConnectorRepository.live(homeURL: home)
        let credentials = InMemoryConnectorCredentialStore()
        let center = makeCenter(credentials: credentials, repository: repository)
        XCTAssertNil(center.googleAppClientID)

        try await center.saveGoogleApp(clientID: "  \(FakeGoogle.clientID) ", secret: " \(FakeGoogle.clientSecret) ")
        XCTAssertEqual(center.googleAppClientID, FakeGoogle.clientID)
        XCTAssertEqual(try credentials.load(GoogleOAuth.appCredentialID),
                       .client(id: FakeGoogle.clientID, secret: FakeGoogle.clientSecret)
                        .bound(to: ConnectorAccountProvider.google.credentialDestination))
        center.finishSaving()
        let file = try String(contentsOf: repository.fileURL, encoding: .utf8)
        XCTAssertTrue(file.contains(FakeGoogle.clientID), "The client ID is shown without a keychain read")
        XCTAssertFalse(file.contains(FakeGoogle.clientSecret), "The secret stays in the secure store")

        // A relaunch knows the app; removing it forgets both.
        XCTAssertEqual(makeCenter(credentials: credentials, repository: repository).googleAppClientID, FakeGoogle.clientID)
        try await center.removeGoogleApp()
        XCTAssertNil(center.googleAppClientID)
        XCTAssertNil(try credentials.load(GoogleOAuth.appCredentialID))
        center.finishSaving()
        XCTAssertNil(makeCenter(credentials: credentials, repository: repository).googleAppClientID)
    }

    func testWithoutAGoogleAppNoBrowserOpens() async throws {
        let agent = FakeUserAgent()
        let center = makeCenter(agent: agent)
        let record = try XCTUnwrap(center.addGmailAccount())
        await center.waitForConnection(record.id)
        XCTAssertEqual(center.failures[record.id], GoogleSignInError.noApp.errorDescription)
        XCTAssertTrue(agent.opened.isEmpty)
        XCTAssertEqual(center.record(record.id)?.status, .notConnected)
        XCTAssertEqual(ConnectorSettingsState.make(try XCTUnwrap(center.record(record.id)), in: center),
                       .error(try XCTUnwrap(GoogleSignInError.noApp.errorDescription)))
    }

    // MARK: - Sign-in

    /// The browser goes to Google's authorization page with the saved app, one scope, offline access
    /// and the account chooser, PKCE, and the fixed loopback redirect; the code comes back to the
    /// loopback and is exchanged with the app's secret; Google's profile names the account.
    func testAnAccountSignsInWithTheGoogleAppOnTheFixedRedirect() async throws {
        let google = FakeGoogle()
        let agent = FakeUserAgent()
        let credentials = InMemoryConnectorCredentialStore()
        let (center, record) = try await signedIn(google: google, agent: agent, credentials: credentials)

        XCTAssertEqual(record.account, "person@example.test")
        XCTAssertEqual(record.slug, "gmail")
        XCTAssertEqual(record.localService, .gmail)
        XCTAssertEqual(record.displayName, "Gmail · person@example.test")
        XCTAssertEqual(agent.loopbackPorts, [ConnectorOAuth.registeredClientRedirectPort], "The fixed 47823 a Web client names")

        let opened = try XCTUnwrap(agent.opened.first)
        XCTAssertEqual(opened.host(), "accounts.google.test")
        XCTAssertEqual(opened.path(), "/o/oauth2/v2/auth")
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["client_id"], FakeGoogle.clientID)
        XCTAssertEqual(query["scope"], GoogleOAuth.scope(for: [.gmail]))
        XCTAssertEqual(query["access_type"], "offline")
        XCTAssertEqual(query["prompt"], "select_account consent")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["redirect_uri"], FakeUserAgent.redirect.absoluteString)
        XCTAssertNil(query["resource"], "A REST API sign-in names no MCP resource")
        XCTAssertNil(query["login_hint"])

        let form = FakeConnectorServer.form(try XCTUnwrap(google.requests.first { $0.url?.path() == "/token" }))
        XCTAssertEqual(form["grant_type"], "authorization_code")
        XCTAssertEqual(form["code"], FakeConnectorServer.code)
        XCTAssertEqual(form["client_id"], FakeGoogle.clientID)
        XCTAssertEqual(form["client_secret"], FakeGoogle.clientSecret)
        XCTAssertEqual(form["redirect_uri"], FakeUserAgent.redirect.absoluteString)
        XCTAssertNil(form["resource"])
        XCTAssertEqual(query["code_challenge"],
                       ConnectorOAuth.codeChallenge(for: try XCTUnwrap(form["code_verifier"]), sha256: MacOAuthUserAgent.sha256))

        let credential = try XCTUnwrap(credentials.load(record.id))
        XCTAssertEqual(credential.kind, .oauth)
        XCTAssertNotNil(credential.refreshToken)
        XCTAssertEqual(credential.clientID, FakeGoogle.clientID)
        XCTAssertEqual(credential.tokenEndpoint, FakeGoogle.endpoints.token)
        XCTAssertNil(credential.resource)
        let profile = try XCTUnwrap(google.requests.first { $0.url?.path().hasSuffix("/users/me/profile") == true })
        XCTAssertEqual(profile.value(forHTTPHeaderField: "Authorization"), "Bearer \(credential.accessToken)")

        // Its tools reach harnesses under the service's name; each call names its account, one of those here.
        let tools = await center.connectorTools(for: ConnectorToolContext())
        XCTAssertEqual(tools.compactMap { $0["name"]?.stringValue },
                       ["gmail_search_threads", "gmail_list_labels", "gmail_send_message"])
        XCTAssertEqual(tools.first?["title"], .string("Gmail: search_threads"))
        XCTAssertTrue(tools.first?["description"]?.stringValue?.hasPrefix("[Gmail] ") == true)
        for tool in tools {
            let schema = tool["inputSchema"]
            XCTAssertEqual(schema?["required"]?.arrayValue?.first, .string("account"), "No default account")
            XCTAssertEqual(schema?["properties"]?["account"]?["enum"], .array([.string("person@example.test")]))
        }
        XCTAssertEqual(ConnectorSettingsState.make(record, in: center), .connected(tools: 3))
        XCTAssertEqual(ConversationLineWording.mcpLabel("mcp__yardlet__gmail_send_message", account: "person@example.test"),
                       "Gmail · person@example.test: send message")
    }

    /// The same flow through the real loopback listener: the browser stand-in follows Google's
    /// redirect to 127.0.0.1 over HTTP.
    func testTheCodeComesBackThroughTheRealLoopbackListener() async throws {
        let google = FakeGoogle()
        let browser = LoopbackBrowser()
        let center = makeCenter(google: google, agent: browser)
        try await center.saveGoogleApp(clientID: FakeGoogle.clientID, secret: FakeGoogle.clientSecret)
        let record = try XCTUnwrap(center.addGmailAccount())
        await center.waitForConnection(record.id)
        XCTAssertNil(center.failures[record.id])
        XCTAssertEqual(center.record(record.id)?.status, .connected)
        XCTAssertEqual(browser.requestedPorts, [ConnectorOAuth.registeredClientRedirectPort])
        let redirect = try XCTUnwrap(browser.redirects.first)
        XCTAssertEqual(redirect.host(), "127.0.0.1")
        XCTAssertEqual(redirect.path(), "/callback")
        try await waitUntil { !browser.pages.isEmpty }
        XCTAssertEqual(browser.pages.first?.contains("Yardlet"), true, "The loopback's page tells the person to go back")
        let form = FakeConnectorServer.form(try XCTUnwrap(google.requests.first { $0.url?.path() == "/token" }))
        XCTAssertEqual(form["redirect_uri"], redirect.absoluteString.components(separatedBy: "?").first)
    }

    func testAScopeLeftUncheckedOrNoRefreshTokenIsNotASignIn() async throws {
        let google = FakeGoogle()
        google.grantedScope = "openid"
        let center = makeCenter(google: google)
        try await center.saveGoogleApp(clientID: FakeGoogle.clientID, secret: FakeGoogle.clientSecret)
        let record = try XCTUnwrap(center.addGmailAccount())
        await center.waitForConnection(record.id)
        XCTAssertEqual(center.failures[record.id], GoogleSignInError.scopeNotGranted([.gmail]).errorDescription)
        XCTAssertNotEqual(center.record(record.id)?.status, .connected)

        google.grantedScope = GoogleOAuth.scope(for: [.gmail])
        google.issuesRefreshToken = false
        center.connect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertEqual(center.failures[record.id], GoogleSignInError.noRefreshToken.errorDescription)
    }

    // MARK: - Tokens

    func testAnExpiringTokenIsRefreshedFirstAndARefusedOneAfter() async throws {
        let google = FakeGoogle()
        let clock = TestClock()
        let credentials = InMemoryConnectorCredentialStore()
        let (center, record) = try await signedIn(google: google, credentials: credentials, now: { clock.now })
        let first = try XCTUnwrap(credentials.load(record.id))

        // Within a minute of expiry: refreshed before the call, with the app's secret.
        clock.now = clock.now.addingTimeInterval(3_590)
        _ = try json(try await call(center, "gmail_list_labels"))
        let refresh = FakeConnectorServer.form(try XCTUnwrap(google.requests.last { $0.url?.path() == "/token" }))
        XCTAssertEqual(refresh["grant_type"], "refresh_token")
        XCTAssertEqual(refresh["refresh_token"], first.refreshToken)
        XCTAssertEqual(refresh["client_secret"], FakeGoogle.clientSecret)
        let second = try XCTUnwrap(credentials.load(record.id))
        XCTAssertNotEqual(second.accessToken, first.accessToken)
        XCTAssertEqual(second.refreshToken, first.refreshToken, "Google sends no new refresh token; the old one stays")
        XCTAssertEqual(google.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer \(second.accessToken)")

        // Google refuses the token before its time: one refresh and the call again.
        google.forgetAccessTokens()
        let refreshes = google.requests.filter { $0.url?.path() == "/token" }.count
        _ = try json(try await call(center, "gmail_list_labels"))
        XCTAssertEqual(google.requests.filter { $0.url?.path() == "/token" }.count, refreshes + 1)
        XCTAssertEqual(center.record(record.id)?.status, .connected)
    }

    /// A revoked sign-in (Google's `invalid_grant`) leaves the account needing sign-in, the call says
    /// so, and Reconnect signs the same account in again.
    func testARevokedSignInAsksToReconnectAndReconnectNamesTheAccount() async throws {
        let google = FakeGoogle()
        let agent = FakeUserAgent()
        let (center, record) = try await signedIn(google: google, agent: agent)
        google.revoke("person@example.test")

        let refused = try await call(center, "gmail_search_threads")
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("needs the user to sign in again"), refused.text)
        let stale = try XCTUnwrap(center.record(record.id))
        XCTAssertEqual(stale.status, .signInRequired)
        XCTAssertEqual(ConnectorSettingsState.make(stale, in: center), .needsSignIn)
        XCTAssertFalse(center.offersTools, "Its tools leave new sessions")

        center.reconnect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertNil(center.failures[record.id])
        XCTAssertEqual(center.record(record.id)?.status, .connected)
        XCTAssertEqual(center.record(record.id)?.account, "person@example.test")
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(agent.opened.last),
                                                                   resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["login_hint"], "person@example.test")
        XCTAssertEqual(query["prompt"], "consent")
        _ = try json(try await call(center, "gmail_list_labels"))
    }

    /// Signing in again keeps the account's earlier sign-in until a new one is the account's:
    /// Cancel on Google's page changes nothing, not even the account's place in Settings, and a
    /// sign-in as another account is refused while the earlier one still serves the tools, the
    /// account stays connected in its place, and the reason is its row's note.
    func testSigningInAgainKeepsTheEarlierSignInUntilANewOneIsTheAccounts() async throws {
        let google = FakeGoogle()
        let agent = FakeUserAgent()
        let credentials = InMemoryConnectorCredentialStore()
        let (center, record) = try await signedIn(google: google, agent: agent, credentials: credentials)
        google.signInAs = "developer@company.test"
        let work = try XCTUnwrap(center.addGmailAccount())
        await center.waitForConnection(work.id)
        let earlier = try credentials.load(record.id)
        let order = ConnectorSettingsState.ordered(center).map(\.id)
        XCTAssertEqual(order, [record.id, work.id])

        agent.declines = true
        center.reconnect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertEqual(agent.opened.count, 3, "Google's page opened again")
        XCTAssertEqual(try credentials.load(record.id), earlier)
        XCTAssertNil(center.failures[record.id])
        XCTAssertEqual(center.record(record.id), record)
        XCTAssertEqual(ConnectorSettingsState.ordered(center).map(\.id), order)
        _ = try json(try await call(center, "gmail_list_labels", ["account": .string("person@example.test")]))
        XCTAssertEqual(google.account(of: try XCTUnwrap(google.requests.last)), "person@example.test")

        agent.declines = false
        google.signInAs = "someone.else@example.test"
        center.reconnect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertEqual(center.record(record.id), record)
        XCTAssertEqual(center.failures[record.id], L10n.format("Google signed in %@, not %@. Reconnect and choose %@.",
                                                               "someone.else@example.test", "person@example.test", "person@example.test"))
        XCTAssertEqual(try credentials.load(record.id), earlier, "The other account's sign-in is not kept")
        XCTAssertEqual(ConnectorSettingsState.make(record, in: center), .connected(tools: record.offeredTools.count))
        XCTAssertEqual(ConnectorSettingsState.note(record, in: center), center.failures[record.id])
        XCTAssertEqual(ConnectorSettingsState.ordered(center).map(\.id), order)
        _ = try json(try await call(center, "gmail_list_labels", ["account": .string("person@example.test")]))
        XCTAssertEqual(google.account(of: try XCTUnwrap(google.requests.last)), "person@example.test")
    }

    // MARK: - Tools

    func testCancellingAFirstSignInLeavesNoAccount() async throws {
        let agent = FakeUserAgent(answers: false)
        let center = makeCenter(agent: agent)
        try await center.saveGoogleApp(clientID: FakeGoogle.clientID, secret: FakeGoogle.clientSecret)
        let record = try XCTUnwrap(center.addGmailAccount())
        try await waitUntil { center.activity[record.id] == .waitingForBrowser }
        XCTAssertEqual(ConnectorSettingsState.make(try XCTUnwrap(center.record(record.id)), in: center), .waitingForBrowser)
        center.cancelConnect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertNil(center.record(record.id))
        XCTAssertTrue(center.gmailAccounts.isEmpty)
    }

    // MARK: - Several accounts

    func testGoogleWorkspaceMCPRevokedRefreshMarksAllServicesForReconnect() async throws {
        let google = FakeGoogle()
        google.grantedScope = GoogleOAuth.scope(for: [.gmail, .googleCalendar])
        let center = makeCenter(google: google)
        try await center.saveGoogleApp(clientID: FakeGoogle.clientID, secret: FakeGoogle.clientSecret)
        let account = try XCTUnwrap(center.addAccount(services: [.gmail, .googleCalendar]))
        await center.waitForConnection(account.id)
        XCTAssertEqual(account.services.count, 2)
        for record in account.services { XCTAssertEqual(center.record(record.id)?.status, .connected) }
        google.revoke(google.signInAs)
        let refused = try await call(center, "gmail_list_labels")
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("Reconnect"), refused.text)
        for record in account.services { XCTAssertEqual(center.record(record.id)?.status, .signInRequired) }
    }

    func testGoogleWorkspaceMCPRegisteredToolsUseRoundTripDeadlinesAndTaskScope() async throws {
        let google = FakeGoogle()
        let server = GoogleScriptedServer([.init(body: #"{"id":1,"result":{"tools":[{"name":"list_labels"}]}}"#), .form(), .done])
        let center = makeCenter(google: google, configure: { environment in
            environment.googleWorkspaceTransport = server
            environment.toolCallLimit = .zero
        })
        try await center.saveGoogleApp(clientID: FakeGoogle.clientID, secret: FakeGoogle.clientSecret)
        let record = try XCTUnwrap(center.addGmailAccount())
        await center.waitForConnection(record.id)
        let task = UUID()
        let context = ConnectorToolContext(taskID: task)
        XCTAssertEqual(center.googleWorkspaceToolNames(for: context), ["gmail_list_labels"])
        XCTAssertEqual(center.connectorToolFacts(named: "gmail_list_labels", for: context)?.usesGoogleWorkspaceMCP, true)
        XCTAssertEqual(center.connectorToolFacts(named: "gmail_send_message", for: context)?.usesGoogleWorkspaceMCP, nil)
        center.googleWorkspaceResponder = { id in
            XCTAssertEqual(id, task)
            return { _ in "ALLOW_ONCE" }
        }
        let result = try XCTUnwrapAsync(await center.callNamingTheOnlyAccount("gmail_list_labels", [:], for: context))
        XCTAssertFalse(result.isError, result.text)
        let requests = await server.requests
        XCTAssertEqual(requests.map(\.timeoutInterval), [150, 150, 150])
        center.setConnector(record.id, on: false, inTask: task)
        XCTAssertEqual(center.googleWorkspaceToolNames(for: context), [])
    }

    /// Accounts share one set of tools: each call names the account it acts in, one of those connected and
    /// on in the task, with no default, and goes with that account's sign-in.
    func testAccountsShareOneSetOfToolsAndEachCallNamesItsAccount() async throws {
        let google = FakeGoogle()
        let credentials = InMemoryConnectorCredentialStore()
        let (center, personal) = try await signedIn("person@example.test", google: google, credentials: credentials)
        google.signInAs = "developer@company.test"
        let work = try XCTUnwrap(center.addGmailAccount())
        await center.waitForConnection(work.id)
        XCTAssertEqual(center.record(work.id)?.account, "developer@company.test")
        XCTAssertEqual(center.gmailAccounts.map(\.account), ["person@example.test", "developer@company.test"])
        XCTAssertNotEqual(try credentials.load(personal.id)?.accessToken, try credentials.load(work.id)?.accessToken)

        let tools = await center.connectorTools(for: ConnectorToolContext())
        XCTAssertEqual(tools.count, 3, "One set for both accounts")
        XCTAssertTrue(tools.allSatisfy {
            $0["inputSchema"]?["properties"]?["account"]?["enum"]
                == .array([.string("person@example.test"), .string("developer@company.test")])
        })

        // Each call goes with the token of the account it names, in any case, to that account's mailbox.
        let mine = try json(try await call(center, "gmail_list_labels", ["account": .string("person@example.test")]))
        XCTAssertEqual(google.account(of: try XCTUnwrap(google.requests.last)), "person@example.test")
        let theirs = try json(try await call(center, "gmail_list_labels", ["account": .string("Developer@company.test")]))
        XCTAssertEqual(google.account(of: try XCTUnwrap(google.requests.last)), "developer@company.test")
        XCTAssertEqual(mine, theirs)

        // A call that names no account, or one Yardlet does not have, goes nowhere.
        let sent = google.requests.count
        let unnamed = try await call(center, "gmail_list_labels")
        XCTAssertEqual(unnamed.failure?.kind, .invalidArguments, unnamed.text)
        XCTAssertTrue(unnamed.text.contains("account takes one of: person@example.test, developer@company.test."),
                      "A resumed Claude Code task may hold the schema from before `account`: \(unnamed.text)")
        let unknown = try await call(center, "gmail_list_labels", ["account": .string("someone@elsewhere.test")])
        XCTAssertEqual(unknown.failure?.kind, .invalidArguments, unknown.text)
        XCTAssertTrue(unknown.text.contains("person@example.test, developer@company.test"), unknown.text)
        XCTAssertEqual(google.requests.count, sent)

        // The conversation names the account selected by the call.
        XCTAssertEqual(ConversationLineWording.mcpLabel("mcp__yardlet__gmail_send_message", account: "developer@company.test"),
                       "Gmail · developer@company.test: send message")
        // A name from before the accounts shared their tools still reads as its account's.
        XCTAssertEqual(ConversationLineWording.mcpLabel("mcp__yardlet__gmail_developer_send_message"),
                       "Gmail · developer@company.test: send message")

        // Turned off in one task, only that account leaves it.
        let task = UUID()
        center.setConnector(work.id, on: false, inTask: task)
        let inTask = await center.connectorTools(for: ConnectorToolContext(taskID: task))
        XCTAssertEqual(inTask.count, 3)
        XCTAssertEqual(inTask.first?["inputSchema"]?["properties"]?["account"]?["enum"], .array([.string("person@example.test")]))
        let off = try XCTUnwrapAsync(await center.callConnectorTool(
            named: "gmail_list_labels", arguments: .object(["account": .string("developer@company.test")]),
            for: ConnectorToolContext(taskID: task)))
        XCTAssertEqual(off.failure?.kind, .refused, off.text)
        XCTAssertTrue(off.text.contains("developer@company.test"), off.text)

        // Signing in to an account that is here already keeps one connector for it.
        google.signInAs = "Person@example.test"
        let again = try XCTUnwrap(center.addGmailAccount())
        await center.waitForConnection(again.id)
        XCTAssertNil(center.record(again.id))
        XCTAssertEqual(center.gmailAccounts.count, 2)
        XCTAssertNil(try credentials.load(again.id))
        XCTAssertEqual(center.record(personal.id)?.status, .connected)
        _ = try json(try await call(center, "gmail_list_labels", ["account": .string("person@example.test")]))

        // Turning off the last service keeps the account row, but its address leaves tool hints.
        await center.setService(.gmail, on: false, account: work.credentialID)
        XCTAssertEqual(center.googleAccounts.count, 2)
        let invalid = try await call(center, "gmail_list_labels", ["account": .string("unknown@example.test")])
        XCTAssertEqual(invalid.failure?.kind, .invalidArguments)
        XCTAssertTrue(invalid.text.contains("person@example.test"), invalid.text)
        XCTAssertFalse(invalid.text.contains("developer@company.test"), invalid.text)

        // Removing one leaves the other, its sign-in and its tools.
        center.remove(work.id)
        await center.waitForPendingDeletions()
        XCTAssertNil(try credentials.load(work.id))
        XCTAssertNotNil(try credentials.load(personal.id))
        XCTAssertEqual(center.gmailAccounts.map(\.account), ["person@example.test"])
        let left = await center.connectorTools(for: ConnectorToolContext())
        XCTAssertEqual(left.first?["inputSchema"]?["properties"]?["account"]?["enum"], .array([.string("person@example.test")]))
    }

    // MARK: - Reaching each harness

    func testTheToolsReachClaudeCodexAndACPTasks() async throws {
        let (center, _) = try await signedIn()
        let broker = AgentToolBroker(
            environment: AgentToolBroker.Environment(executableURL: try makeExecutable(), endpoint: "/tmp/unused.sock",
                                                     privateDirectory: FileManager.default.temporaryDirectory,
                                                     isEnabled: { false }),
            tools: BrowserAgentTools(usesMacEditingCommands: true, pages: { _ in throw CancellationError() }, closePage: { _ in }))
        broker.connectors = center
        XCTAssertEqual(AgentToolInjectionRoute.route(for: .claudeCode), .claudeMCPConfig)
        XCTAssertEqual(AgentToolInjectionRoute.route(for: .codex), .codexThreadConfig)
        XCTAssertEqual(AgentToolInjectionRoute.route(for: .openCode), .acpSessionMCPServers)
        XCTAssertEqual(AgentToolInjectionRoute.route(for: .antigravityCLI), .acpSessionMCPServers)

        // Off, each harness lists the tools (Antigravity through its gateway); in Auto, the default, three
        // tools leave Claude Code and Codex as they were and give OpenCode and Antigravity Code Mode.
        for mode in [CodeModePreference.Mode.off, .auto] {
            broker.codeModeSetting = { mode }
            for harness in [HarnessKind.claudeCode, .codex, .openCode, .antigravityCLI] {
                let task = UUID()
                let launch = try XCTUnwrap(broker.agentToolServer(for: task, workspaceRoots: [],
                                                                  connectorScope: ConnectorTaskScope(harness: harness)))
                let token = try XCTUnwrap(launch.environment[AgentToolEnvironment.token])
                let list = try XCTUnwrapAsync(await broker.list(AgentToolCall(
                    token: token, session: task.uuidString, tool: "", arguments: .object([:]), method: AgentToolCall.listMethod)))
                let names = list.tools.compactMap { $0["name"]?.stringValue }
                if CodeModePreference.isOn(mode, harness: harness, connectorToolCount: 3) {
                    XCTAssertEqual(mode, .auto)
                    XCTAssertTrue(names.contains(CodeModeToolCatalog.runScript), harness.rawValue)
                    XCTAssertFalse(names.contains { $0.hasPrefix("gmail_") }, harness.rawValue)
                    XCTAssertFalse(names.contains(ConnectorGatewayToolCatalog.listTools), harness.rawValue)
                    let script = await broker.handle(AgentToolCall(
                        token: token, session: task.uuidString, tool: CodeModeToolCatalog.runScript,
                        arguments: .object(["code": .string(
                            "return callTool('gmail_list_labels', { account: 'person@example.test' });")])))
                    XCTAssertFalse(script.isError, "\(harness.rawValue): \(script.text)")
                    XCTAssertTrue(script.text.contains("labels"), script.text)
                } else if harness == .antigravityCLI {
                    XCTAssertTrue(names.contains(ConnectorGatewayToolCatalog.listTools), harness.rawValue)
                    XCTAssertTrue(names.contains(ConnectorGatewayToolCatalog.callTool), harness.rawValue)
                    let listed = await broker.handle(AgentToolCall(
                        token: token, session: task.uuidString, tool: ConnectorGatewayToolCatalog.listTools,
                        arguments: .object(["service": .string("gmail")])))
                    XCTAssertFalse(listed.isError, listed.text)
                    let decoded = try JSONDecoder().decode([ToolJSON].self, from: Data(listed.text.utf8))
                    XCTAssertEqual(decoded.count, 3, harness.rawValue)
                    let call = await broker.handle(AgentToolCall(
                        token: token, session: task.uuidString, tool: ConnectorGatewayToolCatalog.callTool,
                        arguments: .object([
                            "tool": .string("gmail_list_labels"),
                            "arguments": .object(["account": .string("person@example.test")])
                        ])))
                    XCTAssertFalse(call.isError, "\(harness.rawValue): \(call.text)")
                    XCTAssertTrue(call.text.contains("\"labels\""), call.text)
                } else {
                    let gmail = names.filter { $0.hasPrefix("gmail_") }
                    let call = await broker.handle(AgentToolCall(token: token, session: task.uuidString, tool: "gmail_list_labels",
                                                                 arguments: .object(["account": .string("person@example.test")])))
                    XCTAssertEqual(gmail.count, 3, harness.rawValue)
                    XCTAssertFalse(call.isError, "\(harness.rawValue): \(call.text)")
                    XCTAssertTrue(call.text.contains("\"labels\""), call.text)
                }
            }
        }

        // Claude's document and ACP's server carry only the launch; the token never goes to a harness.
        let launch = try XCTUnwrap(broker.agentToolServer(for: UUID(), workspaceRoots: [],
                                                          connectorScope: ConnectorTaskScope(harness: .claudeCode)))
        // The server's instructions name the kinds of services the task has, never an account, and stay short:
        // Codex's code mode repeats them with every tool.
        let services = AgentToolEnvironment.services(in: launch.environment)
        XCTAssertEqual(services, ["Gmail"])
        let instructions = AgentToolCatalog.serverInstructions(services: services)
        XCTAssertTrue(instructions.contains("Services the user connected in Yardlet: Gmail."), instructions)
        XCTAssertFalse(instructions.contains("person@example.test"), instructions)
        XCTAssertLessThan(instructions.count, 1_200)
        let documents = [launch.claudeConfig, launch.codexConfig, launch.acpServer].map { String(describing: $0) }
        for document in documents {
            XCTAssertFalse(document.contains("access-"), "No Google token in a harness's configuration")
            XCTAssertFalse(document.contains(FakeGoogle.clientSecret))
        }
    }

    // MARK: - Helpers

    private func makeExecutable() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "yardlet-mcp-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

}

/// A browser stand-in on the real loopback listener: it listens on any free port (a test must not
/// take 47823 from a running Yardlet), records the port Yardlet asked for, and follows the
/// authorization page's redirect over HTTP as Google would send the browser back.
final class LoopbackBrowser: OAuthUserAgent, @unchecked Sendable {
    private let lock = NSLock()
    private var ports: [UInt16?] = []
    private var followed: [URL] = []
    private var bodies: [String] = []

    var requestedPorts: [UInt16?] { lock.withLock { ports } }
    var redirects: [URL] { lock.withLock { followed } }
    var pages: [String] { lock.withLock { bodies } }

    func startLoopback(port: UInt16?, state: String) async throws -> any OAuthLoopbackReceiving {
        lock.withLock { ports.append(port) }
        return try await MacOAuthLoopback.start(port: nil, state: state)
    }

    func open(_ url: URL) async -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let redirect = items.first(where: { $0.name == "redirect_uri" })?.value,
              let state = items.first(where: { $0.name == "state" })?.value,
              let target = URL(string: "\(redirect)?code=\(FakeConnectorServer.code)&state=\(state)")
        else { return false }
        lock.withLock { followed.append(target) }
        Task.detached {
            guard let (data, _) = try? await URLSession(configuration: .ephemeral).data(from: target) else { return }
            self.lock.withLock { self.bodies.append(String(decoding: data, as: UTF8.self)) }
        }
        return true
    }

    /// Google's sign-in is on Yardlet's own addresses, which ask nothing; a question would stop it.
    func confirm(_ confirmation: ConnectorSignInConfirmation) async -> Bool { false }
}

/// Google's authorization server, token endpoint, and Gmail API for a few mailboxes, as the
/// documentation describes their requests and answers. Tokens map to the account that signed in.
final class FakeGoogle: ConnectorHTTPTransport, @unchecked Sendable {
    static let endpoints = GoogleOAuth.Endpoints(
        authorization: URL(string: "https://accounts.google.test/o/oauth2/v2/auth")!,
        token: URL(string: "https://oauth2.google.test/token")!,
        gmailAPI: URL(string: "https://gmail.google.test/gmail/v1/")!)
    static let clientID = "123-fake.apps.googleusercontent.com"
    static let secondClientID = "456-test.apps.googleusercontent.com"
    static let calendarClientID = "calendar-ui.apps.googleusercontent.com"
    static let clientSecret = "GOC" + "SPX-fake-secret"

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var accessTokens: [String: String] = [:]
    private var refreshTokens: [String: String] = [:]
    /// What each refresh token was granted, as Google lists it again on every refresh.
    private var refreshScopes: [String: String] = [:]
    private var revokedAccounts: Set<String> = []
    private var issued = 0
    private var nextAccount = "person@example.test"
    private var granted: String? = GoogleOAuth.scope(for: [.gmail])
    private var refreshTokenIssued = true

    var requests: [URLRequest] { lock.withLock { recorded } }
    /// The account the browser signs in to next.
    var signInAs: String {
        get { lock.withLock { nextAccount } }
        set { lock.withLock { nextAccount = newValue } }
    }
    var grantedScope: String? {
        get { lock.withLock { granted } }
        set { lock.withLock { granted = newValue } }
    }
    var issuesRefreshToken: Bool {
        get { lock.withLock { refreshTokenIssued } }
        set { lock.withLock { refreshTokenIssued = newValue } }
    }

    func forgetAccessTokens() { lock.withLock { accessTokens.removeAll() } }
    func revoke(_ account: String) {
        lock.withLock {
            revokedAccounts.insert(account)
            accessTokens = accessTokens.filter { $0.value != account }
        }
    }

    func account(of request: URLRequest) -> String? {
        let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
        return lock.withLock { token.flatMap { accessTokens[$0] } }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        guard let url = request.url else { throw URLError(.badURL) }
        if url.host() == "oauth2.google.test", url.path() == "/token" { return token(request) }
        guard let account = account(of: request) else { return reply(url, 401, [:]) }
        if url.path() == "/mcp/v1", let host = url.host(), let names = Self.tools[host] {
            if let problem = lock.withLock({ endpointFailures[host] }) {
                if problem == 0 { throw URLError(.notConnectedToInternet) }
                return reply(url, problem, ["error": .object(["message": .string("SERVICE_DISABLED")])])
            }
            let rpc = try JSONDecoder().decode(ToolJSON.self, from: request.httpBody ?? Data())
            let result: ToolJSON
            if rpc["method"] == .string("tools/list") {
                result = .object(["tools": .array(names.map { name in .object([
                    "name": .string(name), "inputSchema": .object(["type": .string("object")]),
                    "annotations": .object(["readOnlyHint": .bool(!["create_file", "send_message", "create_event"].contains(name))])
                ]) })])
            } else {
                guard let name = rpc["params"]?["name"]?.stringValue, names.contains(name),
                      rpc["params"]?["arguments"]?["account"] == nil else { return reply(url, 400, [:]) }
                let content: ToolJSON = name == "list_labels" ? .object(["labels": .array([])]) : .object(["account": .string(account)])
                let text = String(decoding: try JSONEncoder().encode(content), as: UTF8.self)
                result = .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])])])
            }
            return reply(url, 200, ["id": .integer(1), "result": result])
        }
        if url.path().hasSuffix("/users/me/profile") { return reply(url, 200, ["emailAddress": .string(account)]) }
        if url.path().hasSuffix("/userinfo") { return reply(url, 200, ["email": .string(account)]) }
        return reply(url, 404, [:])
    }

    static let tools = [
        "gmailmcp.googleapis.com": ["search_threads", "list_labels", "send_message"],
        "calendarmcp.googleapis.com": ["list_calendars", "list_events", "create_event"],
        "drivemcp.googleapis.com": ["search_files", "list_recent_files", "create_file"],
        "docsmcp.googleapis.com": ["read_doc"],
        "sheetsmcp.googleapis.com": ["get_values"],
        "slidesmcp.googleapis.com": ["read_presentation"]
    ]
    /// A connected row in a settings preview already has its last discovered schema.
    static func withCachedTools(_ record: ConnectorRecord) -> ConnectorRecord {
        guard record.status == .connected, let endpoints = record.localService?.workspaceEndpoints,
              !endpoints.isEmpty else { return record }
        var row = record
        var routes: [String: GoogleWorkspaceEndpoint] = [:]
        for endpoint in endpoints {
            for name in tools[endpoint.url.host() ?? ""] ?? [] { routes[name] = endpoint }
        }
        row.workspaceToolEndpoints = routes
        row.tools = routes.keys.sorted().map { .object(["name": .string($0)]) }
        row.toolsUpdatedAt = .now
        return row
    }

    private var endpointFailures: [String: Int] = [:]
    func fail(_ endpoint: GoogleWorkspaceEndpoint, status: Int?) {
        lock.withLock { endpointFailures[endpoint.url.host()!] = status }
    }

    private func reply(_ url: URL, _ status: Int, _ body: [String: ToolJSON]) -> (Data, HTTPURLResponse) {
        ((try? JSONEncoder().encode(ToolJSON.object(body))) ?? Data(),
         HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }

    private func token(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        let url = request.url!
        let form = FakeConnectorServer.form(request)
        guard [Self.clientID, Self.secondClientID, Self.calendarClientID].contains(form["client_id"] ?? ""), form["client_secret"] == Self.clientSecret else {
            return reply(url, 401, ["error": .string("invalid_client")])
        }
        return lock.withLock {
            issued += 1
            let access = "access-\(issued)"
            switch form["grant_type"] {
            case "authorization_code":
                guard form["code"] == FakeConnectorServer.code, form["code_verifier"] != nil, form["redirect_uri"] != nil else {
                    return reply(url, 400, ["error": .string("invalid_grant"), "error_description": .string("Bad code")])
                }
                let account = nextAccount
                revokedAccounts.remove(account)
                accessTokens[access] = account
                var body: [String: ToolJSON] = ["access_token": .string(access), "expires_in": .integer(3599),
                                                "token_type": .string("Bearer")]
                if let granted { body["scope"] = .string(granted) }
                if refreshTokenIssued {
                    let refresh = "1//refresh-\(issued)"
                    refreshTokens[refresh] = account
                    refreshScopes[refresh] = granted
                    body["refresh_token"] = .string(refresh)
                }
                return reply(url, 200, body)
            case "refresh_token":
                guard let refresh = form["refresh_token"], let account = refreshTokens[refresh],
                      !revokedAccounts.contains(account) else {
                    return reply(url, 400, ["error": .string("invalid_grant"),
                                            "error_description": .string("Token has been expired or revoked.")])
                }
                accessTokens[access] = account
                return reply(url, 200, ["access_token": .string(access), "expires_in": .integer(3599),
                                        "scope": .string(refreshScopes[refresh] ?? GoogleOAuth.scope(for: [.gmail])),
                                        "token_type": .string("Bearer")])
            default:
                return reply(url, 400, ["error": .string("unsupported_grant_type")])
            }
        }
    }

}
