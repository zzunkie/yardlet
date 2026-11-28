import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Google Calendar and Drive discovery, account routing and native Calendar paging.
@MainActor
final class GoogleCalendarDriveConnectorTests: XCTestCase {
    nonisolated private static let seoul = TimeZone(identifier: "Asia/Seoul")!

    private func makeCenter(
        google: FakeGoogleWorkspace = FakeGoogleWorkspace(),
        agent: FakeUserAgent = FakeUserAgent(),
        credentials: InMemoryConnectorCredentialStore = InMemoryConnectorCredentialStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> ConnectorCenter {
        var environment = ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(), credentials: credentials, http: google, userAgent: agent,
            sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9", now: now)
        environment.google = FakeGoogleWorkspace.endpoints
        environment.googleWorkspaceTransport = google
        environment.googleBuiltInApp = .init(clientID: FakeGoogle.calendarClientID, clientSecret: FakeGoogle.clientSecret)
        environment.timeZone = { Self.seoul }
        return ConnectorCenter(environment: environment)
    }

    /// A center with the Google app saved and one account signed in with `services`.
    private func signedIn(
        _ address: String = "person@example.test",
        services: Set<LocalConnectorService> = Set(LocalConnectorService.googleDefaults),
        google: FakeGoogleWorkspace = FakeGoogleWorkspace(),
        agent: FakeUserAgent = FakeUserAgent(),
        credentials: InMemoryConnectorCredentialStore = InMemoryConnectorCredentialStore()
    ) async throws -> (ConnectorCenter, ConnectorCenter.ServiceAccount) {
        let center = makeCenter(google: google, agent: agent, credentials: credentials)
        try await center.saveGoogleApp(clientID: FakeGoogle.clientID, secret: FakeGoogle.clientSecret)
        google.google.signInAs = address
        let account = try XCTUnwrap(center.addAccount(services: services))
        await center.waitForConnection(account.id)
        let settled = try XCTUnwrap(center.googleAccounts.first { $0.id == account.id })
        return (center, settled)
    }

    private func call(_ center: ConnectorCenter, _ name: String, _ arguments: [String: ToolJSON] = [:],
                      task: UUID? = nil) async throws -> AgentToolResult {
        try XCTUnwrapAsync(await center.callNamingTheOnlyAccount(name, arguments, for: ConnectorToolContext(taskID: task)))
    }

    private func json(_ result: AgentToolResult, file: StaticString = #filePath, line: UInt = #line) throws -> ToolJSON {
        XCTAssertFalse(result.isError, result.text, file: file, line: line)
        return try JSONDecoder().decode(ToolJSON.self, from: Data(result.text.utf8))
    }

    private func query(_ url: URL?) -> [String: String] {
        Dictionary((URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                   uniquingKeysWith: { first, _ in first })
    }

    // MARK: - One sign-in for three services

    /// The account chooser asks once for every chosen service's scopes, offline and incremental;
    /// the account's services share one sign-in, each a connector with its own tools.
    func testOneSignInAsksForEveryChosenServicesScopesAndConnectsEach() async throws {
        let google = FakeGoogleWorkspace()
        let agent = FakeUserAgent()
        let credentials = InMemoryConnectorCredentialStore()
        let (center, account) = try await signedIn(google: google, agent: agent, credentials: credentials)

        XCTAssertEqual(agent.opened.count, 1, "One browser sign-in for three services")
        let asked = query(agent.opened.first)
        XCTAssertEqual(asked["scope"], FakeGoogleWorkspace.allScopes)
        XCTAssertEqual(asked["include_granted_scopes"], "true")
        XCTAssertEqual(asked["access_type"], "offline")
        XCTAssertEqual(asked["prompt"], "select_account consent")
        XCTAssertNil(asked["resource"])
        XCTAssertFalse(asked["scope"]?.contains("https://mail.google.com/") == true)
        XCTAssertTrue(asked["scope"]?.split(separator: " ").contains("https://www.googleapis.com/auth/drive") == true)
        XCTAssertFalse(asked["scope"]?.split(separator: " ").contains("https://www.googleapis.com/auth/calendar") == true,
                       "No full Calendar access")

        XCTAssertEqual(account.address, "person@example.test")
        XCTAssertEqual(account.services.map(\.localService), [.gmail, .googleCalendar, .googleDrive])
        XCTAssertEqual(account.services.map(\.slug), ["gmail", "calendar", "drive"])
        XCTAssertEqual(account.services.map(\.status), [.connected, .connected, .connected])
        XCTAssertEqual(account.services.map(\.displayName),
                       ["Gmail · person@example.test", "Google Calendar · person@example.test", "Google Drive · person@example.test"])
        XCTAssertEqual(Set(account.services.map(\.credentialID)), [account.id], "One sign-in for the account")
        XCTAssertEqual(account.services.first?.id, account.id, "Kept under the first service's ID, as Gmail's was")
        let credential = try XCTUnwrap(credentials.load(account.id))
        XCTAssertEqual(credential.clientID, FakeGoogle.clientID)
        for record in account.services.dropFirst() { XCTAssertNil(try credentials.load(record.id), "No second copy") }

        let tools = await center.connectorTools(for: ConnectorToolContext()).compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(tools.filter { $0.hasPrefix("calendar_") }, ["calendar_list_calendars", "calendar_list_events", "calendar_create_event"])
        XCTAssertEqual(tools.filter { $0.hasPrefix("drive_") }, ["drive_search_files", "drive_list_recent_files", "drive_create_file",
                                                                "drive_read_doc", "drive_get_values", "drive_read_presentation"])
        let label = try XCTUnwrap(ConnectorToolLabels.shared.label(forClaudeTool: "mcp__yardlet__drive_create_file"))
        XCTAssertEqual(label.localService, .googleDrive)
        XCTAssertTrue(label.takesAccount)
        XCTAssertEqual(label.account(named: "person@example.test"), "person@example.test")
        XCTAssertEqual(label.connector, "Google Drive")

        // Every call goes with the account's one token, to its own Calendar and Drive.
        _ = try json(try await call(center, "calendar_list_calendars"))
        _ = try json(try await call(center, "drive_list_recent_files"))
        XCTAssertEqual(Set(google.google.requests.compactMap { google.google.account(of: $0) }), ["person@example.test"])
    }

    /// An account with Calendar or Drive alone is named by what that service says, not by Gmail.
    func testAnAccountWithoutGmailIsNamedByCalendarOrDrive() async throws {
        let calendarOnly = FakeGoogleWorkspace(granting: GoogleOAuth.scope(for: [.googleCalendar]))
        let (_, calendarAccount) = try await signedIn("cal@company.test", services: [.googleCalendar], google: calendarOnly)
        XCTAssertEqual(calendarAccount.address, "cal@company.test")
        XCTAssertEqual(calendarAccount.services.map(\.slug), ["calendar"])
        XCTAssertFalse(calendarOnly.google.requests.contains { $0.url?.path().hasSuffix("/profile") == true },
                       "Gmail is not asked without its scope")
        XCTAssertEqual(calendarOnly.calls("GET").first?.path, "/calendar/v3/users/me/calendarList/primary")

        let driveOnly = FakeGoogleWorkspace(granting: GoogleOAuth.scope(for: [.googleDrive]))
        let (_, driveAccount) = try await signedIn("files@example.test", services: [.googleDrive], google: driveOnly)
        XCTAssertEqual(driveAccount.address, "files@example.test")
        let about = try XCTUnwrap(driveOnly.calls("GET", "/drive/v3/about").first)
        XCTAssertEqual(about.value("fields"), "user(emailAddress)")
    }

    // MARK: - Scopes

    /// With granular consent the person can leave Drive unchecked: Gmail and Calendar connect,
    /// Drive says what is missing and gives no tools; Reconnect asks again for all three.
    func testAScopeLeftUncheckedLeavesOnlyThatServiceNeedingSignIn() async throws {
        let google = FakeGoogleWorkspace(granting: GoogleOAuth.scope(for: [.gmail, .googleCalendar]))
        let agent = FakeUserAgent()
        let (center, account) = try await signedIn(google: google, agent: agent)
        XCTAssertEqual(account.services.map(\.status), [.connected, .connected, .signInRequired])
        let drive = try XCTUnwrap(account.record(.googleDrive))
        XCTAssertEqual(center.failures[drive.id], GoogleSignInError.scopeNotGranted([.googleDrive]).errorDescription)
        XCTAssertEqual(ConnectorSettingsState.make(drive, in: center), .error(try XCTUnwrap(center.failures[drive.id])))
        let tools = await center.connectorTools(for: ConnectorToolContext()).compactMap { $0["name"]?.stringValue }
        XCTAssertFalse(tools.contains { $0.hasPrefix("drive_") })
        XCTAssertTrue(tools.contains("calendar_create_event"))

        google.google.grantedScope = FakeGoogleWorkspace.allScopes
        center.reconnect(drive.id)
        await center.waitForConnection(drive.id)
        let again = query(agent.opened.last)
        XCTAssertEqual(again["login_hint"], "person@example.test")
        XCTAssertEqual(again["prompt"], "consent")
        XCTAssertEqual(again["scope"], FakeGoogleWorkspace.allScopes)
        let settled = try XCTUnwrap(center.googleAccounts.first)
        XCTAssertEqual(center.googleAccounts.count, 1)
        XCTAssertEqual(settled.services.map(\.status), [.connected, .connected, .connected])
        XCTAssertNil(center.failures[drive.id])

        // Nothing granted at all is no sign-in.
        let none = FakeGoogleWorkspace(granting: "openid")
        let empty = makeCenter(google: none)
        try await empty.saveGoogleApp(clientID: FakeGoogle.clientID, secret: FakeGoogle.clientSecret)
        let lone = try XCTUnwrap(empty.addAccount(services: [.googleCalendar, .googleDrive]))
        await empty.waitForConnection(lone.id)
        XCTAssertEqual(empty.failures[lone.id],
                       GoogleSignInError.scopeNotGranted([.googleCalendar, .googleDrive]).errorDescription)
        XCTAssertNotEqual(empty.record(lone.id)?.status, .connected)
    }

    /// Turning a service on asks Google again only when the account's sign-in lacks its scopes
    /// (incremental authorization, the account named); off removes its connector and keeps the
    /// sign-in for the others; removing the account removes all of it.
    func testTurningAServiceOnAsksOnlyWhenTheSignInLacksItsScopes() async throws {
        let google = FakeGoogleWorkspace(granting: GoogleOAuth.scope(for: [.gmail]))
        let agent = FakeUserAgent()
        let credentials = InMemoryConnectorCredentialStore()
        let (center, account) = try await signedIn(services: [.gmail], google: google, agent: agent, credentials: credentials)
        XCTAssertEqual(query(agent.opened.first)["scope"], GoogleOAuth.scope(for: [.gmail]), "Gmail alone asks for Gmail alone")

        google.google.grantedScope = FakeGoogleWorkspace.allScopes
        await center.setService(.googleCalendar, on: true, account: account.id)
        let calendar = try XCTUnwrap(center.googleAccounts.first?.record(.googleCalendar))
        await center.waitForConnection(calendar.id)
        XCTAssertEqual(agent.opened.count, 2, "Calendar's scopes were not granted yet")
        let incremental = query(agent.opened.last)
        XCTAssertEqual(incremental["login_hint"], "person@example.test")
        XCTAssertEqual(incremental["include_granted_scopes"], "true")
        XCTAssertEqual(incremental["scope"], GoogleOAuth.scope(for: [.gmail, .googleCalendar]))
        XCTAssertEqual(center.record(calendar.id)?.status, .connected)
        XCTAssertEqual(center.record(calendar.id)?.slug, "calendar")
        XCTAssertEqual(center.record(calendar.id)?.credentialID, account.id)
        XCTAssertEqual(center.record(account.id)?.status, .connected)

        // That sign-in granted Drive too, so turning Drive on needs no browser.
        await center.setService(.googleDrive, on: true, account: account.id)
        let drive = try XCTUnwrap(center.googleAccounts.first?.record(.googleDrive))
        await center.waitForConnection(drive.id)
        XCTAssertEqual(agent.opened.count, 2)
        XCTAssertEqual(center.record(drive.id)?.status, .connected)
        XCTAssertEqual(center.record(drive.id)?.account, "person@example.test")
        _ = try json(try await call(center, "drive_search_files", ["query": .string("plan")]))

        // Off: Calendar's connector goes, the sign-in stays for Gmail and Drive.
        await center.setService(.googleCalendar, on: false, account: account.id)
        await center.waitForPendingDeletions()
        XCTAssertNil(center.record(calendar.id))
        XCTAssertNotNil(try credentials.load(account.id))
        XCTAssertEqual(center.googleAccounts.first?.enabled, [.gmail, .googleDrive])
        _ = try json(try await call(center, "gmail_list_labels"))
        let gone = await center.callConnectorTool(named: "calendar_list_calendars", arguments: .object([:]),
                                                  for: ConnectorToolContext())
        XCTAssertNil(gone, "No connector answers for Calendar any more")

        // Even Gmail's own connector, whose ID the sign-in is under, can go while Drive stays.
        await center.setService(.gmail, on: false, account: account.id)
        await center.waitForPendingDeletions()
        XCTAssertNotNil(try credentials.load(account.id))
        _ = try json(try await call(center, "drive_list_recent_files"))

        center.removeAccount(account.id)
        await center.waitForPendingDeletions()
        XCTAssertTrue(center.googleAccounts.isEmpty)
        XCTAssertNil(try credentials.load(account.id))
    }

    func testNativeCalendarReadsPagesAndAnswersInvitations() async throws {
        let google = FakeGoogleWorkspace(granting: GoogleOAuth.scope(for: [.googleCalendar]))
        let (center, signedInAccount) = try await signedIn(services: [.googleCalendar], google: google)
        try await center.signInGoogleCalendarUI(account: signedInAccount.id)
        let (account, transport) = try XCTUnwrap(center.calendarAccounts().first)
        XCTAssertEqual(account.provider, .google)
        XCTAssertEqual(account.address, "person@example.test")
        XCTAssertEqual(account.connectorSlug, "calendar")
        let calendarList = try await transport.calendars()
        XCTAssertEqual(calendarList.map(\.name), ["person@example.test", "Days off", "Team"])
        XCTAssertEqual(calendarList[1].serviceName, "Holidays in South Korea")
        XCTAssertEqual(calendarList.map(\.isShownByDefault), [true, false, true])
        let from = try XCTUnwrap(CalendarTime.parse("2026-10-21", in: Self.seoul)?.date)
        let read = try await transport.events(in: calendarList[0], from: from, to: from.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(google.calls("GET", "/calendar/v3/calendars/person%40example.test/events").last?.value("pageToken"), "events-2")
        XCTAssertEqual(read.map(\.id.eventID), ["e1", "e2", "e3"])
        XCTAssertEqual(read[0].start, CalendarTime.parse("2026-10-21T10:00:00", in: Self.seoul)?.date)
        XCTAssertEqual(read[0].response, .needsAction)
        XCTAssertEqual(read[0].conferenceURL?.absoluteString, "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(read[0].webURL?.absoluteString, "https://calendar.google.com/event?eid=e1")
        XCTAssertEqual(read[2].isAllDay, true)
        XCTAssertEqual(read[2].end, CalendarTime.parse("2026-10-23", in: Self.seoul)?.date)
        try await transport.respond(to: read[0], .declined)
        let answer = try XCTUnwrap(google.calls("PATCH").last)
        XCTAssertEqual(answer.path, "/calendar/v3/calendars/person%40example.test/events/e1")
        XCTAssertEqual(answer.json?["attendees"]?.arrayValue?.last?["responseStatus"], .string("declined"))
    }

    func testTwoAccountsKeepTheirOwnTokensAndServicesAndShareTheirTools() async throws {
        let google = FakeGoogleWorkspace()
        let credentials = InMemoryConnectorCredentialStore()
        let (center, personal) = try await signedIn("person@example.test", google: google, credentials: credentials)
        google.google.signInAs = "developer@company.test"
        let work = try XCTUnwrap(center.addAccount(services: [.googleCalendar, .googleDrive]))
        await center.waitForConnection(work.id)
        let settled = try XCTUnwrap(center.googleAccounts.first { $0.id == work.id })
        XCTAssertEqual(settled.address, "developer@company.test")
        XCTAssertEqual(center.googleAccounts.map(\.address), ["person@example.test", "developer@company.test"])
        XCTAssertNotEqual(try credentials.load(personal.id)?.accessToken, try credentials.load(work.id)?.accessToken)

        // Both accounts' Calendar and Drive share one set of tools, each call naming its account.
        let both = await center.connectorTools(for: ConnectorToolContext())
        XCTAssertEqual(both.count, 3 + 3 + 6)
        func accounts(_ tools: [ToolJSON], _ name: String) -> ToolJSON? {
            tools.first { $0["name"] == .string(name) }?["inputSchema"]?["properties"]?["account"]?["enum"]
        }
        XCTAssertEqual(accounts(both, "calendar_list_calendars"),
                       .array([.string("person@example.test"), .string("developer@company.test")]))
        XCTAssertEqual(accounts(both, "gmail_list_labels"), .array([.string("person@example.test")]))
        _ = try json(try await call(center, "calendar_list_calendars", ["account": .string("person@example.test")]))
        XCTAssertEqual(google.google.requests.last.flatMap { google.google.account(of: $0) }, "person@example.test")
        let theirs = try json(try await call(center, "calendar_list_calendars", ["account": .string("developer@company.test")]))
        XCTAssertEqual(google.google.requests.last.flatMap { google.google.account(of: $0) }, "developer@company.test")
        XCTAssertEqual(theirs["account"], .string("developer@company.test"))

        // Turned off in one task, only that account's Calendar leaves it.
        let task = UUID()
        let workCalendar = try XCTUnwrap(settled.record(.googleCalendar))
        center.setConnector(workCalendar.id, on: false, inTask: task)
        let inTask = await center.connectorTools(for: ConnectorToolContext(taskID: task))
        XCTAssertEqual(accounts(inTask, "calendar_list_events"), .array([.string("person@example.test")]))
        XCTAssertEqual(accounts(inTask, "drive_search_files"),
                       .array([.string("person@example.test"), .string("developer@company.test")]))

        // Gmail turned on for the second account joins the Gmail tools the first has.
        await center.setService(.gmail, on: true, account: work.id)
        let workGmail = try XCTUnwrap(center.googleAccounts.first { $0.id == work.id }?.record(.gmail))
        await center.waitForConnection(workGmail.id)
        XCTAssertEqual(center.record(workGmail.id)?.status, .connected)
        let withGmail = await center.connectorTools(for: ConnectorToolContext())
        XCTAssertEqual(accounts(withGmail, "gmail_list_labels"),
                       .array([.string("person@example.test"), .string("developer@company.test")]))

        // Signing in to an account that is here already adds its services to that account.
        google.google.signInAs = "Person@example.test"
        let again = try XCTUnwrap(center.addAccount(services: [.googleDrive]))
        await center.waitForConnection(again.id)
        XCTAssertEqual(center.googleAccounts.count, 2)
        XCTAssertNil(center.record(again.id), "Drive was on for that account already")
        XCTAssertNil(try credentials.load(again.id))

        // A revoked sign-in leaves all that account's services needing sign-in, not the other's.
        google.google.revoke("developer@company.test")
        let refused = try await call(center, "drive_search_files",
                                     ["account": .string("developer@company.test"), "query": .string("x")])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("needs the user to sign in again"), refused.text)
        XCTAssertEqual(center.googleAccounts.first { $0.id == work.id }?.services.map(\.status),
                       [.signInRequired, .signInRequired, .signInRequired])
        XCTAssertEqual(center.googleAccounts.first { $0.id == personal.id }?.services.map(\.status),
                       [.connected, .connected, .connected])
        _ = try json(try await call(center, "drive_search_files", ["account": .string("person@example.test"), "query": .string("x")]))
    }

    func testStartupDiscoversMissingRoutesBeforeAClaudeTaskListsTools() async throws {
        let google = FakeGoogleWorkspace()
        let credentials = InMemoryConnectorCredentialStore()
        let (_, account) = try await signedIn(services: [.googleDrive], google: google, credentials: credentials)
        var row = try XCTUnwrap(account.record(.googleDrive))
        for routes: [String: GoogleWorkspaceEndpoint]? in [nil, [:]] {
            row.workspaceToolEndpoints = routes
            row.tools = []
            row.toolsUpdatedAt = .now
            row.googleUISignIn = nil
            var environment = ConnectorCenter.Environment(
                repository: InMemoryConnectorRepository(records: [row], googleAppClientID: FakeGoogle.clientID),
                credentials: credentials, http: google, userAgent: nil, sha256: MacOAuthUserAgent.sha256, clientVersion: "test")
            environment.google = FakeGoogleWorkspace.endpoints
            environment.googleWorkspaceTransport = google
            let reopened = ConnectorCenter(environment: environment)
            let task = UUID()
            let scope = ConnectorTaskScope(harness: .claudeCode)
            await reopened.waitForInitialWorkspaceTools(for: task, scope: scope)
            XCTAssertTrue(reopened.googleWorkspaceToolNames(for: ConnectorToolContext(taskID: task, scope: scope)).contains("drive_get_values"))
            XCTAssertEqual(reopened.record(row.id)?.workspaceToolEndpoints?["get_values"], .sheets)
        }
    }

    func testDriveDiscoveryKeepsHealthyAPIsAndOfflineSchemas() async throws {
        let google = FakeGoogleWorkspace()
        google.google.fail(.slides, status: 403)
        let (center, account) = try await signedIn(services: [.googleDrive], google: google)
        let drive = try XCTUnwrap(account.record(.googleDrive))
        XCTAssertEqual(drive.status, .connected)
        XCTAssertEqual(Set(drive.workspaceToolEndpoints?.values.map { $0 } ?? []), [.drive, .docs, .sheets])
        XCTAssertTrue(center.failures[drive.id]?.contains("slidesmcp.googleapis.com") == true)
        let exposed = await center.connectorTools(for: ConnectorToolContext())
        XCTAssertFalse(exposed.contains { $0["name"] == .string("drive_read_presentation") })
        _ = try json(try await call(center, "drive_get_values"))
        XCTAssertEqual(google.google.requests.last?.url?.host(), "sheetsmcp.googleapis.com")

        for endpoint in LocalConnectorService.googleDrive.workspaceEndpoints { google.google.fail(endpoint, status: 0) }
        center.connect(drive.id)
        await center.waitForConnection(drive.id)
        XCTAssertEqual(center.record(drive.id)?.toolsUpdatedAt, drive.toolsUpdatedAt)
        XCTAssertEqual(center.record(drive.id)?.tools, drive.tools)
        XCTAssertEqual(center.record(drive.id)?.workspaceToolEndpoints, drive.workspaceToolEndpoints)
        XCTAssertEqual(center.record(drive.id)?.status, .connected)
        for endpoint in LocalConnectorService.googleDrive.workspaceEndpoints { google.google.fail(endpoint, status: 403) }
        center.connect(drive.id)
        await center.waitForConnection(drive.id)
        XCTAssertEqual(center.record(drive.id)?.status, .notConnected)
        let unavailable = await center.connectorTools(for: ConnectorToolContext())
        XCTAssertTrue(unavailable.isEmpty)
    }

    // MARK: - Pieces

    func testFreeSlotsKeepToWorkingHoursAndWeekdays() throws {
        let zone = Self.seoul
        // Friday 2026-10-23 16:00 to Monday 2026-10-26 12:00, Seoul.
        let from = try XCTUnwrap(CalendarTime.parse("2026-10-23T16:00:00", in: zone)?.date)
        let to = try XCTUnwrap(CalendarTime.parse("2026-10-26T12:00:00", in: zone)?.date)
        let busy = [DateInterval(start: try XCTUnwrap(CalendarTime.parse("2026-10-26T09:00:00", in: zone)?.date), duration: 3_600)]
        let window = try CalendarTime.Window(start: "09:00", end: "18:00")
        let slots = CalendarTime.freeSlots(from: from, to: to, busy: busy, minutes: 45, window: window,
                                           excludeWeekends: true, zone: zone, limit: 5)
        XCTAssertEqual(slots.map { CalendarTime.rfc3339($0.start, in: zone) },
                       ["2026-10-23T16:00:00+09:00", "2026-10-23T17:00:00+09:00", "2026-10-26T10:00:00+09:00",
                        "2026-10-26T11:00:00+09:00"])
        XCTAssertThrowsError(try CalendarTime.Window(start: "18:00", end: "09:00"))
        XCTAssertThrowsError(try CalendarTime.Window(start: "9am", end: nil))
    }

}
