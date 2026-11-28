import Foundation
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Google's sign-in and Gmail API (`FakeGoogle`) with the Calendar API v3, the Drive API v3, and the
/// Docs, Sheets, and Slides APIs for a couple of accounts, as their references describe requests
/// and answers. Each call is answered for the account its bearer token belongs to. Nothing leaves
/// the machine.
final class FakeGoogleWorkspace: ConnectorHTTPTransport, @unchecked Sendable {
    static let endpoints = GoogleOAuth.Endpoints(
        authorization: FakeGoogle.endpoints.authorization,
        token: FakeGoogle.endpoints.token,
        gmailAPI: FakeGoogle.endpoints.gmailAPI,
        calendarAPI: URL(string: "https://calendar.google.test/calendar/v3/")!,
        driveAPI: URL(string: "https://drive.google.test/drive/v3/")!)

    static let holidays = "ko.south_korea#holiday@group.v.calendar.google.com"
    static let allScopes = GoogleOAuth.scope(for: LocalConnectorService.googleDefaults)

    /// One request as the fake saw it: method, path as sent (percent-encoded), query, and body.
    struct Seen {
        var method: String
        var path: String
        var query: [String: [String]]
        var body: Data?
        var account: String?

        func value(_ name: String) -> String? { query[name]?.first }
        var json: ToolJSON? { body.flatMap { try? JSONDecoder().decode(ToolJSON.self, from: $0) } }
    }

    let google: FakeGoogle
    private let lock = NSLock()
    private var seen: [Seen] = []
    private var created = 0
    init(granting scope: String? = FakeGoogleWorkspace.allScopes) {
        google = FakeGoogle()
        google.grantedScope = scope
    }

    var requests: [Seen] { lock.withLock { seen } }

    /// Calendar and Drive requests, in order.
    func calls(_ method: String? = nil, _ path: String? = nil) -> [Seen] {
        requests.filter { (method == nil || $0.method == method) && (path == nil || $0.path == path) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let host = url.host(),
              ["calendar.google.test", "drive.google.test"].contains(host) else {
            return try await google.send(request)
        }
        let account = google.account(of: request)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: [String]] = [:]
        for item in components?.queryItems ?? [] { query[item.name, default: []].append(item.value ?? "") }
        let entry = Seen(method: request.httpMethod ?? "GET", path: components?.percentEncodedPath ?? url.path(),
                         query: query, body: request.httpBody, account: account)
        lock.withLock { seen.append(entry) }
        guard let account else {
            return reply(url, 401, ["error": .object(["code": .integer(401), "message": .string("Request had invalid authentication credentials.")])])
        }
        if host == "calendar.google.test" { return calendar(url, entry, account: account) }
        if url.path().hasSuffix("/about") {
            return reply(url, 200, ["user": .object(["emailAddress": .string(account)])])
        }
        return notFound(url)
    }

    // MARK: Calendar

    static func event(_ id: String, account: String, invited: Bool = true) -> [String: ToolJSON] {
        var attendees: [ToolJSON] = [
            .object(["email": .string("bob@example.com"), "responseStatus": .string("accepted"), "organizer": .bool(true)])
        ]
        if invited {
            attendees.append(.object(["email": .string(account), "responseStatus": .string("needsAction"), "self": .bool(true)]))
        }
        return [
            "id": .string(id), "summary": .string("Design review \(id)"), "status": .string("confirmed"),
            "htmlLink": .string("https://calendar.google.com/event?eid=\(id)"),
            "start": .object(["dateTime": .string("2026-10-21T10:00:00+09:00"), "timeZone": .string("Asia/Seoul")]),
            "end": .object(["dateTime": .string("2026-10-21T11:00:00+09:00"), "timeZone": .string("Asia/Seoul")]),
            "organizer": .object(["email": .string("bob@example.com")]),
            "attendees": .array(attendees),
            "hangoutLink": .string("https://meet.google.com/abc-defg-hij"),
            "description": .string("Agenda: the new setup assistant"),
            "transparency": .string("opaque"),
            "etag": .string("\"3381\""), "iCalUID": .string("\(id)@google.com")
        ]
    }

