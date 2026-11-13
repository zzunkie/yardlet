import Foundation
import YardletAgentTools

/// The Google Calendar API v3 requests (developers.google.com/workspace/calendar/api/v3/reference) that the
/// calendar (`GoogleCalendarTransport`) and the agents' Calendar tools (`GoogleCalendarToolRunner`) share, for one
/// account through its connector sign-in. IDs are encoded here, so a calendar ID with `@` and `#` is one path
/// segment, and refused before any request when no request can carry them.
struct GoogleCalendarAPI: Sendable {
    let rest: GoogleREST

    /// `calendarList.list`: the calendars in the account's list.
    func calendarList(maxResults: Int, pageToken: String? = nil) async throws -> ToolJSON {
        var query = [URLQueryItem(name: "maxResults", value: String(maxResults))]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return try await rest.get(["users", "me", "calendarList"], query)
    }

    /// `events.list` of one calendar between two times, a recurring event as its occurrences, by start or, with
    /// `byUpdate`, by last change. `extra` carries the tools' search and filters.
    func events(calendar: String, from start: Date, to end: Date, zone: TimeZone, maxResults: Int,
                byUpdate: Bool = false, extra: [URLQueryItem] = [], pageToken: String? = nil) async throws -> ToolJSON {
        let calendar = try GoogleREST.segment(calendar)
        var query = [
            URLQueryItem(name: "timeMin", value: CalendarTime.rfc3339(start, in: zone)),
            URLQueryItem(name: "timeMax", value: CalendarTime.rfc3339(end, in: zone)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
            URLQueryItem(name: "timeZone", value: zone.identifier),
            URLQueryItem(name: "orderBy", value: byUpdate ? "updated" : "startTime")
        ] + extra
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return try await rest.get(["calendars", calendar, "events"], query)
    }

    /// `events.get`.
    func event(calendar: String, id: String) async throws -> ToolJSON {
        try await rest.get(["calendars", try GoogleREST.segment(calendar), "events", try GoogleREST.segment(id)])
    }

    /// Answers the account's own invitation: its attendee entry, and only it, changes. An event the account was
    /// not invited to has no entry to answer. `notifications` says whom Google tells (`sendUpdates`).
    func respond(calendar: String, event: String, status: String, comment: String?,
                 notifications: [URLQueryItem]) async throws -> ToolJSON {
        let calendar = try GoogleREST.segment(calendar), event = try GoogleREST.segment(event)
        let current = try await rest.get(["calendars", calendar, "events", event])
        var attendees = current["attendees"]?.arrayValue ?? []
        guard let index = attendees.firstIndex(where: { $0["self"] == .bool(true) }),
              var me = attendees[index].objectValue else {
            throw ConnectorToolArguments.Problem.invalid(
                "The account is not among this event's attendees, so it has no invitation to answer.")
        }
        me["responseStatus"] = .string(status)
        if let comment { me["comment"] = .string(comment) }
        attendees[index] = .object(me)
        return try await rest.patch(["calendars", calendar, "events", event], .object(["attendees": .array(attendees)]),
                                    notifications)
    }

    /// An event's start and end: instants for a timed event, the days' midnights in `zone` for an all-day one,
    /// whose end Google gives as the day after its last.
    static func span(of event: ToolJSON, zone: TimeZone) -> (start: Date, end: Date)? {
        func moment(_ value: ToolJSON?) -> Date? {
            if let text = value?["dateTime"]?.stringValue { return CalendarTime.absolute(text) }
            if let text = value?["date"]?.stringValue { return CalendarTime.parse(text, in: zone)?.date }
            return nil
        }
        guard let start = moment(event["start"]), let end = moment(event["end"]) else { return nil }
        return (start, end)
    }

    /// Where to join the event online: its Meet link, or another service's video entry point.
    static func conferenceLink(_ event: ToolJSON) -> ToolJSON? {
        let video = event["conferenceData"]?["entryPoints"]?.arrayValue?
            .first { $0["entryPointType"]?.stringValue == "video" }?["uri"]
        return event["hangoutLink"] ?? video
    }
}

/// The calendar's Google account, through the Calendar API with the account's connector sign-in (the
/// `calendar.calendarlist.readonly` and `calendar.events` scopes it already has; no other). Reading changes
/// nothing on Google; an invitation is answered only when the person asks.
struct GoogleCalendarTransport: CalendarAccountTransport {
    let api: GoogleCalendarAPI
    let account: CalendarAccount
    /// The zone the days are read in: the Mac's.
    var timeZone: TimeZone = .current

