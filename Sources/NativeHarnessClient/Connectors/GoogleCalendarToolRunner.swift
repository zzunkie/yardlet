import Foundation
import YardletAgentTools

/// Runs one Google Calendar tool call against the Calendar API v3
/// (developers.google.com/workspace/calendar/api/v3/reference) and answers with compact JSON
/// text. Arguments are checked before any request; a mistake the model can fix is an error result.
/// Google's errors and a sign-in that ended are thrown to the connector center, which words them.
struct GoogleCalendarToolRunner {
    let api: GoogleREST
    /// The zone for a time given without an offset when the call names none: the Mac's.
    var timeZone: TimeZone = .current
    var now: () -> Date = { Date() }

    typealias Problem = ConnectorToolArguments.Problem
    private typealias Arguments = ConnectorToolArguments

    /// The requests the calendar shares.
    private var calendar: GoogleCalendarAPI { GoogleCalendarAPI(rest: api) }

    func call(_ name: String, _ arguments: ToolJSON) async throws -> AgentToolResult {
        let arguments = arguments.objectValue ?? [:]
        do {
            let result: ToolJSON
            switch name {
            case GoogleCalendarToolCatalog.listCalendars: result = try await listCalendars(arguments)
            case GoogleCalendarToolCatalog.listEvents: result = try await listEvents(arguments)
            case GoogleCalendarToolCatalog.searchEvents: result = try await searchEvents(arguments)
            case GoogleCalendarToolCatalog.getEvent: result = try await getEvent(arguments)
            case GoogleCalendarToolCatalog.suggestTime: result = try await suggestTime(arguments)
            case GoogleCalendarToolCatalog.createEvent: result = try await createEvent(arguments)
            case GoogleCalendarToolCatalog.updateEvent: result = try await updateEvent(arguments)
            case GoogleCalendarToolCatalog.deleteEvent: result = try await deleteEvent(arguments)
            case GoogleCalendarToolCatalog.respondToEvent: result = try await respondToEvent(arguments)
            default: return .error("Unknown tool: \(name)")
            }
            return .text(Arguments.text(result))
        } catch let problem as Problem {
            return .error(problem.localizedDescription)
        } catch GoogleREST.Failure.invalidID(let id) {
            return .error("Not an ID Google Calendar takes: \(id)")
        }
    }

    // MARK: Reading

    private func listCalendars(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let list = try await calendar.calendarList(maxResults: Arguments.pageSize(arguments, range: 1...250, fallback: 100),
                                                   pageToken: Arguments.string(arguments, "pageToken"))
        var result: [String: ToolJSON] = ["calendars": .array((list["items"]?.arrayValue ?? []).map { item in
            var fields = Arguments.pick(item, ["id", "description", "timeZone", "accessRole", "primary"])
            fields["summary"] = item["summaryOverride"] ?? item["summary"] ?? .null
            return .object(fields)
        })]
        if let next = list["nextPageToken"] { result["nextPageToken"] = next }
        return .object(result)
    }

    private func listEvents(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let zone = try zone(arguments)
        let start = try Arguments.string(arguments, "startTime").map { try time($0, in: zone, name: "startTime") } ?? now()
        let end = try Arguments.string(arguments, "endTime").map { try time($0, in: zone, name: "endTime") }
            ?? start.addingTimeInterval(7 * 86_400)
        guard end > start else { throw Problem.invalid("endTime is after startTime.") }
        let order = Arguments.string(arguments, "orderBy") ?? "default"
        var filters: [URLQueryItem] = []
        if let text = Arguments.string(arguments, "fullText") { filters.append(URLQueryItem(name: "q", value: text)) }
        for type in try Arguments.strings(arguments, "eventType") where GoogleCalendarToolCatalog.eventTypes.contains(type) {
            filters.append(URLQueryItem(name: "eventTypes", value: Self.apiEventType(type)))
        }
        let list = try await calendar.events(calendar: Arguments.string(arguments, "calendarId") ?? "primary", from: start, to: end,
                                             zone: zone, maxResults: Arguments.pageSize(arguments, range: 1...250, fallback: 25),
                                             byUpdate: order == "lastModified", extra: filters,
                                             pageToken: Arguments.string(arguments, "pageToken"))
        var events = (list["items"]?.arrayValue ?? []).map(Self.event)
        // Google orders by start ascending only; a descending page is that page turned round.
        if order == "startTimeDesc" { events.reverse() }
        var result: [String: ToolJSON] = ["events": .array(events)]
        if let next = list["nextPageToken"] { result["nextPageToken"] = next }
        if let zone = list["timeZone"] { result["timeZone"] = zone }
        return .object(result)
    }

