import Foundation
import XCTest
@testable import NativeHarnessClient

/// The calendar's center: a calendar that reaches Yardlet both through its connector and
/// through the Mac's Calendar app is shown once, from the connector; a calendar of another account with the same
/// name is not taken for it; the Mac's copy stands in while the connector cannot read; nothing is read while no
/// screen shows the calendar, and turning it off forgets everything; an invitation is answered on its own service.
/// The services are fakes here (`FakeCalendarService`): nothing leaves the machine and no calendar of this Mac is read.
@MainActor
final class CalendarCenterTests: XCTestCase {
    private let google = CalendarAccount(id: UUID(), provider: .google, address: "person@example.test", connectorSlug: "calendar")
    private let mac = CalendarAccount(id: UUID(), provider: .apple, connectorSlug: "apple_calendar")
    private let day = DateInterval(start: Date(timeIntervalSince1970: 1_793_000_000), duration: 86_400)

    /// A Google account with its primary calendar and Team, and the Mac's Calendar, which has the same two (the
    /// account added there too, its address in other letters), a Home calendar of iCloud, and another account's Team.
    private func services() -> (FakeCalendarService, FakeCalendarService) {
        let direct = FakeCalendarService(account: google)
        let primary = direct.add("person@example.test", isPrimary: true)
        let team = direct.add("Team")
        direct.add(event: "Standup", hour: 9, to: primary, day: day)
        direct.add(event: "Planning", hour: 14, to: team, day: day, response: .needsAction)

        let apple = FakeCalendarService(account: mac)
        let primaryCopy = apple.add("person@example.test", source: "Person@Example.test", isPrimary: true)
        let teamCopy = apple.add("Team", source: "person@example.test")
        let home = apple.add("Home", source: "iCloud")
        let otherTeam = apple.add("Team", source: "other@example.test")
        apple.add(event: "Standup", hour: 9, to: primaryCopy, day: day)
        apple.add(event: "Planning", hour: 14, to: teamCopy, day: day)
        apple.add(event: "Dinner", hour: 19, to: home, day: day)
        apple.add(event: "Review", hour: 11, to: otherTeam, day: day)
        return (direct, apple)
    }

    private func center(_ services: FakeCalendarService...) -> CalendarCenter {
        let center = CalendarCenter()
        center.setEnabled(true)
        center.setAccounts(services.map { ($0.account, $0) })
        return center
    }

    func testACalendarThatComesBothWaysIsShownOnceFromItsConnector() async throws {
        let (direct, apple) = services()
        let center = center(direct, apple)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(direct.reads + apple.reads, 0, "Turned on, nothing is read until a screen shows the calendar")

        let screen = UUID()
        center.show(day, for: screen)
        try await waitUntil { !center.events(in: day).isEmpty }
        let events = center.events(in: day)
        XCTAssertEqual(events.map(\.title), ["Standup", "Review", "Planning", "Dinner"])
        XCTAssertEqual(events.first { $0.title == "Standup" }?.id.calendar.accountID, google.id, "The connector's, which answers invitations")
        XCTAssertEqual(events.first { $0.title == "Review" }?.id.calendar.accountID, mac.id, "Another account's Team is its own")
        XCTAssertEqual(center.calendars.map(\.name), ["person@example.test", "Team", "Home", "Team"])
        XCTAssertEqual(center.calendars.last?.source, "other@example.test")

        // Another screen showing the same days within the refresh interval reads nothing again.
        let reads = direct.reads + apple.reads
        center.show(day, for: UUID())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(direct.reads + apple.reads, reads)
    }