    private func calendar(_ url: URL, _ call: Seen, account: String) -> (Data, HTTPURLResponse) {
        let path = call.path.replacingOccurrences(of: "/calendar/v3/", with: "")
        switch (call.method, path) {
        case ("GET", "users/me/calendarList"):
            // A second page holds one more calendar and ends the list.
            if call.value("pageToken") == "calendars-2" {
                return reply(url, 200, ["items": .array([
                    .object(["id": .string("team@group.calendar.google.com"), "summary": .string("Team"), "selected": .bool(true),
                             "backgroundColor": .string("#9fe1e7"), "accessRole": .string("writer")])
                ])])
            }
            return reply(url, 200, ["items": .array([
                .object(["id": .string(account), "summary": .string(account), "timeZone": .string("Asia/Seoul"),
                         "accessRole": .string("owner"), "primary": .bool(true), "etag": .string("\"1\"")]),
                .object(["id": .string(Self.holidays), "summary": .string("Holidays in South Korea"),
                         "summaryOverride": .string("Days off"), "timeZone": .string("Asia/Seoul"), "accessRole": .string("reader")])
            ]), "nextPageToken": .string("calendars-2")])
        case ("GET", "users/me/calendarList/primary"):
            return reply(url, 200, ["id": .string(account), "timeZone": .string("Asia/Seoul"), "primary": .bool(true)])
        case ("POST", "freeBusy"):
            return reply(url, 200, ["calendars": .object([
                "primary": .object(["busy": .array([
                    .object(["start": .string("2026-10-21T00:00:00Z"), "end": .string("2026-10-21T01:30:00Z")])
                ])]),
                "bob@example.com": .object(["busy": .array([
                    .object(["start": .string("2026-10-21T01:00:00Z"), "end": .string("2026-10-21T02:10:00Z")])
                ])]),
                "nobody@example.com": .object(["errors": .array([.object(["domain": .string("global"), "reason": .string("notFound")])]),
                                               "busy": .array([])])
            ])])
        default:
            break
        }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "calendars", parts[2] == "events" else { return notFound(url) }
        let calendar = parts[1].removingPercentEncoding ?? parts[1]
        switch (call.method, parts.count) {
        case ("GET", 3):
            // The second page is the last: one all-day event, and one cancelled.
            if call.value("pageToken") == "events-2" {
                return reply(url, 200, ["items": .array([
                    .object(["id": .string("e3"), "summary": .string("Offsite"), "status": .string("confirmed"),
                             "start": .object(["date": .string("2026-10-22")]), "end": .object(["date": .string("2026-10-23")])]),
                    .object(["id": .string("e4"), "status": .string("cancelled")])
                ]), "timeZone": .string("Asia/Seoul")])
            }
            return reply(url, 200, ["items": .array([.object(Self.event("e1", account: account)),
                                                     .object(Self.event("e2", account: account))]),
                                    "nextPageToken": .string("events-2"), "timeZone": .string("Asia/Seoul"),
                                    "summary": .string(calendar)])
        case ("POST", 3):
            var event = call.json?.objectValue ?? [:]
            let id = lock.withLock { created += 1; return "new-\(created)" }
            event["id"] = .string(id)
            event["status"] = .string("confirmed")
            event["htmlLink"] = .string("https://calendar.google.com/event?eid=\(id)")
            if event["conferenceData"] != nil, call.value("conferenceDataVersion") == "1" {
                event["hangoutLink"] = .string("https://meet.google.com/new-meet-\(id)")
            }
            return reply(url, 200, event)
        case ("GET", 4):
            switch parts[3] {
            case "e1": return reply(url, 200, Self.event("e1", account: account))
            case "not-invited": return reply(url, 200, Self.event("not-invited", account: account, invited: false))
            default: return notFound(url)
            }
        case ("PATCH", 4):
            guard parts[3] == "e1" || parts[3] == "not-invited" else { return notFound(url) }
            var event = Self.event(parts[3], account: account)
            for (key, value) in call.json?.objectValue ?? [:] { event[key] = value }
            return reply(url, 200, event)
        case ("DELETE", 4):
            guard parts[3] == "e1" else { return notFound(url) }
            return (Data(), HTTPURLResponse(url: url, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: [:])!)
        default:
            return notFound(url)
        }
    }

    // MARK: Answers

    private func reply(_ url: URL, _ status: Int, _ body: [String: ToolJSON]) -> (Data, HTTPURLResponse) {
        ((try? JSONEncoder().encode(ToolJSON.object(body))) ?? Data(), Self.ok(url, status: status))
    }

    private func notFound(_ url: URL) -> (Data, HTTPURLResponse) {
        reply(url, 404, ["error": .object(["code": .integer(404), "message": .string("Not Found")])])
    }

    private func badRequest(_ url: URL) -> (Data, HTTPURLResponse) {
        reply(url, 400, ["error": .object(["code": .integer(400), "message": .string("Bad Request")])])
    }

    private static func ok(_ url: URL, status: Int = 200, type: String = "application/json") -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
    }
}
