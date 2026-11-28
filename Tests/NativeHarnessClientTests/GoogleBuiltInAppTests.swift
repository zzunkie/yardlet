import Foundation
import XCTest
@testable import NativeHarnessClient

/// Account migrations and Calendar sign-in use an in-memory Keychain and a local Google stand-in.
@MainActor
final class GoogleBuiltInAppTests: XCTestCase {
    private static let otherClientID = "999-builtin.apps.googleusercontent.com"

    private func makeCenter(
        builtIn: GoogleOAuth.BuiltInApp?,
        google: any ConnectorHTTPTransport = FakeGoogle(),
        agent: FakeUserAgent = FakeUserAgent(),
        credentials: InMemoryConnectorCredentialStore = InMemoryConnectorCredentialStore(),
        records: [ConnectorRecord] = [],
        repository: InMemoryConnectorRepository? = nil
    ) -> ConnectorCenter {
        var environment = ConnectorCenter.Environment(
            repository: repository ?? InMemoryConnectorRepository(records: records), credentials: credentials, http: google, userAgent: agent,
            sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9")
        environment.googleWorkspaceTransport = google
        environment.google = FakeGoogleWorkspace.endpoints
        environment.googleBuiltInApp = builtIn
        var settings = environment.repository.loadSettings()
        let secrets = GoogleAccountCredentials(store: credentials.bound(to: ConnectorAccountProvider.google.credentialDestination),
                                               tokenEndpoint: environment.google.token, builtInClientID: builtIn?.clientID)
        settings.googleMigrations = secrets.migrations(in: settings, builtIn: builtIn)
        return ConnectorCenter(environment: environment, saved: settings)
    }

    func testTheBuiltInAppComesFromTheInfoDictionary() {
        XCTAssertEqual(GoogleOAuth.BuiltInApp.from(info: [
            "YardletGoogleOAuthClientID": " \(FakeGoogle.clientID) ",
            "YardletGoogleOAuthClientSecret": "\(FakeGoogle.clientSecret)\n"
        ]), GoogleOAuth.BuiltInApp(clientID: FakeGoogle.clientID, clientSecret: FakeGoogle.clientSecret))
        XCTAssertEqual(GoogleOAuth.BuiltInApp.from(info: ["YardletGoogleOAuthClientID": FakeGoogle.clientID]),
                       GoogleOAuth.BuiltInApp(clientID: FakeGoogle.clientID, clientSecret: nil))
        XCTAssertNil(GoogleOAuth.BuiltInApp.from(info: ["YardletGoogleOAuthClientSecret": FakeGoogle.clientSecret]))
        XCTAssertNil(GoogleOAuth.BuiltInApp.from(info: ["YardletGoogleOAuthClientID": "  "]))
        XCTAssertNil(GoogleOAuth.BuiltInApp.from(info: nil))
    }

    func testLegacyAccountsKeepIdentityTaskChoicesAndCalendarAccess() async throws {
        let credentials = InMemoryConnectorCredentialStore()
        var records = [ConnectorRecord]()
        for index in 0..<7 {
            let address = "account\(index)@example.test"
            let gmail = ConnectorRecord(name: "Gmail", slug: "gmail_\(index)", serverURL: FakeGoogle.endpoints.gmailAPI,
                                        authorization: .oauth, status: .connected, localService: .gmail, account: address)
            records.append(gmail)
            if index == 0 {
                records.append(ConnectorRecord(name: "Calendar", slug: "calendar", serverURL: FakeGoogleWorkspace.endpoints.calendarAPI,
                                               authorization: .oauth, status: .connected, localService: .googleCalendar,
                                               account: address, accountSignInID: gmail.id))
            }
            try credentials.save(ConnectorCredential(kind: .oauth, accessToken: "access-\(index)", refreshToken: "refresh-\(index)",
                                                      expiresAt: .distantFuture, scope: GoogleOAuth.calendarUIScope,
                                                      clientID: index.isMultiple(of: 2) ? nil : FakeGoogle.clientID), for: gmail.id)
        }
        let choices = [UUID(): Set(records.map(\.id))]
        let repository = InMemoryConnectorRepository(records: records, taskChoices: choices, googleAppClientID: FakeGoogle.clientID)
        let builtIn = GoogleOAuth.BuiltInApp(clientID: FakeGoogle.clientID, clientSecret: FakeGoogle.clientSecret)
        let center = makeCenter(builtIn: builtIn, credentials: credentials, repository: repository)
        XCTAssertEqual(center.googleAccounts.count, 7)
        XCTAssertNil(repository.googleAppClientID)
        XCTAssertEqual(center.offInTasks, choices)
        for before in records {
            let after = try XCTUnwrap(center.record(before.id))
            XCTAssertEqual(after.account, before.account)
            XCTAssertEqual(after.credentialID, before.credentialID)
            XCTAssertEqual(after.status, .signInRequired)
            XCTAssertEqual(after.hasGoogleUISignIn, before.credentialID == records[0].id)
            let stored = try XCTUnwrap(credentials.load(after.credentialID))
            XCTAssertTrue(stored.accessToken.isEmpty)
            XCTAssertNil(stored.refreshToken)
        }
        let restored = try XCTUnwrap(credentials.load(records[0].id))
        XCTAssertEqual(restored.uiAccessToken, "access-0")
        XCTAssertEqual(restored.uiRefreshToken, "refresh-0")
        XCTAssertEqual(restored.uiClientID, FakeGoogle.clientID)
        XCTAssertEqual(restored.uiGrantedScopes, GoogleOAuth.calendarUIScope)
        XCTAssertEqual(center.calendarAccounts().count, 1)
        let reopened = makeCenter(builtIn: builtIn, credentials: credentials, repository: repository)
        XCTAssertEqual(reopened.connectors, center.connectors)

        // Setting up one migrated account must leave the other six on the setup path.
        try await reopened.saveGoogleClient(account: records[0].id, clientID: Self.otherClientID, secret: nil)
        for record in reopened.agentConnectors {
            XCTAssertEqual(reopened.needsAccountApp(for: record), record.credentialID != records[0].id)
        }
        try await reopened.saveGoogleApp(clientID: Self.otherClientID, secret: nil)
        XCTAssertTrue(reopened.agentConnectors.allSatisfy { !reopened.needsAccountApp(for: $0) })
    }

    func testRestartAfterKeychainMigrationRecognizesBuiltInCalendarWithSharedAppConfigured() throws {
        let credentials = InMemoryConnectorCredentialStore()
        let row = ConnectorRecord(name: "Calendar", slug: "calendar", serverURL: FakeGoogleWorkspace.endpoints.calendarAPI,
                                  status: .connected, localService: .googleCalendar, account: "person@example.test")
        var stored = ConnectorCredential(kind: .client, accessToken: "")
        stored.uiClientID = FakeGoogle.clientID
        stored.uiAccessToken = "calendar"
        stored.uiGrantedScopes = GoogleOAuth.calendarUIScope
        try credentials.save(stored, for: row.id)
        let repository = InMemoryConnectorRepository(records: [row], googleAppClientID: Self.otherClientID)
        let center = makeCenter(builtIn: .init(clientID: FakeGoogle.clientID, clientSecret: nil), credentials: credentials,
                                repository: repository)
        XCTAssertEqual(center.record(row.id)?.status, .signInRequired)
        XCTAssertEqual(center.record(row.id)?.hasGoogleUISignIn, true)
        XCTAssertEqual(try credentials.load(row.id)?.uiAccessToken, stored.uiAccessToken)
    }

    func testRemovingAccountDuringKeychainSaveDoesNotBlockUIOrRestoreTheGrant() async throws {
        let credentials = PausedGoogleCredentialStore()
        let row = ConnectorRecord(name: "Gmail", slug: "gmail", serverURL: GoogleWorkspaceEndpoint.gmail.url,
                                  status: .connected, localService: .gmail, account: "person@example.test")
        var environment = ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(records: [row]), credentials: credentials, http: FakeGoogle(),
            userAgent: nil, sha256: MacOAuthUserAgent.sha256, clientVersion: "test")
        environment.googleBuiltInApp = .init(clientID: FakeGoogle.clientID, clientSecret: nil)
        let center = ConnectorCenter(environment: environment)
        let saving = Task { try await center.saveGoogleClient(account: row.id, clientID: Self.otherClientID, secret: nil) }
        defer { credentials.release() }
        try await waitUntil { credentials.started }
        center.removeAccount(row.id)
        credentials.release()
        do {
            try await saving.value
            XCTFail("A removed account cannot accept a new client")
        } catch is CancellationError {}
        await center.waitForPendingDeletions()
        XCTAssertNil(try credentials.values.load(row.id))
        XCTAssertNil(center.record(row.id))
    }

