import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Yardlet's own Gmail server (docs/CONNECTORS.md, "Google"): the Google OAuth app kept in the secure
/// store, each Google account's sign-in over the loopback redirect, token refresh and a revoked
/// sign-in, every tool's Gmail API request and answer, attachments from local files, the harness
/// asking before sends, draft deletions, and label changes, several accounts, and the tools
/// reaching each harness. Google is a local fake here:
/// no request leaves the machine and no real account signs in.
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
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> ConnectorCenter {
        var environment = ConnectorCenter.Environment(
            repository: repository, credentials: credentials, http: google, userAgent: agent,
            sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9", now: now)
        environment.google = FakeGoogle.endpoints
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
        try XCTUnwrapAsync(await center.callConnectorTool(named: name, arguments: .object(arguments),
                                                          for: ConnectorToolContext(workspaceRoots: folders)))
    }

    /// An empty folder of the test's own, removed afterwards.
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "yardlet-gmail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        directories.append(folder)
        return folder
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
                       .client(id: FakeGoogle.clientID, secret: FakeGoogle.clientSecret))
        let file = try String(contentsOf: repository.fileURL, encoding: .utf8)
        XCTAssertTrue(file.contains(FakeGoogle.clientID), "The client ID is shown without a keychain read")
        XCTAssertFalse(file.contains(FakeGoogle.clientSecret), "The secret stays in the secure store")

        // A relaunch knows the app; removing it forgets both.
        XCTAssertEqual(makeCenter(credentials: credentials, repository: repository).googleAppClientID, FakeGoogle.clientID)
        try await center.removeGoogleApp()
        XCTAssertNil(center.googleAppClientID)
        XCTAssertNil(try credentials.load(GoogleOAuth.appCredentialID))
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
        XCTAssertEqual(query["scope"], "https://www.googleapis.com/auth/gmail.modify", "One restricted scope, not mail.google.com")
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

        // Its tools reach harnesses under its slug, led by the account.
        let tools = await center.connectorTools(for: ConnectorToolContext())
        XCTAssertEqual(tools.compactMap { $0["name"]?.stringValue },
                       ["gmail_search_threads", "gmail_get_thread", "gmail_get_message", "gmail_list_labels",
                        "gmail_create_draft", "gmail_send_draft", "gmail_send_message", "gmail_modify_labels",
                        "gmail_delete_draft"])
        XCTAssertEqual(tools.first?["title"], .string("Gmail · person@example.test: Search threads"))
        XCTAssertTrue(tools.first?["description"]?.stringValue?.hasPrefix("[Gmail · person@example.test] ") == true)
        XCTAssertEqual(ConnectorSettingsState.make(record, in: center), .connected(tools: 9))
        XCTAssertEqual(ConnectorToolLabels.shared.label(forClaudeTool: "mcp__yardlet__gmail_send_message")?.account,
                       "person@example.test")
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

        google.grantedScope = GmailToolCatalog.scope
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
        _ = try json(try await call(center, "gmail_list_labels"))
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
        _ = try json(try await call(center, "gmail_list_labels"))
        XCTAssertEqual(google.account(of: try XCTUnwrap(google.requests.last)), "person@example.test")
    }

    // MARK: - Tools

    func testSearchThreadsMapsTheQueryAndSummarizesEachThread() async throws {
        let google = FakeGoogle()
        let (center, _) = try await signedIn(google: google)
        let result = try json(try await call(center, "gmail_search_threads", [
            "query": .string("from:alice +report is:unread"), "pageSize": .integer(80),
            "pageToken": .string("page-2"), "includeTrash": .bool(true)
        ]))
        let list = try XCTUnwrap(google.requests.first { $0.url?.path() == "/gmail/v1/users/me/threads" })
        let items = URLComponents(url: try XCTUnwrap(list.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "from:alice +report is:unread")
        XCTAssertTrue(list.url?.absoluteString.contains("%2Breport") == true, "+ is kept, not read as a space")
        XCTAssertEqual(items.first { $0.name == "maxResults" }?.value, "50", "At most 50 a page")
        XCTAssertEqual(items.first { $0.name == "pageToken" }?.value, "page-2")
        XCTAssertEqual(items.first { $0.name == "includeSpamTrash" }?.value, "true")

        let detail = try XCTUnwrap(google.requests.first { $0.url?.path() == "/gmail/v1/users/me/threads/t1" })
        let detailItems = URLComponents(url: try XCTUnwrap(detail.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(detailItems.first { $0.name == "format" }?.value, "metadata", "No bodies for a search")

        let threads = try XCTUnwrap(result["threads"]?.arrayValue)
        XCTAssertEqual(threads.compactMap { $0["id"]?.stringValue }, ["t1", "t2"], "The search's order")
        XCTAssertEqual(result["nextPageToken"], .string("page-3"))
        XCTAssertEqual(threads[0]["messageCount"], .integer(2))
        let first = try XCTUnwrap(threads[0]["messages"]?.arrayValue?.first)
        XCTAssertEqual(first["from"], .string("Alice <alice@example.com>"))
        XCTAssertEqual(first["subject"], .string("Quarterly report"))
        XCTAssertEqual(first["snippet"], .string("Numbers for Q3 & what's next"), "Entities decoded")
        XCTAssertEqual(first["unread"], .bool(true))
        XCTAssertNil(first["body"])
        XCTAssertTrue(first["date"]?.stringValue?.hasPrefix("2026-") == true)

        // A thread deleted between the list and its lookup is left out, not an error.
        let gone = try json(try await call(center, "gmail_search_threads", ["query": .string("gone")]))
        XCTAssertEqual(gone["threads"]?.arrayValue?.compactMap { $0["id"]?.stringValue }, ["t1"])
    }

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

    func testGetThreadAndMessageReadBodiesInTheirCharsetAndFormats() async throws {
        let google = FakeGoogle()
        let (center, _) = try await signedIn(google: google)

        let thread = try json(try await call(center, "gmail_get_thread", ["threadId": .string("t1")]))
        let request = try XCTUnwrap(google.requests.last { $0.url?.path() == "/gmail/v1/users/me/threads/t1" })
        XCTAssertTrue(request.url?.query()?.contains("format=full") == true)
        let messages = try XCTUnwrap(thread["messages"]?.arrayValue)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["body"], .string("Hi team,\nNumbers attached."), "The plain part")
        XCTAssertNil(messages[0]["htmlBody"], "PLAIN_TEXT is the default")
        XCTAssertEqual(messages[0]["attachments"], .array([.object(["filename": .string("q3.pdf"),
                                                                     "mimeType": .string("application/pdf"),
                                                                     "size": .integer(2048)])]))
        XCTAssertEqual(messages[1]["body"], .string("Thanks!\nWill read."), "An HTML-only reply as text")

        let full = try json(try await call(center, "gmail_get_message", ["messageId": .string("m2"),
                                                                        "messageFormat": .string("FULL_CONTENT")]))
        XCTAssertEqual(full["htmlBody"], .string("<p>Thanks!<br>Will <b>read</b>.</p>"))

        let korean = try json(try await call(center, "gmail_get_message", ["messageId": .string("m3")]))
        XCTAssertEqual(korean["body"], .string("안녕하세요, 회의 자료입니다."), "EUC-KR decoded")
        XCTAssertEqual(korean["subject"], .string("회의 자료"))

        let metadata = try json(try await call(center, "gmail_get_message", ["messageId": .string("m1"),
                                                                            "messageFormat": .string("METADATA_ONLY")]))
        XCTAssertNil(metadata["subject"])
        XCTAssertNil(metadata["snippet"])
        XCTAssertEqual(metadata["from"], .string("Alice <alice@example.com>"))
        let metadataRequest = try XCTUnwrap(google.requests.last { $0.url?.path() == "/gmail/v1/users/me/messages/m1" })
        XCTAssertTrue(metadataRequest.url?.query()?.contains("format=metadata") == true)

        let labels = try json(try await call(center, "gmail_list_labels"))
        XCTAssertEqual(labels["labels"]?.arrayValue?.compactMap { $0["id"]?.stringValue }, ["INBOX", "UNREAD", "STARRED", "Label_7"])
        XCTAssertEqual(labels["labels"]?.arrayValue?.last?["name"], .string("Clients"))

        // Mistakes the model can fix come back as errors, before any request.
        let before = google.requests.count
        let missing = try await call(center, "gmail_get_thread")
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.hasPrefix("gmail_get_thread was not run: it needs threadId."), missing.text)
        XCTAssertEqual(missing.failure?.kind, .invalidArguments, "Checked against the schema Yardlet lists the tool with")
        let odd = try await call(center, "gmail_get_message", ["messageId": .string("../drafts")])
        XCTAssertEqual(odd.text, "Not a Gmail ID: ../drafts")
        let format = try await call(center, "gmail_get_message", ["messageId": .string("m1"), "messageFormat": .string("RAW")])
        XCTAssertTrue(format.isError)
        XCTAssertEqual(google.requests.count, before)

        // Google's own error, not a body.
        let gone = try await call(center, "gmail_get_thread", ["threadId": .string("t404")])
        XCTAssertTrue(gone.isError)
        XCTAssertEqual(gone.text, "Gmail: Requested entity was not found. (HTTP 404)")
    }

    func testDraftsAndSendsCarryAWellFormedMessage() async throws {
        let google = FakeGoogle()
        let (center, _) = try await signedIn(google: google)

        let draft = try json(try await call(center, "gmail_create_draft", [
            "to": .array([.string("bob@example.com"), .string("김철수 <kim@example.kr>")]),
            "cc": .string("carol@example.com"),
            "subject": .string("회의 자료 공유"),
            "body": .string("첨부를 확인해 주세요.\n감사합니다.")
        ]))
        XCTAssertEqual(draft["draftId"], .string("r-1"))
        XCTAssertEqual(draft["messageId"], .string("m-draft-1"))
        let created = try XCTUnwrap(google.posted.last)
        XCTAssertEqual(created.path, "/gmail/v1/users/me/drafts")
        let mime = try XCTUnwrap(FakeGoogle.mime(fromRaw: created.body["message"]?["raw"]?.stringValue))
        XCTAssertTrue(mime.contains("To: bob@example.com, =?UTF-8?B?\(Data("김철수".utf8).base64EncodedString())?= <kim@example.kr>\r\n"), mime)
        XCTAssertTrue(mime.contains("Cc: carol@example.com\r\n"), mime)
        XCTAssertTrue(mime.contains("Subject: =?UTF-8?B?\(Data("회의 자료 공유".utf8).base64EncodedString())?=\r\n"), mime)
        XCTAssertTrue(mime.contains("Content-Type: text/plain; charset=\"UTF-8\"\r\nContent-Transfer-Encoding: base64"), mime)
        XCTAssertTrue(mime.contains(Data("첨부를 확인해 주세요.\r\n감사합니다.".utf8).base64EncodedString()), "CRLF lines in base64")
        XCTAssertFalse(mime.contains("From:"), "Gmail fills the sender")
        XCTAssertNil(created.body["message"]?["threadId"])

        // A reply: the original's thread, its Reply-To as recipient, Re: subject, and threading headers.
        _ = try json(try await call(center, "gmail_create_draft", ["replyToMessageId": .string("m1"),
                                                                  "body": .string("Got it.")]))
        let reply = try XCTUnwrap(google.posted.last)
        XCTAssertEqual(reply.body["message"]?["threadId"], .string("t1"))
        let replyMIME = try XCTUnwrap(FakeGoogle.mime(fromRaw: reply.body["message"]?["raw"]?.stringValue))
        XCTAssertTrue(replyMIME.contains("To: reports@example.com\r\n"), replyMIME)
        XCTAssertTrue(replyMIME.contains("Subject: Re: Quarterly report\r\n"), replyMIME)
        XCTAssertTrue(replyMIME.contains("In-Reply-To: <m1@example.com>\r\n"), replyMIME)
        XCTAssertTrue(replyMIME.contains("References: <m0@example.com> <m1@example.com>\r\n"), replyMIME)

        // HTML goes beside a plain-text part.
        let sent = try json(try await call(center, "gmail_send_message", [
            "to": .array([.string("bob@example.com")]), "subject": .string("Hello"),
            "htmlBody": .string("<p>Hello <b>Bob</b></p>")
        ]))
        XCTAssertEqual(sent["sent"], .bool(true))
        XCTAssertEqual(sent["messageId"], .string("m-sent-1"))
        let send = try XCTUnwrap(google.posted.last)
        XCTAssertEqual(send.path, "/gmail/v1/users/me/messages/send")
        let sentMIME = try XCTUnwrap(FakeGoogle.mime(fromRaw: send.body["raw"]?.stringValue))
        XCTAssertTrue(sentMIME.contains("Content-Type: multipart/alternative; boundary="), sentMIME)
        XCTAssertTrue(sentMIME.contains("Content-Type: text/html; charset=\"UTF-8\""), sentMIME)
        XCTAssertTrue(sentMIME.contains(Data("Hello Bob".utf8).base64EncodedString()), "Plain text from the HTML")

        let draftSent = try json(try await call(center, "gmail_send_draft", ["draftId": .string("r-1")]))
        XCTAssertEqual(draftSent["messageId"], .string("m-sent-2"))
        XCTAssertEqual(google.posted.last?.path, "/gmail/v1/users/me/drafts/send")
        XCTAssertEqual(google.posted.last?.body, .object(["id": .string("r-1")]))

        // Nothing is sent without a recipient or with an address that is not one.
        let posts = google.posted.count
        let nobody = try await call(center, "gmail_send_message", ["subject": .string("Hi"), "body": .string("x")])
        XCTAssertEqual(nobody.text, "Give at least one recipient in to, cc, or bcc.")
        let injected = try await call(center, "gmail_send_message", ["to": .array([.string("a@b.c\r\nBcc: evil@x.y")])])
        XCTAssertTrue(injected.isError)
        XCTAssertEqual(google.posted.count, posts)
    }

    func testModifyLabelsChangesAThreadOrAMessage() async throws {
        let google = FakeGoogle()
        let (center, _) = try await signedIn(google: google)
        let archived = try json(try await call(center, "gmail_modify_labels", [
            "threadId": .string("t1"), "removeLabelIds": .array([.string("INBOX"), .string("UNREAD")])
        ]))
        XCTAssertEqual(google.posted.last?.path, "/gmail/v1/users/me/threads/t1/modify")
        XCTAssertEqual(google.posted.last?.body, .object(["addLabelIds": .array([]),
                                                          "removeLabelIds": .array([.string("INBOX"), .string("UNREAD")])]))
        XCTAssertEqual(archived["threadId"], .string("t1"))
        XCTAssertEqual(archived["messages"]?.arrayValue?.count, 2)

        let starred = try json(try await call(center, "gmail_modify_labels", [
            "messageId": .string("m3"), "addLabelIds": .array([.string("STARRED")])
        ]))
        XCTAssertEqual(google.posted.last?.path, "/gmail/v1/users/me/messages/m3/modify")
        XCTAssertEqual(starred["labelIds"], .array([.string("INBOX"), .string("STARRED")]))

        let posts = google.posted.count
        let both = try await call(center, "gmail_modify_labels", ["threadId": .string("t1"), "messageId": .string("m1"),
                                                                  "addLabelIds": .array([.string("STARRED")])])
        XCTAssertEqual(both.text, "Give either threadId or messageId, not both.")
        let none = try await call(center, "gmail_modify_labels", ["threadId": .string("t1")])
        XCTAssertEqual(none.text, "Give at least one label in addLabelIds or removeLabelIds.")
        XCTAssertEqual(google.posted.count, posts)
    }


    // MARK: - Attachments

    func testAttachmentsGoInMultipartMixedThroughTheUploadEndpoint() async throws {
        let google = FakeGoogle()
        let (center, _) = try await signedIn(google: google)
        let folder = try makeFolder()
        // macOS keeps a Korean name decomposed; the recipient gets it composed.
        let png = folder.appending(path: "스크린샷 1.png".decomposedStringWithCanonicalMapping)
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 7, count: 300)
        try pngBytes.write(to: png)
        let notes = folder.appending(path: "notes.md")
        try Data("# 데모 설명\n화면 18장".utf8).write(to: notes)

        let draft = try json(try await call(center, "gmail_create_draft", [
            "replyToMessageId": .string("m1"), "body": .string("화면을 첨부합니다."),
            "attachments": .array([.string(png.path(percentEncoded: false)), .string(notes.path(percentEncoded: false))])
        ], folders: [folder]))
        XCTAssertEqual(draft["draftId"], .string("r-1"))
        XCTAssertEqual(draft["attachments"]?.arrayValue?.map { $0["filename"] }, [.string("스크린샷 1.png"), .string("notes.md")])
        XCTAssertEqual(draft["attachments"]?.arrayValue?.first?["size"], .integer(Int64(pngBytes.count)))
        let upload = try XCTUnwrap(google.uploads.last)
        XCTAssertEqual(upload.path, "/upload/gmail/v1/users/me/drafts")
        XCTAssertEqual(upload.query, "uploadType=multipart")
        XCTAssertEqual(upload.metadata, .object(["message": .object(["threadId": .string("t1")])]))
        let mime = upload.message
        XCTAssertTrue(mime.contains("In-Reply-To: <m1@example.com>\r\n"), mime)
        XCTAssertTrue(mime.contains("Content-Type: multipart/mixed; boundary="), mime)
        XCTAssertTrue(mime.contains(Data("화면을 첨부합니다.".utf8).base64EncodedString()), "The text comes first")
        let name = "=?UTF-8?B?\(Data("스크린샷 1.png".utf8).base64EncodedString())?="
        XCTAssertTrue(mime.contains("Content-Type: image/png; name=\"\(name)\"\r\n"
            + "Content-Disposition: attachment; filename=\"\(name)\"\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            + pngBytes.base64EncodedString(options: .lineLength76Characters)), mime)
        XCTAssertTrue(mime.contains("Content-Type: text/markdown; charset=\"UTF-8\"; name=\"notes.md\""), mime)
        XCTAssertFalse(google.posted.contains { $0.path.hasSuffix("/drafts") }, "Not as JSON raw")

        // HTML and attachments: the text and HTML side by side, then the files.
        let sent = try json(try await call(center, "gmail_send_message", [
            "to": .string("client@example.com"), "subject": .string("Demo"), "htmlBody": .string("<p>Screens</p>"),
            "attachments": .string(png.path(percentEncoded: false))
        ], folders: [folder]))
        XCTAssertEqual(sent["sent"], .bool(true))
        let send = try XCTUnwrap(google.uploads.last)
        XCTAssertEqual(send.path, "/upload/gmail/v1/users/me/messages/send")
        XCTAssertEqual(send.metadata, .object([:]))
        XCTAssertTrue(send.message.contains("Content-Type: multipart/alternative; boundary=\""), send.message)
        XCTAssertTrue(send.message.contains("Content-Type: text/html; charset=\"UTF-8\""), send.message)
        XCTAssertTrue(send.message.contains("Content-Disposition: attachment;"), send.message)

        // Nothing goes when a file is too large, hidden, outside the folders, or not given by a full path.
        let uploads = google.uploads.count
        let big = folder.appending(path: "video.mov")
        FileManager.default.createFile(atPath: big.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(GmailAttachmentFiles.limit + 1))
        try handle.close()
        let hidden = folder.appending(path: ".env")
        try Data("TOKEN=x".utf8).write(to: hidden)
        let link = folder.appending(path: "hosts.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: "/etc/hosts"))
        for (path, reason) in [(big.path(percentEncoded: false), "over Gmail's 25 MB"),
                               (hidden.path(percentEncoded: false), "hidden"),
                               (link.path(percentEncoded: false), "files come from"),
                               ("notes.md", "absolute path"),
                               (folder.path(percentEncoded: false), "not a file")] {
            let refused = try await call(center, "gmail_create_draft", ["attachments": .array([.string(path)])],
                                         folders: [folder])
            XCTAssertTrue(refused.isError && refused.text.contains(reason), "\(path): \(refused.text)")
        }
        XCTAssertEqual(google.uploads.count, uploads)

        // Only the task's folders and the person's own: another folder is not one of them.
        let elsewhere = try makeFolder().appending(path: "x.txt")
        try Data("x".utf8).write(to: elsewhere)
        XCTAssertNoThrow(try GmailAttachmentFiles.resolve(png.path(percentEncoded: false), roots: [folder]))
        XCTAssertThrowsError(try GmailAttachmentFiles.resolve(elsewhere.path(percentEncoded: false), roots: [folder]))
    }

    // MARK: - Deleting drafts

    func testDeleteDraftByItsIDOrByItsMessage() async throws {
        let google = FakeGoogle()
        let (center, _) = try await signedIn(google: google)
        let deleted = try json(try await call(center, "gmail_delete_draft", ["draftId": .string("r-1")]))
        XCTAssertEqual(deleted, .object(["deleted": .bool(true), "draftId": .string("r-1")]))
        XCTAssertEqual(google.requests.last?.httpMethod, "DELETE")
        XCTAssertEqual(google.requests.last?.url?.path(), "/gmail/v1/users/me/drafts/r-1")

        // By the message get_thread shows with the DRAFT label, found on the second page of drafts.
        let byMessage = try json(try await call(center, "gmail_delete_draft", ["messageId": .string("m-draft-old")]))
        XCTAssertEqual(byMessage["draftId"], .string("r-old"))
        XCTAssertEqual(google.requests.last?.url?.path(), "/gmail/v1/users/me/drafts/r-old")

        let deletes = google.requests.filter { $0.httpMethod == "DELETE" }.count
        let notADraft = try await call(center, "gmail_delete_draft", ["messageId": .string("m3")])
        XCTAssertEqual(notADraft.text, "No draft has the message m3. A draft's message has the DRAFT label.")
        let both = try await call(center, "gmail_delete_draft", ["draftId": .string("r-1"), "messageId": .string("m3")])
        XCTAssertEqual(both.text, "Give either draftId or messageId, not both.")
        XCTAssertEqual(google.requests.filter { $0.httpMethod == "DELETE" }.count, deletes)
    }

    // MARK: - Asking before sends and label changes

    func testSendingAndChangingLabelsAskInEveryHarness() async throws {
        let (center, record) = try await signedIn()
        // The annotations say which tools only read, which leave the mailbox, and which change it.
        let tools = Dictionary(uniqueKeysWithValues: GmailToolCatalog.tools.map { ($0["name"]!.stringValue!, $0) })
        for name in ["search_threads", "get_thread", "get_message", "list_labels"] {
            XCTAssertEqual(tools[name]?["annotations"]?["readOnlyHint"], .bool(true), name)
        }
        for name in ["send_draft", "send_message"] {
            XCTAssertEqual(tools[name]?["annotations"]?["readOnlyHint"], .bool(false), name)
            XCTAssertEqual(tools[name]?["annotations"]?["openWorldHint"], .bool(true), name)
        }
        XCTAssertEqual(tools["modify_labels"]?["annotations"]?["destructiveHint"], .bool(true))
        XCTAssertEqual(tools["delete_draft"]?["annotations"]?["destructiveHint"], .bool(true))
        XCTAssertEqual(GmailToolCatalog.approvalRequired, ["send_draft", "send_message", "modify_labels", "delete_draft"])
        for tool in GmailToolCatalog.tools {
            let description = tool["description"]?.stringValue ?? ""
            XCTAssertLessThan(description.count, 260, description)
            for word in ["always", "must", "should", "IMPORTANT"] {
                XCTAssertFalse(description.contains(word), "Neutral wording: \(description)")
            }
        }

        // Claude Code: none is allowed up front, so the CLI asks before each.
        let allowed = Set(AgentToolServerLaunch.claudeAllowedTools)
        XCTAssertFalse(allowed.contains { $0.contains("gmail") })

        // Codex: asking follows the task's approval setting and the tools' annotations (2026-10-22).
        let broker = AgentToolBroker(
            environment: AgentToolBroker.Environment(executableURL: try makeExecutable(), endpoint: "/tmp/unused.sock",
                                                     privateDirectory: FileManager.default.temporaryDirectory,
                                                     isEnabled: { false }),
            tools: BrowserAgentTools(usesMacEditingCommands: true, pages: { _ in throw CancellationError() }, closePage: { _ in }))
        broker.connectors = center
        let launch = try XCTUnwrap(broker.agentToolServer(for: UUID(), workspaceRoots: [],
                                                          connectorScope: ConnectorTaskScope(harness: .codex)))
        XCTAssertNil(launch.codexConfig["mcp_servers"]?["yardlet"]?["tools"])

        // Claude Code's card names the account, the recipients and subject over the body, and has no
        // "always allow" even when the CLI offers one.
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport })
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/workspace"), initialPrompt: nil))
        let recorder = GmailPermissionRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                if case let .permissionRequested(request) = event.payload { await recorder.append(request) }
            }
        }
        defer { collector.cancel() }
        let suggestion: JSONValue = .object([
            "type": .string("addRules"), "destination": .string("session"), "behavior": .string("allow"),
            "rules": .array([.object(["toolName": .string("mcp__yardlet__gmail_send_message")])])
        ])
        await transport.emit(Self.canUseTool(id: "send-1", tool: "mcp__yardlet__gmail_send_message", input: .object([
            "to": .array([.string("bob@example.com")]), "subject": .string("Hello"), "body": .string("See you at 3.")
        ]), suggestions: [suggestion]))
        let send = try await recorder.waitFor("send-1")
        XCTAssertEqual(send.title, L10n.format("Allow Claude to send an email from %@?", "person@example.test"))
        let detail = try XCTUnwrap(send.detail)
        XCTAssertTrue(detail.contains(L10n.format("To: %@", "bob@example.com")), detail)
        XCTAssertTrue(detail.contains(L10n.format("Subject: %@", "Hello")), detail)
        XCTAssertTrue(detail.contains("See you at 3."), detail)
        XCTAssertTrue(send.actions.isEmpty, "No always-allow: \(send.actions.map(\.id))")

        await transport.emit(Self.canUseTool(id: "read-1", tool: "mcp__yardlet__gmail_search_threads",
                                             input: .object([:]), suggestions: [suggestion]))
        let read = try await recorder.waitFor("read-1")
        XCTAssertFalse(read.actions.isEmpty, "Reading is the CLI's ordinary card")

        // A draft to delete is read from Gmail first: its recipients, subject, and attachments.
        await transport.emit(Self.canUseTool(id: "delete-1", tool: "mcp__yardlet__gmail_delete_draft",
                                             input: .object(["draftId": .string("r-1")]), suggestions: [suggestion]))
        let delete = try await recorder.waitFor("delete-1")
        XCTAssertEqual(delete.title, L10n.format("Allow Claude to delete a draft from %@?", "person@example.test"))
        let deleteDetail = try XCTUnwrap(delete.detail)
        XCTAssertTrue(deleteDetail.contains(L10n.format("To: %@", "Client <client@example.com>")), deleteDetail)
        XCTAssertTrue(deleteDetail.contains(L10n.format("Subject: %@", "Demo screens")), deleteDetail)
        XCTAssertTrue(deleteDetail.contains("demo-01.png (\(ByteCountFormatter.string(fromByteCount: 61_440, countStyle: .file)))"),
                      deleteDetail)
        XCTAssertTrue(deleteDetail.contains("Here are the screens."), deleteDetail)
        XCTAssertTrue(delete.actions.isEmpty)
        await adapter.close(handle)

        // A send names each file it attaches with its size, and one that is not there.
        let folder = try makeFolder()
        let shot = folder.appending(path: "shot.png")
        try Data(repeating: 1, count: 2_048).write(to: shot)
        let attaching = try XCTUnwrap(GmailToolApproval.request(toolName: "mcp__yardlet__gmail_send_message", input: .object([
            "to": .string("client@example.com"),
            "attachments": .array([.string(shot.path(percentEncoded: false)), .string("/nowhere/notes.md")])
        ])))
        let size = ByteCountFormatter.string(fromByteCount: 2_048, countStyle: .file)
        XCTAssertTrue(attaching.detail.contains(L10n.format("Attachments: %@", size)), attaching.detail)
        XCTAssertTrue(attaching.detail.contains("• shot.png (\(size))"), attaching.detail)
        XCTAssertTrue(attaching.detail.contains("• " + L10n.format("%@ (not found)", "notes.md")), attaching.detail)

        let archive = try XCTUnwrap(GmailToolApproval.request(
            toolName: "mcp__yardlet__gmail_modify_labels",
            input: .object(["threadId": .string("t1"), "removeLabelIds": .array([.string("INBOX")])])))
        XCTAssertEqual(archive.title, L10n.format("Allow Claude to change labels in %@?", "person@example.test"))
        XCTAssertTrue(archive.detail.contains(L10n.string("Archives it.")), archive.detail)
        let draft = try XCTUnwrap(GmailToolApproval.request(toolName: "mcp__yardlet__gmail_send_draft",
                                                            input: .object(["draftId": .string("r-1")])))
        XCTAssertEqual(draft.title, L10n.format("Allow Claude to send a draft from %@?", "person@example.test"))
        XCTAssertTrue(draft.detail.contains(L10n.string("Yardlet could not read this draft from Gmail.")), draft.detail)
        XCTAssertNil(GmailToolApproval.request(toolName: "mcp__yardlet__gmail_create_draft", input: .object([:])))
        XCTAssertNil(GmailToolApproval.request(toolName: "mcp__claude_ai_Gmail__send_message", input: .object([:])),
                     "claude.ai's own Gmail is its own")
        _ = record
    }

    // MARK: - Several accounts

    func testEachAccountIsItsOwnConnectorWithItsOwnTokenAndNames() async throws {
        let google = FakeGoogle()
        let credentials = InMemoryConnectorCredentialStore()
        let (center, personal) = try await signedIn("person@example.test", google: google, credentials: credentials)
        google.signInAs = "developer@company.test"
        let work = try XCTUnwrap(center.addGmailAccount())
        await center.waitForConnection(work.id)
        let workRecord = try XCTUnwrap(center.record(work.id))
        XCTAssertEqual(workRecord.account, "developer@company.test")
        XCTAssertEqual(workRecord.slug, "gmail_developer", "A second account's tools are named after it")
        XCTAssertEqual(center.gmailAccounts.map(\.account), ["person@example.test", "developer@company.test"])
        XCTAssertNotEqual(try credentials.load(personal.id)?.accessToken, try credentials.load(work.id)?.accessToken)

        // Each call goes with its own account's token, to its own mailbox.
        let mine = try json(try await call(center, "gmail_list_labels"))
        XCTAssertEqual(google.account(of: try XCTUnwrap(google.requests.last)), "person@example.test")
        let theirs = try json(try await call(center, "gmail_developer_list_labels"))
        XCTAssertEqual(google.account(of: try XCTUnwrap(google.requests.last)), "developer@company.test")
        XCTAssertEqual(mine, theirs)

        let names = await center.connectorTools(for: ConnectorToolContext()).compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(names.count, 18)
        XCTAssertTrue(names.contains("gmail_developer_send_message"))
        XCTAssertTrue(names.contains("gmail_developer_delete_draft"))
        XCTAssertEqual(GmailToolApproval.request(toolName: "mcp__yardlet__gmail_developer_delete_draft",
                                                 input: .object(["draftId": .string("r-1")]))?.title,
                       L10n.format("Allow Claude to delete a draft from %@?", "developer@company.test"))

        // Turned off in one task, only that account leaves it.
        let task = UUID()
        center.setConnector(work.id, on: false, inTask: task)
        let inTask = await center.connectorTools(for: ConnectorToolContext(taskID: task)).compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(inTask.count, 9)
        XCTAssertTrue(inTask.allSatisfy { !$0.hasPrefix("gmail_developer_") })

        // Signing in to an account that is here already keeps one connector for it.
        google.signInAs = "Person@example.test"
        let again = try XCTUnwrap(center.addGmailAccount())
        await center.waitForConnection(again.id)
        XCTAssertNil(center.record(again.id))
        XCTAssertEqual(center.gmailAccounts.count, 2)
        XCTAssertNil(try credentials.load(again.id))
        XCTAssertEqual(center.record(personal.id)?.status, .connected)
        _ = try json(try await call(center, "gmail_list_labels"))

        // Removing one leaves the other and its sign-in.
        center.remove(work.id)
        await center.waitForPendingDeletions()
        XCTAssertNil(try credentials.load(work.id))
        XCTAssertNotNil(try credentials.load(personal.id))
        XCTAssertEqual(center.gmailAccounts.map(\.account), ["person@example.test"])
    }

    // MARK: - Reaching each harness

    func testTheToolsReachClaudeCodexAndACPTasksButNotAntigravity() async throws {
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

        for harness in [HarnessKind.claudeCode, .codex, .openCode, .antigravityCLI] {
            let task = UUID()
            let launch = try XCTUnwrap(broker.agentToolServer(for: task, workspaceRoots: [],
                                                              connectorScope: ConnectorTaskScope(harness: harness)))
            let token = try XCTUnwrap(launch.environment[AgentToolEnvironment.token])
            let list = try XCTUnwrapAsync(await broker.list(AgentToolCall(
                token: token, session: task.uuidString, tool: "", arguments: .object([:]), method: AgentToolCall.listMethod)))
            let gmail = list.tools.compactMap { $0["name"]?.stringValue }.filter { $0.hasPrefix("gmail_") }
            let call = await broker.handle(AgentToolCall(token: token, session: task.uuidString,
                                                         tool: "gmail_list_labels", arguments: .object([:])))
            if harness == .antigravityCLI {
                XCTAssertEqual(gmail, [], "Antigravity gets no connectors")
                XCTAssertTrue(call.isError)
            } else {
                XCTAssertEqual(gmail.count, 9, harness.rawValue)
                XCTAssertFalse(call.isError, "\(harness.rawValue): \(call.text)")
                XCTAssertTrue(call.text.contains("\"labels\""), call.text)
            }
        }

        // Claude's document and ACP's server carry only the launch; the token never goes to a harness.
        let launch = try XCTUnwrap(broker.agentToolServer(for: UUID(), workspaceRoots: [],
                                                          connectorScope: ConnectorTaskScope(harness: .claudeCode)))
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

    private static func canUseTool(id: String, tool: String, input: JSONValue, suggestions: [JSONValue]) -> JSONValue {
        .object([
            "type": .string("control_request"), "request_id": .string(id),
            "request": .object([
                "subtype": .string("can_use_tool"), "tool_name": .string(tool), "input": input,
                "tool_use_id": .string("toolu-\(id)"), "permission_suggestions": .array(suggestions)
            ])
        ])
    }
}

