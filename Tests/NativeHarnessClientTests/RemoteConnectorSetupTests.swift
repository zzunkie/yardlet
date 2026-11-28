import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote

@MainActor
final class RemoteConnectorSetupTests: XCTestCase {
    private let owner = "connection-one"

    private func center(server: FakeConnectorServer = FakeConnectorServer(), agent: FakeUserAgent = FakeUserAgent(),
                        credentials: InMemoryConnectorCredentialStore = InMemoryConnectorCredentialStore()) -> ConnectorCenter {
        ConnectorCenter(environment: .init(repository: InMemoryConnectorRepository(), credentials: credentials,
            http: server, userAgent: agent, sha256: MacOAuthUserAgent.sha256, clientVersion: "test"))
    }

    private func start(_ coordinator: RemoteConnectorSetupCoordinator, center: ConnectorCenter,
                       draft: RemoteConnectorDraft? = nil) throws -> String {
        let id = UUID().uuidString
        _ = try coordinator.handle(.init(action: .start, operationID: id,
            draft: draft ?? .init(name: "Example", serverURL: FakeConnectorServer.mcpURL.absoluteString)),
            owner: owner, center: center).get()
        return id
    }

    private func poll(_ coordinator: RemoteConnectorSetupCoordinator, id: String,
                      center: ConnectorCenter) throws -> RemoteConnectorSetupState {
        try coordinator.handle(.init(action: .poll, operationID: id), owner: owner, center: center).get()
    }

    private func step(_ kind: RemoteConnectorSetupStep.Kind, coordinator: RemoteConnectorSetupCoordinator,
                      id: String, center: ConnectorCenter) async throws -> RemoteConnectorSetupStep {
        try await waitUntil {
            let state = try self.poll(coordinator, id: id, center: center)
            return state.step?.kind == kind || state.status != .working
        }
        let state = try poll(coordinator, id: id, center: center)
        XCTAssertEqual(state.status, .working, state.message ?? "")
        let step = try XCTUnwrap(state.step)
        XCTAssertEqual(step.kind, kind)
        return step
    }

    private func answer(_ step: RemoteConnectorSetupStep, value: String? = nil, accepted: Bool? = nil,
                        coordinator: RemoteConnectorSetupCoordinator, id: String, center: ConnectorCenter) throws {
        _ = try coordinator.handle(.init(action: .answer, operationID: id,
            reply: .init(stepID: step.id, value: value, accepted: accepted)), owner: owner, center: center).get()
    }

    private func completeOAuth(_ coordinator: RemoteConnectorSetupCoordinator, id: String,
                               center: ConnectorCenter) async throws -> (RemoteConnectorSetupState, URL) {
        let listen = try await step(.listen, coordinator: coordinator, id: id, center: center)
        let redirect = "http://127.0.0.1:\(listen.port ?? 54321)/callback"
        try answer(listen, value: redirect, coordinator: coordinator, id: id, center: center)
        let open = try await step(.open, coordinator: coordinator, id: id, center: center)
        let url = try XCTUnwrap(open.url.flatMap(URL.init(string:)))
        try answer(open, accepted: true, coordinator: coordinator, id: id, center: center)
        let callback = try await step(.callback, coordinator: coordinator, id: id, center: center)
        let state = try XCTUnwrap(callback.state)
        try answer(callback, value: "\(redirect)?code=code-1&state=\(state)", coordinator: coordinator, id: id, center: center)
        try await waitUntil { try self.poll(coordinator, id: id, center: center).status != .working }
        return (try poll(coordinator, id: id, center: center), url)
    }

