import Foundation
import XCTest
@testable import NativeHarnessClient

/// The Google OAuth app a build carries (docs/CONNECTORS.md, "Google"): read from the bundle's
/// Info.plist, used to sign in when the person saved no app of their own, set aside by one they
/// save, and signing in for Gmail, Calendar, and Drive only. Google is a local fake here: no
/// request leaves the machine and no real account signs in.
@MainActor
final class GoogleBuiltInAppTests: XCTestCase {
    private static let otherClientID = "999-builtin.apps.googleusercontent.com"

    private func makeCenter(
        builtIn: GoogleOAuth.BuiltInApp?,
        google: FakeGoogle = FakeGoogle(),
        agent: FakeUserAgent = FakeUserAgent(),
        credentials: InMemoryConnectorCredentialStore = InMemoryConnectorCredentialStore(),
        records: [ConnectorRecord] = []
    ) -> ConnectorCenter {
        var environment = ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(records: records), credentials: credentials, http: google, userAgent: agent,
            sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9")
        environment.google = FakeGoogle.endpoints
        environment.googleBuiltInApp = builtIn
        return ConnectorCenter(environment: environment)
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

    /// With no app of the person's own, an account signs in with the built-in one, and its sign-in
    /// keeps that client for later refreshes.
    func testAnAccountSignsInWithTheBuiltInApp() async throws {
        let google = FakeGoogle()
        let agent = FakeUserAgent()
        let credentials = InMemoryConnectorCredentialStore()
        let center = makeCenter(builtIn: .init(clientID: FakeGoogle.clientID, clientSecret: FakeGoogle.clientSecret),
                                google: google, agent: agent, credentials: credentials)
        XCTAssertNil(center.googleAppClientID)
        XCTAssertTrue(center.canSignInWithGoogle)

        let record = try XCTUnwrap(center.addGmailAccount())
        await center.waitForConnection(record.id)
        XCTAssertNil(center.failures[record.id])
        XCTAssertEqual(center.record(record.id)?.status, .connected)

        let opened = try XCTUnwrap(agent.opened.first)
        let query = URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "client_id" }?.value, FakeGoogle.clientID)
        let form = FakeConnectorServer.form(try XCTUnwrap(google.requests.first { $0.url?.path() == "/token" }))
        XCTAssertEqual(form["client_secret"], FakeGoogle.clientSecret)
        XCTAssertEqual(try credentials.load(record.id)?.clientID, FakeGoogle.clientID)
        XCTAssertNil(try credentials.load(GoogleOAuth.appCredentialID), "Nothing is saved as the person's own app")
    }

    /// An app the person saves signs in instead of the built-in one; removing it brings the built-in
    /// one back.
    func testAnAppOfYourOwnTakesPrecedence() async throws {
        let agent = FakeUserAgent()
        let center = makeCenter(builtIn: .init(clientID: Self.otherClientID, clientSecret: "GOCSPX-builtin"), agent: agent)
        try await center.saveGoogleApp(clientID: FakeGoogle.clientID, secret: FakeGoogle.clientSecret)

        let record = try XCTUnwrap(center.addGmailAccount())
        await center.waitForConnection(record.id)
        XCTAssertNil(center.failures[record.id], "The fake Google takes only the person's app")
        let query = URLComponents(url: try XCTUnwrap(agent.opened.first), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "client_id" }?.value, FakeGoogle.clientID)

        try await center.removeGoogleApp()
        XCTAssertNil(center.googleAppClientID)
        XCTAssertTrue(center.canSignInWithGoogle)
    }

    /// Yardlet's own app asks Google for these six scopes and no others, even for an account that
    /// wants Analytics or Ads and when Google lists their scopes as granted from before
    /// (`include_granted_scopes`): those services wait for an app of the person's own, without
    /// opening a sign-in or offering tools. An app saved under Yardlet's client ID is Yardlet's.
    func testTheBuiltInAppSignsInForGmailCalendarAndDriveOnly() async throws {
        let auth = "https://www.googleapis.com/auth/"
        XCTAssertEqual(GoogleOAuth.scope(for: GoogleOAuth.BuiltInApp.services),
                       ["gmail.modify", "calendar.calendarlist.readonly", "calendar.events", "calendar.events.freebusy",
                        "drive.readonly", "drive.file"].map { auth + $0 }.joined(separator: " "))

        let google = FakeGoogle()
        google.grantedScope = GoogleOAuth.scope(for: LocalConnectorService.google)
        let agent = FakeUserAgent()
        let center = makeCenter(builtIn: .init(clientID: FakeGoogle.clientID, clientSecret: FakeGoogle.clientSecret),
                                google: google, agent: agent)
        XCTAssertEqual(center.signInServices(.google), GoogleOAuth.BuiltInApp.services)

        let account = try XCTUnwrap(center.addAccount(services: [.gmail, .googleAnalytics, .googleAds]))
        await center.waitForConnection(account.id)
        let scope = URLComponents(url: try XCTUnwrap(agent.opened.first), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "scope" }?.value
        XCTAssertEqual(scope, auth + "gmail.modify")
        XCTAssertEqual(center.googleAccounts.first?.services.map(\.localService), [.gmail])

        await center.setService(.googleAnalytics, on: true, account: account.id)
        await center.waitForConnection(account.id)
        XCTAssertEqual(agent.opened.count, 1, "No sign-in opens for a service Yardlet's app does not sign in for")
        let analytics = try XCTUnwrap(center.googleAccounts.first?.record(.googleAnalytics))
        XCTAssertEqual(analytics.status, .signInRequired)
        XCTAssertEqual(center.failures[analytics.id], GoogleSignInError.needsOwnApp([.googleAnalytics]).errorDescription)
        XCTAssertEqual(center.googleAccounts.first?.record(.gmail)?.status, .connected)
        let tools = await center.connectorTools(for: ConnectorToolContext()).compactMap { $0["name"]?.stringValue }
        XCTAssertTrue(tools.contains { $0.hasPrefix("gmail_") }, "\(tools)")
        XCTAssertFalse(tools.contains { $0.hasPrefix("analytics_") }, "\(tools)")

        try await center.saveGoogleApp(clientID: FakeGoogle.clientID, secret: FakeGoogle.clientSecret)
        XCTAssertEqual(center.signInServices(.google), GoogleOAuth.BuiltInApp.services, "Yardlet's app saved as one's own")
    }

    /// An account that turned Analytics on with Yardlet's app, from before that app was kept to
    /// Gmail, Calendar, and Drive, keeps Gmail as it was; Analytics waits for an app of the
    /// person's own, and signing the account in again with one brings it back.
    func testAnalyticsTurnedOnWithTheBuiltInAppWaitsForAnAppOfYourOwn() async throws {
        let google = FakeGoogle()
        google.grantedScope = GoogleOAuth.scope(for: [.gmail, .googleAnalytics])
        let agent = FakeUserAgent()
        let credentials = InMemoryConnectorCredentialStore()
        let gmail = ConnectorRecord(name: "Gmail", slug: "gmail", serverURL: FakeGoogle.endpoints.gmailAPI, authorization: .oauth,
                                    status: .connected, toolsUpdatedAt: Date(), presetID: "gmail", scope: GmailToolCatalog.scope,
                                    localService: .gmail, account: "person@example.test")
        let analytics = ConnectorRecord(name: "Google Analytics", slug: "analytics",
                                        serverURL: FakeGoogle.endpoints.analyticsAdminAPI, authorization: .oauth,
                                        status: .connected, toolsUpdatedAt: Date(), presetID: "google-analytics",
                                        scope: GoogleAnalyticsToolCatalog.scopes.joined(separator: " "),
                                        localService: .googleAnalytics, account: "person@example.test", accountSignInID: gmail.id)
        try credentials.save(ConnectorCredential(kind: .oauth, accessToken: "access-old", refreshToken: "1//refresh-old",
                                                 expiresAt: .distantFuture, scope: google.grantedScope,
                                                 clientID: Self.otherClientID, clientSecret: "GOCSPX-builtin",
                                                 tokenEndpoint: FakeGoogle.endpoints.token), for: gmail.id)
        let center = makeCenter(builtIn: .init(clientID: Self.otherClientID, clientSecret: "GOCSPX-builtin"), google: google,
                                agent: agent, credentials: credentials, records: [gmail, analytics])

        try await waitUntil { center.record(analytics.id)?.status == .signInRequired }
        XCTAssertEqual(center.failures[analytics.id], GoogleSignInError.needsOwnApp([.googleAnalytics]).errorDescription)
        XCTAssertEqual(center.record(gmail.id)?.status, .connected)
        XCTAssertNil(center.failures[gmail.id])
        let tools = await center.connectorTools(for: ConnectorToolContext()).compactMap { $0["name"]?.stringValue }
        XCTAssertTrue(tools.contains { $0.hasPrefix("gmail_") }, "\(tools)")
        XCTAssertFalse(tools.contains { $0.hasPrefix("analytics_") }, "\(tools)")

        try await center.saveGoogleApp(clientID: FakeGoogle.clientID, secret: FakeGoogle.clientSecret)
        center.reconnect(gmail.id)
        await center.waitForConnection(gmail.id)
        let scope = URLComponents(url: try XCTUnwrap(agent.opened.first), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "scope" }?.value
        XCTAssertEqual(scope, GoogleOAuth.scope(for: [.gmail, .googleAnalytics]))
        XCTAssertEqual(center.record(analytics.id)?.status, .connected)
        XCTAssertNil(center.failures[analytics.id])
        XCTAssertEqual(try credentials.load(gmail.id)?.clientID, FakeGoogle.clientID)
    }

    func testWithoutEitherAppNoAccountCanSignIn() {
        XCTAssertFalse(makeCenter(builtIn: nil).canSignInWithGoogle)
    }

    /// The setup page's assistant: with the built-in app, signing in is the only step.
    func testTheAssistantWithTheBuiltInAppIsOnlyTheSignIn() {
        let builtIn = ConnectorSetupAssistant.google(opened: [], appSaved: false, connectedAccounts: 0, builtIn: true)
        XCTAssertEqual(builtIn.steps.map(\.id), [.googleSignIn])
        XCTAssertEqual(builtIn.current, .googleSignIn)
        XCTAssertTrue(ConnectorSetupAssistant.google(opened: [], appSaved: false, connectedAccounts: 1, builtIn: true).isComplete)
        XCTAssertEqual(ConnectorSetupAssistant.google(opened: [], appSaved: false, connectedAccounts: 0).steps.count, 7)
    }
}