    func testTheMacCopyStandsInWhileItsConnectorCannotRead() async throws {
        let (direct, apple) = services()
        let team = try XCTUnwrap(direct.calendarIDs.last)
        direct.failing = [team]
        let center = center(direct, apple)
        center.show(day, for: UUID())
        try await waitUntil { !center.events(in: day).isEmpty }
        let planning = try XCTUnwrap(center.events(in: day).first { $0.title == "Planning" })
        XCTAssertEqual(planning.id.calendar.accountID, mac.id, "Google could not read Team, so the Mac's copy shows")
        XCTAssertEqual(center.events(in: day).filter { $0.title == "Standup" }.map(\.id.calendar.accountID), [google.id])

        // A sign-in that ended: every calendar of the account comes from the Mac until it is signed in again.
        direct.failing = []
        direct.refusesSignIn = true
        await center.refresh()
        XCTAssertEqual(center.failures[google.id]?.kind, .signInRequired)
        XCTAssertEqual(Set(center.events(in: day).map(\.id.calendar.accountID)), [mac.id])
        XCTAssertEqual(center.events(in: day).filter { $0.title == "Standup" }.count, 1)
        XCTAssertEqual(center.calendars.filter { $0.id.accountID == mac.id }.map(\.name), ["person@example.test", "Team", "Home", "Team"])

        direct.refusesSignIn = false
        await center.refresh()
        XCTAssertNil(center.failures[google.id])
        XCTAssertEqual(center.events(in: day).filter { $0.title != "Dinner" && $0.title != "Review" }.map(\.id.calendar.accountID),
                       [google.id, google.id])
    }

    func testTurningOffForgetsEverythingAndReadsNothing() async throws {
        let (direct, apple) = services()
        let center = center(direct, apple)
        let screen = UUID()
        center.show(day, for: screen)
        try await waitUntil { !center.events(in: day).isEmpty }

        center.setEnabled(false)
        XCTAssertTrue(center.accounts.isEmpty)
        XCTAssertTrue(center.calendars.isEmpty)
        XCTAssertTrue(center.accountCalendars.isEmpty)
        XCTAssertTrue(center.shownEvents.isEmpty)
        XCTAssertTrue(center.failures.isEmpty)

        let reads = direct.reads + apple.reads
        center.show(day, for: screen)
        center.setAccounts([(direct.account, direct), (apple.account, apple)])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(direct.reads + apple.reads, reads, "Off, nothing is read")
        XCTAssertTrue(center.accounts.isEmpty)

        // On again, a screen that stops showing the calendar stops its reading.
        center.setEnabled(true)
        center.refreshInterval = .milliseconds(30)
        center.setAccounts([(direct.account, direct), (apple.account, apple)])
        center.show(day, for: screen)
        try await waitUntil { direct.reads + apple.reads > reads + 10 }
        center.stopShowing(for: screen)
        try await Task.sleep(for: .milliseconds(40))
        let stopped = direct.reads + apple.reads
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(direct.reads + apple.reads, stopped, "No screen shows the calendar, so nothing is read again")
    }

    func testAnInvitationIsAnsweredOnItsOwnService() async throws {
        let (direct, apple) = services()
        let outlook = FakeCalendarService(account: CalendarAccount(id: UUID(), provider: .outlook, address: "person@contoso.test"))
        let work = outlook.add("Calendar", isPrimary: true)
        outlook.add(event: "Budget", hour: 16, to: work, day: day, response: .needsAction)
        let center = center(direct, apple, outlook)
        center.show(day, for: UUID())
        try await waitUntil { center.events(in: day).count == 5 }

        let budget = try XCTUnwrap(center.events(in: day).first { $0.title == "Budget" })
        XCTAssertTrue(budget.awaitsAnswer)
        try await center.respond(to: budget, .accepted)
        XCTAssertEqual(outlook.answers, [budget.id.eventID + " accepted"])
        XCTAssertEqual(direct.answers, [])
        XCTAssertEqual(center.events(in: day).first { $0.title == "Budget" }?.response, .accepted, "Shown at once")

        let dinner = try XCTUnwrap(center.events(in: day).first { $0.title == "Dinner" })
        do {
            try await center.respond(to: dinner, .declined)
            XCTFail("The Mac's calendars cannot answer invitations")
        } catch {}
        XCTAssertEqual(apple.answers, [])
    }
}

