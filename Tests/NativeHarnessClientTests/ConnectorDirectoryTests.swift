import AppKit
import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Yardlet's connectors as the one place to connect services for every harness and account
/// (docs/CONNECTORS.md): the directory and its sign-ins (dynamic registration, a client the user
/// registered, a token, a key in the address), the per-task switch, leaving out a connector the
/// harness loads itself, reading each harness's own configuration read-only, the import
/// suggestions, the claude.ai switch on Claude processes, and connector names on tool rows.
/// Every server here is a local fake; nothing reaches the network.
@MainActor
final class ConnectorDirectoryTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "connector-directory-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    private func makeCenter(
        server: FakeConnectorServer,
        agent: FakeUserAgent? = FakeUserAgent(),
        credentials: InMemoryConnectorCredentialStore = InMemoryConnectorCredentialStore(),
        repository: any ConnectorRepository = InMemoryConnectorRepository()
    ) -> ConnectorCenter {
        ConnectorCenter(environment: ConnectorCenter.Environment(
            repository: repository, credentials: credentials, http: server, userAgent: agent,
            sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9"
        ))
    }

    private func connectedCenter(
        server: FakeConnectorServer = FakeConnectorServer(),
        repository: any ConnectorRepository = InMemoryConnectorRepository()
    ) async throws -> (ConnectorCenter, ConnectorRecord) {
        let center = makeCenter(server: server, repository: repository)
        let record = try await center.add(name: "Example", serverURL: FakeConnectorServer.mcpURL)
        center.connect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertEqual(center.record(record.id)?.status, .connected)
        return (center, try XCTUnwrap(center.record(record.id)))
    }

    // MARK: - Directory

    /// Each entry is the service's own public endpoint with the sign-in its live metadata showed
    /// on 2026-10-16, 2026-10-21, 2026-10-27 and 2026-10-29 (docs/CONNECTORS.md, "Directory").
    func testTheDirectoryHasEachServicesOfficialEndpointAndSignIn() throws {
        func preset(_ id: String) throws -> ConnectorPreset { try XCTUnwrap(ConnectorPreset.preset(id: id), id) }
        XCTAssertEqual(ConnectorPreset.all.map(\.id), [
            "linear", "notion", "slack", "gmail", "google-calendar", "google-drive", "google-analytics", "google-ads",
            "outlook-mail", "outlook-calendar", "onedrive", "microsoft-teams", "apple-calendar", "apple-reminders",
            "apple-contacts", "github", "browserbase", "atlassian", "sentry", "asana", "clickup", "monday", "todoist", "airtable",
            "miro", "dropbox", "intercom", "zapier", "pipedream", "composio", "make", "granola", "fireflies", "gamma",
            "basecamp", "teamwork", "lucid", "pandadoc", "fathom", "deepl", "mobbin",
            "zoom-meetings", "zoom-team-chat", "zoom-docs",
            "apollo-io", "attio", "customer-io", "klaviyo", "mailerlite", "ahrefs", "semrush", "similarweb", "amplitude", "mixpanel",
            "xcode", "app-store-connect", "gitlab", "supabase", "neon", "prisma", "netlify", "cloudflare", "posthog", "semgrep",
            "postman", "jam", "circleci", "browserstack", "bugsnag", "swagger", "zephyr", "grafana", "honeycomb", "axiom", "statsig",
            "port", "aiven", "upstash", "algolia", "contentful", "sanity", "workos", "apify", "mapbox",
            "stripe", "paypal", "square", "mercury", "webflow", "wix", "ramp", "brex", "paddle", "beancount-io", "hostinger",
            "figma-desktop", "tavily", "exa", "huggingface",
            "context7", "deepwiki", "openai-docs", "microsoft-learn", "aws-knowledge", "cloudflare-docs", "twilio-docs"
        ])
        XCTAssertEqual(Set(ConnectorPreset.all.map(\.id)).count, ConnectorPreset.all.count)
        XCTAssertEqual(Set(ConnectorPreset.all.map { MCPServerAddress.canonical($0.serverURL) }).count, ConnectorPreset.all.count,
                       "Each service once")
        XCTAssertNil(ConnectorPreset.preset(id: "clobe"), "A service only this Mac used is not in everyone's directory")
        XCTAssertEqual(try preset("linear").signIn, .oauth)
        XCTAssertEqual(try preset("notion").signIn, .oauth)
        for id in ["asana", "clickup", "monday", "todoist", "airtable", "miro", "dropbox", "intercom", "zapier", "pipedream",
                   "composio", "make", "granola",
                   "fireflies", "gamma", "gitlab", "supabase", "neon", "prisma", "netlify", "cloudflare", "posthog", "semgrep",
                   "postman", "jam", "stripe", "paypal", "square", "mercury", "webflow", "wix", "tavily",
                   "basecamp", "teamwork", "lucid", "pandadoc", "fathom", "deepl", "mobbin", "apollo-io", "attio", "customer-io",
                   "klaviyo", "mailerlite", "ahrefs", "semrush", "similarweb", "amplitude", "mixpanel", "circleci", "browserstack",
                   "bugsnag", "swagger", "zephyr", "grafana", "honeycomb", "axiom", "statsig", "port", "aiven", "upstash", "algolia",
                   "contentful", "sanity", "workos", "apify", "mapbox", "ramp", "brex", "paddle", "beancount-io", "hostinger"] {
            XCTAssertEqual(try preset(id).signIn, .oauth, "\(id) registers its client dynamically")
        }
        for id in ["exa", "huggingface", "context7", "deepwiki", "openai-docs", "microsoft-learn", "aws-knowledge", "cloudflare-docs",
                   "twilio-docs"] {
            XCTAssertEqual(try preset(id).signIn, ConnectorPreset.SignIn.none, "\(id) answers without a sign-in")
        }
        XCTAssertFalse(ConnectorPreset.all.contains { $0.serverURL.host() == "mcp.vercel.com" || $0.serverURL.host() == "mcp.canva.com" },
                       "Vercel and Canva admit only clients they approved")
        // Each icon is a symbol this macOS draws.
        for item in ConnectorPreset.all {
            XCTAssertNotNil(NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil), "\(item.id): \(item.symbol)")
        }
        XCTAssertEqual(try preset("slack").signIn, .registeredClient)
        // Zoom's product servers register no client (2026-10-27): a Zoom app of the person's own,
        // asked only for each server's read scopes.
        for id in ["zoom-meetings", "zoom-team-chat", "zoom-docs"] {
            let zoom = try preset(id)
            XCTAssertEqual(zoom.signIn, .registeredClient, id)
            XCTAssertEqual(zoom.serverURL.host(), "mcp.zoom.us", id)
            XCTAssertTrue(zoom.scope?.split(separator: " ").allSatisfy { $0.contains(":read") || $0 == "canvas:write:file_search" } == true, id)
        }
        XCTAssertEqual(try preset("slack").serverURL.absoluteString, "https://mcp.slack.com/mcp")
        // Gmail is Yardlet's own server on the public Gmail API (2026-10-17), with one scope.
        let gmail = try preset("gmail")
        XCTAssertEqual(gmail.signIn, .googleAccount)
        XCTAssertEqual(gmail.serverURL.absoluteString, "https://gmail.googleapis.com/gmail/v1/")
        XCTAssertEqual(gmail.scope, "https://www.googleapis.com/auth/gmail.modify")
        // Calendar and Drive are Yardlet's own too since 2026-10-19, on the same Google OAuth app,
        // not Google's MCP servers that need the developer preview.
        for (id, base) in [("google-calendar", "https://www.googleapis.com/calendar/v3/"),
                           ("google-drive", "https://www.googleapis.com/drive/v3/")] {
            let google = try preset(id)
            XCTAssertEqual(google.signIn, .googleAccount, id)
            XCTAssertEqual(google.serverURL.absoluteString, base, id)
            XCTAssertEqual(google.localService?.presetID, id)
            XCTAssertFalse(google.serverURL.host()?.hasSuffix("mcp.googleapis.com") == true, "No preview MCP server: \(id)")
            XCTAssertTrue(google.scope?.contains("https://www.googleapis.com/auth/") == true, id)
            XCTAssertFalse(google.scope?.contains("https://mail.google.com/") == true, "No full mail access: \(id)")
            XCTAssertFalse(google.scope?.split(separator: " ").contains("https://www.googleapis.com/auth/drive") == true,
                           "No full Drive access: \(id)")
        }
        // Mercury reads only: the server lists payment, transfer, category, and note scopes too, and
        // the sign-in asks for none of them (docs.mercury.com/docs/connecting-mercury-mcp).
        XCTAssertEqual(try preset("mercury").serverURL.absoluteString, "https://mcp.mercury.com/mcp")
        XCTAssertEqual(try preset("mercury").scope, "read offline_access")
        // Ramp, Brex, and Apollo.io list payment, card, bank account, sending, and purchase scopes too
        // (2026-10-29); each asks for a few read scopes from its list and nothing that writes.
        XCTAssertEqual(try preset("ramp").scope, "transactions:read business:read cards:read")
        XCTAssertEqual(try preset("brex").scope, "openid offline_access users.readonly expenses.card.readonly accounts.cash.readonly")
        XCTAssertEqual(try preset("apollo-io").scope, "read_user_profile app_scopes people_match organizations_enrich contacts_search")
        for id in ["mercury", "ramp", "brex", "apollo-io"] {
            XCTAssertEqual(ConnectorSetupGuide.summary(try preset(id)), L10n.string("Read-only"), id)
        }
        // The rest ask for what their server lists (docs/CONNECTORS.md, "Connection types", step 5).
        XCTAssertEqual(ConnectorPreset.all.filter { $0.signIn == .oauth && $0.scope != nil }.map(\.id).sorted(),
                       ["apollo-io", "brex", "mercury", "ramp"])
        XCTAssertEqual(try preset("github").signIn, .token)
        XCTAssertTrue(try preset("github").acceptsRegisteredClient)
        XCTAssertEqual(try preset("browserbase").tokenQueryParameter, "browserbaseApiKey")
        XCTAssertEqual(try preset("openai-docs").signIn, ConnectorPreset.SignIn.none)
        XCTAssertEqual(try preset("figma-desktop").serverURL.host(), "127.0.0.1", "Figma's remote server admits only its catalog")
        // The Mac's own data and Xcode are served from this Mac (docs/CONNECTORS.md, "Apple"); App Store
        // Connect is Apple's API.
        for (id, signIn) in [("apple-calendar", ConnectorPreset.SignIn.macPermission), ("apple-reminders", .macPermission),
                             ("apple-contacts", .macPermission), ("xcode", .localApp), ("app-store-connect", .appStoreConnectKey)] {
            XCTAssertEqual(try preset(id).signIn, signIn, id)
            XCTAssertEqual(try preset(id).localService?.presetID, id)
        }
        XCTAssertEqual(try preset("app-store-connect").serverURL.absoluteString, "https://api.appstoreconnect.apple.com/")
        for item in ConnectorPreset.all where item.id != "figma-desktop" {
            let onThisMac = item.localService.map { $0.isMac || $0 == .xcode } ?? false
            XCTAssertEqual(item.serverURL.scheme, onThisMac ? "file" : "https", item.id)
        }
        XCTAssertEqual(ConnectorPreset.preset(for: URL(string: "https://api.githubcopilot.com/mcp")!)?.id, "github",
                       "A trailing slash does not hide a preset")
        XCTAssertEqual(ConnectorPreset.preset(for: URL(string: "https://mcp.browserbase.com/mcp?browserbaseApiKey=x")!)?.id,
                       "browserbase")
    }

    /// Discovery against metadata shaped as the live servers sent it: Slack's protected resource
    /// metadata only at the root and no registration endpoint, Google's issuer with a trailing
    /// slash, Clobe's registration with public clients.
    func testDiscoveryReadsTheLiveMetadataShapes() async throws {
        let server = RecordedMetadataServer()
        let slack = try await ConnectorOAuth.discover(
            serverURL: URL(string: "https://mcp.slack.com/mcp")!,
            challenge: BearerChallenge(resourceMetadata: URL(string: "https://mcp.slack.com/.well-known/oauth-protected-resource")!),
            http: server)
        XCTAssertNil(slack.server.registrationEndpoint)
        XCTAssertEqual(slack.server.authorizationEndpoint.absoluteString, "https://slack.com/oauth/v2_user/authorize")
        XCTAssertEqual(slack.server.tokenEndpointAuthMethods, ["client_secret_post"])
        XCTAssertEqual(slack.scope, "chat:write search:read.public")
        XCTAssertEqual(ConnectorOAuth.registeredClient(id: "1.2", secret: "s", server: slack.server).authMethod, "client_secret_post")
        XCTAssertEqual(ConnectorOAuth.registeredClient(id: "1.2", secret: nil, server: slack.server).authMethod, "none",
                       "A PKCE app has no secret")

        let gmail = try await ConnectorOAuth.discover(serverURL: URL(string: "https://gmailmcp.googleapis.com/mcp/v1")!,
                                                      challenge: nil, http: server)
        XCTAssertEqual(gmail.server.tokenEndpoint.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(gmail.resource, "https://gmailmcp.googleapis.com/mcp/v1")
        XCTAssertNil(gmail.server.registrationEndpoint)

        let github = try await ConnectorOAuth.discover(serverURL: URL(string: "https://api.githubcopilot.com/mcp/")!,
                                                       challenge: nil, http: server)
        XCTAssertNil(github.server.registrationEndpoint)
        XCTAssertEqual(ConnectorOAuth.registeredClient(id: "Iv1", secret: "s", server: github.server).authMethod,
                       "client_secret_post", "No listed methods: the form, as GitHub takes it")

        let clobe = try await ConnectorOAuth.discover(serverURL: URL(string: "https://api.clobe.ai/mcp")!, challenge: nil, http: server)
        XCTAssertEqual(clobe.server.registrationEndpoint?.absoluteString, "https://api.clobe.ai/oauth/register")
        XCTAssertEqual(clobe.scope, "mcp")
        XCTAssertEqual(clobe.resource, "https://api.clobe.ai/mcp")
    }

    // MARK: - Sign-in paths

    /// A Google-style server: tools listed to anyone, calls only with a token, no dynamic
    /// registration. A connector with the user's client signs in before it counts as connected,
    /// on the fixed redirect port, with the preset's scope and offline access.
    func testARegisteredClientSignsInBeforeConnectingAndKeepsItsClientOnDisconnect() async throws {
        let server = FakeConnectorServer(supportsRegistration: false, authMethods: ["client_secret_post", "client_secret_basic"],
                                         listsToolsToAnyone: true)
        let agent = FakeUserAgent()
        let credentials = InMemoryConnectorCredentialStore()
        let center = makeCenter(server: server, agent: agent, credentials: credentials)
        // Shaped as Google's own MCP servers are (Google's scope and offline access); the directory's
        // Google services are Yardlet's own servers now, so the entry is the test's.
        let calendar = ConnectorPreset(id: "google-style", name: "Google Calendar", serverURL: FakeConnectorServer.mcpURL,
                                       signIn: .registeredClient,
                                       scope: "https://www.googleapis.com/auth/calendar.events.readonly",
                                       authorizationParameters: ["access_type": "offline", "prompt": "consent"],
                                       symbol: "calendar")
        let record = try await center.add(name: "Google Calendar", serverURL: FakeConnectorServer.mcpURL,
                                          client: (id: " client-x ", secret: "secret-x"), preset: calendar)
        XCTAssertEqual(record.oauthClientID, "client-x")
        XCTAssertEqual(try credentials.load(record.id), .client(id: "client-x", secret: "secret-x"))

        center.connect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertNil(center.failures[record.id])
        XCTAssertEqual(center.record(record.id)?.status, .connected)
        XCTAssertFalse(server.requests.contains { $0.url?.path() == "/register" }, "No dynamic registration")
        XCTAssertEqual(agent.loopbackPorts, [ConnectorOAuth.registeredClientRedirectPort])
        XCTAssertEqual(ConnectorOAuth.registeredClientRedirectURI.absoluteString, "http://127.0.0.1:47823/callback")

        let opened = try XCTUnwrap(agent.opened.first)
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["client_id"], "client-x")
        XCTAssertEqual(query["scope"], calendar.scope)
        XCTAssertEqual(query["access_type"], "offline")
        XCTAssertEqual(query["prompt"], "consent")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        let form = FakeConnectorServer.form(try XCTUnwrap(server.requests.last { $0.url?.path() == "/token" }))
        XCTAssertEqual(form["client_id"], "client-x")
        XCTAssertEqual(form["client_secret"], "secret-x")
        XCTAssertNotNil(form["code_verifier"])
        let credential = try XCTUnwrap(credentials.load(record.id))
        XCTAssertEqual(credential.kind, .oauth)
        XCTAssertEqual(credential.clientSecret, "secret-x")

        let call = await center.callConnectorTool(named: "google_calendar_whoami", arguments: .object([:]),
                                                  for: ConnectorToolContext())
        XCTAssertEqual(call?.isError, false)
        XCTAssertEqual(server.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")

        // Disconnecting forgets the token and keeps the client, so connecting signs in at once.
        center.disconnect(record.id)
        await center.waitForPendingDeletions()
        XCTAssertEqual(try credentials.load(record.id), .client(id: "client-x", secret: "secret-x"))
        center.connect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertEqual(center.record(record.id)?.status, .connected)
        XCTAssertEqual(agent.loopbackPorts.count, 2)

        // Removing deletes everything.
        center.remove(record.id)
        await center.waitForPendingDeletions()
        XCTAssertNil(try credentials.load(record.id))
    }

    /// A service that lists its tools to anyone (Google's MCP servers do) is not "connected" before the user's
    /// client is there: connecting says what is missing and sends nothing.
    func testAServiceThatNeedsAClientDoesNotConnectWithoutOne() async throws {
        let server = FakeConnectorServer(supportsRegistration: false, listsToolsToAnyone: true)
        let center = makeCenter(server: server)
        let slack = try XCTUnwrap(ConnectorPreset.preset(id: "slack"))
        let record = try await center.add(name: "Slack", serverURL: FakeConnectorServer.mcpURL, preset: slack)
        XCTAssertTrue(record.needsSetupBeforeConnecting)
        center.connect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertEqual(center.record(record.id)?.status, .notConnected)
        XCTAssertEqual(center.failures[record.id], ConnectorOAuthError.noDynamicRegistration.errorDescription)
        XCTAssertTrue(server.requests.isEmpty)
        let github = try await center.add(name: "GitHub", serverURL: FakeConnectorServer.mcpURL, token: "t",
                                          preset: try XCTUnwrap(ConnectorPreset.preset(id: "github")))
        XCTAssertFalse(github.needsSetupBeforeConnecting, "A token is enough")
    }

    /// "Reconnect" starts an OAuth sign-in over, and one cancelled on the server's page leaves the
    /// earlier sign-in as it was; a pasted token is kept, since only the user can replace it.
    func testReconnectSignsInAgainAndKeepsAPastedToken() async throws {
        let server = FakeConnectorServer()
        server.validTokens.insert("pasted")
        let credentials = InMemoryConnectorCredentialStore()
        let agent = FakeUserAgent()
        let center = makeCenter(server: server, agent: agent, credentials: credentials)
        let oauth = try await center.add(name: "Example", serverURL: FakeConnectorServer.mcpURL)
        center.connect(oauth.id)
        await center.waitForConnection(oauth.id)
        let connected = try XCTUnwrap(center.record(oauth.id))
        let earlier = try credentials.load(oauth.id)
        agent.declines = true
        center.reconnect(oauth.id)
        await center.waitForConnection(oauth.id)
        XCTAssertEqual(agent.opened.count, 2)
        XCTAssertEqual(try credentials.load(oauth.id), earlier)
        XCTAssertEqual(center.record(oauth.id), connected)
        XCTAssertNil(center.failures[oauth.id])

        agent.declines = false
        let registrations = server.requests.filter { $0.url?.path() == "/register" }.count
        center.reconnect(oauth.id)
        await center.waitForConnection(oauth.id)
        XCTAssertEqual(server.requests.filter { $0.url?.path() == "/register" }.count, registrations + 1)
        XCTAssertEqual(center.record(oauth.id)?.status, .connected)
        XCTAssertEqual(try credentials.load(oauth.id)?.accessToken, "access-2")

        let token = try await center.add(name: "Token", serverURL: FakeConnectorServer.mcpURL, token: "pasted")
        center.reconnect(token.id)
        await center.waitForConnection(token.id)
        await center.waitForPendingDeletions()
        XCTAssertEqual(try credentials.load(token.id), .token("pasted"))
        XCTAssertEqual(center.record(token.id)?.status, .connected)
    }

    /// A Slack app with PKCE turned on is a public client: no secret in the token request.
    func testARegisteredPublicClientSendsNoSecret() async throws {
        let server = FakeConnectorServer(supportsRegistration: false, authMethods: ["client_secret_post"])
        let credentials = InMemoryConnectorCredentialStore()
        let center = makeCenter(server: server, credentials: credentials)
        let record = try await center.add(name: "Slack", serverURL: FakeConnectorServer.mcpURL)
        center.connect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertEqual(center.failures[record.id], ConnectorOAuthError.noDynamicRegistration.errorDescription,
                       "Without a client the error says to add one or a token")

        try await center.useRegisteredClient(id: "123.456", secret: "  ", for: record.id)
        await center.waitForConnection(record.id)
        XCTAssertEqual(center.record(record.id)?.status, .connected)
        XCTAssertEqual(center.record(record.id)?.oauthClientID, "123.456")
        let form = FakeConnectorServer.form(try XCTUnwrap(server.requests.last { $0.url?.path() == "/token" }))
        XCTAssertEqual(form["client_id"], "123.456")
        XCTAssertNil(form["client_secret"])
        XCTAssertNil(server.requests.last { $0.url?.path() == "/token" }?.value(forHTTPHeaderField: "Authorization"))
    }

    /// Browserbase takes its key in the address. The key goes in each request's query and in the
    /// keychain, never in the saved record or a header.
    func testAKeyInTheAddressStaysOutOfTheRecord() async throws {
        let server = FakeConnectorServer(queryTokenName: "browserbaseApiKey")
        server.validTokens.insert("bb-key-1")
        let directory = try temporaryDirectory()
        let repository = FileConnectorRepository(fileURL: directory.appending(path: "connectors.json"))
        let credentials = InMemoryConnectorCredentialStore()
        let center = makeCenter(server: server, agent: nil, credentials: credentials, repository: repository)
        let browserbase = try XCTUnwrap(ConnectorPreset.preset(id: "browserbase"))
        let record = try await center.add(name: "Browserbase", serverURL: FakeConnectorServer.mcpURL, token: "bb-key-1",
                                          preset: browserbase)
        XCTAssertEqual(record.tokenQueryParameter, "browserbaseApiKey")
        center.connect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertEqual(center.record(record.id)?.status, .connected)
        let last = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(last.url), resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "browserbaseApiKey", value: "bb-key-1")])
        XCTAssertNil(last.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(center.record(record.id)?.serverURL, FakeConnectorServer.mcpURL)
        let saved = try String(contentsOf: directory.appending(path: "connectors.json"), encoding: .utf8)
        XCTAssertFalse(saved.contains("bb-key-1"), saved)
        XCTAssertTrue(saved.contains("browserbaseApiKey"), "The parameter's name is not a secret")
    }

    /// A no-sign-in preset (OpenAI's docs) connects as such.
    func testAPresetWithoutSignInConnectsDirectly() async throws {
        let server = FakeConnectorServer(requiresToken: false)
        let center = makeCenter(server: server, agent: nil)
        let docs = try XCTUnwrap(ConnectorPreset.preset(id: "openai-docs"))
        let record = try await center.add(name: "", serverURL: FakeConnectorServer.mcpURL, preset: docs)
        XCTAssertEqual(record.name, "OpenAI Docs")
        XCTAssertEqual(record.authorization, ConnectorRecord.Authorization.none)
        center.connect(record.id)
        await center.waitForConnection(record.id)
        XCTAssertEqual(center.record(record.id)?.status, .connected)
        XCTAssertNil(server.requests.first { $0.value(forHTTPHeaderField: "Authorization") != nil })
    }

    // MARK: - Per task

    func testAConnectorTurnedOffInATaskLeavesThatTaskOnlyAndIsRemembered() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appending(path: "connectors.json")
        let (center, record) = try await connectedCenter(repository: FileConnectorRepository(fileURL: file))
        let taskA = UUID()
        let taskB = UUID()
        center.setConnector(record.id, on: false, inTask: taskA)
        XCTAssertFalse(center.isOn(record.id, inTask: taskA))
        XCTAssertTrue(center.isOn(record.id, inTask: taskB))
        XCTAssertEqual(center.state(of: record, inTask: taskA, scope: nil), .off)

        let inA = await center.connectorTools(for: ConnectorToolContext(taskID: taskA))
        let inB = await center.connectorTools(for: ConnectorToolContext(taskID: taskB))
        XCTAssertEqual(inA, [])
        XCTAssertEqual(inB.compactMap { $0["name"]?.stringValue }, ["example_list_issues", "example_create_issue", "example_whoami"])
        let refused = await center.callConnectorTool(named: "example_whoami", arguments: .object([:]),
                                                     for: ConnectorToolContext(taskID: taskA))
        XCTAssertEqual(refused?.isError, true)
        XCTAssertTrue(refused?.text.contains("turned off for this task") == true, refused?.text ?? "")
        let allowed = await center.callConnectorTool(named: "example_whoami", arguments: .object([:]),
                                                     for: ConnectorToolContext(taskID: taskB))
        XCTAssertEqual(allowed?.text, "you")

        // Kept with the connectors, and read back by the next run.
        let reloaded = FileConnectorRepository(fileURL: file)
        XCTAssertEqual(reloaded.loadTaskChoices(), [taskA: [record.id]])
        XCTAssertEqual(reloaded.load().map(\.id), [record.id], "Saving the choice keeps the connectors")
        center.setConnector(record.id, on: true, inTask: taskA)
        XCTAssertEqual(reloaded.loadTaskChoices(), [:])
        center.setConnector(record.id, on: false, inTask: taskA)
        center.remove(record.id)
        XCTAssertEqual(reloaded.loadTaskChoices(), [:], "Removing a connector forgets its choices")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("offInTasks"))
    }

    /// Through the Yardlet MCP server: the task's own list and calls follow its switch and scope.
    func testTheBrokerAppliesEachTasksSwitchAndScope() async throws {
        let (center, record) = try await connectedCenter()
        let broker = AgentToolBroker(
            environment: AgentToolBroker.Environment(
                executableURL: try makeExecutable(), endpoint: "/tmp/unused.sock",
                privateDirectory: FileManager.default.temporaryDirectory, isEnabled: { false }),
            tools: BrowserAgentTools(usesMacEditingCommands: true, pages: { _ in throw CancellationError() }, closePage: { _ in })
        )
        broker.connectors = center
        func names(_ task: UUID, scope: ConnectorTaskScope?) async throws -> [String] {
            let launch = try XCTUnwrap(broker.agentToolServer(for: task, workspaceRoots: [], connectorScope: scope))
            let token = try XCTUnwrap(launch.environment[AgentToolEnvironment.token])
            let list = try XCTUnwrapAsync(await broker.list(AgentToolCall(token: token, session: task.uuidString, tool: "",
                                                                          arguments: .object([:]), method: AgentToolCall.listMethod)))
            return list.tools.compactMap { $0["name"]?.stringValue }
        }
        let codex = ConnectorTaskScope(harness: .codex)
        let plain = try await names(UUID(), scope: codex)
        XCTAssertEqual(plain, ["example_list_issues", "example_create_issue", "example_whoami"])

        let off = UUID()
        center.setConnector(record.id, on: false, inTask: off)
        let turnedOff = try await names(off, scope: codex)
        XCTAssertEqual(turnedOff, [])

        // The harness loads a server at the same address itself: Yardlet leaves its copy out.
        let native = ConnectorTaskScope(harness: .claudeCode,
                                        nativeServerURLs: [MCPServerAddress.canonical(URL(string: "https://MCP.example.test/mcp/")!)])
        let duplicated = UUID()
        let left = try await names(duplicated, scope: native)
        XCTAssertEqual(left, [])
        XCTAssertEqual(broker.connectorScope(for: duplicated), native)
        XCTAssertEqual(center.state(of: record, inTask: duplicated, scope: native), .harnessHasIt)
        let launch = try XCTUnwrap(broker.agentToolServer(for: duplicated, workspaceRoots: [], connectorScope: native))
        let call = await broker.handle(AgentToolCall(token: try XCTUnwrap(launch.environment[AgentToolEnvironment.token]),
                                                     session: duplicated.uuidString, tool: "example_whoami", arguments: .object([:])))
        XCTAssertTrue(call.isError)
        XCTAssertTrue(call.text.contains("its own Example server"), call.text)

        // Antigravity tasks get none.
        let antigravity = try await names(UUID(), scope: ConnectorTaskScope(harness: .antigravityCLI))
        XCTAssertEqual(antigravity, [])
        XCTAssertEqual(center.state(of: record, inTask: nil, scope: ConnectorTaskScope(harness: .antigravityCLI)),
                       .unsupportedHarness)
    }

    /// A connected Yardlet connector stands in for Claude Code's own server at the same address:
    /// the task gets Yardlet's tools and the process is told to leave the harness's copy out, so
    /// one sign-in serves every account. Other harnesses, and a connector not connected now, keep
    /// the harness's own server as before.
    func testAConnectedConnectorStandsInForClaudeCodesOwnServer() async throws {
        let (center, record) = try await connectedCenter()
        let broker = AgentToolBroker(
            environment: AgentToolBroker.Environment(
                executableURL: try makeExecutable(), endpoint: "/tmp/unused.sock",
                privateDirectory: FileManager.default.temporaryDirectory, isEnabled: { false }),
            tools: BrowserAgentTools(usesMacEditingCommands: true, pages: { _ in throw CancellationError() }, closePage: { _ in })
        )
        broker.connectors = center
        // The folder registers the same server twice under its own names, as written in its file,
        // and a read-only endpoint on the same host that Yardlet does not serve.
        let servers = [
            HarnessRemoteServer(name: "example", url: URL(string: "https://MCP.example.test/mcp/")!),
            HarnessRemoteServer(name: "example-server", url: URL(string: "https://mcp.example.test/mcp")!),
            HarnessRemoteServer(name: "example-readonly", url: URL(string: "https://mcp.example.test/mcp/readonly")!)
        ]
        func scope(_ harness: HarnessKind) -> ConnectorTaskScope {
            center.withYardletStandIns(ConnectorTaskScope(harness: harness, nativeServerURLs: Set(servers.map(\.address)),
                                                          nativeServers: servers))
        }

        let claude = scope(.claudeCode)
        XCTAssertEqual(claude.yardletServedURLs, ["https://mcp.example.test/mcp"])
        XCTAssertEqual(claude.leftOutNativeServers.map(\.name), ["example", "example-server"])
        XCTAssertEqual(center.state(of: record, inTask: UUID(), scope: claude), .on)
        let task = UUID()
        let launch = try XCTUnwrap(broker.agentToolServer(for: task, workspaceRoots: [], connectorScope: claude))
        XCTAssertEqual(launch.claudeSettings, .object(["deniedMcpServers": .array([
            .object(["serverUrl": .string("https://MCP.example.test/mcp/")]),
            .object(["serverUrl": .string("https://MCP.example.test/mcp/?*")]),
            .object(["serverUrl": .string("https://mcp.example.test/mcp")]),
            .object(["serverUrl": .string("https://mcp.example.test/mcp?*")])
        ])]))
        let token = try XCTUnwrap(launch.environment[AgentToolEnvironment.token])
        let list = try XCTUnwrapAsync(await broker.list(AgentToolCall(token: token, session: task.uuidString, tool: "",
                                                                      arguments: .object([:]), method: AgentToolCall.listMethod)))
        XCTAssertEqual(list.tools.compactMap { $0["name"]?.stringValue }, ["example_list_issues", "example_create_issue", "example_whoami"])
        let call = await broker.handle(AgentToolCall(token: token, session: task.uuidString, tool: "example_whoami",
                                                     arguments: .object([:])))
        XCTAssertFalse(call.isError, call.text)

        // Codex cannot leave a server out of one thread here: it keeps its own, Yardlet's stays out.
        let codex = scope(.codex)
        XCTAssertEqual(codex.yardletServedURLs, [])
        XCTAssertEqual(center.state(of: record, inTask: UUID(), scope: codex), .harnessHasIt)
        XCTAssertNil(try XCTUnwrap(broker.agentToolServer(for: UUID(), workspaceRoots: [], connectorScope: codex)).claudeSettings)

        // Signed out in Yardlet: the next Claude launch keeps the harness's own server.
        center.disconnect(record.id)
        let fallback = scope(.claudeCode)
        XCTAssertEqual(fallback.yardletServedURLs, [])
        XCTAssertEqual(center.state(of: record, inTask: UUID(), scope: fallback), .harnessHasIt)
        XCTAssertEqual(fallback.leftOutNativeServers, [], "Nothing for the launch to leave out")
    }

    /// The servers Claude Code leaves out go as one `--settings` document for that process, ahead
    /// of `--mcp-config` (which takes several values and so comes last); none, no flag.
    func testTheLeftOutServersGoToTheProcessAsItsOwnSettings() {
        let base = ClaudeLaunchConfiguration(providerSessionID: "s", workspaceURL: URL(filePath: "/tmp"),
                                             resumesExistingSession: false, agentToolConfigPath: "/private/claude.json")
        XCTAssertFalse(ClaudeProcessTransport.arguments(for: base).contains("--settings"))
        var configuration = base
        configuration.settings = #"{"deniedMcpServers":[{"serverUrl":"https://mcp.linear.app/mcp"}]}"#
        let arguments = ClaudeProcessTransport.arguments(for: configuration)
        let index = try? XCTUnwrap(arguments.firstIndex(of: "--settings"))
        XCTAssertEqual(index.map { arguments[$0 + 1] }, configuration.settings)
        XCTAssertLessThan(index ?? .max, arguments.firstIndex(of: "--mcp-config") ?? -1)
        XCTAssertEqual(arguments.suffix(2), ["--mcp-config", "/private/claude.json"])
    }

    /// The harness's own server that Yardlet's connector stands in for says so, in plain words; the
    /// harness reports it failed ("blocked"), but it is not an error and needs nothing.
    func testAStoodInServerReadsAsUsingYardletsConnector() throws {
        let linear = ConnectorRecord(name: "Linear", slug: "linear", serverURL: URL(string: "https://mcp.linear.app/mcp")!,
                                     authorization: .oauth, status: .connected, tools: [.object(["name": .string("a")])],
                                     presetID: "linear")
        let list = try XCTUnwrap(ComposerConnectorList.make(
            ComposerConnectorsSlot(sessionServers: [HarnessMCPServerStatus(name: "linear", state: .failed),
                                                    HarnessMCPServerStatus(name: "sentry", state: .failed)],
                                   carriesYardletConnectors: true),
            connectors: [linear], taskState: { _ in .on }, standInServerNames: ["linear"]))
        XCTAssertEqual(list.rows.map(\.name), ["sentry", "Linear", "linear"])
        XCTAssertEqual(list.rows.map(\.state), [.failed, .connected, .yardletStandsIn])
        XCTAssertEqual(list.rows.last?.statusText, L10n.string("Uses Yardlet's connector"))
        XCTAssertEqual(list.needsReconnectionCount, 1, "Only the server that really failed")
        XCTAssertEqual(list.rows.map(\.isSwitchable), [false, true, false])
    }

    /// The composer list: Yardlet's rows carry this task's state, switch, and "Reconnect"; the
    /// harness's own servers are read-only.
    func testTheComposerListShowsEachConnectorsStateInTheTask() throws {
        let linear = ConnectorRecord(name: "Linear", slug: "linear", serverURL: URL(string: "https://mcp.linear.app/mcp")!,
                                     authorization: .oauth, status: .connected, tools: [.object(["name": .string("a")])],
                                     presetID: "linear")
        let notion = ConnectorRecord(name: "Notion", slug: "notion", serverURL: URL(string: "https://mcp.notion.com/mcp")!,
                                     authorization: .oauth, status: .connected, presetID: "notion")
        let slack = ConnectorRecord(name: "Slack", slug: "slack", serverURL: URL(string: "https://mcp.slack.com/mcp")!,
                                    authorization: .oauth, status: .signInRequired, presetID: "slack")
        let states: [UUID: ConnectorTaskState] = [linear.id: .harnessHasIt, notion.id: .off, slack.id: .on]
        let list = try XCTUnwrap(ComposerConnectorList.make(
            ComposerConnectorsSlot(sessionServers: [HarnessMCPServerStatus(name: "linear", state: .connected, toolCount: 3)],
                                   carriesYardletConnectors: true),
            connectors: [linear, notion, slack], taskState: { states[$0.id] ?? .on }))
        XCTAssertEqual(list.rows.map(\.name), ["Slack", "Linear", "Notion", "linear"])
        XCTAssertEqual(list.rows.map(\.state), [.needsAuthentication, .harnessHasIt, .offInTask, .connected])
        XCTAssertEqual(list.rows.map(\.isSwitchable), [true, false, true, false])
        XCTAssertEqual(list.rows.map(\.canReconnect), [true, false, false, false])
        XCTAssertEqual(list.rows.map(\.isOn), [true, true, false, true])
        XCTAssertEqual(list.rows[1].statusText, L10n.string("Uses the harness's own server"))
        XCTAssertEqual(list.rows[2].statusText, L10n.string("Off for this task"))
        XCTAssertEqual(list.rows.first?.presetID, "slack")
    }

    // MARK: - Native configuration, read-only

    func testClaudeConfigKeepsNamesAndAddressesButNoSecret() throws {
        let config = ClaudeNativeMCPConfig.parse(Data(Self.claudeFixture.utf8))
        XCTAssertEqual(config.userServers.map(\.name), ["docs"])
        XCTAssertEqual(config.userServers.first?.url?.absoluteString, "https://mcp.example.test/mcp", "The query is dropped")
        let project = try XCTUnwrap(config.projects["/work/rental"])
        XCTAssertEqual(project.servers.map(\.name), ["browserbase", "linear", "yardlet"])
        XCTAssertEqual(project.servers[1].url?.absoluteString, "https://mcp.linear.app/mcp")
        XCTAssertEqual(project.servers[2].command, "yardlet-mcp", "A program by its file name alone")
        XCTAssertEqual(project.servers.first?.command, "npx")
        XCTAssertEqual(project.servers.first?.package, "@browserbasehq/mcp-browserbase")
        XCTAssertEqual(project.disabled, ["claude.ai Gmail"])
        XCTAssertEqual(config.claudeAIConnectors, ["claude.ai Gmail", "claude.ai Linear", "claude.ai Claude Docs"])
        XCTAssertFalse(String(describing: config).contains("SECRET"), String(describing: config))

        let codex = CodexNativeMCPConfig.parse(Self.codexFixture)
        XCTAssertEqual(codex.servers.map(\.name), ["clobe", "node_repl", "computer-use", "docs.v2"])
        XCTAssertEqual(codex.servers.map(\.isEnabled), [true, true, false, true])
        XCTAssertEqual(codex.servers.first?.url?.absoluteString, "https://api.clobe.ai/mcp")
        XCTAssertEqual(codex.servers[1].command, "node_repl")
        XCTAssertEqual(codex.servers.last?.url?.absoluteString, "https://docs.example.test/mcp")
        XCTAssertEqual(codex.plugins, ["linear@openai-curated", "github@openai-curated"])
        XCTAssertFalse(String(describing: codex).contains("SECRET"), String(describing: codex))

        XCTAssertEqual(AntigravityNativeMCPConfig.parse(Data()), [], "An empty file has no servers")
        let antigravity = AntigravityNativeMCPConfig.parse(Data(#"{"mcpServers":{"notion":{"serverUrl":"https://mcp.notion.com/mcp"}}}"#.utf8))
        XCTAssertEqual(antigravity.map(\.name), ["notion"])
        XCTAssertEqual(antigravity.first?.scope, .antigravity)

        XCTAssertNil(NativeMCPConfigFiles.packageName(in: ["--api-key", "abcdefghijklmnopqrstuvwxyz0123"]),
                     "An argument that may be a key is never kept")
    }

    /// The servers a task's harness loads itself, from fixture homes: Claude's user servers, the
    /// folder's local ones less those turned off, its approved `.mcp.json` ones; Codex's enabled ones.
    func testTheServersATaskLoadsComeFromItsAccountAndFolder() throws {
        let root = try temporaryDirectory()
        let account = root.appending(path: "account", directoryHint: .isDirectory)
        let workspace = root.appending(path: "work/rental", directoryHint: .isDirectory)
        let other = root.appending(path: "work/other", directoryHint: .isDirectory)
        for folder in [account, workspace, other] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var workspacePath = workspace.standardizedFileURL.path(percentEncoded: false)
        if workspacePath.hasSuffix("/") { workspacePath.removeLast() }
        let fixture = Self.claudeFixture.replacingOccurrences(of: "/work/rental", with: workspacePath)
        try Data(fixture.utf8).write(to: account.appending(path: ".claude.json"))
        try Data(#"{"mcpServers":{"sentry":{"type":"http","url":"https://mcp.sentry.dev/mcp"},"atlassian":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp"}}}"#.utf8)
            .write(to: workspace.appending(path: ".mcp.json"))
        try FileManager.default.createDirectory(at: workspace.appending(path: ".claude"), withIntermediateDirectories: true)
        try Data(#"{"enabledMcpjsonServers":["sentry"]}"#.utf8).write(to: workspace.appending(path: ".claude/settings.local.json"))

        let inTask = NativeMCPInventory.loadedRemoteServers(harness: .claudeCode, configFolder: account,
                                                            workspaceURL: workspace, homeURL: root)
        XCTAssertEqual(inTask, ["https://mcp.example.test/mcp", "https://mcp.linear.app/mcp", "https://mcp.sentry.dev/mcp"],
                       "Atlassian's `.mcp.json` entry was never approved")
        let elsewhere = NativeMCPInventory.loadedRemoteServers(harness: .claudeCode, configFolder: account,
                                                               workspaceURL: other, homeURL: root)
        XCTAssertEqual(elsewhere, ["https://mcp.example.test/mcp"], "A local server belongs to its folder")

        let codexHome = root.appending(path: "codex", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try Data(Self.codexFixture.utf8).write(to: codexHome.appending(path: "config.toml"))
        XCTAssertEqual(NativeMCPInventory.loadedRemoteServers(harness: .codex, configFolder: codexHome, workspaceURL: workspace),
                       ["https://api.clobe.ai/mcp", "https://docs.example.test/mcp"])
        XCTAssertEqual(NativeMCPInventory.loadedRemoteServers(harness: .openCode, configFolder: codexHome, workspaceURL: workspace), [])

        // The default login's `.claude.json` sits beside `~/.claude`; an account folder holds its own.
        XCTAssertEqual(NativeMCPHome.claudeConfigFile(configDirectory: root.appending(path: ".claude"), homeURL: root),
                       root.appending(path: ".claude.json"))
        XCTAssertEqual(NativeMCPHome.claudeConfigFile(configDirectory: account, homeURL: root), account.appending(path: ".claude.json"))

        // A session's scope reads the same files for its account.
        let connection = ProviderConnection(id: "a", name: "developer@example.test", harness: .claudeCode, providerID: nil,
                                            homePath: account.path(percentEncoded: false), credentialSelector: nil)
        let session = SessionRecord(harness: .claudeCode, workspaceURL: workspace, runtimeExecutableURL: URL(filePath: "/bin/true"),
                                    title: "t", connection: connection)
        let scope = ConnectorCenter.scope(for: session, locations: HarnessModelSettingsLocations(
            claudeConfigDirectory: root.appending(path: ".claude"), codexHome: codexHome, codexYardletHome: codexHome))
        XCTAssertEqual(scope.harness, .claudeCode)
        XCTAssertTrue(scope.nativeServerURLs.contains("https://mcp.linear.app/mcp"))
    }

    /// Every home's servers, and what they suggest connecting through Yardlet: each service once,
    /// in the directory's order, less what is added, the Yardlet server, and claude.ai's own.
    func testImportSuggestionsComeFromEveryHarnessAndAccount() throws {
        let root = try temporaryDirectory()
        let claudeFile = root.appending(path: "claude.json")
        try Data(Self.claudeFixture.utf8).write(to: claudeFile)
        let codexHome = root.appending(path: "codex", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try Data(Self.codexFixture.utf8).write(to: codexHome.appending(path: "config.toml"))
        let empty = root.appending(path: "mcp_config.json")
        try Data().write(to: empty)
        let inventory = NativeMCPInventory.read([
            NativeMCPHome(kind: .claude(file: claudeFile), account: "developer@example.test"),
            NativeMCPHome(kind: .codex(home: codexHome)),
            NativeMCPHome(kind: .antigravity(file: empty)),
            NativeMCPHome(kind: .claude(file: root.appending(path: "missing.json")))
        ])
        XCTAssertEqual(inventory.map(\.home.harness), [.claudeCode, .codex], "Missing and empty files are left out")

        let notion = ConnectorRecord(name: "Notion", slug: "notion", serverURL: URL(string: "https://mcp.notion.com/mcp")!)
        let suggestions = ConnectorImportSuggestion.suggestions(from: inventory, connected: [notion])
        XCTAssertEqual(suggestions.map(\.name), ["Linear", "Gmail", "GitHub", "Browserbase", "docs", "clobe", "docs.v2"])
        let linear = try XCTUnwrap(suggestions.first)
        XCTAssertEqual(linear.foundIn, ["Claude Code · developer@example.test", L10n.format("claude.ai · %@", "developer@example.test"),
                                        L10n.string("Codex plugin")])
        XCTAssertTrue(linear.connectsInOneClick)
        XCTAssertFalse(try XCTUnwrap(suggestions.first { $0.name == "Gmail" }).connectsInOneClick, "Gmail needs a client first")
        XCTAssertFalse(suggestions.contains { $0.name == "yardlet" || $0.name.contains("Claude Docs") })
        XCTAssertEqual(suggestions.first { $0.name == "docs" }?.serverURL?.absoluteString, "https://mcp.example.test/mcp",
                       "A server the directory does not know is offered as it is, without its query")
    }

    // MARK: - Per-process injection

    /// Claude Code processes Yardlet starts leave the account's claude.ai connectors out unless the
    /// setting is on, through the CLI's own variable; nothing else changes.
    func testClaudeProcessesLeaveClaudeAIConnectorsOutUnlessTurnedOn() throws {
        let suite = testDefaultsSuite("connector-directory")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertFalse(ClaudeAIConnectorPreference.isEnabled(in: defaults), "Off by default")
        defaults.set(true, forKey: ClaudeAIConnectorPreference.key)
        XCTAssertTrue(ClaudeAIConnectorPreference.isEnabled(in: defaults))

        let base = ["PATH": "/usr/bin", "HOME": "/Users/x"]
        let off = ClaudeProcessTransport.environment(base: base, overrides: ["CLAUDE_CONFIG_DIR": "/accounts/a"])
        XCTAssertEqual(off["ENABLE_CLAUDEAI_MCP_SERVERS"], "false")
        XCTAssertEqual(off["CLAUDE_CONFIG_DIR"], "/accounts/a")
        let on = ClaudeProcessTransport.environment(base: base, overrides: ["CLAUDE_CONFIG_DIR": "/accounts/a"],
                                                    claudeAIConnectors: true)
        XCTAssertNil(on["ENABLE_CLAUDEAI_MCP_SERVERS"])
        XCTAssertEqual(on.filter { $0.key != "ENABLE_CLAUDEAI_MCP_SERVERS" }, off.filter { $0.key != "ENABLE_CLAUDEAI_MCP_SERVERS" })
    }

    /// Every harness gets the one Yardlet server per process; the launch carries the task's token
    /// and never a connector's credential, so any account's process gets the same connectors.
    func testEachProcessGetsTheYardletServerAndNoConnectorSecret() async throws {
        let (center, _) = try await connectedCenter()
        let broker = AgentToolBroker(
            environment: AgentToolBroker.Environment(
                executableURL: try makeExecutable(), endpoint: "/tmp/unused.sock",
                privateDirectory: try temporaryDirectory(), isEnabled: { true }),
            tools: BrowserAgentTools(usesMacEditingCommands: true, pages: { _ in throw CancellationError() }, closePage: { _ in })
        )
        broker.connectors = center
        let task = UUID()
        let launch = try XCTUnwrap(broker.agentToolServer(for: task, workspaceRoots: [],
                                                          connectorScope: ConnectorTaskScope(harness: .claudeCode)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let claude = String(decoding: try encoder.encode(launch.claudeConfig), as: UTF8.self)
        let codex = String(decoding: try encoder.encode(launch.codexConfig), as: UTF8.self)
        let acp = String(decoding: try encoder.encode(launch.acpServer), as: UTF8.self)
        XCTAssertEqual(launch.claudeConfig["mcpServers"]?.objectValue.map { Array($0.keys) }, ["yardlet"])
        XCTAssertEqual(launch.codexConfig["mcp_servers"]?.objectValue.map { Array($0.keys) }, ["yardlet"])
        for document in [claude, codex, acp] {
            XCTAssertFalse(document.contains("access-1"), document)
            XCTAssertFalse(document.contains("refresh-1"), document)
            XCTAssertTrue(document.contains(task.uuidString), document)
        }
        let file = try launch.writeClaudeConfig(for: task)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: - Tool rows

    func testAConnectorsToolReadsAsTheConnectorsOnItsRow() throws {
        let linear = ConnectorRecord(name: "Linear", slug: "linear", serverURL: URL(string: "https://mcp.linear.app/mcp")!,
                                     status: .connected, tools: [.object(["name": .string("create_issue")])], presetID: "linear")
        ConnectorToolLabels.shared.update([linear])
        defer { ConnectorToolLabels.shared.update([]) }
        XCTAssertEqual(ConversationLineWording.mcpLabel("mcp__yardlet__linear_create_issue"), "Linear: create issue")
        XCTAssertEqual(ConversationLineWording.mcpLabel("mcp__github__create_issue"), "github: create issue",
                       "Other servers keep their names")
        XCTAssertEqual(ConversationLineWording.mcpLabel("mcp__yardlet__browser_snapshot"), "yardlet: browser snapshot")
        let label = try XCTUnwrap(ConnectorToolLabels.shared.label(forTool: "linear_create_issue"))
        XCTAssertEqual(label, ConnectorToolLabels.Label(connector: "Linear", presetID: "linear", tool: "create_issue",
                                                        icons: .preset("linear")))

        let activity = HarnessActivity(id: "toolu_1", kind: "mcp__yardlet__linear_create_issue",
                                       title: "mcp__yardlet__linear_create_issue")
        guard case .tool(let tool) = ConversationActivityProjection.kind(activity, harness: .claudeCode, phase: .completed,
                                                                         isApproved: false) else {
            return XCTFail("A connector call is a tool row")
        }
        XCTAssertEqual(tool.connector, label)
        XCTAssertEqual(ConversationLineWording.tool(tool, phase: .completed, harness: .claudeCode, workspaceURL: nil).text,
                       ConversationLineWords.filling(L10n.string("claude.used"), ["Linear: create issue"]).text)
    }

    // MARK: - Fixtures

    /// A `.claude.json` with fake values where real ones keep secrets: a header, a query, a
    /// command-line key, an environment value.
    static let claudeFixture = #"""
    {
      "mcpServers": {
        "docs": {"type": "http", "url": "https://mcp.example.test/mcp?key=SECRET-1",
                 "headers": {"Authorization": "Bearer SECRET-2"}}
      },
      "projects": {
        "/work/rental": {
          "mcpServers": {
            "linear": {"type": "http", "url": "https://mcp.linear.app/mcp"},
            "browserbase": {"type": "stdio", "command": "npx",
                            "args": ["-y", "@smithery/cli@latest", "install", "@browserbasehq/mcp-browserbase", "--key", "sk-SECRET-3"],
                            "env": {"BROWSERBASE_API_KEY": "SECRET-4"}},
            "yardlet": {"type": "stdio", "command": "/Applications/Yardlet.app/Contents/Helpers/yardlet-mcp"}
          },
          "disabledMcpServers": ["claude.ai Gmail"],
          "history": [{"display": "SECRET-5"}]
        },
        "/work/empty": {"allowedTools": []}
      },
      "claudeAiMcpEverConnected": ["claude.ai Gmail", "claude.ai Linear", "claude.ai Claude Docs"],
      "oauthAccount": {"emailAddress": "developer@example.test"}
    }
    """#

    /// A Codex `config.toml` with fake values: an environment table and a tokened query.
    static let codexFixture = #"""
    model = "gpt-5"
    [plugins."linear@openai-curated"]
    enabled = true
    [plugins."figma@openai-curated"]
    enabled = false
    [plugins."github@openai-curated"]
    enabled = true
    [mcp_servers.clobe]
    url = "https://api.clobe.ai/mcp"
    enabled_tools = ["get_my_context"]
    [mcp_servers.node_repl]
    command = "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl"
    args = []
    [mcp_servers.node_repl.env]
    TOKEN = "SECRET-7"
    [mcp_servers.computer-use]
    command = "./Codex Computer Use.app/Contents/MacOS/SkyComputerUseClient"
    args = ["mcp"]
    enabled = false
    [mcp_servers."docs.v2"]
    url = "https://docs.example.test/mcp?token=SECRET-8"
    """#

    private func makeExecutable() throws -> URL {
        let url = try temporaryDirectory().appending(path: "yardlet-mcp")
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        return url
    }
}

/// Discovery documents as the live servers sent them on 2026-10-16 (trimmed to the fields
/// discovery reads); everything else is 404.
final class RecordedMetadataServer: ConnectorHTTPTransport, @unchecked Sendable {
    private static let documents: [String: String] = [
        "https://mcp.slack.com/.well-known/oauth-protected-resource":
            #"{"resource":"https://mcp.slack.com","authorization_servers":["https://mcp.slack.com"],"scopes_supported":["chat:write","search:read.public"]}"#,
        "https://mcp.slack.com/.well-known/oauth-authorization-server":
            #"{"issuer":"https://mcp.slack.com","authorization_endpoint":"https://slack.com/oauth/v2_user/authorize","token_endpoint":"https://slack.com/api/oauth.v2.user.access","token_endpoint_auth_methods_supported":["client_secret_post"],"code_challenge_methods_supported":["S256"]}"#,
        "https://gmailmcp.googleapis.com/.well-known/oauth-protected-resource/mcp/v1":
            #"{"resource":"https://gmailmcp.googleapis.com/mcp/v1","authorization_servers":["https://accounts.google.com/"],"scopes_supported":["https://mail.google.com/","https://www.googleapis.com/auth/gmail.readonly"]}"#,
        "https://accounts.google.com/.well-known/oauth-authorization-server":
            #"{"issuer":"https://accounts.google.com","authorization_endpoint":"https://accounts.google.com/o/oauth2/v2/auth","token_endpoint":"https://oauth2.googleapis.com/token","token_endpoint_auth_methods_supported":["client_secret_post","client_secret_basic"]}"#,
        "https://api.githubcopilot.com/.well-known/oauth-protected-resource/mcp/":
            #"{"resource":"https://api.githubcopilot.com/mcp","authorization_servers":["https://github.com/login/oauth"]}"#,
        "https://github.com/.well-known/oauth-authorization-server/login/oauth":
            #"{"issuer":"https://github.com/login/oauth","authorization_endpoint":"https://github.com/login/oauth/authorize","token_endpoint":"https://github.com/login/oauth/access_token"}"#,
        "https://api.clobe.ai/.well-known/oauth-protected-resource":
            #"{"resource":"https://api.clobe.ai/mcp","authorization_servers":["https://api.clobe.ai"],"scopes_supported":["mcp"]}"#,
        "https://api.clobe.ai/.well-known/oauth-authorization-server":
            #"{"issuer":"https://api.clobe.ai","authorization_endpoint":"https://api.clobe.ai/oauth/authorize","token_endpoint":"https://api.clobe.ai/oauth/token","registration_endpoint":"https://api.clobe.ai/oauth/register","token_endpoint_auth_methods_supported":["none"]}"#
    ]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        guard request.httpMethod ?? "GET" == "GET", let body = Self.documents[url.absoluteString] else {
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Content-Type": "application/json"])!)
    }
}
