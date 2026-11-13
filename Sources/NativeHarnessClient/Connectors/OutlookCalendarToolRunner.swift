import Foundation
import YardletAgentTools

/// Runs one Outlook calendar tool call against Microsoft Graph and answers with compact JSON text.
/// Graph is asked for times in UTC and gets them in UTC, so no Windows time zone name is needed;
/// answers give each time with its offset in the call's zone. Arguments are checked before any
/// request; Graph's errors and a sign-in that ended are thrown to the connector center.
struct OutlookCalendarToolRunner {
    let api: GraphAPI
    /// The signed-in account's address, whose own free and busy times `suggest_time` reads.
    var account: String?
    /// The zone for a time given without an offset when the call names none: the Mac's.
    var timeZone: TimeZone = .current
    var now: () -> Date = { Date() }

    typealias Problem = ConnectorToolArguments.Problem
    private typealias Arguments = ConnectorToolArguments
    private typealias Catalog = OutlookCalendarToolCatalog
    private typealias API = OutlookCalendarAPI

    static let bodyLimit = 20_000

    /// The requests the calendar shares.
    private var calendar: OutlookCalendarAPI { OutlookCalendarAPI(graph: api) }

    func call(_ name: String, _ arguments: ToolJSON) async throws -> AgentToolResult {
        let arguments = arguments.objectValue ?? [:]
        do {
            let result: ToolJSON
            switch name {
            case Catalog.listCalendars: result = try await calendars()
            case Catalog.listEvents: result = try await events(arguments)
            case Catalog.getEvent: result = try await event(arguments)
            case Catalog.suggestTime: result = try await suggestTime(arguments)
            case Catalog.createEvent: result = try await create(arguments)
            case Catalog.updateEvent: result = try await update(arguments)
            case Catalog.deleteEvent: result = try await delete(arguments)
            case Catalog.respondToEvent: result = try await respond(arguments)
            default: return .error("Unknown tool: \(name)")
            }
            return .text(Arguments.text(result))
        } catch let problem as Problem {
            return .error(problem.localizedDescription)
        } catch GraphAPI.Failure.invalidID(let id) {
            return .error("Not an ID Outlook takes: \(id)")
        }
    }

    // MARK: Reading

    private func calendars() async throws -> ToolJSON {
        let list = try await calendar.calendars()
        return GraphShape.page(list, key: "calendars") { calendar in
            var fields = Arguments.pick(calendar, ["id", "name", "isDefaultCalendar", "canEdit", "canShare", "color"])
            if let owner = GraphShape.person(.object(["emailAddress": calendar["owner"] ?? .null])) { fields["owner"] = owner }
            return .object(fields)
        }
    }

    private func events(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let zone = try zone(arguments)
        let list: ToolJSON
        if let token = Arguments.string(arguments, "pageToken") {
            list = try await calendar.page(token)
        } else {
            let start = try Arguments.string(arguments, "startTime").map { try time($0, in: zone, name: "startTime") } ?? now()
            let end = try Arguments.string(arguments, "endTime").map { try time($0, in: zone, name: "endTime") }
                ?? start.addingTimeInterval(7 * 86_400)
            guard end > start else { throw Problem.invalid("endTime is after startTime.") }
            list = try await calendar.calendarView(calendarID: Arguments.string(arguments, "calendarId"), from: start, to: end,
                                                   top: Arguments.pageSize(arguments, range: 1...250, fallback: 50))
        }
        var result = GraphShape.page(list, key: "events") { Self.event($0, zone: zone) }.objectValue ?? [:]
        result["timeZone"] = .string(zone.identifier)
        return .object(result)
    }

    private func event(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let zone = try zone(arguments)
        let id = try GraphAPI.segment(try Arguments.required(arguments, "eventId"))
        let event = try await api.get(["me", "events", id], [URLQueryItem(name: "$select", value: API.fields + ",body")],
                                      headers: API.prefer(body: true))
        var fields = Self.event(event, zone: zone).objectValue ?? [:]
        fields["bodyPreview"] = nil
        let (body, cut) = GraphShape.cut(event["body"]?["content"]?.stringValue ?? "", Self.bodyLimit)
        if !body.isEmpty { fields["description"] = .string(body) }
        if cut { fields["descriptionTruncated"] = .bool(true) }
        return .object(fields)
    }

