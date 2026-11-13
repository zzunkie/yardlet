import Foundation

/// The calendar's Mac calendars: every account added to Calendar on this Mac (iCloud, Exchange, CalDAV, a Google
/// account added there), through the same store the Apple Calendar connector's tools use (`MacDataStoring`,
/// EventKit on the Mac). It only reads while macOS lets Yardlet reach the calendars and never asks: macOS asked
/// once, when the connector was turned on. EventKit cannot answer invitations.
struct MacCalendarTransport: CalendarAccountTransport {
    let store: any MacDataStoring
    let account: CalendarAccount

    /// Every event calendar, the one new events go to first; each names the account Calendar keeps it in.
    func calendars() async throws -> [CalendarInfo] {
        let calendars = try read { try store.calendars(.calendars) }.map { calendar in
            CalendarInfo(id: CalendarKey(accountID: account.id, calendarID: calendar.id), name: calendar.title,
                         color: calendar.color, isPrimary: calendar.isDefault, source: calendar.account)
        }
        return calendars.filter(\.isPrimary) + calendars.filter { !$0.isPrimary }
    }

    /// EventKit ends an all-day event within its last day; the calendar's end is the midnight after it.
    func events(in calendar: CalendarInfo, from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let days = Calendar.current
        return try read { try store.events(from: start, to: end, calendarIDs: [calendar.id.calendarID]) }.map { event in
            let last = days.startOfDay(for: max(event.start, event.end.addingTimeInterval(-1)))
            return CalendarEvent(
                id: CalendarEventKey(calendar: calendar.id, eventID: event.id, occurrence: event.occurrence),
                title: event.title,
                start: event.start,
                end: event.allDay ? days.date(byAdding: .day, value: 1, to: last) ?? event.end : event.end,
                isAllDay: event.allDay,
                location: event.location.flatMap { $0.isEmpty ? nil : $0 },
                notes: event.notes.flatMap { $0.isEmpty ? nil : String($0.prefix(CalendarEvent.notesLimit)) },
                organizer: event.organizer.map(Self.person),
                attendees: event.attendees.map(Self.person))
        }
    }

    func respond(to event: CalendarEvent, _ response: CalendarResponse) async throws {
        throw CalendarFailure(kind: .unavailable, message: L10n.string("Answer this invitation in Calendar."))
    }

    private func read<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let failure as MacDataError {
            throw CalendarFailure(kind: .unavailable, message: failure.localizedDescription)
        }
    }

    private static func person(_ person: MacEvent.Person) -> CalendarPerson {
        CalendarPerson(name: person.name, email: person.email, response: person.status.flatMap { status in
            switch status {
            case "accepted": .accepted
            case "declined": .declined
            case "tentative": .tentative
            case "pending": .needsAction
            default: nil
            }
        })
    }
}