private actor GmailPermissionRecorder {
    private var requests: [PermissionRequest] = []
    func append(_ request: PermissionRequest) { requests.append(request) }
    func waitFor(_ id: String) async throws -> PermissionRequest {
        let deadline = ContinuousClock.now + testWaitLimit
        while ContinuousClock.now < deadline {
            if let request = requests.last(where: { $0.id == id }) { return request }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw HarnessAdapterError.invalidProviderEvent("no permission request \(id)")
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

    func startLoopback(port: UInt16?) async throws -> any OAuthLoopbackReceiving {
        lock.withLock { ports.append(port) }
        return try await MacOAuthLoopback.start(port: nil)
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
}

/// Google's authorization server, token endpoint, and Gmail API for a few mailboxes, as the
/// documentation describes their requests and answers. Tokens map to the account that signed in.
final class FakeGoogle: ConnectorHTTPTransport, @unchecked Sendable {
    static let endpoints = GoogleOAuth.Endpoints(
        authorization: URL(string: "https://accounts.google.test/o/oauth2/v2/auth")!,
        token: URL(string: "https://oauth2.google.test/token")!,
        gmailAPI: URL(string: "https://gmail.google.test/gmail/v1/")!)
    static let clientID = "123-fake.apps.googleusercontent.com"
    static let clientSecret = "GOC" + "SPX-fake-secret"

    struct Post: Equatable {
        var path: String
        var body: ToolJSON
    }

    /// A message through the upload endpoint: its metadata and the message itself.
    struct Upload: Equatable {
        var path: String
        var query: String?
        var metadata: ToolJSON
        var message: String
    }

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var posts: [Post] = []
    private var uploaded: [Upload] = []
    private var accessTokens: [String: String] = [:]
    private var refreshTokens: [String: String] = [:]
    /// What each refresh token was granted, as Google lists it again on every refresh.
    private var refreshScopes: [String: String] = [:]
    private var revokedAccounts: Set<String> = []
    private var issued = 0
    private var drafts = 0
    private var sends = 0
    private var nextAccount = "person@example.test"
    private var granted: String? = GmailToolCatalog.scope
    private var refreshTokenIssued = true

    var requests: [URLRequest] { lock.withLock { recorded } }
    var posted: [Post] { lock.withLock { posts } }
    var uploads: [Upload] { lock.withLock { uploaded } }
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

    static func mime(fromRaw raw: String?) -> String? {
        guard var text = raw?.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") else { return nil }
        while text.count % 4 != 0 { text.append("=") }
        return Data(base64Encoded: text).map { String(decoding: $0, as: UTF8.self) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        guard let url = request.url else { throw URLError(.badURL) }
        if url.host() == "oauth2.google.test", url.path() == "/token" { return token(request) }
        guard url.host() == "gmail.google.test" else { return reply(url, 404, ["error": .string("not found")]) }
        guard let account = account(of: request) else {
            return reply(url, 401, ["error": .object(["code": .integer(401), "status": .string("UNAUTHENTICATED"),
                                                      "message": .string("Request had invalid authentication credentials.")])])
        }
        if url.path().hasPrefix("/upload/") { return upload(request, url) }
        let body = request.httpBody.flatMap { try? JSONDecoder().decode(ToolJSON.self, from: $0) }
        if request.httpMethod == "POST" { lock.withLock { posts.append(Post(path: url.path(), body: body ?? .null)) } }
        return gmail(url, method: request.httpMethod ?? "GET", account: account, body: body)
    }

    /// `uploadType=multipart`: the JSON metadata part, then the `message/rfc822` part.
    private func upload(_ request: URLRequest, _ url: URL) -> (Data, HTTPURLResponse) {
        guard let type = request.value(forHTTPHeaderField: "Content-Type"), type.hasPrefix("multipart/related; boundary="),
              let body = request.httpBody.map({ String(decoding: $0, as: UTF8.self) }) else {
            return reply(url, 400, ["error": .object(["message": .string("Not a multipart upload.")])])
        }
        let boundary = String(type.dropFirst("multipart/related; boundary=".count))
        let parts = body.components(separatedBy: "--\(boundary)").dropFirst().dropLast().map { part -> (String, String) in
            // "\r\n" is one Character.
            let pieces = part.dropFirst().components(separatedBy: "\r\n\r\n")
            return (pieces[0], String(pieces.dropFirst().joined(separator: "\r\n\r\n").dropLast()))
        }
        guard parts.count == 2, parts[0].0.contains("application/json"), parts[1].0 == "Content-Type: message/rfc822",
              let metadata = try? JSONDecoder().decode(ToolJSON.self, from: Data(parts[0].1.utf8)) else {
            return reply(url, 400, ["error": .object(["message": .string("Bad parts.")])])
        }
        let path = url.path()
        lock.withLock { uploaded.append(Upload(path: path, query: url.query(), metadata: metadata, message: parts[1].1)) }
        if path.hasSuffix("/drafts") {
            let id = lock.withLock { drafts += 1; return drafts }
            return reply(url, 200, ["id": .string("r-\(id)"), "message": .object([
                "id": .string("m-draft-\(id)"), "threadId": metadata["message"]?["threadId"] ?? .string("t-new-\(id)")])])
        }
        let id = lock.withLock { sends += 1; return sends }
        return reply(url, 200, ["id": .string("m-sent-\(id)"), "threadId": .string("t-sent"),
                                "labelIds": .array([.string("SENT")])])
    }

    private func reply(_ url: URL, _ status: Int, _ body: [String: ToolJSON]) -> (Data, HTTPURLResponse) {
        ((try? JSONEncoder().encode(ToolJSON.object(body))) ?? Data(),
         HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }

    private func token(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        let url = request.url!
        let form = FakeConnectorServer.form(request)
        guard form["client_id"] == Self.clientID, form["client_secret"] == Self.clientSecret else {
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
                                        "scope": .string(refreshScopes[refresh] ?? GmailToolCatalog.scope),
                                        "token_type": .string("Bearer")])
            default:
                return reply(url, 400, ["error": .string("unsupported_grant_type")])
            }
        }
    }

    private func gmail(_ url: URL, method: String, account: String, body: ToolJSON?) -> (Data, HTTPURLResponse) {
        let path = url.path().replacingOccurrences(of: "/gmail/v1/users/me/", with: "")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let metadata = query.first { $0.name == "format" }?.value == "metadata"
        switch (method, path) {
        case ("GET", "profile"):
            return reply(url, 200, ["emailAddress": .string(account), "messagesTotal": .integer(3)])
        case ("GET", "labels"):
            return reply(url, 200, ["labels": .array([
                Self.label("INBOX", "INBOX", "system"), Self.label("UNREAD", "UNREAD", "system"),
                Self.label("STARRED", "STARRED", "system"), Self.label("Label_7", "Clients", "user")
            ])])
        case ("GET", "threads"):
            // "gone" finds a thread deleted before its lookup.
            let second = query.first { $0.name == "q" }?.value == "gone" ? "t404" : "t2"
            return reply(url, 200, ["threads": .array([.object(["id": .string("t1")]), .object(["id": .string(second)])]),
                                    "nextPageToken": .string("page-3"), "resultSizeEstimate": .integer(2)])
        case ("GET", "threads/t1"):
            return reply(url, 200, ["id": .string("t1"), "messages": .array([Self.m1(metadata), Self.m2(metadata)])])
        case ("GET", "threads/t2"):
            return reply(url, 200, ["id": .string("t2"), "messages": .array([Self.m3(metadata)])])
        case ("GET", "messages/m1"): return (try! JSONEncoder().encode(Self.m1(metadata)), Self.ok(url))
        case ("GET", "messages/m2"): return (try! JSONEncoder().encode(Self.m2(metadata)), Self.ok(url))
        case ("GET", "messages/m3"): return (try! JSONEncoder().encode(Self.m3(metadata)), Self.ok(url))
        case ("POST", "drafts"):
            let id = lock.withLock { drafts += 1; return drafts }
            return reply(url, 200, ["id": .string("r-\(id)"), "message": .object([
                "id": .string("m-draft-\(id)"), "threadId": body?["message"]?["threadId"] ?? .string("t-new-\(id)")])])
        case ("GET", "drafts/r-1"):
            return reply(url, 200, ["id": .string("r-1"), "message": Self.draft()])
        case ("GET", "drafts"):
            // Two pages: the old draft is on the second.
            guard query.first(where: { $0.name == "pageToken" })?.value == "drafts-2" else {
                return reply(url, 200, ["drafts": .array([Self.draftEntry("r-1", "m-draft-1")]),
                                        "nextPageToken": .string("drafts-2")])
            }
            return reply(url, 200, ["drafts": .array([Self.draftEntry("r-old", "m-draft-old")])])
        case ("DELETE", "drafts/r-1"), ("DELETE", "drafts/r-old"):
            return (Data(), HTTPURLResponse(url: url, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: [:])!)
        case ("POST", "drafts/send"), ("POST", "messages/send"):
            let id = lock.withLock { sends += 1; return sends }
            return reply(url, 200, ["id": .string("m-sent-\(id)"), "threadId": .string("t-sent"),
                                    "labelIds": .array([.string("SENT")])])
        case ("POST", "threads/t1/modify"):
            return reply(url, 200, ["id": .string("t1"), "messages": .array([
                .object(["id": .string("m1"), "labelIds": .array([.string("Label_7")])]),
                .object(["id": .string("m2"), "labelIds": .array([.string("SENT")])])])])
        case ("POST", "messages/m3/modify"):
            return reply(url, 200, ["id": .string("m3"), "labelIds": .array([.string("INBOX"), .string("STARRED")])])
        default:
            return reply(url, 404, ["error": .object(["code": .integer(404), "status": .string("NOT_FOUND"),
                                                      "message": .string("Requested entity was not found.")])])
        }
    }

    private static func ok(_ url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }

    private static func label(_ id: String, _ name: String, _ type: String) -> ToolJSON {
        .object(["id": .string(id), "name": .string(name), "type": .string(type), "labelListVisibility": .string("labelShow")])
    }

    private static func b64(_ data: Data) -> String { ConnectorOAuth.base64URL(data) }

    private static func headers(_ pairs: [(String, String)]) -> ToolJSON {
        .array(pairs.map { .object(["name": .string($0.0), "value": .string($0.1)]) })
    }

    private static func message(id: String, thread: String, labels: [String], date: Int64, snippet: String,
                                headers pairs: [(String, String)], parts: [ToolJSON], metadata: Bool) -> ToolJSON {
        var payload: [String: ToolJSON] = ["mimeType": .string("multipart/mixed"), "headers": headers(pairs)]
        if !metadata { payload["parts"] = .array(parts) }
        return .object(["id": .string(id), "threadId": .string(thread), "labelIds": .array(labels.map { .string($0) }),
                        "snippet": .string(snippet), "internalDate": .string(String(date)), "payload": .object(payload)])
    }

    private static func draftEntry(_ id: String, _ message: String) -> ToolJSON {
        .object(["id": .string(id), "message": .object(["id": .string(message), "threadId": .string("t1")])])
    }

    static func draft() -> ToolJSON {
        message(id: "m-draft-1", thread: "t1", labels: ["DRAFT"], date: 1_792_300_000_000, snippet: "Here are the screens.",
                headers: [("To", "Client <client@example.com>"), ("Subject", "Demo screens")],
                parts: [
                    .object(["mimeType": .string("text/plain"), "filename": .string(""),
                             "body": .object(["data": .string(b64(Data("Here are the screens.".utf8)))])]),
                    .object(["mimeType": .string("image/png"), "filename": .string("demo-01.png"),
                             "body": .object(["size": .integer(61_440), "attachmentId": .string("ANGjdJ-png")])])
                ], metadata: false)
    }

    static func m1(_ metadata: Bool) -> ToolJSON {
        message(id: "m1", thread: "t1", labels: ["INBOX", "UNREAD"], date: 1_792_200_000_000,
                snippet: "Numbers for Q3 &amp; what&#39;s next",
                headers: [("From", "Alice <alice@example.com>"), ("To", "person@example.test"), ("Subject", "Quarterly report"),
                          ("Date", "Fri, 16 Oct 2026 09:00:00 +0900"), ("Message-ID", "<m1@example.com>"),
                          ("References", "<m0@example.com>"), ("Reply-To", "reports@example.com")],
                parts: [
                    .object(["mimeType": .string("multipart/alternative"), "filename": .string(""), "parts": .array([
                        .object(["mimeType": .string("text/plain"), "filename": .string(""),
                                 "headers": headers([("Content-Type", "text/plain; charset=\"UTF-8\"")]),
                                 "body": .object(["size": .integer(26), "data": .string(b64(Data("Hi team,\nNumbers attached.".utf8)))])]),
                        .object(["mimeType": .string("text/html"), "filename": .string(""),
                                 "body": .object(["data": .string(b64(Data("<p>Hi team,</p>".utf8)))])])
                    ])]),
                    .object(["mimeType": .string("application/pdf"), "filename": .string("q3.pdf"),
                             "body": .object(["size": .integer(2048), "attachmentId": .string("ANGjdJ-long-id")])])
                ], metadata: metadata)
    }

    static func m2(_ metadata: Bool) -> ToolJSON {
        message(id: "m2", thread: "t1", labels: ["SENT"], date: 1_792_203_600_000, snippet: "Thanks! Will read.",
                headers: [("From", "Person <person@example.test>"), ("To", "Alice <alice@example.com>"),
                          ("Subject", "Re: Quarterly report")],
                parts: [.object(["mimeType": .string("text/html"), "filename": .string(""),
                                 "body": .object(["data": .string(b64(Data("<p>Thanks!<br>Will <b>read</b>.</p>".utf8)))])])],
                metadata: metadata)
    }

    static func m3(_ metadata: Bool) -> ToolJSON {
        let eucKR = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))
        let body = "안녕하세요, 회의 자료입니다.".data(using: eucKR)!
        return message(id: "m3", thread: "t2", labels: ["INBOX"], date: 1_792_207_200_000, snippet: "안녕하세요, 회의 자료입니다.",
                       headers: [("From", "김철수 <kim@example.kr>"), ("To", "person@example.test"), ("Subject", "회의 자료")],
                       parts: [.object(["mimeType": .string("text/plain"), "filename": .string(""),
                                        "headers": headers([("Content-Type", "text/plain; charset=euc-kr")]),
                                        "body": .object(["data": .string(b64(body))])])],
                       metadata: metadata)
    }
}