    func testMigratingCustomAppKeepsItsAgentGrantAndConnectedStatus() throws {
        let credentials = InMemoryConnectorCredentialStore()
        let row = ConnectorRecord(name: "Gmail", slug: "gmail", serverURL: FakeGoogle.endpoints.gmailAPI,
                                  authorization: .oauth, status: .connected, localService: .gmail, account: "person@example.test")
        let saved = ConnectorCredential(kind: .oauth, accessToken: "agent", refreshToken: "refresh", clientID: Self.otherClientID)
        try credentials.save(saved, for: row.id)
        let repository = InMemoryConnectorRepository(records: [row], googleAppClientID: Self.otherClientID)
        let center = makeCenter(builtIn: .init(clientID: FakeGoogle.clientID, clientSecret: nil), credentials: credentials,
                                repository: repository)
        XCTAssertEqual(center.record(row.id)?.status, .connected)
        XCTAssertEqual(try credentials.load(row.id)?.refreshToken, saved.refreshToken)
        XCTAssertFalse(try XCTUnwrap(center.record(row.id)).hasGoogleUISignIn)
    }

    func testLegacySharedStandardClientKeepsBothScreensAfterAgentClientChanges() async throws {
        let credentials = InMemoryConnectorCredentialStore()
        let gmail = ConnectorRecord(name: "Gmail", slug: "gmail", serverURL: FakeGoogleWorkspace.endpoints.gmailAPI,
                                    status: .connected, localService: .gmail, account: "person@example.test")
        let calendar = ConnectorRecord(name: "Calendar", slug: "calendar", serverURL: FakeGoogleWorkspace.endpoints.calendarAPI,
                                      status: .connected, localService: .googleCalendar, account: gmail.account, accountSignInID: gmail.id)
        let scopes = ([GoogleOAuth.mailboxScope] + LocalConnectorService.googleCalendar.scopes).joined(separator: " ")
        try credentials.save(.client(id: Self.otherClientID, secret: "shared"), for: GoogleOAuth.appCredentialID)
        try credentials.save(ConnectorCredential(kind: .oauth, accessToken: "standard", refreshToken: "legacy-refresh",
                                                  expiresAt: .distantFuture, scope: scopes), for: gmail.id)
        let repository = InMemoryConnectorRepository(records: [gmail, calendar], googleAppClientID: Self.otherClientID)
        let server = ScriptedRegistry { _ in (200, Data("{}".utf8)) }
        let center = makeCenter(builtIn: .init(clientID: FakeGoogle.clientID, clientSecret: nil), google: server,
                                credentials: credentials, repository: repository)
        let migrated = try XCTUnwrap(credentials.load(gmail.id))
        XCTAssertEqual(migrated.clientID, Self.otherClientID)
        XCTAssertEqual(migrated.tokenEndpoint, FakeGoogle.endpoints.token)
        XCTAssertEqual(migrated.tokenEndpointAuthMethod, "client_secret_post")
        XCTAssertEqual(migrated.uiClientID, Self.otherClientID)
        XCTAssertEqual(migrated.uiClientSecret, "shared")
        try await center.saveGoogleClient(account: gmail.id, clientID: "personal", secret: "personal-secret")
        await center.setService(.gmail, on: false, account: gmail.id)
        await center.setService(.googleCalendar, on: false, account: gmail.id)
        XCTAssertEqual(center.googleAccounts.first?.enabled, [])
        let mailbox = try XCTUnwrap(center.mailAccounts().first?.1)
        let calendarScreen = try XCTUnwrap(center.calendarAccounts().first?.1)
        _ = try await mailbox.folders()
        _ = try await calendarScreen.calendars()
        XCTAssertGreaterThan(server.requests.count, 1)
        XCTAssertTrue(server.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer standard" })
    }

    func testBuiltInAndFreshAgentGrantsNeverServeMailbox() throws {
        let credentials = InMemoryConnectorCredentialStore()
        var gmail = ConnectorRecord(name: "Gmail", slug: "gmail", serverURL: FakeGoogleWorkspace.endpoints.gmailAPI,
                                    status: .connected, localService: .gmail, account: "person@example.test")
        let builtIn = GoogleOAuth.BuiltInApp(clientID: FakeGoogle.clientID, clientSecret: nil)
        let scopes = GoogleOAuth.scope(for: [.gmail, .googleCalendar])
        let grant = ConnectorCredential(kind: .oauth, accessToken: "agent", refreshToken: "agent-refresh", scope: scopes,
                                        clientID: Self.otherClientID)
        var legacy = grant
        legacy.clientID = builtIn.clientID
        try credentials.save(legacy, for: gmail.id)
        XCTAssertTrue(makeCenter(builtIn: builtIn, credentials: credentials, records: [gmail]).mailAccounts().isEmpty)

        gmail.hasGoogleUISignIn = false
        try credentials.save(grant, for: gmail.id)
        let repository = InMemoryConnectorRepository(records: [gmail], googleAppClientID: Self.otherClientID)
        let current = makeCenter(builtIn: builtIn, credentials: credentials, repository: repository)
        XCTAssertTrue(current.mailAccounts().isEmpty)
        XCTAssertNil(try credentials.load(gmail.id)?.uiAccessToken)
    }

    func testCalendarOnlySignInPreservesMigratedMailboxGrant() async throws {
        let credentials = InMemoryConnectorCredentialStore()
        let gmail = ConnectorRecord(name: "Gmail", slug: "gmail", serverURL: FakeGoogleWorkspace.endpoints.gmailAPI,
                                    status: .connected, localService: .gmail, account: "person@example.test")
        let saved = ConnectorCredential(kind: .oauth, accessToken: "standard-mail", refreshToken: "mail-refresh",
                                        expiresAt: .distantFuture, scope: GoogleOAuth.mailboxScope, clientID: Self.otherClientID)
        try credentials.save(saved, for: gmail.id)
        let google = FakeGoogleWorkspace(granting: GoogleOAuth.calendarUIScope)
        let center = makeCenter(builtIn: .init(clientID: FakeGoogle.clientID, clientSecret: FakeGoogle.clientSecret), google: google,
                                credentials: credentials, records: [gmail])
        try await center.signInGoogleCalendarUI(account: gmail.id)
        let both = try XCTUnwrap(credentials.load(gmail.id))
        XCTAssertEqual(both.uiClientID, FakeGoogle.clientID)
        XCTAssertEqual(both.uiMailboxGrant?.clientID, Self.otherClientID)
        XCTAssertEqual(both.uiMailboxGrant?.refreshToken, saved.refreshToken)
        XCTAssertEqual(center.mailAccounts().count, 1)
        XCTAssertEqual(center.calendarAccounts().count, 1)
    }

    func testCalendarScreenRefreshAndReconnectLeaveAgentGrantAlone() async throws {
        let google = FakeGoogleWorkspace(granting: GoogleOAuth.calendarUIScope)
        let agent = FakeUserAgent()
        let credentials = InMemoryConnectorCredentialStore()
        let center = makeCenter(builtIn: .init(clientID: FakeGoogle.clientID, clientSecret: FakeGoogle.clientSecret),
                                google: google, agent: agent, credentials: credentials)
        try await center.signInGoogleCalendarUI()
        let account = try XCTUnwrap(center.googleAccounts.first)
        XCTAssertTrue(account.enabled.isEmpty)
        let transport = try XCTUnwrap(center.calendarAccounts().first?.1)
        let calendars = try await transport.calendars()
        XCTAssertFalse(calendars.isEmpty)
        let query = URLComponents(url: try XCTUnwrap(agent.opened.first), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "scope" }?.value, GoogleOAuth.calendarUIScope)
        XCTAssertNil(query?.first { $0.name == "include_granted_scopes" })
        google.google.revoke(try XCTUnwrap(account.address))
        do {
            _ = try await transport.calendars()
            XCTFail("Revocation must expire the Calendar sign-in")
        } catch OAuthAPISession.Failure.signInRequired {}
        XCTAssertFalse(try XCTUnwrap(center.googleAccounts.first?.record(.googleCalendar)).hasGoogleUISignIn)
        XCTAssertTrue(center.calendarAccounts().isEmpty)
        XCTAssertNil(try credentials.load(account.id)?.uiRefreshToken)
    }

