import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Yardlet's own Google Calendar and Drive servers on the Google OAuth app Gmail uses
/// (docs/CONNECTORS.md, "Google"): one sign-in per Google account carrying the scopes of the services
/// turned on for it, incremental consent when one more is turned on, a scope left unchecked, each
/// tool's Calendar or Drive API request and answer, the harness asking before writes and not
/// before reads, and two accounts side by side. Google is a local fake (`FakeGoogleWorkspace`): no
/// request leaves the machine and no real account signs in.
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
        XCTAssertEqual(asked["scope"], [GmailToolCatalog.scope, GoogleCalendarToolCatalog.calendarListScope,
                                        GoogleCalendarToolCatalog.eventsScope, GoogleCalendarToolCatalog.freeBusyScope,
                                        GoogleDriveToolCatalog.readScope, GoogleDriveToolCatalog.fileScope].joined(separator: " "))
        XCTAssertEqual(asked["include_granted_scopes"], "true")
        XCTAssertEqual(asked["access_type"], "offline")
        XCTAssertEqual(asked["prompt"], "select_account consent")
        XCTAssertNil(asked["resource"])
        XCTAssertFalse(asked["scope"]?.contains("https://mail.google.com/") == true)
        XCTAssertFalse(asked["scope"]?.split(separator: " ").contains("https://www.googleapis.com/auth/drive") == true,
                       "No full Drive access")
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
        XCTAssertEqual(tools.filter { $0.hasPrefix("calendar_") },
                       ["calendar_list_calendars", "calendar_list_events", "calendar_search_events", "calendar_get_event",
                        "calendar_suggest_time", "calendar_create_event", "calendar_update_event", "calendar_delete_event",
                        "calendar_respond_to_event"])
        XCTAssertEqual(tools.filter { $0.hasPrefix("drive_") },
                       ["drive_search_files", "drive_list_recent_files", "drive_get_file_metadata", "drive_get_file_permissions",
                        "drive_read_file_content", "drive_download_file_content", "drive_create_file", "drive_copy_file",
                        "drive_update_file", "drive_read_doc", "drive_update_doc", "drive_get_spreadsheet", "drive_get_values",
                        "drive_update_values", "drive_update_formulas", "drive_insert_dimension", "drive_update_spreadsheet",
                        "drive_read_presentation", "drive_read_slide_page", "drive_read_slide_page_thumbnail",
                        "drive_update_presentation"])
        XCTAssertEqual(tools.count, 9 + 9 + 21)
        let exposed = await center.connectorTools(for: ConnectorToolContext())
        XCTAssertEqual(exposed.first { $0["name"] == .string("calendar_list_events") }?["title"],
                       .string("Google Calendar: List events"))
        let label = try XCTUnwrap(ConnectorToolLabels.shared.label(forClaudeTool: "mcp__yardlet__drive_create_file"))
        XCTAssertEqual(label.localService, .googleDrive)
        XCTAssertTrue(label.takesAccount)
        XCTAssertEqual(label.account(named: "person@example.test"), "person@example.test")
        XCTAssertEqual(label.connector, "Google Drive")

        // Every call goes with the account's one token, to its own Calendar and Drive.
        _ = try json(try await call(center, "calendar_list_calendars"))
        _ = try json(try await call(center, "drive_list_recent_files"))
        XCTAssertEqual(Set(google.requests.compactMap(\.account)), ["person@example.test"])
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
        let google = FakeGoogleWorkspace(granting: GmailToolCatalog.scope)
        let agent = FakeUserAgent()
        let credentials = InMemoryConnectorCredentialStore()
        let (center, account) = try await signedIn(services: [.gmail], google: google, agent: agent, credentials: credentials)
        XCTAssertEqual(query(agent.opened.first)["scope"], GmailToolCatalog.scope, "Gmail alone asks for Gmail alone")

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

    // MARK: - Calendar tools

    func testCalendarToolsMapToTheCalendarAPI() async throws {
        let google = FakeGoogleWorkspace()
        let (center, _) = try await signedIn(google: google)

        let calendars = try json(try await call(center, "calendar_list_calendars"))
        XCTAssertEqual(calendars["calendars"]?.arrayValue?.compactMap { $0["id"]?.stringValue },
                       ["person@example.test", FakeGoogleWorkspace.holidays])
        XCTAssertEqual(calendars["calendars"]?.arrayValue?.last?["summary"], .string("Days off"), "The person's own name for it")
        XCTAssertEqual(calendars["nextPageToken"], .string("calendars-2"))
        XCTAssertNil(calendars["calendars"]?.arrayValue?.first?["etag"])
        XCTAssertEqual(google.calls("GET", "/calendar/v3/users/me/calendarList").last?.value("maxResults"), "100")

        // A local time is read in the zone; the calendar ID is one encoded path segment.
        let events = try json(try await call(center, "calendar_list_events", [
            "calendarId": .string(FakeGoogleWorkspace.holidays), "startTime": .string("2026-10-20T09:00:00"),
            "endTime": .string("2026-10-22T18:00"), "fullText": .string("review"),
            "eventType": .array([.string("DEFAULT"), .string("FOCUS_TIME")]), "pageSize": .integer(500)
        ]))
        let list = try XCTUnwrap(google.calls("GET").last)
        XCTAssertEqual(list.path, "/calendar/v3/calendars/ko.south_korea%23holiday%40group.v.calendar.google.com/events")
        XCTAssertEqual(list.value("timeMin"), "2026-10-20T09:00:00+09:00")
        XCTAssertEqual(list.value("timeMax"), "2026-10-22T18:00:00+09:00")
        XCTAssertEqual(list.value("singleEvents"), "true")
        XCTAssertEqual(list.value("orderBy"), "startTime")
        XCTAssertEqual(list.value("q"), "review")
        XCTAssertEqual(list.query["eventTypes"], ["default", "focusTime"])
        XCTAssertEqual(list.value("maxResults"), "250")
        XCTAssertEqual(list.value("timeZone"), "Asia/Seoul")
        let first = try XCTUnwrap(events["events"]?.arrayValue?.first)
        XCTAssertEqual(first["id"], .string("e1"))
        XCTAssertEqual(first["conferenceUrl"], .string("https://meet.google.com/abc-defg-hij"))
        XCTAssertEqual(first["organizer"], .string("bob@example.com"))
        XCTAssertEqual(first["availability"], .string("AVAILABILITY_BUSY"))
        XCTAssertEqual(first["attendees"]?.arrayValue?.last?["self"], .bool(true))
        XCTAssertNil(first["etag"])
        XCTAssertEqual(events["nextPageToken"], .string("events-2"))
        let reversed = try json(try await call(center, "calendar_list_events", ["orderBy": .string("startTimeDesc")]))
        XCTAssertEqual(reversed["events"]?.arrayValue?.compactMap { $0["id"]?.stringValue }, ["e2", "e1"])
        let defaults = try XCTUnwrap(google.calls("GET").last)
        XCTAssertEqual(defaults.path, "/calendar/v3/calendars/primary/events")
        let start = try XCTUnwrap(defaults.value("timeMin").flatMap(CalendarTime.absolute))
        let end = try XCTUnwrap(defaults.value("timeMax").flatMap(CalendarTime.absolute))
        XCTAssertEqual(end.timeIntervalSince(start), 7 * 86_400, accuracy: 1, "The 7 days from now")

        _ = try json(try await call(center, "calendar_search_events", ["query": .string("design review")]))
        let search = try XCTUnwrap(google.calls("GET").last)
        XCTAssertEqual(search.path, "/calendar/v3/calendars/primary/events")
        XCTAssertEqual(search.value("q"), "design review")
        let got = try json(try await call(center, "calendar_get_event", ["eventId": .string("e1")]))
        XCTAssertEqual(got["summary"], .string("Design review e1"))

        // Free times every attendee shares, past the merged busy times, on quarter hours.
        let free = try json(try await call(center, "calendar_suggest_time", [
            "attendeeEmails": .array([.string("bob@example.com"), .string("nobody@example.com")]),
            "startTime": .string("2026-10-21T09:00:00"), "endTime": .string("2026-10-21T13:00:00"),
            "durationMinutes": .integer(30)
        ]))
        let freeBusy = try XCTUnwrap(google.calls("POST", "/calendar/v3/freeBusy").last?.json)
        XCTAssertEqual(freeBusy["items"]?.arrayValue?.compactMap { $0["id"]?.stringValue },
                       ["primary", "bob@example.com", "nobody@example.com"])
        XCTAssertEqual(freeBusy["timeMin"], .string("2026-10-21T09:00:00+09:00"))
        XCTAssertEqual(free["timeSlots"]?.arrayValue?.compactMap { $0["startTime"]?.stringValue },
                       ["2026-10-21T11:15:00+09:00", "2026-10-21T12:15:00+09:00"])
        XCTAssertEqual(free["unavailableCalendars"]?.arrayValue?.first?["calendar"], .string("nobody@example.com"))

        // Creating: the times with their offset and zone, attendees, a Meet link, a recurrence.
        let made = try json(try await call(center, "calendar_create_event", [
            "summary": .string("Yardlet sync"), "startTime": .string("2026-10-23T15:00:00"),
            "endTime": .string("2026-10-23T15:30:00"), "description": .string("Connectors"),
            "attendees": .array([.object(["email": .string("bob@example.com"), "optionalAttendee": .bool(true)])]),
            "attendeeEmails": .array([.string("carol@example.com"), .string("BOB@example.com")]),
            "addGoogleMeetUrl": .bool(true), "recurrenceData": .array([.string("RRULE:FREQ=WEEKLY;COUNT=4")]),
            "overrideReminders": .array([.object(["method": .string("popup"), "minutes": .integer(10)])]),
            "availability": .string("AVAILABILITY_FREE")
        ]))
        let insert = try XCTUnwrap(google.calls("POST", "/calendar/v3/calendars/primary/events").last)
        XCTAssertEqual(insert.value("conferenceDataVersion"), "1")
        XCTAssertEqual(insert.value("sendUpdates"), "all")
        let body = try XCTUnwrap(insert.json)
        XCTAssertEqual(body["start"], .object(["dateTime": .string("2026-10-23T15:00:00+09:00"), "timeZone": .string("Asia/Seoul")]))
        XCTAssertEqual(body["attendees"]?.arrayValue?.compactMap { $0["email"]?.stringValue },
                       ["bob@example.com", "carol@example.com"], "Bob once")
        XCTAssertEqual(body["attendees"]?.arrayValue?.first?["optional"], .bool(true))
        XCTAssertEqual(body["conferenceData"]?["createRequest"]?["conferenceSolutionKey"]?["type"], .string("hangoutsMeet"))
        XCTAssertEqual(body["recurrence"], .array([.string("RRULE:FREQ=WEEKLY;COUNT=4")]))
        XCTAssertEqual(body["reminders"]?["useDefault"], .bool(false))
        XCTAssertEqual(body["transparency"], .string("transparent"))
        XCTAssertEqual(made["conferenceUrl"]?.stringValue?.hasPrefix("https://meet.google.com/"), true)
        XCTAssertEqual(made["availability"], .string("AVAILABILITY_FREE"))

        // An all-day event: dates, the end day included; an offset given is kept as the instant.
        _ = try json(try await call(center, "calendar_create_event", [
            "summary": .string("Offsite"), "startTime": .string("2026-11-02"), "endTime": .string("2026-11-03"),
            "allDay": .bool(true), "notificationLevel": .string("NONE")
        ]))
        let allDay = try XCTUnwrap(google.calls("POST", "/calendar/v3/calendars/primary/events").last)
        XCTAssertEqual(allDay.json?["start"], .object(["date": .string("2026-11-02")]))
        XCTAssertEqual(allDay.json?["end"], .object(["date": .string("2026-11-04")]))
        XCTAssertEqual(allDay.value("sendUpdates"), "none")
        _ = try json(try await call(center, "calendar_create_event", [
            "summary": .string("Call"), "startTime": .string("2026-10-23T06:00:00Z"), "endTime": .string("2026-10-23T06:30:00Z"),
            "timeZone": .string("Europe/Zurich")
        ]))
        let zoned = try XCTUnwrap(google.calls("POST", "/calendar/v3/calendars/primary/events").last?.json)
        XCTAssertEqual(zoned["start"], .object(["dateTime": .string("2026-10-23T08:00:00+02:00"), "timeZone": .string("Europe/Zurich")]))

        // Moving only the start keeps the length; attendees change by email.
        _ = try json(try await call(center, "calendar_update_event", [
            "eventId": .string("e1"), "startTime": .string("2026-10-21T14:00:00"),
            "addedAttendeeEmails": .array([.string("dana@example.com")]), "removedAttendeeEmails": .array([.string("BOB@example.com")]),
            "notificationLevel": .string("EXTERNAL_ONLY")
        ]))
        let patch = try XCTUnwrap(google.calls("PATCH", "/calendar/v3/calendars/primary/events/e1").last)
        XCTAssertEqual(patch.value("sendUpdates"), "externalOnly")
        XCTAssertEqual(patch.json?["start"]?["dateTime"], .string("2026-10-21T14:00:00+09:00"))
        XCTAssertEqual(patch.json?["end"]?["dateTime"], .string("2026-10-21T15:00:00+09:00"))
        XCTAssertEqual(patch.json?["attendees"]?.arrayValue?.compactMap { $0["email"]?.stringValue },
                       ["person@example.test", "dana@example.com"])

        let deleted = try json(try await call(center, "calendar_delete_event", ["eventId": .string("e1")]))
        XCTAssertEqual(deleted["deleted"], .bool(true))
        XCTAssertEqual(google.calls("DELETE").last?.value("sendUpdates"), "all")

        // Answering: the account's own attendee entry, and only it, changes.
        let answered = try json(try await call(center, "calendar_respond_to_event", [
            "eventId": .string("e1"), "responseStatus": .string("accepted"), "responseComment": .string("See you")
        ]))
        let response = try XCTUnwrap(google.calls("PATCH", "/calendar/v3/calendars/primary/events/e1").last?.json)
        XCTAssertEqual(response["attendees"]?.arrayValue?.map { $0["responseStatus"] }, [.string("accepted"), .string("accepted")])
        XCTAssertEqual(response["attendees"]?.arrayValue?.last?["comment"], .string("See you"))
        XCTAssertEqual(response.objectValue?.keys.sorted(), ["attendees"])
        XCTAssertNotNil(answered["attendees"])
        let notInvited = try await call(center, "calendar_respond_to_event",
                                        ["eventId": .string("not-invited"), "responseStatus": .string("declined")])
        XCTAssertTrue(notInvited.isError)

        // Mistakes the model can fix answer before any request.
        let before = google.requests.count
        for (tool, arguments) in [("calendar_create_event", ["startTime": ToolJSON.string("2026-10-23T15:00:00"),
                                                              "endTime": .string("2026-10-23T16:00:00")]),
                                  ("calendar_list_events", ["timeZone": .string("Mars/Olympus")]),
                                  ("calendar_create_event", ["summary": .string("x"), "startTime": .string("tomorrow"),
                                                             "endTime": .string("later")]),
                                  ("calendar_update_event", ["eventId": .string("e1")]),
                                  ("calendar_respond_to_event", ["eventId": .string("e1"), "responseStatus": .string("maybe")])] {
            let result = try await call(center, tool, arguments)
            XCTAssertTrue(result.isError, "\(tool) \(arguments)")
        }
        XCTAssertEqual(google.requests.count, before)
        let missing = try await call(center, "calendar_get_event", ["eventId": .string("nope")])
        XCTAssertTrue(missing.isError)
        XCTAssertEqual(missing.text, "Google Calendar: Not Found (HTTP 404)")
    }

    // MARK: - Drive tools

    func testDriveToolsMapToTheDriveAPI() async throws {
        let google = FakeGoogleWorkspace()
        let (center, _) = try await signedIn(google: google)

        // The query terms Google's Drive MCP takes, in the Drive API's words; trashed files stay out.
        let found = try json(try await call(center, "drive_search_files", [
            "query": .string("title contains 'plan' and parentId = 'root' and owner != 'me'"), "pageSize": .integer(500)
        ]))
        let search = try XCTUnwrap(google.calls("GET", "/drive/v3/files").last)
        XCTAssertEqual(search.value("q"), "(name contains 'plan' and 'root' in parents and not 'me' in owners) and trashed = false")
        XCTAssertEqual(search.value("pageSize"), "100")
        XCTAssertEqual(search.value("supportsAllDrives"), "true")
        XCTAssertTrue(search.value("fields")?.hasPrefix("nextPageToken,files(") == true)
        let file = try XCTUnwrap(found["files"]?.arrayValue?.first)
        XCTAssertEqual(file["title"], .string("Launch plan"))
        XCTAssertEqual(file["owner"], .string("person@example.test"))
        XCTAssertEqual(file["parentId"], .string("folder-1"))
        XCTAssertEqual(file["viewUrl"], .string("https://drive.google.com/file/d/doc-1/view"))
        XCTAssertEqual(found["nextPageToken"], .string("files-2"))
        _ = try json(try await call(center, "drive_search_files", ["query": .string("Bob's quarterly plan")]))
        XCTAssertEqual(google.calls("GET", "/drive/v3/files").last?.value("q"),
                       "fullText contains 'Bob\\'s quarterly plan' and trashed = false", "Plain words search the text")
        _ = try json(try await call(center, "drive_list_recent_files", ["orderBy": .string("lastModified")]))
        XCTAssertEqual(google.calls("GET", "/drive/v3/files").last?.value("orderBy"), "modifiedTime desc")
        _ = try json(try await call(center, "drive_list_recent_files"))
        XCTAssertEqual(google.calls("GET", "/drive/v3/files").last?.value("orderBy"), "recency desc")
        XCTAssertEqual(google.calls("GET", "/drive/v3/files").last?.value("pageSize"), "10")

        let metadata = try json(try await call(center, "drive_get_file_metadata", ["fileId": .string("pdf-1")]))
        XCTAssertEqual(metadata["fileSize"], .string("8"))
        let permissions = try json(try await call(center, "drive_get_file_permissions", ["fileId": .string("doc-1")]))
        XCTAssertEqual(permissions["permissions"]?.arrayValue?.compactMap { $0["role"]?.stringValue }, ["owner", "reader"])

        // Reading: a Doc as Markdown with its comments, a Sheet as CSV, text as it is; a PDF is not text.
        let doc = try json(try await call(center, "drive_read_file_content", ["fileId": .string("doc-1"),
                                                                              "includeComments": .bool(true)]))
        XCTAssertEqual(doc["content"], .string("# Launch plan\n\n1. Ship\n"))
        XCTAssertEqual(doc["contentFormat"], .string("markdown"))
        XCTAssertEqual(google.calls("GET", "/drive/v3/files/doc-1/export").last?.value("mimeType"), "text/markdown")
        let thread = try XCTUnwrap(doc["commentThreads"]?.arrayValue?.first)
        XCTAssertEqual(thread["headPost"]?["content"], .string("Is this the final date?"))
        XCTAssertEqual(thread["headPost"]?["authorName"], .string("Bob"))
        XCTAssertEqual(thread["quotedText"], .string("1. Ship"))
        XCTAssertEqual(thread["replies"]?.arrayValue?.first?["content"], .string("Yes."))
        XCTAssertEqual(thread["status"], .string("OPEN"))
        let sheet = try json(try await call(center, "drive_read_file_content", ["fileId": .string("sheet-1")]))
        XCTAssertEqual(sheet["content"], .string("item,cost\nservers,120\n"))
        XCTAssertEqual(sheet["contentFormat"], .string("csv, first sheet"))
        let slides = try json(try await call(center, "drive_read_file_content", ["fileId": .string("slides-1")]))
        XCTAssertEqual(slides["content"], .string("Kickoff\nGoals"))
        let notes = try json(try await call(center, "drive_read_file_content", ["fileId": .string("notes-1")]))
        XCTAssertEqual(notes["content"], .string("# Notes\n- ship it\n"))
        XCTAssertEqual(google.calls("GET", "/drive/v3/files/notes-1").last?.value("alt"), "media")
        let pdf = try await call(center, "drive_read_file_content", ["fileId": .string("pdf-1")])
        XCTAssertTrue(pdf.isError)
        XCTAssertTrue(pdf.text.contains("download_file_content"), pdf.text)

        // Downloading: bytes as base64; a Google type exported, as text unless another type is asked.
        let bytes = try json(try await call(center, "drive_download_file_content", ["fileId": .string("pdf-1")]))
        XCTAssertEqual(bytes["base64Content"], .string(FakeGoogleWorkspace.pdfBytes.base64EncodedString()))
        XCTAssertEqual(bytes["mimeType"], .string("application/pdf"))
        let exported = try json(try await call(center, "drive_download_file_content", [
            "fileId": .string("doc-1"), "exportMimeType": .string("application/pdf")]))
        XCTAssertEqual(exported["mimeType"], .string("application/pdf"))
        // A revision ID Google would not take is refused before a request, as any other ID is.
        let badRevision = try await call(center, "drive_download_file_content", [
            "fileId": .string("pdf-1"), "revisionId": .string("r\u{1}?x")])
        XCTAssertTrue(badRevision.isError && badRevision.text.contains("Not an ID Google Drive takes"), badRevision.text)
        let huge = try await call(center, "drive_download_file_content", ["fileId": .string("huge-1")])
        XCTAssertTrue(huge.isError)
        XCTAssertFalse(google.calls("GET", "/drive/v3/files/huge-1").contains { $0.value("alt") == "media" },
                       "Too large is known from its size, before a download")

        // Creating: CSV content becomes a Sheet in one multipart upload; no content makes a Doc.
        let sheetMade = try json(try await call(center, "drive_create_file", [
            "title": .string("Costs"), "textContent": .string("a,b\n1,2\n"), "contentMimeType": .string("text/csv"),
            "parentId": .string("folder-9")
        ]))
        let upload = try XCTUnwrap(google.calls("POST", "/upload/drive/v3/files").last)
        XCTAssertEqual(upload.value("uploadType"), "multipart")
        let (sentMetadata, sentContent) = try XCTUnwrap(FakeGoogleWorkspace.multipart(
            upload.body, contentType: "multipart/related; boundary=\(try XCTUnwrap(Self.boundary(upload.body)))"))
        XCTAssertEqual(sentMetadata["mimeType"], .string(GoogleDriveToolCatalog.spreadsheet))
        XCTAssertEqual(sentMetadata["parents"], .array([.string("folder-9")]))
        XCTAssertEqual(sentContent, "a,b\n1,2\n")
        XCTAssertEqual(sheetMade["title"], .string("Costs"))
        let kept = try json(try await call(center, "drive_create_file", [
            "title": .string("raw.csv"), "textContent": .string("x"), "contentMimeType": .string("text/csv"),
            "disableConversionToGoogleType": .bool(true)
        ]))
        XCTAssertEqual(kept["mimeType"], .string("text/csv"))
        let emptyDoc = try json(try await call(center, "drive_create_file", ["title": .string("Notes")]))
        XCTAssertEqual(emptyDoc["mimeType"], .string(GoogleDriveToolCatalog.document))
        XCTAssertEqual(google.calls("POST", "/drive/v3/files").last?.json?["mimeType"], .string(GoogleDriveToolCatalog.document))

        let copied = try json(try await call(center, "drive_copy_file", ["fileId": .string("doc-1"), "title": .string("Plan v2")]))
        XCTAssertEqual(copied["title"], .string("Plan v2"))
        XCTAssertEqual(google.calls("POST", "/drive/v3/files/doc-1/copy").last?.json?["name"], .string("Plan v2"))

        // Changing: a file Yardlet made, renamed, moved, and given new content in one request.
        let changed = try json(try await call(center, "drive_update_file", [
            "fileId": .string("app-note"), "title": .string("Renamed"), "textContent": .string("new text"),
            "parentId": .string("folder-2")
        ]))
        let update = try XCTUnwrap(google.calls("PATCH", "/upload/drive/v3/files/app-note").last)
        XCTAssertEqual(update.value("addParents"), "folder-2")
        XCTAssertEqual(update.value("removeParents"), "folder-1")
        XCTAssertEqual(changed["title"], .string("Renamed"))
        // Someone else's file: `drive.file` gives no write access, and Google's words say so.
        let refused = try await call(center, "drive_update_file", ["fileId": .string("doc-1"), "title": .string("Mine now")])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.hasPrefix("Google Drive: The user has not granted the app"), refused.text)
        XCTAssertTrue(refused.text.hasSuffix("(HTTP 403)"), refused.text)

        let before = google.requests.count
        for arguments: [String: ToolJSON] in [["fileId": .string("app-note")],
                                              ["fileId": .string("x\ny")],
                                              ["fileId": .string("doc-1"), "textContent": .string("a"), "base64Content": .string("YQ==")]] {
            let result = try await call(center, "drive_update_file", arguments)
            XCTAssertTrue(result.isError, "\(arguments)")
        }
        let untyped = try await call(center, "drive_create_file", ["title": .string("x"), "base64Content": .string("YQ==")])
        XCTAssertTrue(untyped.isError, "base64 needs its type")
        XCTAssertEqual(google.requests.count, before)
    }

    /// Docs, Sheets, and Slides through the Drive connector, on Drive's own scopes: a document's
    /// structure with the indexes its requests take, values and formulas by range, slides with their
    /// object IDs and notes, each long one in parts, a thumbnail fetched with no token, and writes
    /// as the APIs' own batchUpdate requests, which Google lets Yardlet make only on its own files.
    func testDocsSheetsAndSlidesToolsReadInPartsAndWriteOnlyYardletsFiles() async throws {
        let google = FakeGoogleWorkspace()
        let (center, _) = try await signedIn(google: google)
        XCTAssertEqual(LocalConnectorService.googleDrive.scopes, [GoogleDriveToolCatalog.readScope, GoogleDriveToolCatalog.fileScope],
                       "No scope beyond Drive's")

        // A document: paragraphs with styles, a list item, a link and an image's one index, a table cell by cell.
        let doc = try json(try await call(center, "drive_read_doc", ["documentId": .string("https://docs.google.com/document/d/doc-1/edit"),
                                                                     "commentsIncluded": .bool(true)]))
        XCTAssertEqual(google.calls("GET", "/v1/documents/doc-1").last?.value("includeTabsContent"), "true")
        XCTAssertEqual(doc["documentId"], .string("doc-1"), "A link gives its ID")
        XCTAssertEqual(doc["revisionId"], .string("rev-7"))
        let content = try XCTUnwrap(doc["content"]?.arrayValue)
        XCTAssertEqual(content.map { $0["kind"]?.stringValue }, ["paragraph", "paragraph", "paragraph", "table", "paragraph"],
                       "The section break every body opens with is left out")
        XCTAssertEqual(content[0]["style"], .string("HEADING_1"))
        XCTAssertEqual(content[0]["text"], .string("Launch plan\n"))
        XCTAssertEqual(content[1]["bullet"]?["listId"], .string("kix.list1"))
        XCTAssertNil(content[1]["style"], "Normal text has no style line")
        let linked = try XCTUnwrap(content[2]["text"]?.stringValue)
        XCTAssertEqual(linked, "See spec\u{FFFC}\n")
        XCTAssertEqual(linked.utf16.count, 28 - 18, "The text is as long as its indexes")
        XCTAssertEqual(content[2]["links"]?.arrayValue?.first?["url"], .string("https://example.test/spec"))
        XCTAssertEqual(content[3]["cells"]?.arrayValue?[1].arrayValue?[0]["text"], .string("Servers\n"))
        XCTAssertEqual(content[3]["cells"]?.arrayValue?[1].arrayValue?[0]["startIndex"], .integer(44), "Where a cell's text starts")
        XCTAssertNil(doc["nextStartIndex"])
        XCTAssertNil(doc["tabs"], "One tab needs no list")
        XCTAssertEqual(doc["commentThreads"]?.arrayValue?.first?["headPost"]?["content"], .string("Is this the final date?"))

        // A long document in parts, each picking up where the last stopped.
        var start: Int?
        var paragraphs = 0
        var parts = 0
        repeat {
            var arguments: [String: ToolJSON] = ["documentId": .string("doc-long")]
            if let start { arguments["startIndex"] = .integer(Int64(start)) }
            let part = try json(try await call(center, "drive_read_doc", arguments))
            let items = try XCTUnwrap(part["content"]?.arrayValue)
            if let start { XCTAssertEqual(items.first?["startIndex"], .integer(Int64(start)), "Each part starts where the last stopped") }
            XCTAssertLessThanOrEqual(ConnectorToolArguments.text(.array(items)).count, 100_000)
            paragraphs += items.count
            parts += 1
            start = part["nextStartIndex"].flatMap { ConnectorToolArguments.integer($0) }
            if let start { XCTAssertEqual(items.last?["endIndex"], .integer(Int64(start))) }
        } while start != nil && parts < 10
        XCTAssertEqual(paragraphs, 2_000)
        XCTAssertGreaterThan(parts, 1)
        // Tabs, child tabs too, by ID.
        let tabs = try json(try await call(center, "drive_read_doc", ["documentId": .string("doc-tabs"), "tabId": .string("t.1")]))
        XCTAssertEqual(tabs["tabs"]?.arrayValue?.compactMap { $0["tabId"]?.stringValue }, ["t.0", "t.1"])
        XCTAssertEqual(tabs["content"]?.arrayValue?.first?["text"], .string("Child tab\n"))
        let noTab = try await call(center, "drive_read_doc", ["documentId": .string("doc-tabs"), "tabId": .string("t.9")])
        XCTAssertTrue(noTab.isError)

        // A spreadsheet: its sheets in a line each; asked for its grid, the Sheets API's JSON unless too large.
        let sheet = try json(try await call(center, "drive_get_spreadsheet", ["spreadsheetId": .string("sheet-1")]))
        XCTAssertEqual(google.calls("GET", "/v4/spreadsheets/sheet-1").last?.value("fields"), GoogleEditorsToolRunner.spreadsheetFields)
        XCTAssertEqual(sheet["title"], .string("Budget"))
        XCTAssertEqual(sheet["sheets"]?.arrayValue?.first, .object([
            "sheetId": .integer(0), "title": .string("Costs"), "index": .integer(0), "rowCount": .integer(1_000),
            "columnCount": .integer(26), "frozenRowCount": .integer(1)]))
        XCTAssertEqual(sheet["sheets"]?.arrayValue?.last?["sheetType"], .string("OBJECT"))
        let grid = try await call(center, "drive_get_spreadsheet", ["spreadsheetId": .string("sheet-1"), "includeGridData": .bool(true)])
        XCTAssertTrue(grid.isError)
        XCTAssertTrue(grid.text.contains("smaller range"), grid.text)
        // Values and formulas by range; a large range in parts.
        let formulas = try json(try await call(center, "drive_get_values", ["spreadsheetId": .string("sheet-1"), "range": .string("Costs!A1:B3"),
                                                                            "valueRenderOption": .string("FORMULA")]))
        let read = try XCTUnwrap(google.calls("GET", "/v4/spreadsheets/sheet-1/values/Costs%21A1%3AB3").last)
        XCTAssertEqual(read.value("valueRenderOption"), "FORMULA")
        XCTAssertEqual(formulas["values"]?.arrayValue?.last, .array([.string("total"), .string("=SUM(B2:B2)")]))
        let big = try json(try await call(center, "drive_get_values", ["spreadsheetId": .string("sheet-1"), "range": .string("Data!A1:D3000")]))
        let returned = try XCTUnwrap(big["rowsReturned"].flatMap { ConnectorToolArguments.integer($0) })
        XCTAssertLessThan(returned, 3_000)
        XCTAssertEqual(big["nextRange"], .string("Data!A\(1 + returned):D3000"))
        XCTAssertEqual(A1Range("'Q3 plan'!B2:F")?.rows(after: 5), "'Q3 plan'!B7:F")
        XCTAssertNil(A1Range("Sheet1!A1:B2")?.rows(after: 2))

        // Writing values as they are, formulas as typed, and the API's own requests; only on Yardlet's files.
        let wrote = try json(try await call(center, "drive_update_values", [
            "spreadsheetId": .string("app-sheet"), "range": .string("Costs!A2:B2"),
            "values": .array([.array([.string("=not a formula"), .integer(3)])])]))
        let put = try XCTUnwrap(google.calls("PUT", "/v4/spreadsheets/app-sheet/values/Costs%21A2%3AB2").last)
        XCTAssertEqual(put.value("valueInputOption"), "RAW")
        XCTAssertEqual(put.json?["values"], .array([.array([.string("=not a formula"), .integer(3)])]))
        XCTAssertEqual(wrote["updatedCells"], .integer(2))
        _ = try json(try await call(center, "drive_update_formulas", [
            "spreadsheetId": .string("app-sheet"), "range": .string("Costs!C2"), "formulas": .array([.array([.string("=A2*2")])])]))
        XCTAssertEqual(google.calls("PUT", "/v4/spreadsheets/app-sheet/values/Costs%21C2").last?.value("valueInputOption"), "USER_ENTERED")
        _ = try json(try await call(center, "drive_insert_dimension", [
            "spreadsheetId": .string("app-sheet"), "sheetId": .integer(0), "dimension": .string("ROWS"),
            "startIndex": .integer(1), "endIndex": .integer(3)]))
        XCTAssertEqual(google.calls("POST", "/v4/spreadsheets/app-sheet:batchUpdate").last?.json?["requests"], .array([.object([
            "insertDimension": .object(["range": .object(["sheetId": .integer(0), "dimension": .string("ROWS"),
                                                          "startIndex": .integer(1), "endIndex": .integer(3)])])])]))
        let added = try json(try await call(center, "drive_update_spreadsheet", [
            "spreadsheetId": .string("app-sheet"), "requests": .array([.object(["addSheet": .object(["properties": .object(["title": .string("Q4")])])])])]))
        XCTAssertEqual(added["replies"]?.arrayValue?.first?["addSheet"]?["properties"]?["sheetId"], .integer(123))
        let edited = try json(try await call(center, "drive_update_doc", [
            "documentId": .string("app-doc"),
            "requests": .array([.object(["insertText": .object(["location": .object(["index": .integer(1)]), "text": .string("Hi\n")])]),
                                .object(["updateParagraphStyle": .object([
                                    "range": .object(["startIndex": .integer(1), "endIndex": .integer(4)]),
                                    "paragraphStyle": .object(["namedStyleType": .string("HEADING_2")]),
                                    "fields": .string("namedStyleType")])])]),
            "writeControl": .object(["requiredRevisionId": .string("rev-7")])]))
        let docBatch = try XCTUnwrap(google.calls("POST", "/v1/documents/app-doc:batchUpdate").last?.json)
        XCTAssertEqual(docBatch["requests"]?.arrayValue?.count, 2)
        XCTAssertEqual(docBatch["writeControl"], .object(["requiredRevisionId": .string("rev-7")]))
        XCTAssertEqual(edited["writeControl"]?["requiredRevisionId"], .string("rev-8"))
        let refused = try await call(center, "drive_update_doc", [
            "documentId": .string("doc-1"), "requests": .array([.object(["insertText": .object(["text": .string("x")])])])])
        XCTAssertTrue(refused.isError)
        XCTAssertEqual(refused.text, "Google Drive: The caller does not have permission (HTTP 403)")
        let before = google.requests.count
        for (tool, arguments) in [
            ("drive_update_values", ["spreadsheetId": .string("app-sheet"), "range": .string("A1"), "values": .array([.string("flat")])]),
            ("drive_update_values", ["spreadsheetId": .string("app-sheet"), "range": .string("A1"), "values": .array([.array([.object([:])])])]),
            ("drive_update_doc", ["documentId": .string("app-doc"), "requests": .array([])]),
            ("drive_insert_dimension", ["spreadsheetId": .string("app-sheet"), "sheetId": .integer(0), "dimension": .string("ROWS"),
                                        "startIndex": .integer(3), "endIndex": .integer(3)]),
            ("drive_get_values", ["spreadsheetId": .string("sheet-1"), "range": .string("A1"), "valueRenderOption": .string("RAW")])
        ] as [(String, [String: ToolJSON])] {
            let result = try await call(center, tool, arguments)
            XCTAssertTrue(result.isError, "\(tool) \(arguments)")
        }
        XCTAssertEqual(google.requests.count, before, "Checked before any request")

        // Slides: each slide's layout, elements with IDs and text, and notes; a long deck in parts.
        let deck = try json(try await call(center, "drive_read_presentation", ["presentationId": .string("slides-1")]))
        XCTAssertEqual(google.calls("GET", "/v1/presentations/slides-1").last?.value("fields"), GoogleEditorsToolRunner.presentationFields)
        let slide = try XCTUnwrap(deck["slides"]?.arrayValue?.first)
        XCTAssertEqual(slide["objectId"], .string("p1"))
        XCTAssertEqual(slide["layout"], .string("Title and body"))
        XCTAssertEqual(slide["notes"], .string("Say hello\n"))
        XCTAssertEqual(slide["notesObjectId"], .string("p1-notes"))
        let elements = try XCTUnwrap(slide["elements"]?.arrayValue)
        XCTAssertEqual(elements.map { $0["kind"]?.stringValue }, ["shape", "shape", "image"])
        XCTAssertEqual(elements[0]["placeholder"], .string("TITLE"))
        XCTAssertEqual(elements[0]["text"], .string("Kickoff\n"))
        XCTAssertNil(elements[0]["size"], "Positions only for one slide")
        XCTAssertEqual(deck["slideCount"], .integer(2))
        let long = try json(try await call(center, "drive_read_presentation", ["presentationId": .string("deck-long")]))
        let nextSlide = try XCTUnwrap(long["nextStartSlide"].flatMap { ConnectorToolArguments.integer($0) })
        XCTAssertEqual(long["slides"]?.arrayValue?.count, nextSlide)
        let rest = try json(try await call(center, "drive_read_presentation", ["presentationId": .string("deck-long"),
                                                                               "startSlide": .integer(Int64(nextSlide))]))
        XCTAssertEqual(rest["slides"]?.arrayValue?.first?["index"], .integer(Int64(nextSlide)))
        let page = try json(try await call(center, "drive_read_slide_page", ["presentationId": .string("slides-1"), "pageId": .string("p2")]))
        XCTAssertEqual(page["elements"]?.arrayValue?.first?["size"]?["width"]?["magnitude"], .integer(3_000_000))
        XCTAssertEqual(page["layoutId"], .string("L1"))
        // A thumbnail: its size, and the image, fetched with no Google token.
        let thumbnail = try await call(center, "drive_read_slide_page_thumbnail", ["presentationId": .string("slides-1"), "pageId": .string("p1")])
        XCTAssertFalse(thumbnail.isError, thumbnail.text)
        XCTAssertEqual(google.calls("GET", "/v1/presentations/slides-1/pages/p1/thumbnail").last?.value("thumbnailProperties.thumbnailSize"),
                       "MEDIUM")
        XCTAssertEqual(thumbnail.content.last, .image(data: FakeGoogleWorkspace.pngBytes.base64EncodedString(), mimeType: "image/png"))
        let fetched = try XCTUnwrap(google.calls("GET", "/p1.png").last)
        XCTAssertNil(fetched.account, "No Authorization header to the image's address")
        let created = try json(try await call(center, "drive_update_presentation", [
            "presentationId": .string("app-deck"),
            "requests": .array([.object(["createSlide": .object(["slideLayoutReference": .object(["predefinedLayout": .string("TITLE_AND_BODY")])])])])]))
        XCTAssertEqual(created["replies"]?.arrayValue?.first?["createSlide"]?["objectId"], .string("new-slide"))
    }

    private static func boundary(_ body: Data?) -> String? {
        guard let first = body.flatMap({ String(decoding: $0, as: UTF8.self).components(separatedBy: "\r\n").first }),
              first.hasPrefix("--") else { return nil }
        return String(first.dropFirst(2))
    }

    // MARK: - Asking before writes

    func testWritesAskInEveryHarnessAndReadsDoNot() async throws {
        let (center, _) = try await signedIn()
        XCTAssertEqual(GoogleCalendarToolCatalog.approvalRequired,
                       ["create_event", "update_event", "delete_event", "respond_to_event"])
        XCTAssertEqual(GoogleDriveToolCatalog.approvalRequired, ["create_file", "copy_file", "update_file", "update_doc",
                                                                 "update_values", "update_formulas", "insert_dimension",
                                                                 "update_spreadsheet", "update_presentation"])
        for tool in GoogleCalendarToolCatalog.tools + GoogleDriveToolCatalog.tools {
            let name = try XCTUnwrap(tool["name"]?.stringValue)
            let writes = GoogleCalendarToolCatalog.approvalRequired.contains(name) || GoogleDriveToolCatalog.approvalRequired.contains(name)
            XCTAssertEqual(tool["annotations"]?["readOnlyHint"], .bool(!writes), name)
            let description = tool["description"]?.stringValue ?? ""
            XCTAssertLessThan(description.count, 260, description)
            for word in ["always", "must", "should", "IMPORTANT", "NEVER"] {
                XCTAssertFalse(description.contains(word), "Neutral wording: \(description)")
            }
        }
        XCTAssertEqual(GoogleCalendarToolCatalog.tools.first { $0["name"] == .string("delete_event") }?["annotations"]?["destructiveHint"],
                       .bool(true))

        // Claude Code: none is allowed up front, so the CLI asks before each.
        XCTAssertFalse(AgentToolServerLaunch.claudeAllowedTools.contains { $0.contains("calendar") || $0.contains("drive") })

        // Codex: the writes ask every time; reading does not.
        let broker = AgentToolBroker(
            environment: AgentToolBroker.Environment(executableURL: try makeExecutable(), endpoint: "/tmp/unused.sock",
                                                     privateDirectory: FileManager.default.temporaryDirectory,
                                                     isEnabled: { false }),
            tools: BrowserAgentTools(usesMacEditingCommands: true, pages: { _ in throw CancellationError() }, closePage: { _ in }))
        broker.connectors = center
        let launch = try XCTUnwrap(broker.agentToolServer(for: UUID(), workspaceRoots: [],
                                                          connectorScope: ConnectorTaskScope(harness: .codex)))
        // Codex asks as the task's approval setting has it (2026-10-22): no per-tool mode of Yardlet's.
        XCTAssertNil(launch.codexConfig["mcp_servers"]?["yardlet"]?["tools"])

        // Claude Code's card: the account and what the call would do, with no "always allow".
        let create = try XCTUnwrap(GoogleToolApproval.request(toolName: "mcp__yardlet__calendar_create_event", input: .object(["account": .string("person@example.test"), 
            "summary": .string("Yardlet sync"), "startTime": .string("2026-10-23T15:00:00"), "endTime": .string("2026-10-23T15:30:00"),
            "attendees": .array([.object(["email": .string("bob@example.com")])]), "addGoogleMeetUrl": .bool(true)
        ])))
        XCTAssertEqual(create.title, L10n.format("Allow Claude to create an event in %@'s calendar?", "person@example.test"))
        for part in [L10n.format("Title: %@", "Yardlet sync"), L10n.format("Invites: %@", "bob@example.com"),
                     L10n.string("Adds a Google Meet link."), L10n.string("Google emails the guests.")] {
            XCTAssertTrue(create.detail.contains(part), "\(part) in \(create.detail)")
        }
        let delete = try XCTUnwrap(GoogleToolApproval.request(toolName: "mcp__yardlet__calendar_delete_event",
                                                              input: .object(["account": .string("person@example.test"), "eventId": .string("e1"), "notificationLevel": .string("NONE")])))
        XCTAssertEqual(delete.title, L10n.format("Allow Claude to delete an event from %@'s calendar?", "person@example.test"))
        XCTAssertTrue(delete.detail.contains(L10n.string("Google emails no one about it.")))
        let respond = try XCTUnwrap(GoogleToolApproval.request(toolName: "mcp__yardlet__calendar_respond_to_event",
                                                               input: .object(["account": .string("person@example.test"), "eventId": .string("e1"), "responseStatus": .string("declined")])))
        XCTAssertEqual(respond.title, L10n.format("Allow Claude to answer an invitation as %@?", "person@example.test"))
        XCTAssertTrue(respond.detail.contains(L10n.format("Answer: %@", L10n.string("Not going"))), respond.detail)
        let file = try XCTUnwrap(GoogleToolApproval.request(toolName: "mcp__yardlet__drive_create_file", input: .object(["account": .string("person@example.test"), 
            "title": .string("Costs"), "textContent": .string("a,b\n1,2"), "contentMimeType": .string("text/csv")
        ])))
        XCTAssertEqual(file.title, L10n.format("Allow Claude to create a file in %@'s Drive?", "person@example.test"))
        XCTAssertTrue(file.detail.contains("a,b\n1,2"), file.detail)
        XCTAssertEqual(GoogleToolApproval.request(toolName: "mcp__yardlet__drive_update_file", input: .object(["account": .string("person@example.test")]))?.title,
                       L10n.format("Allow Claude to change a file in %@'s Drive?", "person@example.test"))
        // A change inside a Doc, Sheet, or Slides file: which file, the kinds of change, and what it writes.
        let docCard = try XCTUnwrap(GoogleToolApproval.request(toolName: "mcp__yardlet__drive_update_doc", input: .object(["account": .string("person@example.test"), 
            "documentId": .string("app-doc"),
            "requests": .array([.object(["insertText": .object(["text": .string("New intro")])]),
                                .object(["insertText": .object(["text": .string("More")])]),
                                .object(["updateParagraphStyle": .object([:])])])
        ])))
        XCTAssertEqual(docCard.title, L10n.format("Allow Claude to change a document in %@'s Drive?", "person@example.test"))
        for part in [L10n.format("File %@", "app-doc"), L10n.format("Changes: %@", "insertText ×2, updateParagraphStyle"), "New intro"] {
            XCTAssertTrue(docCard.detail.contains(part), "\(part) in \(docCard.detail)")
        }
        let cells = try XCTUnwrap(GoogleToolApproval.request(toolName: "mcp__yardlet__drive_update_values", input: .object(["account": .string("person@example.test"), 
            "spreadsheetId": .string("app-sheet"), "range": .string("Costs!A2:B2"),
            "values": .array([.array([.string("servers"), .integer(120)])])
        ])))
        XCTAssertEqual(cells.title, L10n.format("Allow Claude to change a spreadsheet in %@'s Drive?", "person@example.test"))
        XCTAssertTrue(cells.detail.contains(L10n.format("Range: %@", "Costs!A2:B2")), cells.detail)
        XCTAssertTrue(cells.detail.contains("servers\t120"), cells.detail)
        let rows = try XCTUnwrap(GoogleToolApproval.request(toolName: "mcp__yardlet__drive_insert_dimension", input: .object(["account": .string("person@example.test"), 
            "spreadsheetId": .string("app-sheet"), "dimension": .string("ROWS"), "startIndex": .integer(1), "endIndex": .integer(3)
        ])))
        XCTAssertTrue(rows.detail.contains(L10n.format("Inserts %lld rows.", Int64(2))), rows.detail)
        XCTAssertEqual(GoogleToolApproval.request(toolName: "mcp__yardlet__drive_update_presentation", input: .object(["account": .string("person@example.test")]))?.title,
                       L10n.format("Allow Claude to change a presentation in %@'s Drive?", "person@example.test"))
        XCTAssertNotNil(GoogleToolApproval.request(toolName: "mcp__yardlet__gmail_send_message", input: .object(["account": .string("person@example.test")])),
                        "Gmail's cards come through the same place")
        for read in ["mcp__yardlet__calendar_list_events", "mcp__yardlet__drive_read_file_content", "mcp__yardlet__drive_read_doc",
                     "mcp__yardlet__drive_get_values", "mcp__yardlet__drive_read_slide_page_thumbnail",
                     "mcp__claude_ai_Google_Calendar__create_event"] {
            XCTAssertNil(GoogleToolApproval.request(toolName: read, input: .object([:])), read)
        }

        // Through the Claude adapter: the delete card has no "always allow"; a read keeps the CLI's offer.
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport })
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/workspace"), initialPrompt: nil))
        let recorder = PermissionRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                if case let .permissionRequested(request) = event.payload { await recorder.append(request) }
            }
        }
        defer { collector.cancel() }
        for (id, tool) in [("delete-1", "mcp__yardlet__calendar_delete_event"), ("read-1", "mcp__yardlet__calendar_list_events")] {
            let suggestion: JSONValue = .object([
                "type": .string("addRules"), "destination": .string("session"), "behavior": .string("allow"),
                "rules": .array([.object(["toolName": .string(tool)])])
            ])
            await transport.emit(.object([
                "type": .string("control_request"), "request_id": .string(id),
                "request": .object(["subtype": .string("can_use_tool"), "tool_name": .string(tool),
                                    "input": .object(["account": .string("person@example.test"), "eventId": .string("e1")]),
                                    "tool_use_id": .string("toolu-\(id)"),
                                    "permission_suggestions": .array([suggestion])])
            ]))
        }
        let deleteCard = try await recorder.waitFor("delete-1")
        XCTAssertEqual(deleteCard.title, delete.title)
        XCTAssertTrue(deleteCard.actions.isEmpty, "No always-allow: \(deleteCard.actions.map(\.id))")
        let readCard = try await recorder.waitFor("read-1")
        XCTAssertFalse(readCard.actions.isEmpty, "Reading is the CLI's ordinary card")
        await adapter.close(handle)
    }

    // MARK: - Two accounts

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
        XCTAssertEqual(both.count, 9 + 9 + 21)
        func accounts(_ tools: [ToolJSON], _ name: String) -> ToolJSON? {
            tools.first { $0["name"] == .string(name) }?["inputSchema"]?["properties"]?["account"]?["enum"]
        }
        XCTAssertEqual(accounts(both, "calendar_list_calendars"),
                       .array([.string("person@example.test"), .string("developer@company.test")]))
        XCTAssertEqual(accounts(both, "gmail_list_labels"), .array([.string("person@example.test")]))
        _ = try json(try await call(center, "calendar_list_calendars", ["account": .string("person@example.test")]))
        XCTAssertEqual(google.requests.last?.account, "person@example.test")
        let theirs = try json(try await call(center, "calendar_list_calendars", ["account": .string("developer@company.test")]))
        XCTAssertEqual(google.requests.last?.account, "developer@company.test")
        XCTAssertEqual(theirs["calendars"]?.arrayValue?.first?["id"], .string("developer@company.test"))

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

    func testDriveQueriesTranslateGooglesTermsToTheDriveAPI() {
        XCTAssertEqual(DriveQuery.translate(""), "trashed = false")
        XCTAssertEqual(DriveQuery.translate("mimeType = 'application/pdf' and modifiedTime > '2026-01-01T00:00:00Z'"),
                       "(mimeType = 'application/pdf' and modifiedTime > '2026-01-01T00:00:00Z') and trashed = false")
        XCTAssertEqual(DriveQuery.translate("title = 'It\\'s here' or (starred = true and sharedWithMe = true)"),
                       "(name = 'It\\'s here' or (starred = true and sharedWithMe = true)) and trashed = false")
        XCTAssertEqual(DriveQuery.translate("fullText contains 'title' and trashed = true"),
                       "fullText contains 'title' and trashed = true", "A word inside quotes stays; asking about trash is kept")
        XCTAssertEqual(DriveQuery.translate("budget 2026"), "fullText contains 'budget 2026' and trashed = false")
        XCTAssertEqual(DriveQuery.translate("plan in progress"), "fullText contains 'plan in progress' and trashed = false")
        XCTAssertEqual(DriveQuery.translate("'folder-1' in parents"), "('folder-1' in parents) and trashed = false")
    }

    private func makeExecutable() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "yardlet-mcp-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private actor PermissionRecorder {
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
