import Foundation
import YardletAgentTools

/// The Microsoft Graph calendar requests that the calendar (`OutlookCalendarTransport`) and the agents' Outlook
/// Calendar tools (`OutlookCalendarToolRunner`) share, for one account through its connector sign-in. Graph is asked
/// for times in UTC and gives them in UTC, so no Windows time zone name is needed.
struct OutlookCalendarAPI: Sendable {
    let graph: GraphAPI

    static let utc = TimeZone(identifier: "UTC")!
    /// The event fields a list or an event is read with.
    static let fields = "id,subject,start,end,isAllDay,location,organizer,attendees,isOnlineMeeting,onlineMeeting,"
        + "showAs,responseStatus,isOrganizer,isCancelled,webLink,bodyPreview,seriesMasterId,type,categories"

    /// `GET me/calendars`: the account's calendars.
    func calendars() async throws -> ToolJSON {
        try await graph.get(["me", "calendars"], [URLQueryItem(name: "$top", value: "100")])
    }

    /// The calendar view between two times, each occurrence of a recurring event on its own, by start: of one
    /// calendar, or of the default calendar when `calendarID` is nil.
    func calendarView(calendarID: String?, from start: Date, to end: Date, top: Int) async throws -> ToolJSON {
        var path = ["me", "calendarView"]
        if let calendarID { path = ["me", "calendars", try GraphAPI.segment(calendarID), "calendarView"] }
        return try await graph.get(path, [
            URLQueryItem(name: "startDateTime", value: CalendarTime.rfc3339(start, in: Self.utc)),
            URLQueryItem(name: "endDateTime", value: CalendarTime.rfc3339(end, in: Self.utc)),
            URLQueryItem(name: "$orderby", value: "start/dateTime"),
            URLQueryItem(name: "$top", value: String(top)),
            URLQueryItem(name: "$select", value: Self.fields)
        ], headers: Self.prefer())
    }

    /// The next page of a list, from the link Graph gave with the one before.
    func page(_ link: String) async throws -> ToolJSON {
        try await graph.get(page: link, headers: Self.prefer())
    }

    /// Answers the account's invitation, telling the organizer unless `sendResponse` is false.
    func respond(eventID: String, status: String, comment: String?, sendResponse: Bool) async throws {
        let action = switch status {
        case "accepted": "accept"
        case "declined": "decline"
        case "tentative": "tentativelyAccept"
        default: throw ConnectorToolArguments.Problem.invalid("responseStatus is accepted, declined, or tentative.")
        }
        var body: [String: ToolJSON] = ["sendResponse": .bool(sendResponse)]
        if let comment { body["comment"] = .string(comment) }
        _ = try await graph.post(["me", "events", try GraphAPI.segment(eventID), action], .object(body))
    }

    static func prefer(body: Bool = false) -> [String: String] {
        ["Prefer": "outlook.timezone=\"UTC\"" + (body ? ", outlook.body-content-type=\"text\"" : "")]
    }

    static func utcTime(_ date: Date) -> ToolJSON {
        .object(["dateTime": .string(String(CalendarTime.rfc3339(date, in: utc).prefix(19))), "timeZone": .string("UTC")])
    }

    /// A Graph `dateTimeTimeZone` asked for in UTC: "2026-10-28T01:00:00.0000000".
    static func instant(_ value: ToolJSON?) -> Date? {
        guard let text = value?["dateTime"]?.stringValue, text.count >= 19 else { return nil }
        let zone = value?["timeZone"]?.stringValue.flatMap(TimeZone.init(identifier:)) ?? utc
        return CalendarTime.parse(String(text.prefix(19)), in: zone)?.date
    }
}

/// The calendar's Outlook account, through Microsoft Graph with the account's connector sign-in (its
/// `Calendars.ReadWrite`; no other permission). Reading changes nothing in Outlook; an invitation is answered only
/// when the person asks.
struct OutlookCalendarTransport: CalendarAccountTransport {
    let api: OutlookCalendarAPI
    let account: CalendarAccount
    /// The zone the days are read in: the Mac's.
    var timeZone: TimeZone = .current

    /// Pages read of one list at most, so a calendar with a runaway recurrence still answers.
    static let pageLimit = 4
    static let pageSize = 250

