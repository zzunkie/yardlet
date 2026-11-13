import Foundation

/// The service a calendar account is read through: Google Calendar, Outlook through Microsoft Graph, or the
/// Mac's own calendars through EventKit (the iCloud, Exchange, CalDAV and other accounts added to Calendar).
enum CalendarProvider: String, Hashable, Sendable {
    case google
    case outlook
    case apple

    /// The service's name as people know it.
    var serviceName: String {
        switch self {
        case .google: "Google Calendar"
        case .outlook: "Outlook Calendar"
        case .apple: "Apple Calendar"
        }
    }

    /// Whether Yardlet can answer an invitation through it: EventKit offers no way to.
    var answersInvitations: Bool { self != .apple }
}

/// One account the calendar shows: a calendar connector connected in Settings › Connectors. `id` is the
/// connector's sign-in for Google and Outlook (`ConnectorRecord.credentialID`), so the calendar and the agents'
/// tools share it, and the connector's own ID for the Mac's calendars.
struct CalendarAccount: Identifiable, Hashable, Sendable {
    let id: UUID
    let provider: CalendarProvider
    /// The account's address; nil for the Mac's calendars, which hold several accounts.
    var address: String?
    /// The prefix of the tools by which an agent reads the account's calendar (`calendar`), which its service's
    /// accounts share: a call names the account by its address.
    var connectorSlug: String? = nil

    /// The address, or the service for the Mac's calendars.
    var displayName: String { address ?? provider.serviceName }
}

/// A calendar across all accounts: the account it belongs to and the service's own calendar ID.
struct CalendarKey: Hashable, Sendable {
    let accountID: UUID
    let calendarID: String
}

/// A calendar of an account, as its service lists it.
struct CalendarInfo: Identifiable, Hashable, Sendable {
    let id: CalendarKey
    /// The name the person sees in the service's own app.
    var name: String
    /// The service's own name for it when the person gave it another (Google's name under a renamed calendar).
    var serviceName: String? = nil
    /// Its color as `#RRGGBB`, where the service gives one.
    var color: String? = nil
    /// The account's main calendar.
    var isPrimary = false
    /// Whether it is shown before the person chooses: Google's own choice in its calendar list, every calendar
    /// elsewhere.
    var isShownByDefault = true
    /// For one of the Mac's calendars, the account Calendar keeps it in, as Calendar names it: an address for a
    /// Google or Exchange account, or "iCloud" or "On My Mac".
    var source: String? = nil
}

/// How the account answered an invitation.
enum CalendarResponse: String, Hashable, Sendable {
    case needsAction
    case accepted
    case declined
    case tentative
}

struct CalendarPerson: Hashable, Sendable {
    var name: String?
    var email: String?
    /// Their answer, where the service gives one.
    var response: CalendarResponse?

    /// The name when the service gave one, else the address.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return email ?? ""
    }
}

/// An event across all accounts: its calendar, the service's event ID, and for the Mac's calendars the start
/// of the occurrence when it is one of a recurring event's (Google and Outlook give each occurrence an ID).
struct CalendarEventKey: Hashable, Sendable {
    let calendar: CalendarKey
    let eventID: String
    var occurrence: Date? = nil
}

/// One event, or one occurrence of a recurring event, as the calendar shows it. Events are read only for the
/// days a screen shows and kept in memory only.
struct CalendarEvent: Identifiable, Hashable, Sendable {
    let id: CalendarEventKey
    /// The event's title as the service gives it; empty when it has none.
    var title: String
    var start: Date
    /// The end, not included: for an all-day event, the midnight after its last day.
    var end: Date
    var isAllDay: Bool
    var location: String? = nil
    /// Its description, as text and cut to `CalendarEvent.notesLimit`.
    var notes: String? = nil
    var organizer: CalendarPerson? = nil
    var attendees: [CalendarPerson] = []
    /// The account's own answer when it was invited; nil when it was not, or organizes it.
    var response: CalendarResponse? = nil
    /// Where to join the meeting online.
    var conferenceURL: URL? = nil
    /// The event on the service's own web app.
    var webURL: URL? = nil

    static let notesLimit = 4_000

    /// An invitation the account has not answered yet.
    var awaitsAnswer: Bool { response == .needsAction }

    func overlaps(_ range: DateInterval) -> Bool {
        start < range.end && end > range.start
    }
}

/// Why a calendar could not be read, in words the calendar shows.
struct CalendarFailure: Error, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case signInRequired
        case unavailable
    }

    var kind: Kind
    var message: String
}

extension CalendarFailure: LocalizedError {
    var errorDescription: String? { message }
}

/// How the calendar reaches one account's service. Each provider has one: the Google Calendar API, Microsoft
/// Graph, or EventKit. It reads only the days asked for and changes only what the person asks.
protocol CalendarAccountTransport: Sendable {
    /// The account's calendars, its main calendar first.
    func calendars() async throws -> [CalendarInfo]
    /// One calendar's events that overlap the range, a recurring event as its occurrences.
    func events(in calendar: CalendarInfo, from start: Date, to end: Date) async throws -> [CalendarEvent]
    /// Answers the account's invitation to an event on its service, telling the organizer.
    func respond(to event: CalendarEvent, _ response: CalendarResponse) async throws
}

extension DateInterval {
    /// Whether `other` lies within this interval.
    func contains(_ other: DateInterval) -> Bool {
        start <= other.start && end >= other.end
    }
}