    func testTurningOffLastChipKeepsOnlyClientAndCalendarUntilRemoval() async throws {
        let credentials = InMemoryConnectorCredentialStore()
        var row = ConnectorRecord(name: "Gmail", slug: "gmail", serverURL: FakeGoogle.endpoints.gmailAPI,
                                  authorization: .oauth, status: .connected, localService: .gmail, account: "person@example.test")
        row.googleOAuthClientID = Self.otherClientID
        row.hasGoogleUISignIn = true
        var saved = ConnectorCredential(kind: .oauth, accessToken: "agent", refreshToken: "agent-refresh",
                                        clientID: Self.otherClientID, clientSecret: "client-secret")
        saved.uiAccessToken = "calendar"
        saved.uiRefreshToken = "calendar-refresh"
        saved.uiClientID = FakeGoogle.clientID
        try credentials.save(saved, for: row.id)
        let center = makeCenter(builtIn: .init(clientID: FakeGoogle.clientID, clientSecret: nil),
                                credentials: credentials, records: [row])
        await center.setService(.gmail, on: false, account: row.id)
        XCTAssertEqual(center.googleAccounts.first?.enabled, [])
        XCTAssertTrue(center.agentConnectors.isEmpty)
        XCTAssertTrue(ConnectorSettingsState.ordered(center).isEmpty)
        let kept = try XCTUnwrap(credentials.load(row.id))
        XCTAssertEqual(kept.accessToken, "")
        XCTAssertNil(kept.refreshToken)
        XCTAssertEqual(kept.uiRefreshToken, saved.uiRefreshToken)
        XCTAssertEqual(kept.uiAccessToken, saved.uiAccessToken)
        XCTAssertEqual(kept.clientID, saved.clientID)
        XCTAssertEqual(kept.clientSecret, saved.clientSecret)
        try await center.saveGoogleClient(account: row.id, clientID: Self.otherClientID, secret: nil)
        XCTAssertEqual(center.record(row.id)?.status, .notConnected)
        center.removeAccount(row.id)
        await center.waitForPendingDeletions()
        XCTAssertNil(try credentials.load(row.id))
    }

