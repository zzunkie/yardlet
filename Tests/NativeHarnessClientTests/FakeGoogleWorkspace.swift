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
        driveAPI: URL(string: "https://drive.google.test/drive/v3/")!,
        driveUpload: URL(string: "https://drive.google.test/upload/drive/v3/")!,
        docsAPI: URL(string: "https://docs.google.test/v1/")!,
        sheetsAPI: URL(string: "https://sheets.google.test/v4/")!,
        slidesAPI: URL(string: "https://slides.google.test/v1/")!)

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
    /// Files this fake's Drive says Yardlet created, which `drive.file` lets it change.
    private var appFiles: Set<String> = ["app-note", "app-doc", "app-sheet", "app-deck"]

    init(granting scope: String? = FakeGoogleWorkspace.allScopes) {
        google = FakeGoogle()
        google.grantedScope = scope
    }

    var requests: [Seen] { lock.withLock { seen } }

    /// Calendar and Drive requests, in order.
    func calls(_ method: String? = nil, _ path: String? = nil) -> [Seen] {
        requests.filter { (method == nil || $0.method == method) && (path == nil || $0.path == path) }
    }

    static let apiHosts: Set<String> = ["calendar.google.test", "drive.google.test", "docs.google.test",
                                        "sheets.google.test", "slides.google.test", "thumbnails.google.test"]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let host = url.host(), Self.apiHosts.contains(host) else {
            return try await google.send(request)
        }
        // A thumbnail's address is signed for the account: it is fetched with no token.
        if host == "thumbnails.google.test" {
            lock.withLock {
                seen.append(Seen(method: request.httpMethod ?? "GET", path: url.path(), query: [:], body: nil,
                                 account: request.value(forHTTPHeaderField: "Authorization")))
            }
            return (Self.pngBytes, Self.ok(url, type: "image/png"))
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
        switch host {
        case "calendar.google.test": return calendar(url, entry, account: account)
        case "docs.google.test", "sheets.google.test", "slides.google.test": return editors(url, entry)
        default: return drive(url, entry, account: account, contentType: request.value(forHTTPHeaderField: "Content-Type"))
        }
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

    // MARK: Drive

    static let document = GoogleDriveToolCatalog.document
    static let spreadsheet = GoogleDriveToolCatalog.spreadsheet

    static func file(_ id: String, name: String, mimeType: String, size: Int? = nil) -> [String: ToolJSON] {
        var file: [String: ToolJSON] = [
            "id": .string(id), "name": .string(name), "mimeType": .string(mimeType),
            "createdTime": .string("2026-10-01T00:00:00.000Z"), "modifiedTime": .string("2026-10-18T09:30:00.000Z"),
            "owners": .array([.object(["emailAddress": .string("person@example.test"), "displayName": .string("Person")])]),
            "parents": .array([.string("folder-1")]),
            "webViewLink": .string("https://drive.google.com/file/d/\(id)/view"),
            "starred": .bool(false), "shared": .bool(true)
        ]
        if let size { file["size"] = .string(String(size)) }
        return file
    }

    static let files: [String: [String: ToolJSON]] = [
        "doc-1": file("doc-1", name: "Launch plan", mimeType: document),
        "sheet-1": file("sheet-1", name: "Budget", mimeType: spreadsheet),
        "slides-1": file("slides-1", name: "Kickoff", mimeType: GoogleDriveToolCatalog.presentation),
        "notes-1": file("notes-1", name: "notes.md", mimeType: "text/markdown", size: 24),
        "pdf-1": file("pdf-1", name: "contract.pdf", mimeType: "application/pdf", size: 8),
        "huge-1": file("huge-1", name: "video.mov", mimeType: "video/quicktime", size: 900_000_000),
        "app-note": file("app-note", name: "Yardlet note", mimeType: document)
    ]

    static let pdfBytes = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37])

    private func drive(_ url: URL, _ call: Seen, account: String, contentType: String?) -> (Data, HTTPURLResponse) {
        let upload = call.path.hasPrefix("/upload/drive/v3/")
        let path = call.path.replacingOccurrences(of: upload ? "/upload/drive/v3/" : "/drive/v3/", with: "")
        let parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        switch (call.method, parts.first, parts.count) {
        case ("GET", "about"?, 1):
            return reply(url, 200, ["user": .object(["emailAddress": .string(account), "displayName": .string("Person")])])
        case ("GET", "files"?, 1):
            return reply(url, 200, ["files": .array([.object(Self.files["doc-1"]!), .object(Self.files["sheet-1"]!)]),
                                    "nextPageToken": .string("files-2")])
        case ("POST", "files"?, 1):
            let id = lock.withLock { created += 1; appFiles.insert("made-\(created)"); return "made-\(created)" }
            var metadata: [String: ToolJSON]
            var content: String?
            if upload {
                guard call.value("uploadType") == "multipart", contentType?.hasPrefix("multipart/related; boundary=") == true,
                      let (json, body) = Self.multipart(call.body, contentType: contentType!) else { return badRequest(url) }
                metadata = json
                content = body
            } else {
                metadata = call.json?.objectValue ?? [:]
            }
            var file = Self.file(id, name: metadata["name"]?.stringValue ?? "Untitled",
                                 mimeType: metadata["mimeType"]?.stringValue ?? "application/octet-stream")
            if let parents = metadata["parents"] { file["parents"] = parents }
            if let content { file["size"] = .string(String(content.utf8.count)) }
            return reply(url, 200, file)
        case (_, "files"?, _):
            break
        default:
            return notFound(url)
        }
        let id = parts[1]
        let madeHere = lock.withLock { appFiles.contains(id) }
        guard var file = Self.files[id] ?? (madeHere ? Self.file(id, name: "Made by Yardlet", mimeType: Self.document) : nil)
        else { return notFound(url) }
        switch (call.method, parts.count, parts.count > 2 ? parts[2] : nil) {
        case ("GET", 2, nil):
            if call.value("alt") == "media" {
                switch id {
                case "notes-1": return (Data("# Notes\n- ship it\n".utf8), Self.ok(url, type: "text/markdown"))
                case "pdf-1": return (Self.pdfBytes, Self.ok(url, type: "application/pdf"))
                default: return reply(url, 403, ["error": .object(["message": .string("Only files with binary content can be downloaded.")])])
                }
            }
            return reply(url, 200, file)
        case ("GET", 3, "export"?):
            switch (id, call.value("mimeType")) {
            case ("doc-1", "text/markdown"?): return (Data("# Launch plan\n\n1. Ship\n".utf8), Self.ok(url, type: "text/markdown"))
            case ("doc-1", "text/plain"?): return (Data("Launch plan\n1. Ship\n".utf8), Self.ok(url, type: "text/plain"))
            case ("doc-1", "application/pdf"?): return (Self.pdfBytes, Self.ok(url, type: "application/pdf"))
            case ("sheet-1", "text/csv"?): return (Data("item,cost\nservers,120\n".utf8), Self.ok(url, type: "text/csv"))
            case ("slides-1", "text/plain"?): return (Data("Kickoff\nGoals".utf8), Self.ok(url, type: "text/plain"))
            default: return badRequest(url)
            }
        case ("GET", 3, "permissions"?):
            return reply(url, 200, ["permissions": .array([
                .object(["id": .string("p1"), "type": .string("user"), "role": .string("owner"),
                         "emailAddress": .string("person@example.test"), "displayName": .string("Person")]),
                .object(["id": .string("p2"), "type": .string("domain"), "role": .string("reader"), "domain": .string("company.test")])
            ])])
        case ("GET", 3, "comments"?):
            return reply(url, 200, ["comments": .array([.object([
                "id": .string("c1"), "content": .string("Is this the final date?"), "resolved": .bool(false),
                "quotedFileContent": .object(["value": .string("1. Ship")]),
                "author": .object(["displayName": .string("Bob")]), "modifiedTime": .string("2026-10-18T10:00:00Z"),
                "replies": .array([.object(["content": .string("Yes."), "author": .object(["displayName": .string("Person")])])])
            ])])])
        case ("POST", 3, "copy"?):
            let copy = lock.withLock { created += 1; appFiles.insert("copy-\(created)"); return "copy-\(created)" }
            let body = call.json?.objectValue ?? [:]
            var made = Self.file(copy, name: body["name"]?.stringValue ?? "Copy of \(file["name"]?.stringValue ?? "")",
                                 mimeType: file["mimeType"]?.stringValue ?? Self.document)
            if let parents = body["parents"] { made["parents"] = parents }
            return reply(url, 200, made)
        case ("PATCH", 2, nil):
            // `drive.file` reaches only files the app created or copied.
            guard madeHere else {
                return reply(url, 403, ["error": .object(["code": .integer(403),
                    "message": .string("The user has not granted the app 123 write access to the file \(id).")])])
            }
            var metadata = call.json?.objectValue ?? [:]
            if upload {
                guard let (json, _) = Self.multipart(call.body, contentType: contentType ?? "") else { return badRequest(url) }
                metadata = json
            }
            for (key, value) in metadata { file[key] = value }
            if let add = call.value("addParents") { file["parents"] = .array([.string(add)]) }
            return reply(url, 200, file)
        default:
            return notFound(url)
        }
    }

    // MARK: Docs, Sheets, and Slides

    static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    static func run(_ text: String, _ start: Int, link: String? = nil) -> ToolJSON {
        var run: [String: ToolJSON] = ["content": .string(text)]
        if let link { run["textStyle"] = .object(["link": .object(["url": .string(link)])]) }
        return .object(["startIndex": .integer(Int64(start)), "endIndex": .integer(Int64(start + text.utf16.count)),
                        "textRun": .object(run)])
    }

    static func paragraph(_ start: Int, _ parts: [ToolJSON], style: String = "NORMAL_TEXT",
                          bullet: String? = nil) -> ToolJSON {
        let end = parts.compactMap { $0["endIndex"] }.last.flatMap { ConnectorToolArguments.integer($0) } ?? start
        var paragraph: [String: ToolJSON] = ["elements": .array(parts),
                                             "paragraphStyle": .object(["namedStyleType": .string(style)])]
        if let bullet { paragraph["bullet"] = .object(["listId": .string(bullet)]) }
        return .object(["startIndex": .integer(Int64(start)), "endIndex": .integer(Int64(end)), "paragraph": .object(paragraph)])
    }

    /// "Launch plan": a heading, a list item, a paragraph with a link and an image, a 2 × 2 table,
    /// and a last paragraph, at the indexes the Docs API would give them.
    static let launchPlanBody: [ToolJSON] = [
        .object(["endIndex": .integer(1), "sectionBreak": .object([:])]),
        paragraph(1, [run("Launch plan\n", 1)], style: "HEADING_1"),
        paragraph(13, [run("Ship\n", 13)], bullet: "kix.list1"),
        paragraph(18, [run("See ", 18), run("spec", 22, link: "https://example.test/spec"),
                       .object(["startIndex": .integer(26), "endIndex": .integer(27),
                                "inlineObjectElement": .object(["inlineObjectId": .string("kix.image1")])]),
                       run("\n", 27)]),
        .object(["startIndex": .integer(28), "endIndex": .integer(58), "table": .object([
            "rows": .integer(2), "columns": .integer(2),
            "tableRows": .array([
                .object(["startIndex": .integer(29), "endIndex": .integer(42), "tableCells": .array([
                    .object(["startIndex": .integer(30), "endIndex": .integer(36), "content": .array([paragraph(31, [run("Item\n", 31)])])]),
                    .object(["startIndex": .integer(36), "endIndex": .integer(42), "content": .array([paragraph(37, [run("Cost\n", 37)])])])
                ])]),
                .object(["startIndex": .integer(42), "endIndex": .integer(57), "tableCells": .array([
                    .object(["startIndex": .integer(43), "endIndex": .integer(52), "content": .array([paragraph(44, [run("Servers\n", 44)])])]),
                    .object(["startIndex": .integer(52), "endIndex": .integer(57), "content": .array([paragraph(53, [run("120\n", 53)])])])
                ])])
            ])
        ])]),
        paragraph(58, [run("Done.\n", 58)])
    ]

    /// A document long enough to come in parts: 2,000 paragraphs of 100 characters.
    static let longBody: [ToolJSON] = [.object(["endIndex": .integer(1), "sectionBreak": .object([:])])]
        + (0..<2_000).map { paragraph(1 + $0 * 100, [run(String(repeating: "x", count: 99) + "\n", 1 + $0 * 100)]) }

    private static func tab(_ id: String, _ title: String, _ body: [ToolJSON]) -> ToolJSON {
        .object(["tabProperties": .object(["tabId": .string(id), "title": .string(title), "index": .integer(0)]),
                 "documentTab": .object(["body": .object(["content": .array(body)])])])
    }

    private static func slide(_ id: String, title: String, body: String) -> ToolJSON {
        .object([
            "objectId": .string(id), "pageType": .string("SLIDE"),
            "slideProperties": .object([
                "layoutObjectId": .string("L1"),
                "notesPage": .object([
                    "notesProperties": .object(["speakerNotesObjectId": .string("\(id)-notes")]),
                    "pageElements": .array([.object(["objectId": .string("\(id)-notes"), "shape": .object([
                        "shapeType": .string("TEXT_BOX"),
                        "text": .object(["textElements": .array([.object(["textRun": .object(["content": .string("Say hello\n")])])])])
                    ])])])
                ])
            ]),
            "pageElements": .array([
                .object(["objectId": .string("\(id)-title"),
                         "size": .object(["width": .object(["magnitude": .integer(3_000_000), "unit": .string("EMU")])]),
                         "transform": .object(["translateX": .integer(311_700), "unit": .string("EMU")]),
                         "shape": .object(["shapeType": .string("TEXT_BOX"), "placeholder": .object(["type": .string("TITLE")]),
                                           "text": .object(["textElements": .array([
                                               .object(["paragraphMarker": .object([:])]),
                                               .object(["textRun": .object(["content": .string("\(title)\n")])])
                                           ])])])]),
                .object(["objectId": .string("\(id)-body"),
                         "shape": .object(["shapeType": .string("TEXT_BOX"), "placeholder": .object(["type": .string("BODY")]),
                                           "text": .object(["textElements": .array([
                                               .object(["textRun": .object(["content": .string("\(body)\n")])])
                                           ])])])]),
                .object(["objectId": .string("\(id)-image"), "image": .object(["contentUrl": .string("https://example.test/i.png")])])
            ])
        ])
    }

    private func editors(_ url: URL, _ call: Seen) -> (Data, HTTPURLResponse) {
        let host = url.host() ?? ""
        let base = ["docs.google.test": "/v1/", "sheets.google.test": "/v4/", "slides.google.test": "/v1/"][host] ?? "/"
        let parts = call.path.replacingOccurrences(of: base, with: "").split(separator: "/")
            .map { String($0).removingPercentEncoding ?? String($0) }
        guard let collection = parts.first, parts.count >= 2 else { return notFound(url) }
        var id = parts[1]
        let batch = id.hasSuffix(":batchUpdate")
        if batch { id = String(id.dropLast(":batchUpdate".count)) }
        let madeHere = lock.withLock { appFiles.contains(id) }
        // `drive.file` reaches only files the app created or copied, for writing.
        if batch || call.method == "PUT" {
            guard madeHere else {
                return reply(url, 403, ["error": .object(["code": .integer(403), "message": .string("The caller does not have permission")])])
            }
            if batch {
                let requests = call.json?["requests"]?.arrayValue ?? []
                var answer: [String: ToolJSON] = ["replies": .array(requests.map { request -> ToolJSON in
                    if request["addSheet"] != nil { return .object(["addSheet": .object(["properties": .object(["sheetId": .integer(123)])])]) }
                    if request["createSlide"] != nil { return .object(["createSlide": .object(["objectId": .string("new-slide")])]) }
                    return .object([:])
                })]
                if collection != "spreadsheets" { answer["writeControl"] = .object(["requiredRevisionId": .string("rev-8")]) }
                return reply(url, 200, answer)
            }
            let rows = call.json?["values"]?.arrayValue ?? []
            return reply(url, 200, ["spreadsheetId": .string(id), "updatedRange": .string(parts.count > 3 ? parts[3] : ""),
                                    "updatedRows": .integer(Int64(rows.count)),
                                    "updatedColumns": .integer(Int64(rows.first?.arrayValue?.count ?? 0)),
                                    "updatedCells": .integer(Int64(rows.reduce(0) { $0 + ($1.arrayValue?.count ?? 0) }))])
        }
        switch (collection, parts.count, id) {
        case ("documents", 2, "doc-1"):
            return reply(url, 200, ["documentId": .string("doc-1"), "title": .string("Launch plan"), "revisionId": .string("rev-7"),
                                    "body": .object([:]), "tabs": .array([Self.tab("t.0", "Tab 1", Self.launchPlanBody)])])
        case ("documents", 2, "doc-long"):
            return reply(url, 200, ["documentId": .string("doc-long"), "title": .string("Long"),
                                    "tabs": .array([Self.tab("t.0", "Tab 1", Self.longBody)])])
        case ("documents", 2, "doc-tabs"):
            var first = Self.tab("t.0", "Plan", Array(Self.launchPlanBody.prefix(2))).objectValue ?? [:]
            first["childTabs"] = .array([Self.tab("t.1", "Notes", [.object(["endIndex": .integer(1), "sectionBreak": .object([:])]),
                                                                   Self.paragraph(1, [Self.run("Child tab\n", 1)])])])
            return reply(url, 200, ["documentId": .string("doc-tabs"), "title": .string("Tabs"), "tabs": .array([.object(first)])])
        case ("spreadsheets", 2, "sheet-1"):
            if call.value("includeGridData") == "true" {
                return reply(url, 200, ["spreadsheetId": .string("sheet-1"), "sheets": .array([.object(["data": .array([
                    .object(["rowData": .array(Array(repeating: .object(["values": .array(Array(repeating:
                        .object(["formattedValue": .string("0123456789")]), count: 26))]), count: 1_000))])
                ])])])])
            }
            return reply(url, 200, [
                "spreadsheetId": .string("sheet-1"), "spreadsheetUrl": .string("https://docs.google.com/spreadsheets/d/sheet-1/edit"),
                "properties": .object(["title": .string("Budget"), "locale": .string("ko_KR"), "timeZone": .string("Asia/Seoul")]),
                "sheets": .array([
                    .object(["properties": .object(["sheetId": .integer(0), "title": .string("Costs"), "index": .integer(0),
                                                    "sheetType": .string("GRID"),
                                                    "gridProperties": .object(["rowCount": .integer(1_000), "columnCount": .integer(26),
                                                                               "frozenRowCount": .integer(1)])])]),
                    .object(["properties": .object(["sheetId": .integer(77), "title": .string("Chart"), "index": .integer(1),
                                                    "sheetType": .string("OBJECT")])])
                ])
            ])
        case ("spreadsheets", 4, "sheet-1") where parts[2] == "values":
            let range = parts[3]
            if range == "Data!A1:D3000" {
                return reply(url, 200, ["range": .string(range), "majorDimension": .string("ROWS"), "values": .array(
                    (1...3_000).map { row in .array([.string("item \(row)"), .integer(Int64(row)), .number(Double(row) / 4),
                                                     .string("note for row \(row)")]) })])
            }
            let formulas = call.value("valueRenderOption") == "FORMULA"
            return reply(url, 200, ["range": .string("Costs!A1:B3"), "majorDimension": .string("ROWS"), "values": .array([
                .array([.string("item"), .string("cost")]), .array([.string("servers"), .string("120")]),
                .array([.string("total"), .string(formulas ? "=SUM(B2:B2)" : "120")])
            ])])
        case ("presentations", 2, "slides-1"):
            return reply(url, 200, ["presentationId": .string("slides-1"), "title": .string("Kickoff"), "revisionId": .string("r-3"),
                                    "pageSize": .object(["width": .object(["magnitude": .integer(9_144_000), "unit": .string("EMU")])]),
                                    "layouts": .array([.object(["objectId": .string("L1"), "layoutProperties": .object([
                                        "name": .string("TITLE_AND_BODY"), "displayName": .string("Title and body")])])]),
                                    "slides": .array([Self.slide("p1", title: "Kickoff", body: "Goals"),
                                                      Self.slide("p2", title: "Plan", body: "Ship it")])])
        case ("presentations", 2, "deck-long"):
            return reply(url, 200, ["presentationId": .string("deck-long"), "title": .string("Long deck"),
                                    "slides": .array((0..<300).map { Self.slide("s\($0)", title: "Slide \($0)",
                                                                                  body: String(repeating: "y", count: 500)) })])
        case ("presentations", 4, "slides-1") where parts[2] == "pages" && parts[3] == "p2":
            return reply(url, 200, Self.slide("p2", title: "Plan", body: "Ship it").objectValue ?? [:])
        case ("presentations", 5, "slides-1") where parts[2] == "pages" && parts[4] == "thumbnail":
            return reply(url, 200, ["width": .integer(800), "height": .integer(450),
                                    "contentUrl": .string("https://thumbnails.google.test/\(parts[3]).png")])
        default:
            return notFound(url)
        }
    }

    /// A `multipart/related` upload's JSON metadata and its content as text.
    static func multipart(_ body: Data?, contentType: String) -> ([String: ToolJSON], String)? {
        guard let body, let boundary = contentType.components(separatedBy: "boundary=").last else { return nil }
        let text = String(decoding: body, as: UTF8.self)
        // Before the first boundary nothing; after the last, `--`. Each part is CRLF, its headers,
        // a blank line, its content, and the CRLF before the next boundary.
        let sections = text.components(separatedBy: "--\(boundary)").dropFirst().filter { !$0.hasPrefix("--") }
        guard sections.count == 2 else { return nil }
        func content(_ section: String) -> String {
            var part = section
            if part.hasPrefix("\r\n") { part.removeFirst() }
            if part.hasSuffix("\r\n") { part.removeLast() }
            return part.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        }
        guard let metadata = try? JSONDecoder().decode(ToolJSON.self, from: Data(content(sections[0]).utf8)).objectValue else { return nil }
        return (metadata, content(sections[1]))
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
