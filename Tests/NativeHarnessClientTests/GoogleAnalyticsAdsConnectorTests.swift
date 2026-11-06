import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Google Analytics 4 and Google Ads on the account's one Google sign-in (docs/CONNECTORS.md,
/// "Google"): turned on per account, their scopes asked for only then, the account named by its
/// OpenID user info when it has none of Gmail, Calendar, and Drive, and requests that only read:
/// reports through the Data API, and Google Ads only through listing customers and GAQL SELECTs.
/// Google is a local fake: nothing leaves the machine.
@MainActor
final class GoogleAnalyticsAdsConnectorTests: XCTestCase {
    private func signedIn(_ services: Set<LocalConnectorService>, google: FakeAnalyticsAds,
                          agent: FakeUserAgent = FakeUserAgent()) async throws -> ConnectorCenter {
        var environment = ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(), credentials: InMemoryConnectorCredentialStore(), http: google,
            userAgent: agent, sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9")
        environment.google = FakeAnalyticsAds.endpoints
        let center = ConnectorCenter(environment: environment)
        try await center.saveGoogleApp(clientID: FakeGoogle.clientID, secret: FakeGoogle.clientSecret)
        let account = try XCTUnwrap(center.addAccount(services: services))
        await center.waitForConnection(account.id)
        return center
    }

    private func call(_ center: ConnectorCenter, _ name: String, _ arguments: [String: ToolJSON]) async throws -> AgentToolResult {
        try XCTUnwrapAsync(await center.callNamingTheOnlyAccount(name, arguments, for: ConnectorToolContext()))
    }

    func testAnalyticsAndAdsAskOnlyForTheirScopesAndNameTheAccountByItsUserInfo() async throws {
        let google = FakeAnalyticsAds()
        let agent = FakeUserAgent()
        let center = try await signedIn([.googleAnalytics, .googleAds], google: google, agent: agent)

        let account = try XCTUnwrap(center.googleAccounts.first)
        XCTAssertEqual(account.address, "person@example.test")
        XCTAssertEqual(account.services.map(\.slug), ["analytics", "google_ads"])
        XCTAssertEqual(account.services.map(\.status), [.connected, .connected])
        let scope = URLComponents(url: try XCTUnwrap(agent.opened.first), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "scope" }?.value
        XCTAssertEqual(scope, "https://www.googleapis.com/auth/analytics.readonly https://www.googleapis.com/auth/userinfo.email "
            + "https://www.googleapis.com/auth/adwords")
        XCTAssertFalse(scope?.contains("gmail") == true)
        // A new account starts with Gmail, Calendar, and Drive only; the two are turned on by hand.
        XCTAssertEqual(LocalConnectorService.googleDefaults, [.gmail, .googleCalendar, .googleDrive])
        XCTAssertTrue(LocalConnectorService.googleAnalytics.approvalRequiredTools.isEmpty)
        XCTAssertTrue(GoogleAdsToolCatalog.tools.allSatisfy { $0["annotations"]?["readOnlyHint"] == .bool(true) })
    }

    func testAReportGoesToTheDataAPIAndComesBackAsRows() async throws {
        let google = FakeAnalyticsAds()
        let center = try await signedIn([.googleAnalytics], google: google)
        let result = try await call(center, "analytics_run_report", [
            "property_id": .string("123"), "metrics": .array([.string("sessions")]), "dimensions": .array([.string("date")]),
            "date_ranges": .array([.object(["start_date": .string("7daysAgo"), "end_date": .string("today")])])
        ])
        XCTAssertFalse(result.isError, result.text)
        let report = try XCTUnwrap(google.seen.last)
        XCTAssertEqual(report.url?.path(), "/v1beta/properties/123:runReport")
        let body = try JSONDecoder().decode(ToolJSON.self, from: try XCTUnwrap(report.httpBody))
        XCTAssertEqual(body["dateRanges"], .array([.object(["startDate": .string("7daysAgo"), "endDate": .string("today")])]))
        XCTAssertEqual(body["metrics"], .array([.object(["name": .string("sessions")])]))
        let rows = try JSONDecoder().decode(ToolJSON.self, from: Data(result.text.utf8))
        XCTAssertEqual(rows["headers"], .array([.string("date"), .string("sessions")]))
        XCTAssertEqual(rows["rows"], .array([.array([.string("20261027"), .string("42")])]))

        let bad = try await call(center, "analytics_run_report", ["property_id": .string("GA-1"), "metrics": .array([.string("x")])])
        XCTAssertTrue(bad.isError)
    }