/// A calendar service for the calendar's tests: its calendars and events kept here, every read counted, and a
/// calendar or the whole account made to fail.
final class FakeCalendarService: CalendarAccountTransport, @unchecked Sendable {
    let account: CalendarAccount
    private let lock = NSLock()
    private var calendarList: [CalendarInfo] = []
    private var eventsByCalendar: [String: [CalendarEvent]] = [:]
    private var readCount = 0
    private var failingIDs: Set<String> = []
    private var refused = false
    private var answered: [String] = []

    init(account: CalendarAccount) {
        self.account = account
    }

    var reads: Int { lock.withLock { readCount } }
    var answers: [String] { lock.withLock { answered } }
    var calendarIDs: [String] { lock.withLock { calendarList.map(\.id.calendarID) } }
    /// Calendars whose events cannot be read.
    var failing: Set<String> {
        get { lock.withLock { failingIDs } }
        set { lock.withLock { failingIDs = newValue } }
    }
    /// The account's sign-in ended: nothing of it can be read.
    var refusesSignIn: Bool {
        get { lock.withLock { refused } }
        set { lock.withLock { refused = newValue } }
    }

    @discardableResult
    func add(_ name: String, source: String? = nil, isPrimary: Bool = false, color: String? = nil) -> CalendarKey {
        lock.withLock {
            let key = CalendarKey(accountID: account.id, calendarID: "\(name)-\(calendarList.count)")
            calendarList.append(CalendarInfo(id: key, name: name, color: color, isPrimary: isPrimary, source: source))
            return key
        }
    }

    /// An event `hour` hours into the day, or the whole day.
    func add(event title: String, hour: Double, minutes: Double = 60, to calendar: CalendarKey, day: DateInterval,
             response: CalendarResponse? = nil, allDay: Bool = false, notes: String? = nil, organizer: CalendarPerson? = nil,
             attendees: [CalendarPerson] = [], conference: URL? = nil) {
        lock.withLock {
            let start = allDay ? day.start : day.start.addingTimeInterval(hour * 3_600)
            let event = CalendarEvent(id: CalendarEventKey(calendar: calendar, eventID: "\(title)-\(calendar.calendarID)"),
                                      title: title, start: start, end: allDay ? day.end : start.addingTimeInterval(minutes * 60),
                                      isAllDay: allDay, notes: notes, organizer: organizer, attendees: attendees, response: response,
                                      conferenceURL: conference,
                                      webURL: account.provider == .apple ? nil : URL(string: "https://calendar.example.test/event"))
            eventsByCalendar[calendar.calendarID, default: []].append(event)
        }
    }

    func calendars() async throws -> [CalendarInfo] {
        try lock.withLock {
            readCount += 1
            if refused { throw OAuthAPISession.Failure.signInRequired }
            return calendarList
        }
    }

    func events(in calendar: CalendarInfo, from start: Date, to end: Date) async throws -> [CalendarEvent] {
        try lock.withLock {
            readCount += 1
            if refused { throw OAuthAPISession.Failure.signInRequired }
            if failingIDs.contains(calendar.id.calendarID) {
                throw CalendarFailure(kind: .unavailable, message: "The calendar could not be read.")
            }
            return (eventsByCalendar[calendar.id.calendarID] ?? []).filter { $0.start < end && $0.end > start }
        }
    }

    /// The answer is kept on the event, as the service keeps it.
    func respond(to event: CalendarEvent, _ response: CalendarResponse) async throws {
        lock.withLock {
            answered.append("\(event.id.eventID) \(response.rawValue)")
            let calendar = event.id.calendar.calendarID
            if let index = eventsByCalendar[calendar]?.firstIndex(where: { $0.id == event.id }) {
                eventsByCalendar[calendar]?[index].response = response
            }
        }
    }
}
