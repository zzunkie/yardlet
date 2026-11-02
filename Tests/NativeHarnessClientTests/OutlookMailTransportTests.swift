import Foundation
import XCTest
import YardletAgentTools
@testable import NativeHarnessClient

/// The mailbox's Outlook account against a fake Microsoft Graph: a folder's newest messages become one
/// line per conversation, a conversation is read in full only when opened, read state and moves are
/// asked message by message, a reply starts from Graph's own reply, and the inbox's delta link tells what
/// arrived after it was taken.
final class OutlookMailTransportTests: XCTestCase {
    func testConversationsAreListedReadChangedAndAnsweredThroughGraph() async throws {
        let graph = FakeGraphMail()
        let account = MailAccount(id: UUID(), address: "dana@contoso.example", provider: .outlook, connectorSlug: "outlook")
        let session = OAuthAPISession(id: account.id, credentials: InMemoryConnectorCredentialStore(), http: graph, now: { Date() })
        await session.use(ConnectorCredential(kind: .oauth, accessToken: "token", expiresAt: .distantFuture))
        let transport = OutlookMailTransport(api: GraphAPI(base: URL(string: "https://graph.microsoft.com/v1.0/")!, session: session),
                                             account: account)

        let folders = try await transport.folders()
        XCTAssertEqual(folders.map(\.role), [.inbox, .sent, .drafts, .archive, .spam, .trash, .label])
        XCTAssertEqual(folders.first?.name, "받은 편지함", "Outlook's own name in the account's language")
        XCTAssertEqual(folders.first?.unreadCount, 1)
        XCTAssertEqual(folders.last?.name, "Clients")

        let page = try await transport.inbox(pageToken: nil)
        XCTAssertEqual(page.threads.map(\.id.threadID), ["conv-quote", "conv-ci"], "One line per conversation, newest first")
        let quote = try XCTUnwrap(page.threads.first)
        XCTAssertEqual(quote.senders.map(\.displayName), ["Haneul Kim"])
        XCTAssertEqual(quote.messageCount, 2)
        XCTAssertTrue(quote.isUnread)
        XCTAssertTrue(quote.isStarred)
        XCTAssertEqual(page.nextPageToken, "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages?$skip=50")
        let list = try XCTUnwrap(graph.requests.first { $0.path == "/v1.0/me/mailFolders/inbox/messages" })
        XCTAssertEqual(list.query["$orderby"], ["receivedDateTime desc"])
        XCTAssertFalse(list.query["$select"]?.first?.contains("body,") ?? true, "A list reads no body")

        let thread = try await transport.thread("conv-quote")
        XCTAssertEqual(thread.messages.map(\.id), ["m1", "m2"], "Oldest first")
        XCTAssertEqual(thread.messages[1].html, "<p>Revised quote attached.</p>")
        XCTAssertEqual(thread.messages[1].text, "Revised quote attached.")
        XCTAssertEqual(thread.messages[1].attachments.map(\.name), ["quote-v3.pdf"])
        XCTAssertEqual(thread.webURL?.absoluteString, "https://outlook.office.com/mail/m2")
        let read = try XCTUnwrap(graph.requests.first { $0.query["$filter"] == ["conversationId eq 'conv-quote'"] })
        XCTAssertEqual(read.headers["Prefer"], "outlook.body-content-type=\"html\"")
        XCTAssertFalse(graph.requests.contains { $0.method != "GET" }, "Reading changes nothing")

        try await transport.change("conv-quote", .read(true))
        try await transport.change("conv-quote", .archived)
        let writes = graph.requests.filter { $0.method != "GET" }.map { "\($0.method) \($0.path)" }
        XCTAssertEqual(writes, ["PATCH /v1.0/me/messages/m2", "POST /v1.0/me/messages/m1/move", "POST /v1.0/me/messages/m2/move"],
                       "Only the unread message is marked read; the inbox's messages move to the archive")

        var reply = MailComposition.answering(thread.messages[1], in: thread, as: .reply, from: account)
        reply.body = "Thanks, I'll reply by Thursday." + reply.body
        let draft = try await transport.saveDraft(reply)
        XCTAssertEqual(draft, "draft-1")
        let replyWrites = graph.requests.filter { $0.method != "GET" }.suffix(2)
        XCTAssertEqual(replyWrites.map { "\($0.method) \($0.path)" },
                       ["POST /v1.0/me/messages/m2/createReply", "PATCH /v1.0/me/messages/draft-1"])
        XCTAssertEqual(replyWrites.last?.body?["toRecipients"]?.arrayValue?.first?["emailAddress"]?["address"]?.stringValue,
                       "haneul@fabrikam.example")
        XCTAssertEqual(replyWrites.last?.body?["body"]?["contentType"]?.stringValue, "Text")
    }

