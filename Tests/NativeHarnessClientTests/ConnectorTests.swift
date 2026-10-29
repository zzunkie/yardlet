import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Connectors: a remote MCP server Yardlet signs in to once and offers to every harness through
/// the Yardlet MCP server (docs/CONNECTORS.md). A scripted server plays both the authorization
/// server and the MCP server, so the whole sign-in and every request's shape are checked here.
@MainActor
final class ConnectorTests: XCTestCase {
    // MARK: - Naming

    func testSlugsAreShortLowercaseUniqueAndNeverTheBrowserPrefix() {
        XCTAssertEqual(ConnectorToolNaming.slug(for: "Linear", taken: []), "linear")
        XCTAssertEqual(ConnectorToolNaming.slug(for: "My Jira (work)", taken: []), "my_jira_work")
        XCTAssertEqual(ConnectorToolNaming.slug(for: "Linear", taken: ["linear"]), "linear2")
        XCTAssertEqual(ConnectorToolNaming.slug(for: "Browser", taken: []), "browser2")
        XCTAssertEqual(ConnectorToolNaming.slug(for: "노션", taken: []), "connector")
        XCTAssertLessThanOrEqual(ConnectorToolNaming.slug(for: String(repeating: "a", count: 60), taken: []).count, 20)
    }