    /// Pages read of one list at most, so a calendar with a runaway recurrence still answers.
    static let pageLimit = 4
    static let pageSize = 250

    /// The calendars in the account's list, its primary first. A calendar is shown as Google's own calendar
    /// shows it (`selected`); with no choice recorded, only the primary is.
    func calendars() async throws -> [CalendarInfo] {
        var items: [ToolJSON] = []
        var token: String?
        for _ in 0..<Self.pageLimit {
            let page = try await api.calendarList(maxResults: Self.pageSize, pageToken: token)
            items += page["items"]?.arrayValue ?? []
            guard let next = page["nextPageToken"]?.stringValue else { break }
            token = next
        }
        let calendars = items.compactMap { item -> CalendarInfo? in
            guard let id = item["id"]?.stringValue else { return nil }
            let own = item["summary"]?.stringValue ?? id
            let name = item["summaryOverride"]?.stringValue ?? own
            let isPrimary = item["primary"] == .bool(true)
            return CalendarInfo(id: CalendarKey(accountID: account.id, calendarID: id), name: name,
                                serviceName: name == own ? nil : own, color: item["backgroundColor"]?.stringValue,
                                isPrimary: isPrimary, isShownByDefault: item["selected"].map { $0 == .bool(true) } ?? isPrimary)
        }
        return calendars.filter(\.isPrimary) + calendars.filter { !$0.isPrimary }
    }

    func events(in calendar: CalendarInfo, from start: Date, to end: Date) async throws -> [CalendarEvent] {
        var events: [CalendarEvent] = []
        var token: String?
        for _ in 0..<Self.pageLimit {
            let page = try await api.events(calendar: calendar.id.calendarID, from: start, to: end, zone: timeZone,
                                            maxResults: Self.pageSize, pageToken: token)
            events += (page["items"]?.arrayValue ?? []).compactMap { Self.event($0, in: calendar.id, zone: timeZone) }
            guard let next = page["nextPageToken"]?.stringValue else { break }
            token = next
        }
        return events
    }

    /// Answers on Google, which tells the organizer as Google Calendar does.
    func respond(to event: CalendarEvent, _ response: CalendarResponse) async throws {
        _ = try await api.respond(calendar: event.id.calendar.calendarID, event: event.id.eventID, status: response.rawValue,
                                  comment: nil, notifications: [URLQueryItem(name: "sendUpdates", value: "all")])
    }

    /// An event of `events.list`; nil for a cancelled one, or one without a start and end.
    static func event(_ json: ToolJSON, in calendar: CalendarKey, zone: TimeZone) -> CalendarEvent? {
        guard let id = json["id"]?.stringValue, json["status"]?.stringValue != "cancelled",
              let span = GoogleCalendarAPI.span(of: json, zone: zone) else { return nil }
        let attendees = (json["attendees"]?.arrayValue ?? []).filter { $0["resource"] != .bool(true) }
        let me = attendees.first { $0["self"] == .bool(true) }
        let notes = json["description"]?.stringValue.flatMap { $0.isEmpty ? nil : String($0.prefix(CalendarEvent.notesLimit)) }
        return CalendarEvent(
            id: CalendarEventKey(calendar: calendar, eventID: id),
            title: json["summary"]?.stringValue ?? "",
            start: span.start, end: max(span.end, span.start), isAllDay: json["start"]?["date"] != nil,
            location: json["location"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            notes: notes,
            organizer: json["organizer"].flatMap { $0["email"] == nil ? nil : person($0) },
            attendees: attendees.map(person),
            response: me?["organizer"] == .bool(true) ? nil : me.flatMap { person($0).response },
            conferenceURL: GoogleCalendarAPI.conferenceLink(json)?.stringValue.flatMap(URL.init(string:)),
            webURL: json["htmlLink"]?.stringValue.flatMap(URL.init(string:)))
    }

    private static func person(_ json: ToolJSON) -> CalendarPerson {
        CalendarPerson(name: json["displayName"]?.stringValue, email: json["email"]?.stringValue,
                       response: json["responseStatus"]?.stringValue.flatMap(CalendarResponse.init(rawValue:)))
    }
}