    /// The account's calendars, its default first. Graph keeps no choice of which are shown, so all are.
    func calendars() async throws -> [CalendarInfo] {
        var list = try await api.calendars()
        var calendars: [CalendarInfo] = []
        for page in 0..<Self.pageLimit {
            calendars += (list["value"]?.arrayValue ?? []).compactMap { item in
                guard let id = item["id"]?.stringValue else { return nil }
                let color = item["hexColor"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                return CalendarInfo(id: CalendarKey(accountID: account.id, calendarID: id), name: item["name"]?.stringValue ?? "",
                                    color: color, isPrimary: item["isDefaultCalendar"] == .bool(true))
            }
            guard page + 1 < Self.pageLimit, let next = list["@odata.nextLink"]?.stringValue else { break }
            list = try await api.page(next)
        }
        return calendars.filter(\.isPrimary) + calendars.filter { !$0.isPrimary }
    }

    func events(in calendar: CalendarInfo, from start: Date, to end: Date) async throws -> [CalendarEvent] {
        var list = try await api.calendarView(calendarID: calendar.id.calendarID, from: start, to: end, top: Self.pageSize)
        var events: [CalendarEvent] = []
        for page in 0..<Self.pageLimit {
            events += (list["value"]?.arrayValue ?? []).compactMap { Self.event($0, in: calendar.id, zone: timeZone) }
            guard page + 1 < Self.pageLimit, let next = list["@odata.nextLink"]?.stringValue else { break }
            list = try await api.page(next)
        }
        return events
    }

    /// Answers in Outlook, which tells the organizer as Outlook does.
    func respond(to event: CalendarEvent, _ response: CalendarResponse) async throws {
        try await api.respond(eventID: event.id.eventID, status: response.rawValue, comment: nil, sendResponse: true)
    }

    /// An event of the calendar view; nil for a cancelled one, or one without a start and end. An all-day event is
    /// on its dates at midnight UTC in Outlook, and on the same dates in the Mac's zone here.
    static func event(_ json: ToolJSON, in calendar: CalendarKey, zone: TimeZone) -> CalendarEvent? {
        guard let id = json["id"]?.stringValue, json["isCancelled"] != .bool(true),
              var start = OutlookCalendarAPI.instant(json["start"]),
              var end = OutlookCalendarAPI.instant(json["end"]) else { return nil }
        let isAllDay = json["isAllDay"] == .bool(true)
        if isAllDay {
            start = day(start, in: zone)
            end = day(end, in: zone)
        }
        let notes = json["bodyPreview"]?.stringValue.flatMap { $0.isEmpty ? nil : String($0.prefix(CalendarEvent.notesLimit)) }
        return CalendarEvent(
            id: CalendarEventKey(calendar: calendar, eventID: id),
            title: json["subject"]?.stringValue ?? "",
            start: start, end: max(end, start), isAllDay: isAllDay,
            location: json["location"]?["displayName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            notes: notes,
            organizer: json["organizer"].flatMap { person($0, response: nil) },
            attendees: (json["attendees"]?.arrayValue ?? []).filter { $0["type"]?.stringValue != "resource" }
                .compactMap { person($0, response: $0["status"]?["response"]) },
            response: json["isOrganizer"] == .bool(true) ? nil : response(json["responseStatus"]?["response"]),
            conferenceURL: json["onlineMeeting"]?["joinUrl"]?.stringValue.flatMap(URL.init(string:)),
            webURL: json["webLink"]?.stringValue.flatMap(URL.init(string:)))
    }

    private static func person(_ json: ToolJSON, response answer: ToolJSON?) -> CalendarPerson? {
        guard let address = json["emailAddress"] else { return nil }
        let name = address["name"]?.stringValue
        return CalendarPerson(name: name?.isEmpty == false ? name : nil, email: address["address"]?.stringValue,
                              response: response(answer))
    }

    /// Graph's `responseType`: an invitation not answered yet is `notResponded`; `none` and `organizer` are not
    /// invitations.
    private static func response(_ value: ToolJSON?) -> CalendarResponse? {
        switch value?.stringValue {
        case "accepted": .accepted
        case "declined": .declined
        case "tentativelyAccepted": .tentative
        case "notResponded": .needsAction
        default: nil
        }
    }

    /// The same date as the UTC midnight Outlook keeps an all-day event's day at, at midnight in `zone`.
    private static func day(_ instant: Date, in zone: TimeZone) -> Date {
        CalendarTime.parse(CalendarTime.dateString(instant, in: OutlookCalendarAPI.utc), in: zone)?.date ?? instant
    }
}