    func testToolNamesFitTheModelLimitAndStayDistinct() {
        XCTAssertEqual(ConnectorToolNaming.name(slug: "notion", tool: "notion-search"), "notion_notion-search")
        XCTAssertEqual(ConnectorToolNaming.name(slug: "x", tool: "a.b/c"), "x_a_b_c")
        let first = ConnectorToolNaming.name(slug: "atlassian", tool: "getConfluencePageFooterCommentsForSpaceWithLongName")
        let second = ConnectorToolNaming.name(slug: "atlassian", tool: "getConfluencePageFooterCommentsForSpaceWithOtherName")
        XCTAssertEqual(first.count, ConnectorToolNaming.maximumLength)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, ConnectorToolNaming.name(slug: "atlassian", tool: "getConfluencePageFooterCommentsForSpaceWithLongName"))
        // Claude Code adds `mcp__yardlet__`; the model APIs stop at 64.
        XCTAssertLessThanOrEqual(("mcp__yardlet__" + first).count, 64)
    }

    // MARK: - Protocol pieces

    func testBearerChallengesAsRealServersSendThem() {
        let linear = BearerChallenge(header: #"Bearer realm="OAuth", resource_metadata="https://mcp.linear.app/.well-known/oauth-protected-resource/mcp", scope="read write""#)
        XCTAssertEqual(linear?.resourceMetadata?.absoluteString, "https://mcp.linear.app/.well-known/oauth-protected-resource/mcp")
        XCTAssertEqual(linear?.scope, "read write")
        let github = BearerChallenge(header: #"Bearer error="invalid_request", error_description="No access token was provided in this request", resource_metadata="https://api.githubcopilot.com/.well-known/oauth-protected-resource/mcp/""#)
        XCTAssertEqual(github?.error, "invalid_request")
        XCTAssertEqual(github?.resourceMetadata?.path(), "/.well-known/oauth-protected-resource/mcp/")
        let atlassian = BearerChallenge(header: #"Bearer realm="OAuth", error="invalid_token", error_description="Missing or invalid access token""#)
        XCTAssertNotNil(atlassian)
        XCTAssertNil(atlassian?.resourceMetadata)
        XCTAssertNil(BearerChallenge(header: #"Basic realm="x""#))
        XCTAssertNil(BearerChallenge(header: nil))
    }

    func testAnEventStreamReplyIsFoundAmongOtherMessages() throws {
        let stream = "event: message\r\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\r\n\r\n"
            + "id: 7\ndata: {\"jsonrpc\":\"2.0\",\n" + "data: \"id\":3,\"result\":{\"ok\":true}}\n\n"
        let reply = try MCPHTTPClient.reply(to: 3, in: Data(stream.utf8), contentType: "text/event-stream")
        XCTAssertEqual(reply["result"]?["ok"], .bool(true))
        XCTAssertThrowsError(try MCPHTTPClient.reply(to: 4, in: Data(stream.utf8), contentType: "text/event-stream"))
    }

    func testDiscoveryAddressesFollowTheMCPSpecificationOrder() {
        let named = URL(string: "https://mcp.linear.app/.well-known/oauth-protected-resource/mcp")!
        XCTAssertEqual(
            ConnectorOAuth.protectedResourceMetadataURLs(
                serverURL: URL(string: "https://mcp.linear.app/mcp")!,
                challenge: BearerChallenge(resourceMetadata: named)
            ).map(\.absoluteString),
            ["https://mcp.linear.app/.well-known/oauth-protected-resource/mcp",
             "https://mcp.linear.app/.well-known/oauth-protected-resource"]
        )
        XCTAssertEqual(
            ConnectorOAuth.authorizationServerMetadataURLs(issuer: URL(string: "https://github.com/login/oauth")!).map(\.absoluteString),
            ["https://github.com/.well-known/oauth-authorization-server/login/oauth",
             "https://github.com/.well-known/openid-configuration/login/oauth",
             "https://github.com/login/oauth/.well-known/openid-configuration"]
        )
        XCTAssertEqual(
            ConnectorOAuth.authorizationServerMetadataURLs(issuer: URL(string: "https://mcp.linear.app")!).map(\.absoluteString),
            ["https://mcp.linear.app/.well-known/oauth-authorization-server",
             "https://mcp.linear.app/.well-known/openid-configuration"]
        )
    }

    func testAServerWithoutResourceMetadataIsItsOwnAuthorizationServer() async throws {
        // Atlassian's MCP server answers 401 with no metadata address and 404 at the well-known one.
        let server = FakeConnectorServer(publishesResourceMetadata: false)
        let plan = try await ConnectorOAuth.discover(
            serverURL: FakeConnectorServer.mcpURL,
            challenge: BearerChallenge(error: "invalid_token"),
            http: server
        )
        XCTAssertEqual(plan.server.authorizationEndpoint.absoluteString, "https://mcp.example.test/authorize")
        XCTAssertEqual(plan.resource, "https://mcp.example.test/mcp")
        XCTAssertNil(plan.scope)
    }

    func testTheAuthorizationRequestCarriesPKCEStateAndResource() throws {
        let plan = OAuthPlan(
            server: OAuthAuthorizationServer(
                authorizationEndpoint: URL(string: "https://auth.example.test/authorize?prompt=consent")!,
                tokenEndpoint: URL(string: "https://auth.example.test/token")!
            ),
            resource: "https://mcp.example.test/mcp",
            scope: "read write"
        )
        let url = ConnectorOAuth.authorizationURL(
            plan: plan,
            client: OAuthClient(id: "client+1", authMethod: "none"),
            redirectURI: URL(string: "http://127.0.0.1:5555/callback")!,
            state: "s1",
            codeChallenge: "c1"
        )
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["prompt"], "consent", "The endpoint's own query stays")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["client_id"], "client+1")
        XCTAssertTrue(url.absoluteString.contains("client_id=client%2B1"))
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:5555/callback")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["code_challenge"], "c1")
        XCTAssertEqual(items["state"], "s1")
        XCTAssertEqual(items["resource"], "https://mcp.example.test/mcp")
        XCTAssertEqual(items["scope"], "read write")

        XCTAssertEqual(try ConnectorOAuth.code(fromCallback: URL(string: "http://127.0.0.1:5555/callback?code=abc&state=s1")!, expectedState: "s1"), "abc")
        XCTAssertThrowsError(try ConnectorOAuth.code(fromCallback: URL(string: "http://127.0.0.1:5555/callback?code=abc&state=other")!, expectedState: "s1")) {
            XCTAssertEqual($0 as? ConnectorOAuthError, .stateMismatch)
        }
        XCTAssertThrowsError(try ConnectorOAuth.code(fromCallback: URL(string: "http://127.0.0.1:5555/callback?error=access_denied&state=s1")!, expectedState: "s1")) {
            XCTAssertEqual($0 as? ConnectorOAuthError, .declined)
        }
        XCTAssertThrowsError(try ConnectorOAuth.code(fromCallback: URL(string: "http://127.0.0.1:5555/callback?error=invalid_scope&error_description=Unknown%20scope&state=s1")!, expectedState: "s1")) {
            XCTAssertEqual($0 as? ConnectorOAuthError, .authorizationDenied("Unknown scope"))
        }
    }

    func testThePKCEChallengeIsTheRFC7636Example() {
        // RFC 7636 appendix B.
        XCTAssertEqual(
            ConnectorOAuth.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", sha256: MacOAuthUserAgent.sha256),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
        XCTAssertEqual(ConnectorOAuth.randomToken().count, 43)
        XCTAssertNotEqual(ConnectorOAuth.randomToken(), ConnectorOAuth.randomToken())
    }

    func testAConfidentialClientSendsItsSecretTheWayItRegistered() async throws {
        let server = FakeConnectorServer(authMethods: ["client_secret_basic"])
        let plan = try await ConnectorOAuth.discover(serverURL: FakeConnectorServer.mcpURL, challenge: nil, http: server)
        let client = try await ConnectorOAuth.register(with: plan.server, redirectURI: URL(string: "http://127.0.0.1:1/callback")!, http: server)
        XCTAssertEqual(client.authMethod, "client_secret_basic")
        XCTAssertEqual(client.secret, "secret-1")
        let registration = try XCTUnwrap(server.requests.last { $0.url?.path() == "/register" })
        let body = try JSONDecoder().decode(ToolJSON.self, from: registration.httpBody ?? Data())
        XCTAssertEqual(body["token_endpoint_auth_method"], .string("client_secret_basic"))
        XCTAssertEqual(body["redirect_uris"], .array([.string("http://127.0.0.1:1/callback")]))

        server.expectedVerifier = "v1"
        _ = try await ConnectorOAuth.exchange(
            code: FakeConnectorServer.code, verifier: "v1", plan: plan, client: client,
            redirectURI: URL(string: "http://127.0.0.1:1/callback")!, http: server, now: Date()
        )
        XCTAssertTrue(server.verifierMatched)
        let token = try XCTUnwrap(server.requests.last { $0.url?.path() == "/token" })
        XCTAssertEqual(token.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("client-1:secret-1".utf8).base64EncodedString())
        XCTAssertFalse(FakeConnectorServer.form(token)["client_secret"] != nil, "A basic client keeps its secret out of the form")
    }

    // MARK: - Sign-in and tools, end to end

    private func makeCenter(
        server: FakeConnectorServer,
        agent: FakeUserAgent? = FakeUserAgent(),
        credentials: InMemoryConnectorCredentialStore = InMemoryConnectorCredentialStore(),
        repository: InMemoryConnectorRepository = InMemoryConnectorRepository(),
        now: @escaping @Sendable () -> Date = { Date() },
        toolCallLimit: Duration = AgentToolTimeLimits.connectorCall
    ) -> ConnectorCenter {
        var environment = ConnectorCenter.Environment(
            repository: repository,
            credentials: credentials,
            http: server,
            userAgent: agent,
            sha256: MacOAuthUserAgent.sha256,
            clientVersion: "9.9",
            now: now,
            refreshRetrySleep: { _ in }
        )
        environment.toolCallLimit = toolCallLimit
        environment.toolRetrySleep = { _ in }
        return ConnectorCenter(environment: environment)
    }

    func testConnectingSignsInOnceAndOffersTheServersTools() async throws {
        let server = FakeConnectorServer()
        let agent = FakeUserAgent()
        let credentials = InMemoryConnectorCredentialStore()
        let repository = InMemoryConnectorRepository()
        let center = makeCenter(server: server, agent: agent, credentials: credentials, repository: repository)
        let record = try await center.add(name: "Example", serverURL: FakeConnectorServer.mcpURL)
        XCTAssertFalse(center.offersTools)

        center.connect(record.id)
        await center.waitForConnection(record.id)

        XCTAssertNil(center.failures[record.id])
        let connected = try XCTUnwrap(center.record(record.id))
        XCTAssertEqual(connected.status, .connected)
        XCTAssertEqual(connected.authorization, .oauth)
        XCTAssertEqual(connected.tools.count, 3, "Both pages of tools/list")
        XCTAssertTrue(center.offersTools)
        XCTAssertEqual(repository.records, center.connectors, "Saved as it changes")

        // The browser opened the authorization server with PKCE, and the token request proved it.
        let opened = try XCTUnwrap(agent.opened.first)
        XCTAssertEqual(opened.host(), "auth.example.test")
        let credential = try XCTUnwrap(credentials.load(record.id))
        XCTAssertEqual(credential.accessToken, "access-1")
        XCTAssertEqual(credential.refreshToken, "refresh-1")
        XCTAssertEqual(credential.clientID, "client-1")
        XCTAssertEqual(credential.resource, "https://mcp.example.test/mcp")
        XCTAssertEqual(credential.scope, "read write")
        let tokenForm = FakeConnectorServer.form(try XCTUnwrap(server.requests.last { $0.url?.path() == "/token" }))
        let openedQuery = URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(
            openedQuery.first { $0.name == "code_challenge" }?.value,
            ConnectorOAuth.codeChallenge(for: try XCTUnwrap(tokenForm["code_verifier"]), sha256: MacOAuthUserAgent.sha256),
            "The token request proves the verifier behind the challenge the browser carried"
        )
        XCTAssertEqual(openedQuery.first { $0.name == "scope" }?.value, "read write")
        XCTAssertEqual(tokenForm["redirect_uri"], FakeUserAgent.redirect.absoluteString)
        XCTAssertEqual(tokenForm["client_id"], "client-1")
        XCTAssertEqual(tokenForm["resource"], "https://mcp.example.test/mcp")

        // MCP requests after sign-in carry the token, the session, and the negotiated version.
        let list = try XCTUnwrap(server.requests.last { FakeConnectorServer.rpcMethod($0) == "tools/list" })
        XCTAssertEqual(list.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
        XCTAssertEqual(list.value(forHTTPHeaderField: "Mcp-Session-Id"), "session-1")
        XCTAssertEqual(list.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-06-18")
        XCTAssertEqual(list.value(forHTTPHeaderField: "Accept"), "application/json, text/event-stream")
        XCTAssertTrue(server.requests.contains { FakeConnectorServer.rpcMethod($0) == "notifications/initialized" })

        // Tools reach harnesses under Yardlet's names, led by the service's name.
        let tools = await center.connectorTools(for: ConnectorToolContext())
        XCTAssertEqual(tools.compactMap { $0["name"]?.stringValue }, ["example_list_issues", "example_create_issue", "example_whoami"])
        XCTAssertEqual(tools.first?["description"], .string("[Example] List issues"))
        XCTAssertEqual(tools.first?["title"], .string("Example: list_issues"), "No title: the tool's name")
        XCTAssertEqual(tools[1]["title"], .string("Example: Create issue"))
        XCTAssertEqual(tools.first?["annotations"]?["readOnlyHint"], .bool(true))
        XCTAssertEqual(tools.last?["inputSchema"], .object(["type": .string("object")]), "A tool with no schema gets an empty object one")

        // A call goes out under the server's own name and its result comes back as sent.
        let result = try XCTUnwrapAsync(await center.callConnectorTool(named: "example_create_issue", arguments: .object(["title": .string("Hi")]), for: ConnectorToolContext()))
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content, [.json(.object(["type": .string("text"), "text": .string("created Hi")])),
                                        .json(.object(["type": .string("resource_link"), "uri": .string("https://example.test/1"), "name": .string("1")]))])
        XCTAssertEqual(result.structuredContent, .object(["id": .integer(1)]))
        let call = try XCTUnwrap(server.requests.last { FakeConnectorServer.rpcMethod($0) == "tools/call" })
        XCTAssertEqual(FakeConnectorServer.rpcParams(call)?["name"], .string("create_issue"))
        let unknown = await center.callConnectorTool(named: "other_tool", arguments: .object([:]), for: ConnectorToolContext())
        XCTAssertNil(unknown, "A name no connector owns is left to the broker")
    }

    func testAnExpiringTokenIsRefreshedBeforeTheCallAndARefusedOneAfter() async throws {
        let server = FakeConnectorServer()
        let credentials = InMemoryConnectorCredentialStore()
        let clock = TestClock()
        let center = makeCenter(server: server, credentials: credentials, now: { clock.now })
        let record = try await center.add(name: "Example", serverURL: FakeConnectorServer.mcpURL)
        center.connect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertEqual(try credentials.load(record.id)?.accessToken, "access-1")

        // Within a minute of expiry: refreshed first, without a refused request.
        clock.now = clock.now.addingTimeInterval(3_590)
        let refusedBefore = server.refusedRequests
        _ = await center.callConnectorTool(named: "example_whoami", arguments: .object([:]), for: ConnectorToolContext())
        XCTAssertEqual(try credentials.load(record.id)?.accessToken, "access-2")
        XCTAssertEqual(try credentials.load(record.id)?.refreshToken, "refresh-1", "A server that does not rotate keeps the old refresh token")
        XCTAssertEqual(server.refusedRequests, refusedBefore)
        let refresh = FakeConnectorServer.form(try XCTUnwrap(server.requests.last { $0.url?.path() == "/token" }))
        XCTAssertEqual(refresh["grant_type"], "refresh_token")
        XCTAssertEqual(refresh["resource"], "https://mcp.example.test/mcp")

        // The server revokes the token early: one refused call, a refresh, and the retry succeeds.
        server.validTokens.remove("access-2")
        let retried = await center.callConnectorTool(named: "example_whoami", arguments: .object([:]), for: ConnectorToolContext())
        XCTAssertEqual(retried?.isError, false)
        XCTAssertEqual(try credentials.load(record.id)?.accessToken, "access-3")

        // The refresh token stops working too: the call says to sign in again. New sessions are
        // no reason to inject the server, but the tools stay listed, each call saying to sign in.
        server.validTokens.removeAll()
        server.refreshWorks = false
        let refused = await center.callConnectorTool(named: "example_whoami", arguments: .object([:]), for: ConnectorToolContext())
        XCTAssertEqual(refused?.isError, true)
        XCTAssertTrue(refused?.text.contains("sign in again") == true, refused?.text ?? "")
        XCTAssertEqual(center.record(record.id)?.status, .signInRequired)
        XCTAssertFalse(center.offersTools)
        let stillListed = await center.connectorTools(for: ConnectorToolContext()).compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(stillListed, ["example_list_issues", "example_create_issue", "example_whoami"],
                       "Signing in again needs no new list")
        let afterwards = await center.callConnectorTool(named: "example_whoami", arguments: .object([:]), for: ConnectorToolContext())
        XCTAssertTrue(afterwards?.text.contains("needs the user to sign in again") == true, afterwards?.text ?? "")
        center.disconnect(record.id)
        let disconnected = await center.callConnectorTool(named: "example_whoami", arguments: .object([:]), for: ConnectorToolContext())
        XCTAssertTrue(disconnected?.text.contains("is not connected in Yardlet") == true)
        let afterDisconnect = await center.connectorTools(for: ConnectorToolContext())
        XCTAssertTrue(afterDisconnect.isEmpty, "A connector the user disconnected leaves the list")
    }

    func testARefreshTheServerCannotAnswerNowKeepsTheSignInAndTriesAgain() async throws {
        let server = FakeConnectorServer()
        let credentials = InMemoryConnectorCredentialStore()
        let clock = TestClock()
        let center = makeCenter(server: server, credentials: credentials, now: { clock.now })
        let record = try await center.add(name: "Example", serverURL: FakeConnectorServer.mcpURL)
        center.connect(record.id)
        await center.waitForConnection(record.id)

        // Just after waking: the token has expired and the first refresh finds no network. The
        // next attempt within the same call gets through.
        clock.now = clock.now.addingTimeInterval(3_700)
        server.validTokens.remove("access-1")
        server.failNextTokenRequests([.offline])
        var before = server.tokenRequests
        let recovered = await center.callConnectorTool(named: "example_whoami", arguments: .object([:]), for: ConnectorToolContext())
        XCTAssertEqual(recovered?.isError, false, recovered?.text ?? "")
        XCTAssertEqual(server.tokenRequests - before, 2)
        XCTAssertEqual(try credentials.load(record.id)?.accessToken, "access-2")
        let other = try await center.add(name: "Other", serverURL: FakeConnectorServer.mcpURL)
        center.connect(other.id)
        await center.waitForConnection(other.id)

        // Every attempt fails (offline, then the server's own trouble and a rate limit): only the
        // call fails. The connector stays connected and keeps offering its tools.
        clock.now = clock.now.addingTimeInterval(3_700)
        server.validTokens.removeAll()
        server.failNextTokenRequests([.offline, .status(503), .status(429), .status(502), .status(500), .offline])
        before = server.tokenRequests
        let failed = await center.callConnectorTool(named: "example_whoami", arguments: .object([:]), for: ConnectorToolContext())
        XCTAssertEqual(failed?.isError, true)
        XCTAssertTrue(failed?.text.contains("Could not renew Example's sign-in just now") == true, failed?.text ?? "")
        XCTAssertEqual(server.tokenRequests - before, 3, "The early refresh tries three times; the refused call does not start over")
        XCTAssertEqual(center.record(record.id)?.status, .connected)
        XCTAssertTrue(center.offersTools)
        XCTAssertEqual(try credentials.load(record.id)?.refreshToken, "refresh-1", "The sign-in is kept")

        // Reading its tools again fails the same way: Settings keeps it connected and in its place,
        // with the reason as its row's note.
        server.failNextTokenRequests([.offline, .offline, .offline])
        center.connect(record.id)
        await center.waitForConnection(record.id)
        let kept = try XCTUnwrap(center.record(record.id))
        XCTAssertNotNil(center.failures[record.id])
        XCTAssertEqual(ConnectorSettingsState.make(kept, in: center), .connected(tools: kept.offeredTools.count))
        XCTAssertEqual(ConnectorSettingsState.note(kept, in: center), center.failures[record.id])
        XCTAssertEqual(ConnectorSettingsState.ordered(center).map(\.id), [record.id, other.id])

        // Once the server answers again, the next call refreshes and goes through.
        server.failNextTokenRequests([])
        let later = await center.callConnectorTool(named: "example_whoami", arguments: .object([:]), for: ConnectorToolContext())
        XCTAssertEqual(later?.isError, false, later?.text ?? "")
        XCTAssertEqual(center.record(record.id)?.status, .connected)
    }

    func testAnotherCopysRefreshIsReadFromTheStoreInsteadOfSpendingTheOldToken() async throws {
        let server = FakeConnectorServer()
        server.rotatesRefreshTokens = true
        let credentials = InMemoryConnectorCredentialStore()
        let repository = InMemoryConnectorRepository()
        let clock = TestClock()
        let first = makeCenter(server: server, credentials: credentials, repository: repository, now: { clock.now })
        let record = try await first.add(name: "Example", serverURL: FakeConnectorServer.mcpURL)
        first.connect(record.id)
        await first.waitForConnection(record.id)
        // A second copy of Yardlet with the same keychain item; it has used the token once.
        let second = makeCenter(server: server, credentials: credentials, repository: repository, now: { clock.now })
        let warmUp = await second.callConnectorTool(named: "example_whoami", arguments: .object([:]), for: ConnectorToolContext())
        XCTAssertEqual(warmUp?.isError, false)

        // Near expiry the first copy refreshes; the server rotates the refresh token.
        clock.now = clock.now.addingTimeInterval(3_590)
        _ = await first.callConnectorTool(named: "example_whoami", arguments: .object([:]), for: ConnectorToolContext())
        let rotated = try XCTUnwrap(try credentials.load(record.id))
        XCTAssertEqual(rotated.refreshToken, "refresh-r1")

        // The second copy still holds the spent token. It reads the store first and uses the
        // first copy's tokens, with no token request and no sign-out.
        let before = server.tokenRequests
        let result = await second.callConnectorTool(named: "example_whoami", arguments: .object([:]), for: ConnectorToolContext())
        XCTAssertEqual(result?.isError, false, result?.text ?? "")
        XCTAssertEqual(server.tokenRequests, before)
        XCTAssertEqual(second.record(record.id)?.status, .connected)
        XCTAssertEqual(try credentials.load(record.id), rotated)
    }

    func testARefusalRightAfterAnotherCopysRefreshTakesThatCopysTokens() async throws {
        let server = FakeConnectorServer()
        server.rotatesRefreshTokens = true
        let credentials = InMemoryConnectorCredentialStore()
        let clock = TestClock()
        let center = makeCenter(server: server, credentials: credentials, now: { clock.now })
        let record = try await center.add(name: "Example", serverURL: FakeConnectorServer.mcpURL)
        center.connect(record.id)
        await center.waitForConnection(record.id)
        let signedIn = try XCTUnwrap(try credentials.load(record.id))

        // Both copies refresh at the same moment: the other one's request reaches the server
        // first and saves, so this one's refresh token is refused as spent.
        clock.now = clock.now.addingTimeInterval(3_590)
        let id = record.id
        let now = clock.now
        server.beforeRefresh = { [server, credentials] in
            server.beforeRefresh = nil
            let (access, refresh) = server.refreshElsewhere()
            var other = signedIn
            other.accessToken = access
            other.refreshToken = refresh
            other.expiresAt = now.addingTimeInterval(3_600)
            try? credentials.save(other, for: id)
        }
        let result = await center.callConnectorTool(named: "example_whoami", arguments: .object([:]), for: ConnectorToolContext())
        XCTAssertEqual(result?.isError, false, result?.text ?? "")
        XCTAssertEqual(center.record(record.id)?.status, .connected)
        XCTAssertEqual(try credentials.load(record.id)?.refreshToken, "refresh-r1", "The other copy's save stands")
        XCTAssertEqual(server.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer access-2")
    }

    func testOnlyARealRefusalOfTheTokenRequestSignsOut() async throws {
        // A 400 that is not about the grant (an unknown client) is final too; a 5xx is not.
        let server = FakeConnectorServer()
        let credentials = InMemoryConnectorCredentialStore()
        let clock = TestClock()
        let center = makeCenter(server: server, credentials: credentials, now: { clock.now })
        let record = try await center.add(name: "Example", serverURL: FakeConnectorServer.mcpURL)
        center.connect(record.id)
        await center.waitForConnection(record.id)
        clock.now = clock.now.addingTimeInterval(3_700)
        server.validTokens.removeAll()
        server.failNextTokenRequests([.status(401)])
        let refused = await center.callConnectorTool(named: "example_whoami", arguments: .object([:]), for: ConnectorToolContext())
        XCTAssertTrue(refused?.text.contains("sign in again") == true, refused?.text ?? "")
        XCTAssertEqual(center.record(record.id)?.status, .signInRequired)
    }

    /// One limit covers a whole connector call, so the app answers before the MCP server stops waiting: past it, a
    /// read says that calling again is safe, and a call that changes something that its outcome is unknown. A read
    /// the server could not answer goes once more; a call that changes something never goes twice. An MCP SDK's
    /// refusal of the arguments reads as one, argument by argument.
    func testACallEndsWithinItsLimitAndOnlyAReadIsSentAgain() async throws {
        let server = FakeConnectorServer()
        let center = makeCenter(server: server, toolCallLimit: .seconds(1))
        let record = try await center.add(name: "Example", serverURL: FakeConnectorServer.mcpURL)
        center.connect(record.id)
        await center.waitForConnection(record.id)
        func call(_ name: String, _ arguments: [String: ToolJSON] = [:]) async -> AgentToolResult? {
            await center.callConnectorTool(named: name, arguments: .object(arguments), for: ConnectorToolContext())
        }
        func calls() -> Int { server.requests.filter { FakeConnectorServer.rpcMethod($0) == "tools/call" }.count }

        server.callDelay = .seconds(60)
        let started = ContinuousClock.now
        let write = await call("example_create_issue", ["title": .string("Hi")])
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(30), "The limit ends the call, not the server")
        XCTAssertEqual(write?.failure?.kind, .outcomeUnknown, write?.text ?? "")
        XCTAssertEqual(write?.failure?.retry, .afterChecking)
        XCTAssertTrue(write?.text.contains("Whether example_create_issue took effect is unknown") == true, write?.text ?? "")
        let read = await call("example_list_issues")
        XCTAssertEqual(read?.failure?.kind, .timedOut, read?.text ?? "")
        XCTAssertEqual(read?.failure?.retry, .later)
        server.callDelay = nil

        var before = calls()
        server.failNextCalls([.networkConnectionLost])
        let readAgain = await call("example_list_issues")
        XCTAssertEqual(readAgain?.isError, false, readAgain?.text ?? "")
        XCTAssertEqual(calls(), before + 2, "A read the server could not answer goes once more")
        before = calls()
        server.failNextCalls([.networkConnectionLost])
        let writeOnce = await call("example_create_issue", ["title": .string("Hi")])
        XCTAssertEqual(writeOnce?.failure?.kind, .outcomeUnknown, writeOnce?.text ?? "")
        XCTAssertEqual(calls(), before + 1, "A call that changes something goes once")
        server.failNextCalls([.cannotConnectToHost])
        let unsent = await call("example_create_issue", ["title": .string("Hi")])
        XCTAssertEqual(unsent?.failure?.kind, .unreachable, unsent?.text ?? "")
        XCTAssertEqual(unsent?.failure?.retry, .later)

        let refused = await call("example_create_issue")
        XCTAssertEqual(refused?.failure?.kind, .invalidArguments, refused?.text ?? "")
        XCTAssertEqual(refused?.failure?.retry, .withChanges)
        XCTAssertEqual(refused?.text, "Example refused the arguments: MCP error -32602: Input validation error: Invalid "
                       + "arguments for tool create_issue: title: Required (expected string)")
    }

    func testTheServerForgettingTheSessionStartsANewOne() async throws {
        let server = FakeConnectorServer()
        let center = makeCenter(server: server)
        let record = try await center.add(name: "Example", serverURL: FakeConnectorServer.mcpURL)
        center.connect(record.id)
        await center.waitForConnection(record.id)
        let initializations = server.requests.filter { FakeConnectorServer.rpcMethod($0) == "initialize" }.count
        server.forgetSessions()
        let result = await center.callConnectorTool(named: "example_whoami", arguments: .object([:]), for: ConnectorToolContext())
        XCTAssertEqual(result?.isError, false)
        XCTAssertEqual(server.requests.filter { FakeConnectorServer.rpcMethod($0) == "initialize" }.count, initializations + 1)
        XCTAssertEqual(server.requests.last?.value(forHTTPHeaderField: "Mcp-Session-Id"), "session-2")
    }

    func testAServerWithoutSignInConnectsDirectlyAndAPastedTokenIsSentAsIs() async throws {
        let open = FakeConnectorServer(requiresToken: false)
        let center = makeCenter(server: open, agent: nil)
        let record = try await center.add(name: "Docs", serverURL: FakeConnectorServer.mcpURL)
        center.connect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertEqual(center.record(record.id)?.authorization, ConnectorRecord.Authorization.none)
        XCTAssertEqual(center.record(record.id)?.status, .connected)

        let guarded = FakeConnectorServer()
        guarded.validTokens.insert("pasted")
        let credentials = InMemoryConnectorCredentialStore()
        let tokenCenter = makeCenter(server: guarded, agent: nil, credentials: credentials)
        let good = try await tokenCenter.add(name: "GitHub", serverURL: FakeConnectorServer.mcpURL, token: "  pasted \n")
        XCTAssertEqual(try credentials.load(good.id), .token("pasted"))
        tokenCenter.connect(good.id)
        await tokenCenter.waitForConnection(good.id)
        XCTAssertEqual(tokenCenter.record(good.id)?.status, .connected)
        XCTAssertEqual(guarded.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer pasted")

        let bad = try await tokenCenter.add(name: "GitHub", serverURL: FakeConnectorServer.mcpURL, token: "wrong")
        XCTAssertEqual(tokenCenter.record(bad.id)?.slug, "github2")
        tokenCenter.connect(bad.id)
        await tokenCenter.waitForConnection(bad.id)
        XCTAssertEqual(tokenCenter.record(bad.id)?.status, .notConnected)
        XCTAssertEqual(tokenCenter.failures[bad.id], L10n.string("The server did not accept the access token."))
        XCTAssertFalse(guarded.requests.contains { $0.url?.path() == "/register" }, "A token connector never starts a sign-in")
    }

    func testAServerWithoutDynamicRegistrationAsksForAToken() async throws {
        let server = FakeConnectorServer(supportsRegistration: false)
        let center = makeCenter(server: server)
        let record = try await center.add(name: "Slack", serverURL: FakeConnectorServer.mcpURL)
        center.connect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertEqual(center.record(record.id)?.status, .notConnected)
        XCTAssertEqual(center.failures[record.id], ConnectorOAuthError.noDynamicRegistration.errorDescription)
    }

    func testAConnectorWithoutRegistrationConnectsOnceATokenIsGiven() async throws {
        let server = FakeConnectorServer(supportsRegistration: false)
        server.validTokens.insert("personal")
        let credentials = InMemoryConnectorCredentialStore()
        let center = makeCenter(server: server, credentials: credentials)
        let record = try await center.add(name: "GitHub", serverURL: FakeConnectorServer.mcpURL)
        center.connect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertNotNil(center.failures[record.id])

        try await center.useToken(" personal ", for: record.id)
        await center.waitForConnection(record.id)
        XCTAssertNil(center.failures[record.id])
        XCTAssertEqual(center.record(record.id)?.authorization, .token)
        XCTAssertEqual(center.record(record.id)?.status, .connected)
        XCTAssertEqual(try credentials.load(record.id), .token("personal"))
    }

    func testCancellingASignInLeavesTheConnectorAsItWas() async throws {
        let server = FakeConnectorServer()
        let agent = FakeUserAgent(answers: false)
        let center = makeCenter(server: server, agent: agent)
        let record = try await center.add(name: "Example", serverURL: FakeConnectorServer.mcpURL)
        center.connect(record.id)
        while center.activity[record.id] != .waitingForBrowser { await Task.yield() }
        center.cancelConnect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertNil(center.activity[record.id])
        XCTAssertNil(center.failures[record.id])
        XCTAssertEqual(center.record(record.id)?.status, .notConnected)
    }

    func testDisconnectAndRemoveForgetTheCredential() async throws {
        let server = FakeConnectorServer()
        let credentials = InMemoryConnectorCredentialStore()
        let center = makeCenter(server: server, credentials: credentials)
        let record = try await center.add(name: "Example", serverURL: FakeConnectorServer.mcpURL)
        center.connect(record.id)
        await center.waitForConnection(record.id)
        center.disconnect(record.id)
        XCTAssertEqual(center.record(record.id)?.status, .notConnected)
        XCTAssertFalse(center.offersTools)
        // Connecting right away signs in again rather than finding the credential being deleted.
        let signInsBefore = server.requests.filter { $0.url?.path() == "/register" }.count
        center.connect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertEqual(server.requests.filter { $0.url?.path() == "/register" }.count, signInsBefore + 1)
        XCTAssertEqual(center.record(record.id)?.status, .connected)
        center.disconnect(record.id)
        await center.waitForPendingDeletions()
        XCTAssertNil(try credentials.load(record.id))
        center.connect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertNotNil(try credentials.load(record.id))
        center.remove(record.id)
        await center.waitForPendingDeletions()
        XCTAssertNil(try credentials.load(record.id))
        XCTAssertTrue(center.connectors.isEmpty)
    }

    func testTheRecordFileKeepsNoSecret() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "connectors-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileConnectorRepository(fileURL: directory.appending(path: "connectors.json"))
        let record = ConnectorRecord(
            name: "Linear", slug: "linear", serverURL: URL(string: "https://mcp.linear.app/mcp")!,
            authorization: .oauth, status: .connected,
            tools: [.object(["name": .string("list_issues")])], toolsUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        repository.save([record])
        XCTAssertEqual(repository.load(), [record])
        let text = try String(contentsOf: directory.appending(path: "connectors.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("access"), text)
        XCTAssertTrue(text.contains("\"version\" : 1"))
    }

    // MARK: - Through the Yardlet MCP server

    func testTheBrokerListsBrowserAndConnectorToolsAndRoutesEachCall() async throws {
        let server = FakeConnectorServer()
        let center = makeCenter(server: server)
        let record = try await center.add(name: "Example", serverURL: FakeConnectorServer.mcpURL)
        center.connect(record.id)
        await center.waitForConnection(record.id)

        let executable = try makeExecutable()
        let browserOn = BrowserSetting()
        let broker = AgentToolBroker(
            environment: AgentToolBroker.Environment(
                executableURL: executable, endpoint: "/tmp/unused.sock",
                privateDirectory: FileManager.default.temporaryDirectory, isEnabled: { browserOn.isOn }
            ),
            tools: BrowserAgentTools(usesMacEditingCommands: true, pages: { _ in throw CancellationError() }, closePage: { _ in })
        )
        broker.connectors = center

        let withBrowser = UUID()
        let launch = try XCTUnwrap(broker.agentToolServer(for: withBrowser, workspaceRoots: []))
        let token = try XCTUnwrap(launch.environment[AgentToolEnvironment.token])
        let listed = try XCTUnwrapAsync(await broker.list(AgentToolCall(token: token, session: withBrowser.uuidString, tool: "", arguments: .object([:]), method: AgentToolCall.listMethod)))
        let names = listed.tools.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(names.count, AgentToolCatalog.browserTools.count + 3)
        XCTAssertEqual(Array(names.suffix(3)), ["example_list_issues", "example_create_issue", "example_whoami"])

        // The browser tools off: the server still comes for the connector, without browser tools.
        browserOn.isOn = false
        let withoutBrowser = UUID()
        let second = try XCTUnwrap(broker.agentToolServer(for: withoutBrowser, workspaceRoots: []))
        let secondToken = try XCTUnwrap(second.environment[AgentToolEnvironment.token])
        let secondList = try XCTUnwrapAsync(await broker.list(AgentToolCall(token: secondToken, session: withoutBrowser.uuidString, tool: "", arguments: .object([:]), method: AgentToolCall.listMethod)))
        XCTAssertEqual(secondList.tools.compactMap { $0["name"]?.stringValue }, ["example_list_issues", "example_create_issue", "example_whoami"])
        let browserCall = await broker.handle(AgentToolCall(token: secondToken, session: withoutBrowser.uuidString, tool: AgentToolCatalog.snapshot, arguments: .object([:])))
        XCTAssertTrue(browserCall.isError)
        XCTAssertTrue(browserCall.text.contains("browser tools were off"), browserCall.text)
        let connectorCall = await broker.handle(AgentToolCall(token: secondToken, session: withoutBrowser.uuidString, tool: "example_whoami", arguments: .object([:])))
        XCTAssertEqual(connectorCall.text, "you")
        let unknown = await broker.handle(AgentToolCall(token: secondToken, session: withoutBrowser.uuidString, tool: "nobody_tool", arguments: .object([:])))
        XCTAssertEqual(unknown.text, "This task has no Yardlet tool named nobody_tool; its Yardlet tools are the ones its harness lists.")
        XCTAssertEqual(unknown.failure?.kind, .unknownTool)
        let misspelt = await broker.handle(AgentToolCall(token: secondToken, session: withoutBrowser.uuidString, tool: "example_list_issue", arguments: .object([:])))
        XCTAssertEqual(misspelt.text, "This task has no Yardlet tool named example_list_issue. Its tools of that kind: "
                       + "example_list_issues, example_create_issue, example_whoami.", "The tools that share its first word")
        let forged = await broker.list(AgentToolCall(token: "0", session: withoutBrowser.uuidString, tool: "", arguments: .object([:]), method: AgentToolCall.listMethod))
        XCTAssertNil(forged)

        // Neither: no server.
        center.disconnect(record.id)
        XCTAssertNil(broker.agentToolServer(for: UUID(), workspaceRoots: []))
    }

    func testTheMCPServerListsWhatTheAppSaysAndPassesConnectorContentThrough() async throws {
        struct AppInvoker: AgentToolInvoking {
            func call(tool: String, arguments: ToolJSON) async -> AgentToolResult {
                AgentToolResult(
                    content: [.json(.object(["type": .string("audio"), "data": .string("AA=="), "mimeType": .string("audio/wav")]))],
                    structuredContent: .object(["tool": .string(tool)])
                )
            }
            func listTools() async -> AgentToolList? { AgentToolList(tools: [.object(["name": .string("example_whoami")])]) }
        }
        let server = MCPServer(version: "1", invoker: AppInvoker())
        let listed = try JSONDecoder().decode(ToolJSON.self, from: try XCTUnwrapAsync(await server.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))))
        XCTAssertEqual(listed["result"]?["tools"], .array([.object(["name": .string("example_whoami")])]))
        let called = try JSONDecoder().decode(ToolJSON.self, from: try XCTUnwrapAsync(await server.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"example_whoami","arguments":{}}}"#.utf8))))
        XCTAssertEqual(called["result"]?["content"]?.arrayValue?.first?["type"], .string("audio"))
        XCTAssertEqual(called["result"]?["structuredContent"]?["tool"], .string("example_whoami"))
        XCTAssertEqual(called["result"]?["isError"], .bool(false))
    }

    func testTheLoopbackListenerTakesTheRedirectAndRefusesOtherPaths() async throws {
        let loopback = try await MacOAuthLoopback.start()
        defer { loopback.stop() }
        XCTAssertEqual(loopback.redirectURI.host(), "127.0.0.1")
        XCTAssertEqual(loopback.redirectURI.path(), "/callback")
        let session = URLSession(configuration: .ephemeral)
        var other = URLComponents(url: loopback.redirectURI, resolvingAgainstBaseURL: false)!
        other.path = "/favicon.ico"
        let (_, otherResponse) = try await session.data(from: other.url!)
        XCTAssertEqual((otherResponse as? HTTPURLResponse)?.statusCode, 404)

        async let callback = loopback.callback()
        let redirect = URL(string: loopback.redirectURI.absoluteString + "?code=abc&state=xyz")!
        let (page, response) = try await session.data(from: redirect)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("Yardlet"))
        let received = try await callback
        XCTAssertEqual(try ConnectorOAuth.code(fromCallback: received, expectedState: "xyz"), "abc")
    }

    func testWaitingForTheRedirectEndsWhenCancelled() async throws {
        let loopback = try await MacOAuthLoopback.start()
        defer { loopback.stop() }
        let waiting = Task { try await loopback.callback() }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("The wait should end with a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    /// Writes, reads, replaces, and deletes one item in the login keychain under a service of its
    /// own, and leaves nothing behind. Opt-in because it touches the user's keychain.
    func testTheKeychainStoreKeepsOneItemPerConnector() throws {
        guard ProcessInfo.processInfo.environment["NHC_KEYCHAIN_LIVE"] == "1" else {
            throw XCTSkip("Set NHC_KEYCHAIN_LIVE=1 to write and delete one test item in the login keychain")
        }
        let store = KeychainConnectorCredentialStore(service: "com.zzunkie.yardlet.tests.connectors-\(UUID().uuidString)")
        let id = UUID()
        defer { try? store.delete(id) }
        XCTAssertNil(try store.load(id))
        let first = ConnectorCredential(kind: .oauth, accessToken: "a1", refreshToken: "r1",
                                        expiresAt: Date(timeIntervalSince1970: 1_800_000_000), clientID: "c1")
        try store.save(first, for: id)
        XCTAssertEqual(try store.load(id), first)
        try store.save(.token("t2"), for: id)
        XCTAssertEqual(try store.load(id), .token("t2"), "Saving again replaces the item")
        try store.delete(id)
        XCTAssertNil(try store.load(id))
        try store.delete(id)
    }

    private func makeExecutable() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "yardlet-mcp-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// The browser-tools setting as a test flips it between injections.
@MainActor
final class BrowserSetting {
    var isOn = true
}

func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Answers the redirect at once with the `state` it was given, unless told not to answer.
final class FakeUserAgent: OAuthUserAgent, @unchecked Sendable {
    static let redirect = URL(string: "http://127.0.0.1:5555/callback")!

    private let lock = NSLock()
    private var openedURLs: [URL] = []
    let answers: Bool
    let loopback = FakeLoopback()

    init(answers: Bool = true) {
        self.answers = answers
    }

    var opened: [URL] { lock.withLock { openedURLs } }

    private var declining = false
    /// Answers sign-ins with `error=access_denied`, as Cancel on Google's page does.
    var declines: Bool {
        get { lock.withLock { declining } }
        set { lock.withLock { declining = newValue } }
    }

    private var ports: [UInt16?] = []
    /// The port each sign-in asked to listen on: nil for any, a number for a registered client.
    var loopbackPorts: [UInt16?] { lock.withLock { ports } }

    func startLoopback(port: UInt16?) async throws -> any OAuthLoopbackReceiving {
        lock.withLock { ports.append(port) }
        return loopback
    }

    func open(_ url: URL) async -> Bool {
        lock.withLock { openedURLs.append(url) }
        guard answers else { return true }
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
        let answer = declines ? "error=access_denied" : "code=\(FakeConnectorServer.code)"
        loopback.deliver(URL(string: "\(Self.redirect.absoluteString)?\(answer)&state=\(state)")!)
        return true
    }

    final class FakeLoopback: OAuthLoopbackReceiving, @unchecked Sendable {
        private let lock = NSLock()
        private var delivered: URL?
        var redirectURI: URL { FakeUserAgent.redirect }

        func deliver(_ url: URL) { lock.withLock { delivered = url } }

        func callback() async throws -> URL {
            while true {
                if let url = lock.withLock({ delivered }) { return url }
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        func stop() {}
    }
}

/// An OAuth authorization server and an MCP server in one, as scripted as the tests need.
final class FakeConnectorServer: ConnectorHTTPTransport, @unchecked Sendable {
    static let mcpURL = URL(string: "https://mcp.example.test/mcp")!
    static let code = "code-1"

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var state = State()

    private struct State {
        var validTokens: Set<String> = []
        var issued = 0
        var sessions = 0
        var liveSessions: Set<String> = []
        var refusedRequests = 0
        var refreshWorks = true
        var expectedVerifier: String?
        var verifierMatched = false
        /// The one refresh token the server takes; a rotating server replaces it on each refresh.
        var liveRefreshToken = "refresh-1"
        var rotatesRefreshTokens = false
        var rotations = 0
        var tokenFailures: [TokenFailure] = []
        var tokenRequests = 0
        var beforeRefresh: (@Sendable () -> Void)?
        var callDelay: Duration?
        var callFailures: [URLError.Code] = []
    }

    /// How the token endpoint fails one request: no network, or an HTTP status.
    enum TokenFailure: Sendable {
        case offline
        case status(Int)
    }

    let requiresToken: Bool
    let publishesResourceMetadata: Bool
    let supportsRegistration: Bool
    let authMethods: [String]
    /// Answers `initialize` and `tools/list` to anyone and wants a token only for calls, as
    /// Google's Workspace servers do.
    let listsToolsToAnyone: Bool
    /// Takes the token in this query parameter instead of a bearer header, as Browserbase does.
    let queryTokenName: String?

    init(requiresToken: Bool = true, publishesResourceMetadata: Bool = true, supportsRegistration: Bool = true,
         authMethods: [String] = ["none", "client_secret_basic"], listsToolsToAnyone: Bool = false,
         queryTokenName: String? = nil) {
        self.requiresToken = requiresToken
        self.publishesResourceMetadata = publishesResourceMetadata
        self.supportsRegistration = supportsRegistration
        self.authMethods = authMethods
        self.listsToolsToAnyone = listsToolsToAnyone
        self.queryTokenName = queryTokenName
    }

    var requests: [URLRequest] { lock.withLock { recorded } }
    var refusedRequests: Int { lock.withLock { state.refusedRequests } }
    var verifierMatched: Bool { lock.withLock { state.verifierMatched } }
    var validTokens: Set<String> {
        get { lock.withLock { state.validTokens } }
        set { lock.withLock { state.validTokens = newValue } }
    }
    var refreshWorks: Bool {
        get { lock.withLock { state.refreshWorks } }
        set { lock.withLock { state.refreshWorks = newValue } }
    }
    var expectedVerifier: String? {
        get { lock.withLock { state.expectedVerifier } }
        set { lock.withLock { state.expectedVerifier = newValue } }
    }
    /// Each refresh answers with a new refresh token and the old one stops working at once.
    var rotatesRefreshTokens: Bool {
        get { lock.withLock { state.rotatesRefreshTokens } }
        set { lock.withLock { state.rotatesRefreshTokens = newValue } }
    }
    var tokenRequests: Int { lock.withLock { state.tokenRequests } }
    /// Runs as a refresh request arrives, before the server answers it.
    var beforeRefresh: (@Sendable () -> Void)? {
        get { lock.withLock { state.beforeRefresh } }
        set { lock.withLock { state.beforeRefresh = newValue } }
    }

    func failNextTokenRequests(_ failures: [TokenFailure]) { lock.withLock { state.tokenFailures = failures } }

    /// How long a `tools/call` waits before the server answers it; nil answers at once.
    var callDelay: Duration? {
        get { lock.withLock { state.callDelay } }
        set { lock.withLock { state.callDelay = newValue } }
    }

    /// The next `tools/call` requests fail on the way, one failure each.
    func failNextCalls(_ failures: [URLError.Code]) { lock.withLock { state.callFailures = failures } }

    /// A refresh by another copy of the app: spends the live refresh token as the server would.
    func refreshElsewhere() -> (access: String, refresh: String) {
        lock.withLock {
            state.issued += 1
            let access = "access-\(state.issued)"
            state.validTokens.insert(access)
            if state.rotatesRefreshTokens {
                state.rotations += 1
                state.liveRefreshToken = "refresh-r\(state.rotations)"
            }
            return (access, state.liveRefreshToken)
        }
    }

    func forgetSessions() { lock.withLock { state.liveSessions.removeAll() } }

    static func form(_ request: URLRequest) -> [String: String] {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        return fields
    }

    static func rpcMethod(_ request: URLRequest) -> String? {
        (try? JSONDecoder().decode(ToolJSON.self, from: request.httpBody ?? Data()))?["method"]?.stringValue
    }

    static func rpcParams(_ request: URLRequest) -> ToolJSON? {
        (try? JSONDecoder().decode(ToolJSON.self, from: request.httpBody ?? Data()))?["params"]
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        let url = request.url!
        switch (url.host() ?? "", url.path(), request.httpMethod ?? "GET") {
        case ("mcp.example.test", "/.well-known/oauth-protected-resource/mcp", "GET") where publishesResourceMetadata:
            return json(["resource": .string("https://mcp.example.test/mcp"),
                         "authorization_servers": .array([.string("https://auth.example.test")]),
                         "scopes_supported": .array([.string("read"), .string("write")])], url: url)
        case ("auth.example.test", "/.well-known/oauth-authorization-server", "GET"),
             ("mcp.example.test", "/.well-known/oauth-authorization-server", "GET") where !publishesResourceMetadata:
            let base = "https://\(url.host()!)"
            var metadata: [String: ToolJSON] = [
                "issuer": .string(base),
                "authorization_endpoint": .string("\(base)/authorize"),
                "token_endpoint": .string("\(base)/token"),
                "token_endpoint_auth_methods_supported": .array(authMethods.map { .string($0) }),
                "code_challenge_methods_supported": .array([.string("S256")])
            ]
            if supportsRegistration { metadata["registration_endpoint"] = .string("\(base)/register") }
            return json(metadata, url: url)
        case (_, "/register", "POST"):
            let body = try JSONDecoder().decode(ToolJSON.self, from: request.httpBody ?? Data())
            var client: [String: ToolJSON] = ["client_id": .string("client-1")]
            if body["token_endpoint_auth_method"] != .string("none") {
                client["client_secret"] = .string("secret-1")
                client["token_endpoint_auth_method"] = body["token_endpoint_auth_method"]
            }
            return json(client, url: url, status: 201)
        case (_, "/token", "POST"):
            let failure: TokenFailure? = lock.withLock {
                state.tokenRequests += 1
                return state.tokenFailures.isEmpty ? nil : state.tokenFailures.removeFirst()
            }
            switch failure {
            case .offline?: throw URLError(.notConnectedToInternet)
            case .status(let code)?:
                let error = code >= 500 || code == 429 ? "temporarily_unavailable" : "invalid_client"
                return json(["error": .string(error)], url: url, status: code)
            case nil: break
            }
            if Self.form(request)["grant_type"] == "refresh_token", let hook = beforeRefresh { hook() }
            return token(request, url: url)
        case ("mcp.example.test", "/mcp", "POST"):
            if Self.rpcMethod(request) == "tools/call" {
                let (delay, failure) = lock.withLock {
                    (state.callDelay, state.callFailures.isEmpty ? nil : state.callFailures.removeFirst())
                }
                if let delay { try await Task.sleep(for: delay) }
                if let failure { throw URLError(failure) }
            }
            return mcp(request, url: url)
        default:
            return (Data("not found".utf8), response(url, status: 404, headers: ["Content-Type": "text/plain"]))
        }
    }

    private func token(_ request: URLRequest, url: URL) -> (Data, HTTPURLResponse) {
        let form = Self.form(request)
        return lock.withLock {
            switch form["grant_type"] {
            case "authorization_code":
                guard form["code"] == Self.code else { return oauthError("invalid_grant", url: url) }
                if let expected = state.expectedVerifier { state.verifierMatched = form["code_verifier"] == expected }
            case "refresh_token":
                guard state.refreshWorks, form["refresh_token"] == state.liveRefreshToken else { return oauthError("invalid_grant", url: url) }
            default:
                return oauthError("unsupported_grant_type", url: url)
            }
            state.issued += 1
            let access = "access-\(state.issued)"
            state.validTokens.insert(access)
            var body: [String: ToolJSON] = ["access_token": .string(access), "token_type": .string("Bearer"), "expires_in": .integer(3_600)]
            if form["grant_type"] == "authorization_code" {
                body["refresh_token"] = .string(state.liveRefreshToken)
                body["scope"] = .string("read write")
            } else if state.rotatesRefreshTokens {
                state.rotations += 1
                state.liveRefreshToken = "refresh-r\(state.rotations)"
                body["refresh_token"] = .string(state.liveRefreshToken)
            }
            return json(body, url: url)
        }
    }

    private func mcp(_ request: URLRequest, url: URL) -> (Data, HTTPURLResponse) {
        let message = (try? JSONDecoder().decode(ToolJSON.self, from: request.httpBody ?? Data())) ?? .null
        let method = message["method"]?.stringValue ?? ""
        let id = message["id"] ?? .null
        return lock.withLock {
            let bearer = if let queryTokenName {
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == queryTokenName }?.value
            } else {
                request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
            }
            let open = listsToolsToAnyone && method != "tools/call"
            if requiresToken, !open, !(bearer.map { state.validTokens.contains($0) } ?? false) {
                state.refusedRequests += 1
                return (Data(), response(url, status: 401, headers: [
                    "WWW-Authenticate": #"Bearer realm="OAuth", resource_metadata="https://mcp.example.test/.well-known/oauth-protected-resource/mcp", scope="read write""#
                ]))
            }
            if method == "initialize" {
                state.sessions += 1
                let session = "session-\(state.sessions)"
                state.liveSessions.insert(session)
                return rpc(id: id, result: .object([
                    "protocolVersion": .string("2025-06-18"),
                    "capabilities": .object(["tools": .object([:])]),
                    "serverInfo": .object(["name": .string("example"), "version": .string("1"), "icons": .array([
                        .object(["src": .string("https://mcp.example.test/icon-64.png"), "mimeType": .string("image/png"),
                                 "sizes": .array([.string("64x64")])]),
                        .object(["src": .string("https://example.test/icon-dark.svg"), "sizes": .array([.string("any")]),
                                 "theme": .string("dark")]),
                        .object(["src": .string("https://icons.elsewhere.test/example.png"), "sizes": .array([.string("512x512")])])
                    ])])
                ]), url: url, headers: ["Mcp-Session-Id": session])
            }
            guard let session = request.value(forHTTPHeaderField: "Mcp-Session-Id"), state.liveSessions.contains(session) else {
                return (Data(), response(url, status: 404))
            }
            switch method {
            case "notifications/initialized":
                return (Data(), response(url, status: 202))
            case "tools/list":
                let first = message["params"]?["cursor"] == nil
                let tools: [ToolJSON] = first
                    ? [.object(["name": .string("list_issues"), "description": .string("List issues"),
                                "inputSchema": .object(["type": .string("object")]),
                                "annotations": .object(["readOnlyHint": .bool(true)])]),
                       .object(["name": .string("create_issue"), "title": .string("Create issue"),
                                "inputSchema": .object(["type": .string("object"), "properties": .object(["title": .object(["type": .string("string")])])])])]
                    : [.object(["name": .string("whoami")])]
                var result: [String: ToolJSON] = ["tools": .array(tools)]
                if first { result["nextCursor"] = .string("page-2") }
                // The second page arrives as an event stream with a notification first.
                return first ? rpc(id: id, result: .object(result), url: url) : eventStream(id: id, result: .object(result), url: url)
            case "tools/call":
                let name = message["params"]?["name"]?.stringValue
                if name == "create_issue", message["params"]?["arguments"]?["title"] == nil {
                    // The TypeScript SDK's refusal of arguments its schema does not take.
                    let issue = #"[{"code":"invalid_type","expected":"string","received":"undefined","path":["title"],"message":"Required"}]"#
                    return rpc(id: id, result: .object([
                        "content": .array([.object(["type": .string("text"), "text": .string(
                            "MCP error -32602: Input validation error: Invalid arguments for tool create_issue: \(issue)")])]),
                        "isError": .bool(true)
                    ]), url: url)
                }
                if name == "create_issue" {
                    let title = message["params"]?["arguments"]?["title"]?.stringValue ?? ""
                    return rpc(id: id, result: .object([
                        "content": .array([
                            .object(["type": .string("text"), "text": .string("created \(title)")]),
                            .object(["type": .string("resource_link"), "uri": .string("https://example.test/1"), "name": .string("1")])
                        ]),
                        "structuredContent": .object(["id": .integer(1)])
                    ]), url: url)
                }
                return eventStream(id: id, result: .object(["content": .array([.object(["type": .string("text"), "text": .string("you")])])]), url: url)
            default:
                return rpc(id: id, error: .object(["code": .integer(-32601), "message": .string("no \(method)")]), url: url)
            }
        }
    }

    private func response(_ url: URL, status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private func json(_ object: [String: ToolJSON], url: URL, status: Int = 200) -> (Data, HTTPURLResponse) {
        ((try? JSONEncoder().encode(ToolJSON.object(object))) ?? Data(), response(url, status: status, headers: ["Content-Type": "application/json"]))
    }

    private func oauthError(_ code: String, url: URL) -> (Data, HTTPURLResponse) {
        json(["error": .string(code)], url: url, status: 400)
    }

    private func rpc(id: ToolJSON, result: ToolJSON? = nil, error: ToolJSON? = nil, url: URL, headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
        var message: [String: ToolJSON] = ["jsonrpc": .string("2.0"), "id": id]
        if let result { message["result"] = result }
        if let error { message["error"] = error }
        var fields = headers
        fields["Content-Type"] = "application/json"
        return ((try? JSONEncoder().encode(ToolJSON.object(message))) ?? Data(), response(url, status: 200, headers: fields))
    }

    private func eventStream(id: ToolJSON, result: ToolJSON, url: URL) -> (Data, HTTPURLResponse) {
        let reply = (try? JSONEncoder().encode(ToolJSON.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))) ?? Data()
        let text = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{}}\n\n"
            + "event: message\ndata: \(String(decoding: reply, as: UTF8.self))\n\n"
        return (Data(text.utf8), response(url, status: 200, headers: ["Content-Type": "text/event-stream"]))
    }
}