    /// The inbox's delta link: a message that came unread after the cursor was taken arrived; a link
    /// Graph no longer knows starts again from a fresh one.
    func testTheInboxDeltaTellsWhatArrived() async throws {
        let graph = FakeGraphMail()
        let account = MailAccount(id: UUID(), address: "dana@contoso.example", provider: .outlook)
        let session = OAuthAPISession(id: account.id, credentials: InMemoryConnectorCredentialStore(), http: graph, now: { Date() })
        await session.use(ConnectorCredential(kind: .oauth, accessToken: "token", expiresAt: .distantFuture))
        let transport = OutlookMailTransport(api: GraphAPI(base: URL(string: "https://graph.microsoft.com/v1.0/")!, session: session),
                                             account: account)

        let cursor = try await transport.changeCursor()
        XCTAssertTrue(cursor.hasSuffix("|https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$deltatoken=first"))
        let first = try XCTUnwrap(graph.requests.first)
        XCTAssertTrue(first.query["$select"]?.first?.contains("conversationId") == true, "The link keeps what changes reads")
        XCTAssertTrue(first.query["$filter"]?.first?.hasPrefix("receivedDateTime ge ") == true)

        let taken = OutlookMailTransport.cursor("https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$deltatoken=first",
                                                at: Date(timeIntervalSince1970: 1_762_000_000))
        let changes = try await transport.changes(since: taken)
        XCTAssertTrue(changes.changed)
        XCTAssertEqual(changes.arrivedThreadIDs, ["conv-new"], "Read, Other-inbox and older mail are not told")
        XCTAssertTrue(changes.cursor.hasSuffix("$deltatoken=second"))

        let expired = OutlookMailTransport.cursor("https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$deltatoken=gone",
                                                  at: .now)
        let again = try await transport.changes(since: expired)
        XCTAssertTrue(again.changed)
        XCTAssertEqual(again.arrivedThreadIDs, [])
        XCTAssertTrue(again.cursor.hasSuffix("$deltatoken=first"))
    }
}

/// Graph's mail folders, messages, conversations, replies and the inbox's delta, as it answers them.
private final class FakeGraphMail: ConnectorHTTPTransport, @unchecked Sendable {
    struct Seen {
        var method: String
        var path: String
        var query: [String: [String]]
        var headers: [String: String]
        var body: ToolJSON?
    }

