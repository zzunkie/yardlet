import Foundation
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Yardlet's own Microsoft 365 servers (docs/CONNECTORS.md, "Microsoft 365"): one sign-in per
/// Microsoft account as a public client with PKCE on the fixed loopback, the account named by its
/// Graph profile, refreshes that name the permissions and keep the rotated refresh token, and the
/// Graph requests behind Outlook mail and calendar, OneDrive, and Teams tools, with the harness
/// asking before every write. Microsoft is a local fake here: nothing leaves the machine and no
/// real account signs in.
@MainActor
final class MicrosoftConnectorTests: XCTestCase {
    private func makeCenter(
        microsoft: FakeMicrosoft = FakeMicrosoft(),
        agent: FakeUserAgent = FakeUserAgent(),
        credentials: InMemoryConnectorCredentialStore = InMemoryConnectorCredentialStore(),
        builtIn: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> ConnectorCenter {
        var environment = ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(), credentials: credentials, http: microsoft, userAgent: agent,
            sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9", now: now)
        environment.microsoft = FakeMicrosoft.endpoints
        environment.microsoftBuiltInApp = builtIn ? MicrosoftOAuth.BuiltInApp(clientID: FakeMicrosoft.clientID) : nil
        environment.timeZone = { TimeZone(identifier: "Asia/Seoul")! }
        return ConnectorCenter(environment: environment)
    }

    private func signedIn(
        _ services: Set<LocalConnectorService> = Set(LocalConnectorService.microsoft),
        microsoft: FakeMicrosoft = FakeMicrosoft(),
        agent: FakeUserAgent = FakeUserAgent(),
        credentials: InMemoryConnectorCredentialStore = InMemoryConnectorCredentialStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> (ConnectorCenter, ConnectorCenter.ServiceAccount) {
        let center = makeCenter(microsoft: microsoft, agent: agent, credentials: credentials, now: now)
        let account = try XCTUnwrap(center.addAccount(services: services))
        await center.waitForConnection(account.id)
        let settled = try XCTUnwrap(center.microsoftAccounts.first)
        XCTAssertEqual(settled.services.map(\.status), Array(repeating: .connected, count: services.count),
                       settled.services.compactMap { center.failures[$0.id] }.joined(separator: "; "))
        return (center, settled)
    }

    private func call(_ center: ConnectorCenter, _ name: String, _ arguments: [String: ToolJSON] = [:],
                      folders: [URL] = []) async throws -> AgentToolResult {
        try XCTUnwrapAsync(await center.callConnectorTool(named: name, arguments: .object(arguments),
                                                          for: ConnectorToolContext(workspaceRoots: folders)))
    }

    private func json(_ result: AgentToolResult, file: StaticString = #filePath, line: UInt = #line) throws -> ToolJSON {
        XCTAssertFalse(result.isError, result.text, file: file, line: line)
        return try JSONDecoder().decode(ToolJSON.self, from: Data(result.text.utf8))
    }

    // MARK: - Sign-in

    /// The browser goes to the common tenant's authorization page with the app's client ID, the
    /// services' Graph permissions with offline access and the profile, the account chooser,
    /// PKCE, and the fixed loopback; the code is exchanged with no secret; Graph's profile names
    /// the account and its four connectors.
    func testAnAccountSignsInAsAPublicClientAndIsNamedByItsProfile() async throws {
        let microsoft = FakeMicrosoft()
        let agent = FakeUserAgent()
        let credentials = InMemoryConnectorCredentialStore()
        let (center, account) = try await signedIn(microsoft: microsoft, agent: agent, credentials: credentials)

        XCTAssertEqual(account.address, "person@contoso.test")
        XCTAssertEqual(account.services.map(\.slug), ["outlook", "outlook_calendar", "onedrive", "teams"])
        XCTAssertEqual(agent.loopbackPorts, [ConnectorOAuth.registeredClientRedirectPort])
        let opened = try XCTUnwrap(agent.opened.first)
        XCTAssertEqual(opened.host(), "login.microsoft.test")
        XCTAssertEqual(opened.path(), "/common/oauth2/v2.0/authorize")
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["client_id"], FakeMicrosoft.clientID)
        XCTAssertEqual(query["prompt"], "select_account")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertNil(query["resource"])
        XCTAssertEqual(query["scope"], "offline_access User.Read Mail.ReadWrite Mail.Send Calendars.ReadWrite Files.ReadWrite "
            + "Chat.Read ChatMessage.Send Team.ReadBasic.All Channel.ReadBasic.All ChannelMessage.Send")

        let exchange = try XCTUnwrap(microsoft.tokenForms.first)
        XCTAssertEqual(exchange["grant_type"], "authorization_code")
        XCTAssertEqual(exchange["client_id"], FakeMicrosoft.clientID)
        XCTAssertNil(exchange["client_secret"], "A public client sends no secret")
        let stored = try XCTUnwrap(try credentials.load(account.id))
        XCTAssertEqual(stored.tokenEndpoint?.absoluteString, "https://login.microsoft.test/common/oauth2/v2.0/token")
        XCTAssertEqual(stored.refreshScope, query["scope"])
        XCTAssertEqual(center.record(account.services[0].id)?.displayName, "Outlook Mail · person@contoso.test")
    }

    func testWithoutAnAppNoBrowserOpens() async throws {
        let agent = FakeUserAgent()
        let center = makeCenter(agent: agent, builtIn: false)
        XCTAssertFalse(center.canSignInWithMicrosoft)
        let account = try XCTUnwrap(center.addAccount(services: [.outlookMail]))
        await center.waitForConnection(account.id)
        XCTAssertEqual(center.failures[account.id], MicrosoftSignInError.noApp.errorDescription)
        XCTAssertTrue(agent.opened.isEmpty)

        // An app of the person's own, in one directory, signs in there instead.
        center.saveMicrosoftApp(clientID: " \(FakeMicrosoft.clientID) ", tenant: "contoso.onmicrosoft.com")
        XCTAssertEqual(center.microsoftApp, MicrosoftOAuth.App(clientID: FakeMicrosoft.clientID, tenant: "contoso.onmicrosoft.com"))
        center.connect(account.id)
        await center.waitForConnection(account.id)
        XCTAssertEqual(agent.opened.first?.path(), "/contoso.onmicrosoft.com/oauth2/v2.0/authorize")
        XCTAssertEqual(center.record(account.id)?.status, .connected)
    }

    /// Microsoft rotates refresh tokens: a refresh names the permissions again and keeps the new
    /// one; a refresh Microsoft refuses leaves every service of the account needing sign-in.
    func testRefreshNamesThePermissionsKeepsTheRotatedTokenAndARefusalNeedsSignIn() async throws {
        let microsoft = FakeMicrosoft()
        let credentials = InMemoryConnectorCredentialStore()
        let (center, account) = try await signedIn([.outlookMail, .oneDrive], microsoft: microsoft, credentials: credentials)
        microsoft.forgetAccessTokens()
        _ = try json(try await call(center, "outlook_list_folders"))
        let refresh = try XCTUnwrap(microsoft.tokenForms.last)
        XCTAssertEqual(refresh["grant_type"], "refresh_token")
        XCTAssertEqual(refresh["scope"], "offline_access User.Read Mail.ReadWrite Mail.Send Files.ReadWrite")
        XCTAssertEqual(try credentials.load(account.id)?.refreshToken, "refresh-2")

        microsoft.revokeRefreshTokens()
        microsoft.forgetAccessTokens()
        let failed = try await call(center, "onedrive_list_folder")
        XCTAssertTrue(failed.isError)
        XCTAssertTrue(failed.text.contains("sign in again"), failed.text)
        XCTAssertEqual(center.microsoftAccounts.first?.services.map(\.status), [.signInRequired, .signInRequired])
    }

    // MARK: - Tools

    func testMailSearchesSendsRepliesAndAttachesFilesThroughGraph() async throws {
        let microsoft = FakeMicrosoft()
        let (center, _) = try await signedIn([.outlookMail], microsoft: microsoft)

        let found = try json(try await call(center, "outlook_search_messages", ["query": .string("from:ana invoice")]))
        let search = try XCTUnwrap(microsoft.graphRequests.last?.url)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["$search"], "\"from:ana invoice\"")
        XCTAssertNil(items["$orderby"], "Graph takes no $orderby with $search")
        XCTAssertEqual(found["messages"]?.arrayValue?.first?["from"], .string("Ana <ana@contoso.test>"))
        XCTAssertEqual(found["nextPageToken"], .string("https://graph.microsoft.test/v1.0/me/messages?$skiptoken=2"))

        // A page link that points elsewhere is refused before any request carries the token.
        let before = microsoft.graphRequests.count
        let foreign = try await call(center, "outlook_search_messages", ["pageToken": .string("https://evil.test/v1.0/me/messages")])
        XCTAssertTrue(foreign.isError)
        XCTAssertEqual(microsoft.graphRequests.count, before)

        _ = try json(try await call(center, "outlook_send_message", [
            "to": .array([.string("bo@contoso.test")]), "subject": .string("Hi"), "body": .string("Hello")
        ]))
        let send = try XCTUnwrap(microsoft.posted.last)
        XCTAssertEqual(send.path, "/v1.0/me/sendMail")
        XCTAssertEqual(send.body["message"]?["toRecipients"]?.arrayValue?.first?["emailAddress"]?["address"], .string("bo@contoso.test"))
        XCTAssertEqual(send.body["message"]?["body"], .object(["contentType": .string("Text"), "content": .string("Hello")]))
        XCTAssertEqual(send.body["saveToSentItems"], .bool(true))

        _ = try json(try await call(center, "outlook_send_message", ["replyToMessageId": .string("m1"), "body": .string("Thanks")]))
        XCTAssertEqual(microsoft.posted.last?.path, "/v1.0/me/messages/m1/reply")
        XCTAssertEqual(microsoft.posted.last?.body, .object(["comment": .string("Thanks")]), "A comment keeps the quoted original")

        let refused = try await call(center, "outlook_send_message", ["to": .array([.string("a@b.test, c@d.test")])])
        XCTAssertTrue(refused.isError)

        // Files go on a saved draft, one request each, by Gmail's rules; a send with files is that draft, sent.
        let folder = FileManager.default.temporaryDirectory.appending(path: "yardlet-outlook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = folder.appending(path: "보고서.pdf".decomposedStringWithCanonicalMapping)
        let reportBytes = Data(repeating: 7, count: 2_048)
        try reportBytes.write(to: report)
        let drafted = try json(try await call(center, "outlook_create_draft", [
            "to": .array([.string("bo@contoso.test")]), "subject": .string("Report"), "body": .string("Attached."),
            "attachments": .array([.string(report.path(percentEncoded: false))])
        ], folders: [folder]))
        XCTAssertEqual(drafted["id"], .string("d1"))
        XCTAssertEqual(drafted["attachments"]?.arrayValue?.first?["filename"], .string("보고서.pdf"))
        let file = try XCTUnwrap(microsoft.posted.last)
        XCTAssertEqual(file.path, "/v1.0/me/messages/d1/attachments")
        XCTAssertEqual(file.body["@odata.type"], .string("#microsoft.graph.fileAttachment"))
        XCTAssertEqual(file.body["name"], .string("보고서.pdf"))
        XCTAssertEqual(file.body["contentBytes"], .string(reportBytes.base64EncodedString()))

        _ = try json(try await call(center, "outlook_send_message", [
            "to": .string("bo@contoso.test"), "subject": .string("Report"), "attachments": .string(report.path(percentEncoded: false))
        ], folders: [folder]))
        XCTAssertEqual(microsoft.posted.suffix(3).map(\.path),
                       ["/v1.0/me/messages", "/v1.0/me/messages/d1/attachments", "/v1.0/me/messages/d1/send"])

        // A file over the 3 MB one request carries, or from outside the folders, is refused before anything is made.
        let posts = microsoft.posted.count
        let large = folder.appending(path: "video.mov")
        FileManager.default.createFile(atPath: large.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(OutlookMailTransport.attachmentLimit + 1))
        try handle.close()
        for (path, reason) in [(large.path(percentEncoded: false), "at most 3 MB"), ("/etc/hosts", "files come from")] {
            let refused = try await call(center, "outlook_send_message", ["to": .string("bo@contoso.test"),
                                                                          "attachments": .string(path)], folders: [folder])
            XCTAssertTrue(refused.isError && refused.text.contains(reason), "\(path): \(refused.text)")
        }
        XCTAssertEqual(microsoft.posted.count, posts)

        // The cards name the files: a send's from the disk, a draft's as Outlook keeps it.
        let size = ByteCountFormatter.string(fromByteCount: 2_048, countStyle: .file)
        let sending = try XCTUnwrap(GoogleToolApproval.request(toolName: "mcp__yardlet__outlook_send_message", input: .object([
            "to": .string("bo@contoso.test"), "attachments": .array([.string(report.path(percentEncoded: false))])
        ])))
        XCTAssertTrue(sending.detail.contains(L10n.format("Attachments: %@", size)), sending.detail)
        XCTAssertTrue(sending.detail.contains("• 보고서.pdf (\(size))"), sending.detail)
        XCTAssertTrue(GmailToolApproval.readsDraft(toolName: "mcp__yardlet__outlook_send_draft"))
        let preview = await center.mailDraftPreview(tool: "outlook_send_draft", arguments: ["draftId": .string("d1")])
        let draftCard = try XCTUnwrap(GoogleToolApproval.request(toolName: "mcp__yardlet__outlook_send_draft",
                                                                 input: .object(["draftId": .string("d1")]), mailDraft: preview))
        XCTAssertEqual(draftCard.title, L10n.format("Allow Claude to send a draft from %@?", "person@contoso.test"))
        XCTAssertTrue(draftCard.detail.contains(L10n.format("To: %@", "Bo <bo@contoso.test>")), draftCard.detail)
        XCTAssertTrue(draftCard.detail.contains("• 보고서.pdf (\(size))"), draftCard.detail)
        XCTAssertFalse(draftCard.detail.contains("logo.png"), "An inline image is the body's, not a file")
        XCTAssertTrue(draftCard.detail.contains("Attached."), draftCard.detail)
    }

    /// Times go to Graph in UTC and come back with the offset of the call's zone; a personal
    /// account, which has no free and busy times, still gets suggestions from its own events.
    func testCalendarSendsUTCAndSuggestsTimesWithoutGetSchedule() async throws {
        let microsoft = FakeMicrosoft()
        let (center, _) = try await signedIn([.outlookCalendar], microsoft: microsoft)

        let created = try json(try await call(center, "outlook_calendar_create_event", [
            "summary": .string("Review"), "startTime": .string("2026-10-28T10:00:00"), "endTime": .string("2026-10-28T11:00:00"),
            "attendeeEmails": .array([.string("bo@contoso.test")]), "addTeamsMeeting": .bool(true)
        ]))
        let body = try XCTUnwrap(microsoft.posted.last?.body)
        XCTAssertEqual(body["start"], .object(["dateTime": .string("2026-10-28T01:00:00"), "timeZone": .string("UTC")]))
        XCTAssertEqual(body["subject"], .string("Review"))
        XCTAssertEqual(body["onlineMeetingProvider"], .string("teamsForBusiness"))
        XCTAssertEqual(created["start"], .string("2026-10-28T10:00:00+09:00"))

        microsoft.scheduleUnavailable = true
        let suggested = try json(try await call(center, "outlook_calendar_suggest_time", [
            "attendeeEmails": .array([.string("bo@contoso.test")]),
            "startTime": .string("2026-10-28T09:00:00"), "endTime": .string("2026-10-28T12:00:00"), "durationMinutes": .integer(60)
        ]))
        XCTAssertEqual(suggested["timeSlots"]?.arrayValue?[0]["startTime"], .string("2026-10-28T09:00:00+09:00"))
        XCTAssertEqual(suggested["timeSlots"]?.arrayValue?[1]["startTime"], .string("2026-10-28T11:00:00+09:00"), "10:00 to 11:00 is busy")
        XCTAssertEqual(suggested["unavailableCalendars"]?.arrayValue?.first?["calendar"], .string("bo@contoso.test"))
    }

    func testOneDriveNeverReplacesAFileAndDownloadsWithoutTheToken() async throws {
        let microsoft = FakeMicrosoft()
        let (center, _) = try await signedIn([.oneDrive], microsoft: microsoft)

        _ = try json(try await call(center, "onedrive_upload_file", ["name": .string("notes.md"), "content": .string("# Notes")]))
        let upload = try XCTUnwrap(microsoft.graphRequests.last)
        XCTAssertEqual(upload.httpMethod, "PUT")
        XCTAssertEqual(upload.url?.path(), "/v1.0/me/drive/root:/notes.md:/content")
        XCTAssertEqual(URLComponents(url: upload.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "fail")
        let replacing = try await call(center, "onedrive_upload_file", ["name": .string("a"), "conflictBehavior": .string("replace")])
        XCTAssertTrue(replacing.isError)
        let outside = try await call(center, "onedrive_upload_file", ["name": .string("../a")])
        XCTAssertTrue(outside.isError)

        let read = try json(try await call(center, "onedrive_read_file_content", ["itemId": .string("f1")]))
        XCTAssertEqual(read["content"], .string("hello"))
        let download = try XCTUnwrap(microsoft.requests.last { $0.url?.host() == "download.microsoft.test" })
        XCTAssertNil(download.value(forHTTPHeaderField: "Authorization"), "The download address carries its own authorization")
    }

    func testTeamsSendsAsTheAccountAndTheCardSaysWhere() async throws {
        let microsoft = FakeMicrosoft()
        let (center, _) = try await signedIn([.teams], microsoft: microsoft)
        _ = try json(try await call(center, "teams_send_chat_message", ["chatId": .string("19:abc@thread.v2"), "content": .string("On my way")]))
        XCTAssertEqual(microsoft.posted.last?.path, "/v1.0/chats/19%3Aabc%40thread.v2/messages")
        XCTAssertEqual(microsoft.posted.last?.body["body"], .object(["contentType": .string("text"), "content": .string("On my way")]))

        XCTAssertEqual(LocalConnectorService.teams.approvalRequiredTools, ["send_chat_message", "send_channel_message"])
        let card = try XCTUnwrap(GoogleToolApproval.request(toolName: "mcp__yardlet__teams_send_chat_message",
                                                            input: .object(["chatId": .string("19:abc"), "content": .string("On my way")])))
        XCTAssertEqual(card.title, L10n.format("Allow Claude to send a Teams message as %@?", "person@contoso.test"))
        XCTAssertEqual(card.detail, L10n.format("Chat %@", "19:abc") + "\n\nOn my way")
        XCTAssertNil(GoogleToolApproval.request(toolName: "mcp__yardlet__teams_list_chats", input: .object([:])))
    }
}

/// Microsoft's identity platform and Graph for one mailbox, calendar, drive, and chat, as the
/// documentation describes their requests and answers. Tokens map to the account that signed in;
/// refresh tokens rotate on every use.
final class FakeMicrosoft: ConnectorHTTPTransport, @unchecked Sendable {
    static let endpoints = MicrosoftOAuth.Endpoints(login: URL(string: "https://login.microsoft.test/")!,
                                                    graph: URL(string: "https://graph.microsoft.test/v1.0/")!)
    static let clientID = "11111111-2222-3333-4444-555555555555"

    struct Post: Equatable {
        var path: String
        var body: ToolJSON
    }

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var forms: [[String: String]] = []
    private var posts: [Post] = []
    private var accessTokens: Set<String> = []
    private var liveRefresh: String?
    private var issued = 0
    private var noSchedule = false

    var requests: [URLRequest] { lock.withLock { recorded } }
    var graphRequests: [URLRequest] { requests.filter { $0.url?.host() == "graph.microsoft.test" } }
    var tokenForms: [[String: String]] { lock.withLock { forms } }
    var posted: [Post] { lock.withLock { posts } }
    /// getSchedule answers as for a personal account, which has none.
    var scheduleUnavailable: Bool {
        get { lock.withLock { noSchedule } }
        set { lock.withLock { noSchedule = newValue } }
    }

    func forgetAccessTokens() { lock.withLock { accessTokens.removeAll() } }
    func revokeRefreshTokens() { lock.withLock { liveRefresh = nil } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        guard let url = request.url else { throw URLError(.badURL) }
        if url.host() == "login.microsoft.test", url.path().hasSuffix("/oauth2/v2.0/token") { return token(request) }
        if url.host() == "download.microsoft.test" { return (Data("hello".utf8), Self.ok(url)) }
        guard url.host() == "graph.microsoft.test" else { return Self.reply(url, 404, [:]) }
        let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
        guard let token, lock.withLock({ accessTokens.contains(token) }) else {
            return Self.reply(url, 401, ["error": .object(["code": .string("InvalidAuthenticationToken"),
                                                           "message": .string("Access token has expired or is not yet valid.")])])
        }
        let body = request.httpBody.flatMap { try? JSONDecoder().decode(ToolJSON.self, from: $0) } ?? .null
        if request.httpMethod == "POST" { lock.withLock { posts.append(Post(path: url.path(percentEncoded: true), body: body)) } }
        return graph(url, method: request.httpMethod ?? "GET", body: body)
    }

    private func token(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        let url = request.url!
        let form = FakeConnectorServer.form(request)
        lock.withLock { forms.append(form) }
        guard form["client_id"] == Self.clientID, form["client_secret"] == nil else {
            return Self.reply(url, 401, ["error": .string("invalid_client")])
        }
        return lock.withLock {
            switch form["grant_type"] {
            case "authorization_code":
                guard form["code"] == FakeConnectorServer.code, form["code_verifier"] != nil else {
                    return Self.reply(url, 400, ["error": .string("invalid_grant")])
                }
            case "refresh_token":
                guard let refresh = form["refresh_token"], refresh == liveRefresh else {
                    return Self.reply(url, 400, ["error": .string("invalid_grant"),
                                                 "error_description": .string("AADSTS700082: The refresh token has expired.")])
                }
            default:
                return Self.reply(url, 400, ["error": .string("unsupported_grant_type")])
            }
            issued += 1
            let access = "access-\(issued)"
            accessTokens.insert(access)
            liveRefresh = "refresh-\(issued)"
            // The identity platform lists Graph's permissions with its address, in its own case.
            return Self.reply(url, 200, ["access_token": .string(access), "refresh_token": .string("refresh-\(issued)"),
                                         "expires_in": .integer(3_600), "token_type": .string("Bearer"),
                                         "scope": .string("https://graph.microsoft.com/mail.readwrite https://graph.microsoft.com/Mail.Send "
                                             + "https://graph.microsoft.com/Calendars.ReadWrite https://graph.microsoft.com/Files.ReadWrite "
                                             + "Chat.Read ChatMessage.Send Team.ReadBasic.All Channel.ReadBasic.All ChannelMessage.Send "
                                             + "User.Read")])
        }
    }

    private func graph(_ url: URL, method: String, body: ToolJSON) -> (Data, HTTPURLResponse) {
        let path = url.path(percentEncoded: true).replacingOccurrences(of: "/v1.0/", with: "")
        switch (method, path) {
        case ("GET", "me"):
            return Self.reply(url, 200, ["mail": .string("person@contoso.test"), "userPrincipalName": .string("person@contoso.test")])
        case ("GET", "me/messages"):
            return Self.reply(url, 200, [
                "value": .array([.object(["id": .string("m1"), "subject": .string("Invoice"), "isRead": .bool(false),
                                          "from": .object(["emailAddress": .object(["name": .string("Ana"), "address": .string("ana@contoso.test")])]),
                                          "toRecipients": .array([])])]),
                "@odata.nextLink": .string("https://graph.microsoft.test/v1.0/me/messages?$skiptoken=2")
            ])
        case ("GET", "me/mailFolders"):
            return Self.reply(url, 200, ["value": .array([.object(["id": .string("inbox-id"), "displayName": .string("Inbox")])])])
        case ("POST", "me/sendMail"), ("POST", "me/messages/m1/reply"), ("POST", "me/messages/d1/send"):
            return (Data(), Self.ok(url, status: 202))
        case ("POST", "me/messages"):
            return Self.reply(url, 201, ["id": .string("d1"), "conversationId": .string("c-d1"), "subject": body["subject"] ?? .null,
                                         "toRecipients": body["toRecipients"] ?? .array([]), "isDraft": .bool(true)])
        case ("POST", "me/messages/d1/attachments"):
            return Self.reply(url, 201, ["id": .string("a1"), "name": body["name"] ?? .null])
        case ("GET", "me/messages/d1"):
            func file(_ id: String, _ name: String, _ size: Int64, inline: Bool) -> ToolJSON {
                .object(["id": .string(id), "name": .string(name), "size": .integer(size), "isInline": .bool(inline)])
            }
            return Self.reply(url, 200, [
                "id": .string("d1"), "subject": .string("Report"), "isDraft": .bool(true),
                "toRecipients": .array([.object(["emailAddress": .object(["name": .string("Bo"), "address": .string("bo@contoso.test")])])]),
                "lastModifiedDateTime": .string("2026-10-27T09:00:00Z"),
                "body": .object(["contentType": .string("text"), "content": .string("Attached.")]),
                "attachments": .array([file("a1", "보고서.pdf", 2_048, inline: false), file("a2", "logo.png", 10, inline: true)])
            ])
        case ("POST", "me/events"):
            return Self.reply(url, 201, ["id": .string("e1"), "subject": body["subject"] ?? .null, "start": body["start"] ?? .null,
                                         "end": body["end"] ?? .null, "isAllDay": .bool(false)])
        case ("POST", "me/calendar/getSchedule"):
            if scheduleUnavailable {
                return Self.reply(url, 400, ["error": .object(["code": .string("ErrorInvalidRequest"),
                                                               "message": .string("Not supported for personal accounts.")])])
            }
            return Self.reply(url, 200, ["value": .array([])])
        case ("GET", "me/calendarView"):
            return Self.reply(url, 200, ["value": .array([.object([
                "start": .object(["dateTime": .string("2026-10-28T01:00:00.0000000"), "timeZone": .string("UTC")]),
                "end": .object(["dateTime": .string("2026-10-28T02:00:00.0000000"), "timeZone": .string("UTC")]),
                "showAs": .string("busy")
            ])])])
        case ("GET", "me/drive/root/children"):
            return Self.reply(url, 200, ["value": .array([])])
        case ("PUT", "me/drive/root:/notes.md:/content"):
            return Self.reply(url, 201, ["id": .string("f2"), "name": .string("notes.md"), "file": .object(["mimeType": .string("text/markdown")])])
        case ("GET", "me/drive/items/f1"):
            return Self.reply(url, 200, ["id": .string("f1"), "name": .string("hello.txt"), "size": .integer(5),
                                         "file": .object(["mimeType": .string("text/plain")]),
                                         "@microsoft.graph.downloadUrl": .string("https://download.microsoft.test/f1?sig=x")])
        case ("POST", "chats/19%3Aabc%40thread.v2/messages"):
            return Self.reply(url, 201, ["id": .string("c1"), "createdDateTime": .string("2026-10-27T09:00:00Z")])
        default:
            return Self.reply(url, 404, ["error": .object(["code": .string("itemNotFound"), "message": .string("Not found: \(method) \(path)")])])
        }
    }

    private static func ok(_ url: URL, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
    }

    private static func reply(_ url: URL, _ status: Int, _ body: [String: ToolJSON]) -> (Data, HTTPURLResponse) {
        ((try? JSONEncoder().encode(ToolJSON.object(body))) ?? Data(),
         HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }
}