    private func searchEvents(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let text = try Arguments.required(arguments, "query")
        let today = now()
        var query = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "timeMin", value: CalendarTime.rfc3339(today.addingTimeInterval(-365 * 86_400), in: timeZone)),
            URLQueryItem(name: "timeMax", value: CalendarTime.rfc3339(today.addingTimeInterval(365 * 86_400), in: timeZone)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: String(Arguments.pageSize(arguments, range: 1...250, fallback: 25)))
        ]
        if let token = Arguments.string(arguments, "pageToken") { query.append(URLQueryItem(name: "pageToken", value: token)) }
        let list = try await api.get(["calendars", "primary", "events"], query)
        var result: [String: ToolJSON] = ["events": .array((list["items"]?.arrayValue ?? []).map(Self.event))]
        if let next = list["nextPageToken"] { result["nextPageToken"] = next }
        return .object(result)
    }

    private func getEvent(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        Self.event(try await calendar.event(calendar: Arguments.string(arguments, "calendarId") ?? "primary",
                                            id: try Arguments.required(arguments, "eventId")))
    }

    /// Free times every attendee and the account share: free/busy for all of them, the busy times
    /// merged, and what is left within the working hours, if any, cut into times of the length.
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
        let items = (["primary"] + attendees).map { ToolJSON.object(["id": .string($0)]) }
        let answer = try await api.post(["freeBusy"], .object([
            "timeMin": .string(CalendarTime.rfc3339(start, in: zone)),
            "timeMax": .string(CalendarTime.rfc3339(end, in: zone)),
            "timeZone": .string(zone.identifier),
            "items": .array(items)
        ]))
        var busy: [DateInterval] = []
        var unavailable: [ToolJSON] = []
        for (id, calendar) in answer["calendars"]?.objectValue ?? [:] {
            if let errors = calendar["errors"]?.arrayValue, !errors.isEmpty {
                unavailable.append(.object(["calendar": .string(id),
                                            "reason": errors.first?["reason"] ?? .string("unavailable")]))
                continue
            }
            for period in calendar["busy"]?.arrayValue ?? [] {
                guard let from = period["start"]?.stringValue.flatMap(CalendarTime.absolute),
                      let to = period["end"]?.stringValue.flatMap(CalendarTime.absolute), to > from else { continue }
                busy.append(DateInterval(start: from, end: to))
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
        if !unavailable.isEmpty {
            result["unavailableCalendars"] = .array(unavailable.sorted { ($0["calendar"]?.stringValue ?? "") < ($1["calendar"]?.stringValue ?? "") })
        }
        return .object(result)
    }

    // MARK: Writing

    private func createEvent(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let zone = try zone(arguments)
        let calendar = try GoogleREST.segment(Arguments.string(arguments, "calendarId") ?? "primary")
        var body = try fields(arguments)
        body["summary"] = .string(try Arguments.required(arguments, "summary"))
        let (start, end) = try times(start: try Arguments.required(arguments, "startTime"),
                                     end: try Arguments.required(arguments, "endTime"),
                                     allDay: Arguments.bool(arguments["allDay"]) == true, zone: zone)
        body["start"] = start
        body["end"] = end
        var attendees = try Self.attendees(arguments["attendees"])
        for email in try Arguments.strings(arguments, "attendeeEmails") where !attendees.contains(where: { Self.same($0, email) }) {
            attendees.append(.object(["email": .string(try Self.address(email))]))
        }
        if !attendees.isEmpty { body["attendees"] = .array(attendees) }
        let recurrence = try Arguments.strings(arguments, "recurrenceData")
        if !recurrence.isEmpty {
            guard recurrence.allSatisfy({ ["RRULE:", "RDATE", "EXDATE", "EXRULE:"].contains(where: $0.uppercased().hasPrefix) }) else {
                throw Problem.invalid("recurrenceData takes RRULE, RDATE, or EXDATE lines.")
            }
            body["recurrence"] = .array(recurrence.map(ToolJSON.string))
        }
        var query = try notifications(arguments)
        if Arguments.bool(arguments["addGoogleMeetUrl"]) == true {
            body["conferenceData"] = Self.meetRequest()
            query.append(URLQueryItem(name: "conferenceDataVersion", value: "1"))
        }
        return Self.event(try await api.post(["calendars", calendar, "events"], .object(body), query))
    }

    private func updateEvent(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let zone = try zone(arguments)
        let (calendar, event) = try ids(arguments)
        var body = try fields(arguments)
        if let summary = Arguments.string(arguments, "summary") { body["summary"] = .string(summary) }
        let newStart = Arguments.string(arguments, "startTime"), newEnd = Arguments.string(arguments, "endTime")
        let added = try Self.attendees(arguments["addedAttendees"])
            + (try Arguments.strings(arguments, "addedAttendeeEmails")).map { ToolJSON.object(["email": .string(try Self.address($0))]) }
        let removed = try Arguments.strings(arguments, "removedAttendeeEmails")
        let allDay = Arguments.bool(arguments["allDay"])
        // The event as it is, when the change builds on it: its attendees, or its length.
        let needsCurrent = !added.isEmpty || !removed.isEmpty || ((newStart == nil) != (newEnd == nil))
        let current = needsCurrent ? try await api.get(["calendars", calendar, "events", event]) : nil
        if newStart != nil || newEnd != nil {
            let isAllDay = allDay ?? (current?["start"]?["date"] != nil)
            var startText = newStart, endText = newEnd
            if startText == nil || endText == nil, let current {
                let (from, to) = try Self.span(of: current, zone: zone)
                let length = to.timeIntervalSince(from)
                if let given = startText {
                    let moved = try time(given, in: zone, name: "startTime")
                    endText = CalendarTime.rfc3339(moved.addingTimeInterval(length), in: zone)
                } else if let given = endText {
                    _ = try time(given, in: zone, name: "endTime")
                    startText = CalendarTime.rfc3339(from, in: zone)
                }
            }
            if let startText, let endText {
                let (start, end) = try times(start: startText, end: endText, allDay: isAllDay, zone: zone)
                body["start"] = start
                body["end"] = end
            }
        }
        if !added.isEmpty || !removed.isEmpty {
            var list = (current?["attendees"]?.arrayValue ?? []).filter { attendee in
                !removed.contains { Self.same(attendee, $0) }
            }
            for attendee in added where !list.contains(where: { Self.same($0, attendee["email"]?.stringValue ?? "") }) {
                list.append(attendee)
            }
            body["attendees"] = .array(list)
        }
        var query = try notifications(arguments)
        if Arguments.bool(arguments["addGoogleMeetUrl"]) == true {
            body["conferenceData"] = Self.meetRequest()
            query.append(URLQueryItem(name: "conferenceDataVersion", value: "1"))
        }
        guard !body.isEmpty else { throw Problem.invalid("Give at least one field to change.") }
        return Self.event(try await api.patch(["calendars", calendar, "events", event], .object(body), query))
    }

    private func deleteEvent(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let (calendar, event) = try ids(arguments)
        try await api.delete(["calendars", calendar, "events", event], try notifications(arguments))
        return .object(["deleted": .bool(true), "eventId": .string(event.removingPercentEncoding ?? event)])
    }

    /// The account's own attendee entry answers; an event it was not invited to has none.
    private func respondToEvent(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let event = try Arguments.required(arguments, "eventId")
        let status = try Arguments.required(arguments, "responseStatus")
        guard ["accepted", "declined", "tentative"].contains(status) else {
            throw Problem.invalid("responseStatus is accepted, declined, or tentative.")
        }
        return Self.event(try await calendar.respond(calendar: Arguments.string(arguments, "calendarId") ?? "primary", event: event,
                                                     status: status, comment: Arguments.string(arguments, "responseComment"),
                                                     notifications: try notifications(arguments)))
    }

    // MARK: Pieces

    private func ids(_ arguments: [String: ToolJSON]) throws -> (calendar: String, event: String) {
        (try GoogleREST.segment(Arguments.string(arguments, "calendarId") ?? "primary"),
         try GoogleREST.segment(try Arguments.required(arguments, "eventId")))
    }

    private func zone(_ arguments: [String: ToolJSON]) throws -> TimeZone {
        guard let name = Arguments.string(arguments, "timeZone") else { return timeZone }
        guard let zone = TimeZone(identifier: name) else { throw Problem.invalid("timeZone is an IANA name such as Asia/Seoul.") }
        return zone
    }

    private func time(_ text: String, in zone: TimeZone, name: String) throws -> Date {
        guard let date = CalendarTime.parse(text, in: zone)?.date else {
            throw Problem.invalid("\(name) is an ISO 8601 date and time, such as 2026-04-30T10:00:00.")
        }
        return date
    }

    /// Start and end as Google takes them: dates for an all-day event (the end day included, so
    /// Google's exclusive end is the day after), otherwise times with their offset and zone.
    private func times(start: String, end: String, allDay: Bool, zone: TimeZone) throws -> (ToolJSON, ToolJSON) {
        let from = try time(start, in: zone, name: "startTime")
        let to = try time(end, in: zone, name: "endTime")
        if allDay {
            let first = CalendarTime.day(from, in: zone)
            let endDay = CalendarTime.day(to, in: zone)
            // A midnight end after the first day is already the day after; a date is included.
            let isMidnight = CalendarTime.parse(end, in: zone)?.dateOnly == false && to == endDay
            let last = isMidnight && endDay > first ? endDay : CalendarTime.nextDay(max(endDay, first), in: zone)
            return (.object(["date": .string(CalendarTime.dateString(first, in: zone))]),
                    .object(["date": .string(CalendarTime.dateString(last, in: zone))]))
        }
        guard to > from else { throw Problem.invalid("endTime is after startTime.") }
        return (.object(["dateTime": .string(CalendarTime.rfc3339(from, in: zone)), "timeZone": .string(zone.identifier)]),
                .object(["dateTime": .string(CalendarTime.rfc3339(to, in: zone)), "timeZone": .string(zone.identifier)]))
    }

    /// The fields create and update share, as Google's event resource names them.
    private func fields(_ arguments: [String: ToolJSON]) throws -> [String: ToolJSON] {
        var body: [String: ToolJSON] = [:]
        if let description = arguments["description"]?.stringValue { body["description"] = .string(description) }
        if let location = arguments["location"]?.stringValue { body["location"] = .string(location) }
        if let color = Arguments.string(arguments, "colorId") { body["colorId"] = .string(color) }
        switch Arguments.string(arguments, "availability") {
        case "AVAILABILITY_FREE"?: body["transparency"] = .string("transparent")
        case "AVAILABILITY_BUSY"?: body["transparency"] = .string("opaque")
        case nil, "AVAILABILITY_UNSPECIFIED"?: break
        default: throw Problem.invalid("availability is AVAILABILITY_BUSY or AVAILABILITY_FREE.")
        }
        if let visibility = Arguments.string(arguments, "visibility") {
            guard ["default", "public", "private"].contains(visibility) else {
                throw Problem.invalid("visibility is default, public, or private.")
            }
            body["visibility"] = .string(visibility)
        }
        let overrides = arguments["overrideReminders"]?.arrayValue ?? []
        if !overrides.isEmpty {
            body["reminders"] = .object(["useDefault": .bool(false), "overrides": .array(try overrides.map { reminder in
                guard let method = reminder["method"]?.stringValue, ["email", "popup"].contains(method),
                      let minutes = ConnectorToolArguments.integer(reminder["minutes"]), minutes >= 0 else {
                    throw Problem.invalid("Each reminder has a method, email or popup, and minutes.")
                }
                return .object(["method": .string(method), "minutes": .integer(Int64(minutes))])
            })])
        } else if let useDefault = Arguments.bool(arguments["useDefaultReminders"]) {
            body["reminders"] = .object(["useDefault": .bool(useDefault)])
        }
        return body
    }

    private func notifications(_ arguments: [String: ToolJSON]) throws -> [URLQueryItem] {
        let level = Arguments.string(arguments, "notificationLevel") ?? "ALL"
        let value: String
        switch level {
        case "ALL", "NOTIFICATION_LEVEL_UNSPECIFIED": value = "all"
        case "EXTERNAL_ONLY": value = "externalOnly"
        case "NONE": value = "none"
        default: throw Problem.invalid("notificationLevel is NONE, EXTERNAL_ONLY, or ALL.")
        }
        return [URLQueryItem(name: "sendUpdates", value: value)]
    }

    /// A new Meet link, with a request ID of its own as Google asks.
    private static func meetRequest() -> ToolJSON {
        .object(["createRequest": .object([
            "requestId": .string(UUID().uuidString),
            "conferenceSolutionKey": .object(["type": .string("hangoutsMeet")])
        ])])
    }

    private static func attendees(_ value: ToolJSON?) throws -> [ToolJSON] {
        try (value?.arrayValue ?? []).map { item in
            guard let email = item["email"]?.stringValue ?? item.stringValue else {
                throw Problem.invalid("Each attendee has an email.")
            }
            var fields: [String: ToolJSON] = ["email": .string(try address(email))]
            if let name = item["displayName"]?.stringValue, !name.isEmpty { fields["displayName"] = .string(name) }
            if item["optionalAttendee"] == .bool(true) { fields["optional"] = .bool(true) }
            return .object(fields)
        }
    }

    private static func address(_ email: String) throws -> String {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("@"), !trimmed.contains(where: { $0.isWhitespace || $0 == "," || $0 == "<" }) else {
            throw Problem.invalid("Not an email address: \(email)")
        }
        return trimmed
    }

    private static func same(_ attendee: ToolJSON, _ email: String) -> Bool {
        attendee["email"]?.stringValue?.lowercased() == email.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func span(of event: ToolJSON, zone: TimeZone) throws -> (Date, Date) {
        guard let span = GoogleCalendarAPI.span(of: event, zone: zone) else {
            throw Problem.invalid("The event has no start and end to keep its length from; give both startTime and endTime.")
        }
        return span
    }

    private static func apiEventType(_ type: String) -> String {
        switch type {
        case "DEFAULT": "default"
        case "OUT_OF_OFFICE": "outOfOffice"
        case "FOCUS_TIME": "focusTime"
        case "WORKING_LOCATION": "workingLocation"
        case "BIRTHDAY": "birthday"
        default: "fromGmail"
        }
    }

    /// An event as the tools return it: what it is, when, who, and where to join.
    static func event(_ event: ToolJSON) -> ToolJSON {
        var fields = ConnectorToolArguments.pick(event, ["id", "summary", "location", "status", "htmlLink", "start", "end",
                                                      "recurringEventId", "recurrence", "eventType", "visibility",
                                                      "colorId", "created", "updated"])
        if let description = event["description"]?.stringValue {
            fields["description"] = .string(description.count > 4_000 ? String(description.prefix(4_000)) + "…" : description)
        }
        if let transparency = event["transparency"]?.stringValue {
            fields["availability"] = .string(transparency == "transparent" ? "AVAILABILITY_FREE" : "AVAILABILITY_BUSY")
        }
        if let organizer = event["organizer"]?["email"] { fields["organizer"] = organizer }
        if let attendees = event["attendees"]?.arrayValue {
            fields["attendees"] = .array(attendees.map { attendee in
                var item = ConnectorToolArguments.pick(attendee, ["email", "displayName", "responseStatus", "comment"])
                for key in ["optional", "organizer", "self", "resource"] where attendee[key] == .bool(true) {
                    item[key == "optional" ? "optionalAttendee" : key] = .bool(true)
                }
                return .object(item)
            })
        }
        if let link = GoogleCalendarAPI.conferenceLink(event) { fields["conferenceUrl"] = link }
        if let attachments = event["attachments"]?.arrayValue {
            fields["attachments"] = .array(attachments.map { .object(ConnectorToolArguments.pick($0, ["title", "fileUrl"])) })
        }
        if let reminders = event["reminders"] { fields["reminders"] = reminders }
        return .object(fields)
    }
}

/// Calendar times: what a tool's argument means (an instant with an offset, a local time in a
/// zone, or a date), and Google's RFC 3339 form.
enum CalendarTime {
    /// A parsed argument: the instant, and whether it named its own offset or only a date.
    static func parse(_ text: String, in zone: TimeZone) -> (date: Date, hasOffset: Bool, dateOnly: Bool)? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if let date = absolute(value) { return (date, true, false) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        for (format, dateOnly) in [("yyyy-MM-dd'T'HH:mm:ss.SSS", false), ("yyyy-MM-dd'T'HH:mm:ss", false),
                                   ("yyyy-MM-dd'T'HH:mm", false), ("yyyy-MM-dd HH:mm:ss", false),
                                   ("yyyy-MM-dd HH:mm", false), ("yyyy-MM-dd", true)] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return (date, false, dateOnly) }
        }
        return nil
    }

    /// A time with its own offset or `Z`.
    static func absolute(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func rfc3339(_ date: Date, in zone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func day(_ date: Date, in zone: TimeZone) -> Date {
        calendar(zone).startOfDay(for: date)
    }

    static func nextDay(_ date: Date, in zone: TimeZone) -> Date {
        calendar(zone).date(byAdding: .day, value: 1, to: day(date, in: zone)) ?? date.addingTimeInterval(86_400)
    }

    static func dateString(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// Working hours, "HH:mm" to "HH:mm", as minutes into the day.
    struct Window: Equatable {
        var start: Int?
        var end: Int?

        init(start: String?, end: String?) throws {
            func minutes(_ text: String?, _ name: String) throws -> Int? {
                guard let text else { return nil }
                let parts = text.split(separator: ":").map { Int($0) }
                guard parts.count == 2, let hour = parts[0], let minute = parts[1], (0...24).contains(hour), (0..<60).contains(minute),
                      hour * 60 + minute <= 1_440 else {
                    throw ConnectorToolArguments.Problem.invalid("\(name) is a time of day such as 09:00.")
                }
                return hour * 60 + minute
            }
            self.start = try minutes(start, "preferences.startHour")
            self.end = try minutes(end, "preferences.endHour")
            if let first = self.start, let last = self.end, last <= first {
                throw ConnectorToolArguments.Problem.invalid("preferences.endHour is after startHour.")
            }
        }
    }

    /// Free times of `minutes` between `from` and `to` outside every busy period, within the
    /// window each day and on weekdays if asked, starting on a quarter hour, at most one an hour
    /// apart so they spread over the free time, `limit` at most.
    static func freeSlots(from: Date, to: Date, busy: [DateInterval], minutes: Int, window: Window,
                          excludeWeekends: Bool, zone: TimeZone, limit: Int) -> [DateInterval] {
        let calendar = calendar(zone)
        let length = TimeInterval(minutes * 60)
        let merged = busy.sorted { $0.start < $1.start }.reduce(into: [DateInterval]()) { list, period in
            if let last = list.last, period.start <= last.end {
                list[list.count - 1] = DateInterval(start: last.start, end: max(last.end, period.end))
            } else {
                list.append(period)
            }
        }
        var slots: [DateInterval] = []
        var day = calendar.startOfDay(for: from)
        while day < to, slots.count < limit {
            defer { day = calendar.date(byAdding: .day, value: 1, to: day) ?? to }
            let weekday = calendar.component(.weekday, from: day)
            if excludeWeekends, weekday == 1 || weekday == 7 { continue }
            let open = max(from, day.addingTimeInterval(TimeInterval((window.start ?? 0) * 60)))
            let close = min(to, day.addingTimeInterval(TimeInterval((window.end ?? 1_440) * 60)))
            guard close > open else { continue }
            var cursor = quarterHour(open, calendar: calendar)
            while cursor.addingTimeInterval(length) <= close, slots.count < limit {
                let candidate = DateInterval(start: cursor, duration: length)
                if let blocking = merged.first(where: { $0.start < candidate.end && $0.end > candidate.start }) {
                    cursor = quarterHour(blocking.end, calendar: calendar)
                    continue
                }
                slots.append(candidate)
                cursor = cursor.addingTimeInterval(max(length, 3_600))
            }
        }
        return slots
    }

    /// The next quarter hour from `date`, or `date` itself on one.
    private static func quarterHour(_ date: Date, calendar: Calendar) -> Date {
        let parts = calendar.dateComponents([.minute, .second, .nanosecond], from: date)
        let into = TimeInterval((parts.minute ?? 0) * 60 + (parts.second ?? 0)) + TimeInterval(parts.nanosecond ?? 0) / 1e9
        let rounded = (into / 900).rounded(.up) * 900
        return date.addingTimeInterval(rounded - into)
    }
}