    private let lock = NSLock()
    private var seen: [Seen] = []
    var requests: [Seen] { lock.withLock { seen } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        var query: [String: [String]] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            query[item.name, default: []].append(item.value ?? "")
        }
        let call = Seen(method: request.httpMethod ?? "GET", path: url.path, query: query,
                        headers: request.allHTTPHeaderFields ?? [:],
                        body: request.httpBody.flatMap { try? JSONDecoder().decode(ToolJSON.self, from: $0) })
        lock.withLock { seen.append(call) }
        let answer: ToolJSON
        switch (call.method, url.path) {
        case ("GET", let path) where path.hasPrefix("/v1.0/me/mailFolders/") && path.split(separator: "/").count == 4:
            let name = String(path.split(separator: "/")[3])
            let names = ["inbox": "받은 편지함", "sentitems": "보낸 편지함", "drafts": "임시 보관함", "archive": "보관",
                         "junkemail": "정크 메일", "deleteditems": "지운 편지함"]
            guard let display = names[name] else { return Self.reply(url, 404, .object([:])) }
            answer = .object(["id": .string("folder-\(name)"), "displayName": .string(display),
                              "unreadItemCount": .integer(name == "inbox" ? 1 : 0), "totalItemCount": .integer(3)])
        case ("GET", "/v1.0/me/mailFolders"):
            answer = .object(["value": .array(["inbox", "sentitems", "drafts", "archive", "junkemail", "deleteditems"]
                .map { ToolJSON.object(["id": .string("folder-\($0)"), "displayName": .string($0)]) }
                + [.object(["id": .string("folder-clients"), "displayName": .string("Clients"), "unreadItemCount": .integer(0)])])])
        case ("GET", "/v1.0/me/mailFolders/inbox/messages"):
            answer = .object(["value": .array([Self.m2, Self.ci, Self.m1]),
                              "@odata.nextLink": .string("https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages?$skip=50")])
        case ("GET", "/v1.0/me/messages"):
            answer = .object(["value": .array([Self.m2, Self.m1])])
        case ("GET", "/v1.0/me/messages/m2/attachments"):
            answer = .object(["value": .array([.object(["id": .string("att-1"), "name": .string("quote-v3.pdf"),
                                                        "size": .integer(186_400), "contentType": .string("application/pdf"),
                                                        "isInline": .bool(false)])])])
        case ("GET", let path) where path.hasSuffix("/attachments"):
            answer = .object(["value": .array([])])
        case ("GET", "/v1.0/me/mailFolders/inbox/messages/delta"):
            if query["$deltatoken"] == ["first"] {
                answer = .object(["value": .array([
                    Self.delta("conv-new", read: false, received: "2026-11-02T10:00:00Z", focused: true),
                    Self.delta("conv-read", read: true, received: "2026-11-02T10:01:00Z", focused: true),
                    Self.delta("conv-other", read: false, received: "2026-11-02T10:02:00Z", focused: false),
                    Self.delta("conv-old", read: false, received: "2025-01-01T00:00:00Z", focused: true)]),
                    "@odata.deltaLink": .string("https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$deltatoken=second")])
            } else if query["$deltatoken"] == ["gone"] {
                return Self.reply(url, 410, .object(["error": .object(["message": .string("syncStateNotFound")])]))
            } else {
                answer = .object(["value": .array([]),
                                  "@odata.deltaLink": .string("https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$deltatoken=first")])
            }
        case ("POST", "/v1.0/me/messages/m2/createReply"):
            answer = .object(["id": .string("draft-1")])
        case ("PATCH", _), ("POST", _), ("DELETE", _):
            answer = .object(["id": .string("ok")])
        default:
            return Self.reply(url, 404, .object([:]))
        }
        return Self.reply(url, 200, answer)
    }

    private static func reply(_ url: URL, _ status: Int, _ body: ToolJSON) -> (Data, HTTPURLResponse) {
        ((try? JSONEncoder().encode(body)) ?? Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private static func person(_ name: String, _ address: String) -> ToolJSON {
        .object(["emailAddress": .object(["name": .string(name), "address": .string(address)])])
    }

    static let m1: ToolJSON = .object([
        "id": .string("m1"), "conversationId": .string("conv-quote"), "subject": .string("Quote for next year"),
        "from": person("Haneul Kim", "haneul@fabrikam.example"), "toRecipients": .array([person("Dana", "dana@contoso.example")]),
        "receivedDateTime": .string("2026-10-28T01:00:00Z"), "isRead": .bool(true), "isDraft": .bool(false),
        "hasAttachments": .bool(false), "bodyPreview": .string("Here is the quote."), "parentFolderId": .string("folder-inbox"),
        "body": .object(["contentType": .string("html"), "content": .string("<p>Here is the quote.</p>")]),
        "flag": .object(["flagStatus": .string("notFlagged")]), "webLink": .string("https://outlook.office.com/mail/m1")])
    static let m2: ToolJSON = .object([
        "id": .string("m2"), "conversationId": .string("conv-quote"), "subject": .string("RE: Quote for next year"),
        "from": person("Haneul Kim", "haneul@fabrikam.example"), "toRecipients": .array([person("Dana", "dana@contoso.example")]),
        "receivedDateTime": .string("2026-11-02T05:14:00Z"), "isRead": .bool(false), "isDraft": .bool(false),
        "hasAttachments": .bool(true), "bodyPreview": .string("Revised quote attached."), "parentFolderId": .string("folder-inbox"),
        "body": .object(["contentType": .string("html"), "content": .string("<p>Revised quote attached.</p>")]),
        "flag": .object(["flagStatus": .string("flagged")]), "webLink": .string("https://outlook.office.com/mail/m2")])
    static let ci: ToolJSON = .object([
        "id": .string("c1"), "conversationId": .string("conv-ci"), "subject": .string("CI passed"),
        "from": person("Build", "ci@contoso.example"), "receivedDateTime": .string("2026-11-02T04:02:00Z"),
        "isRead": .bool(true), "isDraft": .bool(false), "hasAttachments": .bool(false), "bodyPreview": .string("All checks passed.")])

    static func delta(_ conversation: String, read: Bool, received: String, focused: Bool) -> ToolJSON {
        .object(["id": .string("d-\(conversation)"), "conversationId": .string(conversation), "isRead": .bool(read),
                 "isDraft": .bool(false), "receivedDateTime": .string(received),
                 "inferenceClassification": .string(focused ? "focused" : "other")])
    }
}