    /// Free times every attendee and the account share: Outlook's free and busy times for all of
    /// them, everything but free counted busy, and what is left within the working hours, if any,
    /// cut into times of the length.
    private func suggestTime(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let zone = try zone(arguments)
        let attendees = try Arguments.strings(arguments, "attendeeEmails")
        guard !attendees.isEmpty else { throw Problem.missing("attendeeEmails") }
        let start = try time(try Arguments.required(arguments, "startTime"), in: zone, name: "startTime")
        let end = try time(try Arguments.required(arguments, "endTime"), in: zone, name: "endTime")
        guard end > start else { throw Problem.invalid("endTime is after startTime.") }
        let minutes = Arguments.integer(arguments["durationMinutes"]).map { min(max($0, 5), 1_440) } ?? 30
        let preferences = arguments["preferences"]?.objectValue ?? [:]
        let window = try CalendarTime.Window(start: Arguments.string(preferences, "startHour"),
                                             end: Arguments.string(preferences, "endHour"))
        let limit = Arguments.pageSize(preferences, range: 1...20, fallback: 5)
        var busy: [DateInterval] = []
        var unavailable: [ToolJSON] = []
        do {
            let schedules = ([account].compactMap { $0 } + attendees).map(ToolJSON.string)
            let answer = try await api.post(["me", "calendar", "getSchedule"], .object([
                "schedules": .array(schedules),
                "startTime": API.utcTime(start),
                "endTime": API.utcTime(end),
                "availabilityViewInterval": .integer(15)
            ]), headers: API.prefer())
            for schedule in answer["value"]?.arrayValue ?? [] {
                let id = schedule["scheduleId"]?.stringValue ?? ""
                if let error = schedule["error"], error != .null {
                    unavailable.append(.object(["calendar": .string(id), "reason": error["message"] ?? .string("unavailable")]))
                    continue
                }
                for item in schedule["scheduleItems"]?.arrayValue ?? [] where item["status"]?.stringValue != "free" {
                    guard let from = API.instant(item["start"]), let to = API.instant(item["end"]), to > from else { continue }
                    busy.append(DateInterval(start: from, end: to))
                }
            }
        } catch GraphAPI.Failure.http(let status, let message) where (400..<500).contains(status) && status != 401 {
            // A personal Microsoft account has no getSchedule: its own events stand for its busy
            // times, and the attendees' cannot be read.
            busy = try await ownBusyTimes(from: start, to: end)
            unavailable = attendees.map {
                .object(["calendar": .string($0), "reason": .string(message.isEmpty ? "Outlook shares free and busy times only "
                    + "between work or school accounts." : message)])
            }
        }
        let slots = CalendarTime.freeSlots(from: start, to: end, busy: busy, minutes: minutes, window: window,
                                           excludeWeekends: Arguments.bool(preferences["excludeWeekends"]) == true,
                                           zone: zone, limit: limit)
        var result: [String: ToolJSON] = [
            "timeSlots": .array(slots.map { .object(["startTime": .string(CalendarTime.rfc3339($0.start, in: zone)),
                                                     "endTime": .string(CalendarTime.rfc3339($0.end, in: zone))]) }),
            "timeZone": .string(zone.identifier)
        ]
        if !unavailable.isEmpty { result["unavailableCalendars"] = .array(unavailable) }
        return .object(result)
    }

    /// The account's own events that are not free, for an account Outlook gives no free and busy
    /// times for.
    private func ownBusyTimes(from start: Date, to end: Date) async throws -> [DateInterval] {
        var busy: [DateInterval] = []
        var list = try await api.get(["me", "calendarView"], [
            URLQueryItem(name: "startDateTime", value: CalendarTime.rfc3339(start, in: API.utc)),
            URLQueryItem(name: "endDateTime", value: CalendarTime.rfc3339(end, in: API.utc)),
            URLQueryItem(name: "$top", value: "250"),
            URLQueryItem(name: "$select", value: "start,end,showAs,isCancelled")
        ], headers: API.prefer())
        for _ in 0..<8 {
            for event in list["value"]?.arrayValue ?? [] where event["showAs"]?.stringValue != "free" && event["isCancelled"] != .bool(true) {
                guard let from = API.instant(event["start"]), let to = API.instant(event["end"]), to > from else { continue }
                busy.append(DateInterval(start: from, end: to))
            }
            guard let next = list["@odata.nextLink"]?.stringValue else { break }
            list = try await api.get(page: next, headers: API.prefer())
        }
        return busy
    }

    // MARK: Writing

    private func create(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let zone = try zone(arguments)
        var body = try fields(arguments)
        body["subject"] = .string(try Arguments.required(arguments, "summary"))
        let allDay = Arguments.bool(arguments["allDay"]) == true
        let (start, end) = try times(start: try Arguments.required(arguments, "startTime"),
                                     end: try Arguments.required(arguments, "endTime"), allDay: allDay, zone: zone)
        body.merge(times: start, end, allDay: allDay)
        let attendees = try GraphShape.attendees(Arguments.strings(arguments, "attendeeEmails"), type: "required")
            + GraphShape.attendees(Arguments.strings(arguments, "optionalAttendeeEmails"), type: "optional")
        if !attendees.isEmpty { body["attendees"] = .array(attendees) }
        var path = ["me", "events"]
        if let calendar = Arguments.string(arguments, "calendarId") { path = ["me", "calendars", try GraphAPI.segment(calendar), "events"] }
        return Self.event(try await api.post(path, .object(body), headers: API.prefer()), zone: zone)
    }