    func testGoogleAdsOnlyReadsAndSendsNoDeveloperToken() async throws {
        let google = FakeAnalyticsAds()
        let center = try await signedIn([.googleAds], google: google)
        let before = google.seen.count
        let mutate = try await call(center, "google_ads_search", ["customer_id": .string("123-456-7890"),
                                                                  "query": .string("UPDATE campaign SET status = PAUSED")])
        XCTAssertTrue(mutate.isError)
        XCTAssertEqual(google.seen.count, before, "Refused before any request")

        let result = try await call(center, "google_ads_search", [
            "customer_id": .string("123-456-7890"), "login_customer_id": .string("111-222-3333"),
            "query": .string("select campaign.name, metrics.cost_micros from campaign")
        ])
        XCTAssertFalse(result.isError, result.text)
        let search = try XCTUnwrap(google.seen.last)
        XCTAssertEqual(search.url?.path(), "/v26/customers/1234567890/googleAds:search")
        XCTAssertEqual(search.value(forHTTPHeaderField: "login-customer-id"), "1112223333")
        XCTAssertNil(search.value(forHTTPHeaderField: "developer-token"))
    }
}

/// Google's sign-in (`FakeGoogle`) with the OpenID user info endpoint, the Analytics Data API, and
/// the Google Ads API, as far as these tests need.
final class FakeAnalyticsAds: ConnectorHTTPTransport, @unchecked Sendable {
    static let endpoints: GoogleOAuth.Endpoints = {
        var endpoints = FakeGoogle.endpoints
        endpoints.analyticsAdminAPI = URL(string: "https://analyticsadmin.google.test/v1beta/")!
        endpoints.analyticsDataAPI = URL(string: "https://analyticsdata.google.test/v1beta/")!
        endpoints.adsAPI = URL(string: "https://googleads.google.test/v26/")!
        endpoints.userInfo = URL(string: "https://openidconnect.google.test/v1/userinfo")!
        return endpoints
    }()

    let google = FakeGoogle()
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var seen: [URLRequest] { lock.withLock { recorded } }

    init() {
        google.grantedScope = GoogleOAuth.scope(for: [.googleAnalytics, .googleAds])
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let host = url.host(), host.hasSuffix(".google.test"), host != "oauth2.google.test",
              host != "accounts.google.test" else {
            return try await google.send(request)
        }
        lock.withLock { recorded.append(request) }
        guard google.account(of: request) != nil else { return Self.reply(url, 401, [:]) }
        switch (host, url.path()) {
        case ("openidconnect.google.test", "/v1/userinfo"):
            return Self.reply(url, 200, ["email": .string("person@example.test"), "sub": .string("1")])
        case ("analyticsdata.google.test", "/v1beta/properties/123:runReport"):
            return Self.reply(url, 200, [
                "dimensionHeaders": .array([.object(["name": .string("date")])]),
                "metricHeaders": .array([.object(["name": .string("sessions"), "type": .string("TYPE_INTEGER")])]),
                "rows": .array([.object(["dimensionValues": .array([.object(["value": .string("20261027")])]),
                                         "metricValues": .array([.object(["value": .string("42")])])])]),
                "rowCount": .integer(1)
            ])
        case ("googleads.google.test", "/v26/customers/1234567890/googleAds:search"):
            return Self.reply(url, 200, ["results": .array([]), "fieldMask": .string("campaign.name,metrics.costMicros")])
        default:
            return Self.reply(url, 404, ["error": .object(["code": .integer(404), "message": .string("Not found")])])
        }
    }

    private static func reply(_ url: URL, _ status: Int, _ body: [String: ToolJSON]) -> (Data, HTTPURLResponse) {
        ((try? JSONEncoder().encode(ToolJSON.object(body))) ?? Data(),
         HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }
}