    func testPersonalModeMismatchExplainsWhichAccountCanSignIn() throws {
        for query in ["error=client_user_mismatch", "error=access_denied&error_description=client_user_mismatch"] {
            let callback = try XCTUnwrap(URL(string: "http://localhost/?state=s&" + query))
            XCTAssertThrowsError(try ConnectorOAuth.code(fromCallback: callback, expectedState: "s")) { error in
                XCTAssertEqual(error.localizedDescription, ConnectorOAuthError.authorizationDenied(L10n.string("Only the Google Account that created this Personal Mode client can sign in. Open Personal Mode with the account you want to connect and create a client for it.")).localizedDescription)
            }
        }
    }
}

/// Pause a write long enough to remove its account while the system Keychain would be waiting.
private final class PausedGoogleCredentialStore: ConnectorCredentialStoring, @unchecked Sendable {
    let values = InMemoryConnectorCredentialStore()
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var saving = false
    var started: Bool { lock.withLock { saving } }
    func release() { gate.signal() }
    func load(_ id: UUID) throws -> ConnectorCredential? {
        XCTAssertFalse(Thread.isMainThread)
        return try values.load(id)
    }
    func save(_ credential: ConnectorCredential, for id: UUID) throws {
        XCTAssertFalse(Thread.isMainThread)
        lock.withLock { saving = true }
        if !Thread.isMainThread { gate.wait() }
        try values.save(credential, for: id)
    }
    func delete(_ id: UUID) throws {
        XCTAssertFalse(Thread.isMainThread)
        try values.delete(id)
    }
}