    private func update(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let zone = try zone(arguments)
        let id = try GraphAPI.segment(try Arguments.required(arguments, "eventId"))
        var body = try fields(arguments)
        if let summary = Arguments.string(arguments, "summary") { body["subject"] = .string(summary) }
        let added = try Arguments.strings(arguments, "addedAttendeeEmails")
        let removed = Set(try Arguments.strings(arguments, "removedAttendeeEmails").map { $0.lowercased() })
        let startText = Arguments.string(arguments, "startTime"), endText = Arguments.string(arguments, "endTime")
        let allDayArgument = Arguments.bool(arguments["allDay"])
        if startText != nil || endText != nil || allDayArgument != nil || !added.isEmpty || !removed.isEmpty {
            let current = try await api.get(["me", "events", id], [URLQueryItem(name: "$select", value: "start,end,isAllDay,attendees")],
                                            headers: API.prefer())
            if startText != nil || endText != nil || allDayArgument != nil {
                let allDay = allDayArgument ?? (current["isAllDay"] == .bool(true))
                guard let oldStart = API.instant(current["start"]), let oldEnd = API.instant(current["end"]) else {
                    throw GraphAPI.Failure.unreadableAnswer
                }
                let start = try startText.map { try time($0, in: allDay ? API.utc : zone, name: "startTime") } ?? oldStart
                // Moving only the start keeps the length.
                var end = try endText.map { try time($0, in: allDay ? API.utc : zone, name: "endTime") }
                    ?? start.addingTimeInterval(oldEnd.timeIntervalSince(oldStart))
                if allDay, endText != nil { end = CalendarTime.nextDay(end, in: API.utc) }
                if allDay {
                    body.merge(times: CalendarTime.day(start, in: API.utc), max(end, CalendarTime.nextDay(start, in: API.utc)), allDay: true)
                } else {
                    guard end > start else { throw Problem.invalid("endTime is after startTime.") }
                    body.merge(times: start, end, allDay: false)
                }
            }
            if !added.isEmpty || !removed.isEmpty {
                var attendees = (current["attendees"]?.arrayValue ?? []).filter {
                    !removed.contains($0["emailAddress"]?["address"]?.stringValue?.lowercased() ?? "")
                }
                let present = Set(attendees.compactMap { $0["emailAddress"]?["address"]?.stringValue?.lowercased() })
                attendees += try GraphShape.attendees(added.filter { !present.contains($0.lowercased()) }, type: "required")
                body["attendees"] = .array(attendees)
            }
        }
        guard !body.isEmpty else { throw Problem.invalid("Give at least one field to change.") }
        return Self.event(try await api.patch(["me", "events", id], .object(body), headers: API.prefer()), zone: zone)
    }

    private func delete(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let id = try Arguments.required(arguments, "eventId")
        try await api.delete(["me", "events", try GraphAPI.segment(id)])
        return .object(["deleted": .bool(true), "eventId": .string(id)])
    }

    private func respond(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let id = try Arguments.required(arguments, "eventId")
        try await calendar.respond(eventID: id, status: try Arguments.required(arguments, "responseStatus"),
                                   comment: Arguments.string(arguments, "responseComment"),
                                   sendResponse: Arguments.bool(arguments["sendResponse"]) ?? true)
        return .object(["eventId": .string(id), "responseStatus": arguments["responseStatus"] ?? .null])
    }

    /// The event fields a create or an update gives as they are.
    private func fields(_ arguments: [String: ToolJSON]) throws -> [String: ToolJSON] {
        var body: [String: ToolJSON] = [:]
        if let text = arguments["description"]?.stringValue { body["body"] = .object(["contentType": .string("text"), "content": .string(text)]) }
        if let location = Arguments.string(arguments, "location") { body["location"] = .object(["displayName": .string(location)]) }
        if let showAs = Arguments.string(arguments, "showAs") {
            guard Catalog.showAs.contains(showAs) else { throw Problem.invalid("showAs is free, tentative, busy, oof, or workingElsewhere.") }
            body["showAs"] = .string(showAs)
        }
        if let minutes = Arguments.integer(arguments["reminderMinutes"]) {
            body["isReminderOn"] = .bool(true)
            body["reminderMinutesBeforeStart"] = .integer(Int64(max(0, minutes)))
        }
        if Arguments.bool(arguments["addTeamsMeeting"]) == true {
            body["isOnlineMeeting"] = .bool(true)
            body["onlineMeetingProvider"] = .string("teamsForBusiness")
        }
        return body
    }