    func testOAuthUsesClientLoopbackWhileTokensAndPKCERemainOnHost() async throws {
        let server = FakeConnectorServer()
        let credentials = InMemoryConnectorCredentialStore()
        let localAgent = FakeUserAgent()
        let center = center(server: server, agent: localAgent, credentials: credentials)
        let coordinator = RemoteConnectorSetupCoordinator()
        let id = try start(coordinator, center: center)
        let listen = try await step(.listen, coordinator: coordinator, id: id, center: center)
        XCTAssertNil(listen.port)
        try answer(listen, value: "http://127.0.0.1:54321/callback", coordinator: coordinator, id: id, center: center)
        let open = try await step(.open, coordinator: coordinator, id: id, center: center)
        let url = try XCTUnwrap(open.url.flatMap(URL.init(string:)))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "redirect_uri" }?.value, "http://127.0.0.1:54321/callback")
        XCTAssertNotNil(query.first { $0.name == "code_challenge" }?.value)
        XCTAssertNil(query.first { $0.name == "code_verifier" })
        XCTAssertTrue(localAgent.opened.isEmpty)
        try answer(open, accepted: true, coordinator: coordinator, id: id, center: center)
        let callback = try await step(.callback, coordinator: coordinator, id: id, center: center)
        let state = try XCTUnwrap(callback.state)
        for invalid in ["http://127.0.0.1:54322/callback?code=code-1&state=\(state)",
                        "http://127.0.0.1:54321/callback?code=code-1&state=wrong",
                        "http://127.0.0.1:54321/other?code=code-1&state=\(state)"] {
            XCTAssertThrowsError(try answer(callback, value: invalid, coordinator: coordinator, id: id, center: center))
        }
        try answer(callback, value: "http://127.0.0.1:54321/callback?code=code-1&state=\(state)",
                   coordinator: coordinator, id: id, center: center)
        try await waitUntil { try self.poll(coordinator, id: id, center: center).status != .working }
        let result = try poll(coordinator, id: id, center: center)
        XCTAssertEqual(result.status, .connected)
        XCTAssertNil(result.step)
        let recordID = try XCTUnwrap(result.connectorID.flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(try credentials.load(recordID)?.accessToken, "access-1")
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(encoded.contains("access-1"))
        XCTAssertFalse(encoded.contains("refresh-1"))
        let token = try XCTUnwrap(server.requests.first { $0.url?.path() == "/token" })
        XCTAssertFalse(FakeConnectorServer.form(token)["code_verifier", default: ""].isEmpty)
        XCTAssertEqual(FakeConnectorServer.form(token)["redirect_uri"], "http://127.0.0.1:54321/callback")
    }

    func testOwnerBindingOneActiveSetupAndCancellation() async throws {
        let center = center()
        let coordinator = RemoteConnectorSetupCoordinator()
        let id = try start(coordinator, center: center)
        let listen = try await step(.listen, coordinator: coordinator, id: id, center: center)
        XCTAssertThrowsError(try coordinator.handle(.init(action: .poll, operationID: id),
            owner: "other-connection", center: center).get())
        XCTAssertThrowsError(try coordinator.handle(.init(action: .answer, operationID: id,
            reply: .init(stepID: listen.id, value: "http://127.0.0.1:54321/callback")),
            owner: "other-connection", center: center).get())
        XCTAssertThrowsError(try start(coordinator, center: center))
        XCTAssertThrowsError(try coordinator.handle(.init(action: .answer, operationID: id,
            reply: .init(stepID: UUID().uuidString, accepted: true)), owner: owner, center: center).get())
        let connector = try XCTUnwrap(try poll(coordinator, id: id, center: center).connectorID.flatMap(UUID.init(uuidString:)))
        let cancelled = try coordinator.handle(.init(action: .cancel, operationID: id), owner: owner, center: center).get()
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertNil(cancelled.step)
        XCTAssertNil(cancelled.connectorID)
        try await waitUntil { !center.isConnecting(connector) && center.record(connector) == nil }
        XCTAssertThrowsError(try answer(listen, value: "http://127.0.0.1:54321/callback",
                                       coordinator: coordinator, id: id, center: center))
        let next = try start(coordinator, center: center)
        _ = try await step(.listen, coordinator: coordinator, id: next, center: center)
        coordinator.cancel(owner: owner)
        XCTAssertThrowsError(try poll(coordinator, id: next, center: center))
        try await waitUntil { center.connectors.allSatisfy { !center.isConnecting($0.id) } }
    }

    func testRegisteredClientRequiresItsFixedLoopbackPort() async throws {
        let center = center()
        let coordinator = RemoteConnectorSetupCoordinator()
        let id = try start(coordinator, center: center, draft: .init(name: "Own app",
            serverURL: FakeConnectorServer.mcpURL.absoluteString, clientID: "my-client", clientSecret: "my-secret"))
        let listen = try await step(.listen, coordinator: coordinator, id: id, center: center)
        XCTAssertEqual(listen.port, ConnectorOAuth.registeredClientRedirectPort)
        for value in ["http://127.0.0.1:54321/callback", "https://example.test/callback",
                      "http://127.0.0.1:47823/callback?extra=1", "http://user@127.0.0.1:47823/callback"] {
            XCTAssertThrowsError(try answer(listen, value: value, coordinator: coordinator, id: id, center: center))
        }
        try answer(listen, value: "http://127.0.0.1:47823/callback", coordinator: coordinator, id: id, center: center)
        _ = try await step(.open, coordinator: coordinator, id: id, center: center)
        coordinator.cancel(owner: owner)
    }

    func testRemoteSetupDoesNotReplaceLocalSignIns() async throws {
        let localAgent = FakeUserAgent()
        let center = center(agent: localAgent)
        let coordinator = RemoteConnectorSetupCoordinator()
        let id = try start(coordinator, center: center)
        let listen = try await step(.listen, coordinator: coordinator, id: id, center: center)
        let local = try await center.add(name: "Local", serverURL: FakeConnectorServer.mcpURL)
        center.connect(local.id)
        await center.waitForConnection(local.id)
        XCTAssertEqual(center.record(local.id)?.status, .connected)
        XCTAssertEqual(localAgent.opened.count, 1)
        XCTAssertEqual(try poll(coordinator, id: id, center: center).step?.id, listen.id)
        coordinator.cancel(owner: owner)
    }

    func testTokenSetupSavesCredentialOnlyOnHost() async throws {
        let server = FakeConnectorServer()
        server.validTokens = ["secret-token"]
        let credentials = InMemoryConnectorCredentialStore()
        let localAgent = FakeUserAgent()
        let center = center(server: server, agent: localAgent, credentials: credentials)
        let coordinator = RemoteConnectorSetupCoordinator()
        let id = try start(coordinator, center: center, draft: .init(name: "Token server",
            serverURL: FakeConnectorServer.mcpURL.absoluteString, token: "secret-token"))
        try await waitUntil { try self.poll(coordinator, id: id, center: center).status != .working }
        let result = try poll(coordinator, id: id, center: center)
        XCTAssertEqual(result.status, .connected)
        let connector = try XCTUnwrap(result.connectorID.flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(try credentials.load(connector)?.accessToken, "secret-token")
        XCTAssertTrue(localAgent.opened.isEmpty)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("secret-token"))
    }

    func testDeclineAndDeadlineClearPendingBrowserWork() async throws {
        let center = center()
        let coordinator = RemoteConnectorSetupCoordinator()
        let id = try start(coordinator, center: center)
        let listen = try await step(.listen, coordinator: coordinator, id: id, center: center)
        try answer(listen, accepted: false, coordinator: coordinator, id: id, center: center)
        try await waitUntil { try self.poll(coordinator, id: id, center: center).status == .cancelled }
        let short = RemoteConnectorSetupCoordinator(timeout: .milliseconds(40))
        let expiring = try start(short, center: center)
        try await waitUntil { try self.poll(short, id: expiring, center: center).status == .failed }
        XCTAssertNil(try poll(short, id: expiring, center: center).step)
        try await waitUntil { center.connectors.allSatisfy { !center.isConnecting($0.id) } }
    }

    func testRejectsLocalOnlyPresetsAndMalformedAddressesBeforeAdding() throws {
        let center = center()
        let coordinator = RemoteConnectorSetupCoordinator()
        for draft in [RemoteConnectorDraft(presetID: "apple-calendar"), .init(presetID: "xcode"),
                      .init(presetID: "imap-mail"), .init(presetID: "not-a-preset"),
                      .init(serverURL: "file:///tmp/connector"), .init(serverURL: "http://example.test/mcp"),
                      .init(serverURL: "https://user:secret@example.test/mcp"),
                      .init(serverURL: FakeConnectorServer.mcpURL.absoluteString, token: "a", clientID: "b")] {
            XCTAssertThrowsError(try start(coordinator, center: center, draft: draft))
        }
        XCTAssertTrue(center.connectors.isEmpty)
    }

    func testGoogleAccountSetupKeepsClientOnAccountAndResolvesDuplicateAccount() async throws {
        let google = FakeGoogle()
        let localAgent = FakeUserAgent()
        var existing = ConnectorRecord(name: "Gmail", slug: "gmail_work", serverURL: FakeGoogle.endpoints.gmailAPI,
            authorization: .oauth, status: .signInRequired, presetID: "gmail", localService: .gmail,
            account: "work@example.test")
        existing.googleOAuthClientID = "old-client.apps.googleusercontent.com"
        let storedClient = ConnectorCredential.client(id: try XCTUnwrap(existing.googleOAuthClientID), secret: nil)
            .bound(to: existing.credentialDestination)
        let credentials = InMemoryConnectorCredentialStore([existing.id: storedClient])
        var environment = ConnectorCenter.Environment(repository: InMemoryConnectorRepository(records: [existing]),
            credentials: credentials,
            http: google, userAgent: localAgent, sha256: MacOAuthUserAgent.sha256, clientVersion: "test")
        environment.google = FakeGoogle.endpoints
        environment.googleWorkspaceTransport = google
        let center = ConnectorCenter(environment: environment)
        let coordinator = RemoteConnectorSetupCoordinator()
        // A client saved on an existing account cannot authorize a new account.
        let missing = try start(coordinator, center: center, draft: .init(presetID: "gmail", clientID: "  "))
        try await waitUntil { try self.poll(coordinator, id: missing, center: center).status == .failed }
        XCTAssertNil(try poll(coordinator, id: missing, center: center).connectorID)
        XCTAssertEqual(center.googleAccounts.map(\.id), [existing.id])
        XCTAssertTrue(google.requests.isEmpty)

        let id = try start(coordinator, center: center, draft: .init(presetID: "gmail",
            clientID: FakeGoogle.clientID, clientSecret: FakeGoogle.clientSecret))
        let (result, opened) = try await completeOAuth(coordinator, id: id, center: center)
        XCTAssertEqual(result.status, .connected, result.message ?? "")
        let recordID = try XCTUnwrap(result.connectorID.flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(center.record(recordID)?.account, "person@example.test")
        XCTAssertEqual(center.record(recordID)?.localService, .gmail)
        XCTAssertEqual(opened.host(), "accounts.google.test")
        XCTAssertTrue(localAgent.opened.isEmpty)
        XCTAssertNil(center.googleAppClientID)
        XCTAssertEqual(center.record(recordID)?.googleOAuthClientID, FakeGoogle.clientID)
        XCTAssertEqual(try credentials.load(recordID)?.clientID, FakeGoogle.clientID)
        let firstForm = FakeConnectorServer.form(try XCTUnwrap(google.requests.first { $0.url?.path() == "/token" }))
        XCTAssertEqual(firstForm["redirect_uri"], "http://127.0.0.1:47823/callback")
        XCTAssertEqual(firstForm["client_secret"], FakeGoogle.clientSecret)

        // Signing in to the same account again merges it, so the operation must name the surviving connector.
        let duplicate = try start(coordinator, center: center, draft: .init(presetID: "gmail", clientID: FakeGoogle.clientID,
                                                                          clientSecret: FakeGoogle.clientSecret))
        let (merged, _) = try await completeOAuth(coordinator, id: duplicate, center: center)
        XCTAssertEqual(merged.status, .connected, merged.message ?? "")
        XCTAssertEqual(merged.connectorID, recordID.uuidString)
        XCTAssertEqual(center.googleAccounts.count, 2)
        XCTAssertEqual(try credentials.load(existing.id), storedClient)
        XCTAssertEqual(center.record(existing.id)?.googleOAuthClientID, existing.googleOAuthClientID)
        let personal = try XCTUnwrap(try credentials.load(recordID))

        // Change the other account's client in place through remote setup.
        google.signInAs = try XCTUnwrap(existing.account)
        let editID = UUID().uuidString
        _ = try coordinator.handle(.init(action: .start, operationID: editID,
            draft: .init(clientID: FakeGoogle.secondClientID, clientSecret: FakeGoogle.clientSecret), connectorID: existing.id.uuidString),
            owner: owner, center: center).get()
        let (edited, _) = try await completeOAuth(coordinator, id: editID, center: center)
        XCTAssertEqual(edited.status, .connected, edited.message ?? "")
        XCTAssertEqual(edited.connectorID, existing.id.uuidString)
        XCTAssertEqual(center.record(existing.id)?.account, existing.account)
        XCTAssertEqual(center.record(existing.id)?.googleOAuthClientID, FakeGoogle.secondClientID)
        XCTAssertEqual(try credentials.load(existing.id)?.clientID, FakeGoogle.secondClientID)
        XCTAssertEqual(try credentials.load(recordID), personal)
        XCTAssertNil(center.googleAppClientID)
        XCTAssertTrue(google.requests.contains { $0.url?.host() == "gmailmcp.googleapis.com" && $0.url?.path() == "/mcp/v1" })
    }

    func testMicrosoftAccountSetupUsesConfiguredHostApp() async throws {
        let microsoft = FakeMicrosoft()
        let localAgent = FakeUserAgent()
        let credentials = InMemoryConnectorCredentialStore()
        var environment = ConnectorCenter.Environment(repository: InMemoryConnectorRepository(), credentials: credentials,
            http: microsoft, userAgent: localAgent, sha256: MacOAuthUserAgent.sha256, clientVersion: "test")
        environment.microsoft = FakeMicrosoft.endpoints
        environment.microsoftBuiltInApp = .init(clientID: FakeMicrosoft.clientID)
        let center = ConnectorCenter(environment: environment)
        let coordinator = RemoteConnectorSetupCoordinator()
        let id = try start(coordinator, center: center, draft: .init(presetID: "outlook-mail"))
        let (result, opened) = try await completeOAuth(coordinator, id: id, center: center)
        XCTAssertEqual(result.status, .connected, result.message ?? "")
        let recordID = try XCTUnwrap(result.connectorID.flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(center.record(recordID)?.account, "person@contoso.test")
        XCTAssertEqual(center.record(recordID)?.localService, .outlookMail)
        XCTAssertEqual(opened.host(), "login.microsoft.test")
        XCTAssertTrue(localAgent.opened.isEmpty)
        XCTAssertNotNil(try credentials.load(recordID)?.refreshToken)
        XCTAssertEqual(microsoft.tokenForms.first?["redirect_uri"], "http://127.0.0.1:47823/callback")
        XCTAssertNil(microsoft.tokenForms.first?["client_secret"])
    }

    func testCancelledKeychainSaveLeavesNoCredentialOrConnector() async throws {
        let credentials = RemoteSetupBlockingCredentials()
        defer { credentials.release() }
        let server = FakeConnectorServer()
        server.validTokens = ["secret-token"]
        let center = ConnectorCenter(environment: .init(repository: InMemoryConnectorRepository(), credentials: credentials,
            http: server, userAgent: FakeUserAgent(), sha256: MacOAuthUserAgent.sha256, clientVersion: "test"))
        let coordinator = RemoteConnectorSetupCoordinator()
        let id = try start(coordinator, center: center, draft: .init(serverURL: FakeConnectorServer.mcpURL.absoluteString,
                                                                  token: "secret-token"))
        try await waitUntil { credentials.blockedID != nil }
        let credentialID = try XCTUnwrap(credentials.blockedID)
        _ = try coordinator.handle(.init(action: .cancel, operationID: id), owner: owner, center: center).get()
        credentials.release()
        try await waitUntil {
            guard credentials.saved else { return false }
            return try credentials.load(credentialID) == nil && center.connectors.isEmpty
        }
        XCTAssertNil(try poll(coordinator, id: id, center: center).connectorID)
        XCTAssertTrue(server.requests.isEmpty, "Cancelled setup must not start connecting after the keychain answers")
    }

    func testBusyRemoteSetupDoesNotCancelALocalConnectionItDidNotStart() async throws {
        let agent = FakeUserAgent(answers: false)
        let center = center(agent: agent)
        let record = try await center.add(name: "Local", serverURL: FakeConnectorServer.mcpURL)
        let coordinator = RemoteConnectorSetupCoordinator()
        let id = UUID().uuidString
        _ = try coordinator.handle(.init(action: .start, operationID: id, connectorID: record.id.uuidString),
                                   owner: owner, center: center).get()
        // This happens before the coordinator's task is scheduled on the actor.
        center.connect(record.id)
        try await waitUntil { try self.poll(coordinator, id: id, center: center).status == .failed }
        XCTAssertTrue(center.isConnecting(record.id))
        center.cancelConnect(record.id)
        await center.waitForConnection(record.id)
    }

    func testFailedTokenCanBeCorrectedWithoutAnotherConnector() async throws {
        let server = FakeConnectorServer()
        server.validTokens = ["correct"]
        let credentials = InMemoryConnectorCredentialStore()
        let center = center(server: server, credentials: credentials)
        let coordinator = RemoteConnectorSetupCoordinator()
        let first = try start(coordinator, center: center, draft: .init(serverURL: FakeConnectorServer.mcpURL.absoluteString,
                                                                     token: "wrong", tokenHeader: "Authorization"))
        try await waitUntil { try self.poll(coordinator, id: first, center: center).status == .failed }
        let connector = try XCTUnwrap(try poll(coordinator, id: first, center: center).connectorID)
        let retry = UUID().uuidString
        _ = try coordinator.handle(.init(action: .start, operationID: retry, draft: .init(token: "Bearer correct"),
                                         connectorID: connector), owner: owner, center: center).get()
        try await waitUntil { try self.poll(coordinator, id: retry, center: center).status != .working }
        XCTAssertEqual(try poll(coordinator, id: retry, center: center).status, .connected)
        XCTAssertEqual(center.connectors.count, 1)
        XCTAssertEqual(center.connectors.first?.tokenHeader, "Authorization", "Omitting a header preserves the saved header")
        XCTAssertEqual(try credentials.load(try XCTUnwrap(UUID(uuidString: connector)))?.accessToken, "Bearer correct")
    }

    func testProviderEchoedSecretNeverEntersSharedConnectorState() async throws {
        let server = RemoteSetupEchoServer()
        let center = ConnectorCenter(environment: .init(repository: InMemoryConnectorRepository(),
            credentials: InMemoryConnectorCredentialStore(), http: server, userAgent: FakeUserAgent(),
            sha256: MacOAuthUserAgent.sha256, clientVersion: "test"))
        let coordinator = RemoteConnectorSetupCoordinator()
        let id = try start(coordinator, center: center, draft: .init(serverURL: FakeConnectorServer.mcpURL.absoluteString,
            clientID: "client", clientSecret: "swordfish"))
        let (result, _) = try await completeOAuth(coordinator, id: id, center: center)
        XCTAssertEqual(result.status, .failed)
        let record = try XCTUnwrap(center.connectors.first)
        let snapshot = AppModelRemoteBridge.remoteConnector(record, in: center)
        let snapshotText = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(snapshotText.contains("swordfish"))
        XCTAssertFalse(result.message?.contains("swordfish") == true)
        XCTAssertFalse(center.failures[record.id]?.contains("swordfish") == true)
    }
}

private final class RemoteSetupBlockingCredentials: ConnectorCredentialStoring, @unchecked Sendable {
    private let values = InMemoryConnectorCredentialStore()
    private let condition = NSCondition()
    private var waiting: UUID?
    private var released = false
    private var didSave = false
    var blockedID: UUID? { condition.withLock { waiting } }
    var saved: Bool { condition.withLock { didSave } }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
    func load(_ id: UUID) throws -> ConnectorCredential? { try values.load(id) }
    func save(_ credential: ConnectorCredential, for id: UUID) throws {
        condition.lock()
        waiting = id
        while !released { condition.wait() }
        condition.unlock()
        try values.save(credential, for: id)
        condition.withLock { didSave = true }
    }
    func delete(_ id: UUID) throws { try values.delete(id) }
}

private struct RemoteSetupEchoServer: ConnectorHTTPTransport {
    let server = FakeConnectorServer()
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path() == "/token" {
            return (Data(#"{"error":"invalid_grant","error_description":"swordfish"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!)
        }
        return try await server.send(request)
    }
}