    // MARK: Times

    private func zone(_ arguments: [String: ToolJSON]) throws -> TimeZone {
        guard let name = Arguments.string(arguments, "timeZone") else { return timeZone }
        guard let zone = TimeZone(identifier: name) else { throw Problem.invalid("timeZone is an IANA name such as Asia/Seoul.") }
        return zone
    }

    private func time(_ text: String, in zone: TimeZone, name: String) throws -> Date {
        guard let parsed = CalendarTime.parse(text, in: zone) else { throw Problem.invalid("\(name) is an ISO 8601 date or time.") }
        return parsed.date
    }

    /// An event's start and end: instants, or for an all-day event midnight UTC of the first day
    /// and of the day after the last, which Outlook keeps on those dates in every zone.
    private func times(start: String, end: String, allDay: Bool, zone: TimeZone) throws -> (Date, Date) {
        if allDay {
            guard let first = CalendarTime.parse(start, in: zone), let last = CalendarTime.parse(end, in: zone) else {
                throw Problem.invalid("startTime and endTime are dates such as 2026-10-28.")
            }
            let from = Self.day(CalendarTime.dateString(first.date, in: zone))
            let through = Self.day(CalendarTime.dateString(last.date, in: zone))
            guard let from, let through, through >= from else { throw Problem.invalid("endTime is on or after startTime.") }
            return (from, CalendarTime.nextDay(through, in: API.utc))
        }
        let from = try time(start, in: zone, name: "startTime")
        let to = try time(end, in: zone, name: "endTime")
        guard to > from else { throw Problem.invalid("endTime is after startTime.") }
        return (from, to)
    }

    private static func day(_ date: String) -> Date? {
        CalendarTime.parse(date, in: API.utc).map(\.date)
    }

    static func event(_ event: ToolJSON, zone: TimeZone) -> ToolJSON {
        var fields = ConnectorToolArguments.pick(event, ["id", "isAllDay", "showAs", "isOrganizer", "isCancelled", "webLink",
                                                         "bodyPreview", "seriesMasterId", "categories"])
        fields["summary"] = event["subject"] ?? .null
        let allDay = event["isAllDay"] == .bool(true)
        if let start = API.instant(event["start"]) {
            fields["start"] = .string(allDay ? CalendarTime.dateString(start, in: API.utc) : CalendarTime.rfc3339(start, in: zone))
        }
        if let end = API.instant(event["end"]) {
            // An all-day event's end is the day after its last; the answer gives the last, as create takes it.
            fields["end"] = .string(allDay ? CalendarTime.dateString(end.addingTimeInterval(-86_400), in: API.utc)
                                           : CalendarTime.rfc3339(end, in: zone))
        }
        if let location = event["location"]?["displayName"]?.stringValue, !location.isEmpty { fields["location"] = .string(location) }
        if let organizer = GraphShape.person(event["organizer"]) { fields["organizer"] = organizer }
        let attendees = (event["attendees"]?.arrayValue ?? []).map { attendee -> ToolJSON in
            var item: [String: ToolJSON] = [:]
            item["email"] = attendee["emailAddress"]?["address"] ?? .null
            if let name = attendee["emailAddress"]?["name"]?.stringValue, !name.isEmpty { item["name"] = .string(name) }
            if let type = attendee["type"]?.stringValue, type != "required" { item["type"] = .string(type) }
            item["response"] = attendee["status"]?["response"] ?? .string("none")
            return .object(item)
        }
        if !attendees.isEmpty { fields["attendees"] = .array(attendees) }
        if let url = event["onlineMeeting"]?["joinUrl"]?.stringValue { fields["onlineMeetingUrl"] = .string(url) }
        if let response = event["responseStatus"]?["response"]?.stringValue, response != "none", response != "organizer" {
            fields["myResponse"] = .string(response)
        }
        return .object(fields)
    }
}

private extension Dictionary where Key == String, Value == ToolJSON {
    mutating func merge(times start: Date, _ end: Date, allDay: Bool) {
        self["start"] = OutlookCalendarAPI.utcTime(start)
        self["end"] = OutlookCalendarAPI.utcTime(end)
        self["isAllDay"] = .bool(allDay)
    }
}

extension GraphShape {
    /// Graph's attendees for a list of addresses, checked as recipients are.
    static func attendees(_ addresses: [String], type: String) throws -> [ToolJSON] {
        try (recipients(addresses, field: "attendeeEmails").arrayValue ?? []).map {
            .object(["emailAddress": $0["emailAddress"] ?? .null, "type": .string(type)])
        }
    }
}
