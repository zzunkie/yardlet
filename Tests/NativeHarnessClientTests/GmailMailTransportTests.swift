import Foundation
import XCTest
import YardletAgentTools
@testable import NativeHarnessClient

/// The mailbox's Gmail account against a fake Gmail API: the inbox is listed with each thread's
/// headers and no bodies, a thread is read in full only when opened, reading changes no label, and
/// the mailbox's changes become the labels Gmail's own app sets.
final class GmailMailTransportTests: XCTestCase {
    func testTheInboxListsHeadersAndOpeningReadsWithoutChangingLabels() async throws {
        let gmail = FakeGmailThreads()
        let account = MailAccount(id: UUID(), address: "dana@example.com", provider: .gmail)
        let session = OAuthAPISession(id: account.id, credentials: InMemoryConnectorCredentialStore(), http: gmail,
                                      now: { Date() })
        await session.use(ConnectorCredential(kind: .oauth, accessToken: "token", expiresAt: .distantFuture))
        let transport = GmailMailTransport(api: GmailAPI(base: URL(string: "https://gmail.googleapis.com/gmail/v1/")!,
                                                         session: session), account: account)

        let page = try await transport.inbox(pageToken: nil)
        XCTAssertEqual(page.threads.map(\.id.threadID), ["t-quote", "t-ci"], "Gmail's order")
        XCTAssertEqual(page.nextPageToken, "page-2")
        let quote = try XCTUnwrap(page.threads.first)
        XCTAssertEqual(quote.subject, "견적서 회신 부탁드립니다")
        XCTAssertEqual(quote.senders.map(\.displayName), ["김하늘"], "Each sender once; a draft's writer is no sender yet")
        XCTAssertEqual(quote.messageCount, 2, "The draft is not a message of the count")
        XCTAssertTrue(quote.isUnread)
        XCTAssertTrue(quote.hasDraft)
        XCTAssertTrue(quote.hasAttachments)
        XCTAssertEqual(quote.snippet, "수정본을 첨부합니다")
        XCTAssertEqual(quote.date, Date(timeIntervalSince1970: 1_762_060_440))
        let list = try XCTUnwrap(gmail.requests.first)
        XCTAssertEqual(list.path, "/gmail/v1/users/me/threads")
        XCTAssertEqual(list.query["labelIds"], ["INBOX"])
        XCTAssertEqual(Set(gmail.requests.dropFirst().compactMap { $0.query["format"]?.first }), ["metadata"],
                       "A list reads headers only")

        let thread = try await transport.thread("t-quote")
        XCTAssertEqual(thread.messages.map(\.text), ["안녕하세요. 견적서를 보내 드립니다.", "수정본을 첨부합니다.", "잘 받았습니다."])
        XCTAssertEqual(thread.messages.map(\.isDraft), [false, false, true])
        XCTAssertEqual(thread.messages[1].to.map(\.address), ["dana@example.com"])
        XCTAssertEqual(thread.messages[1].cc.map(\.displayName), ["Lee, Doyun"])
        XCTAssertEqual(thread.messages[1].attachments.map(\.name), ["견적서_v3.pdf"])
        XCTAssertEqual(thread.messages[1].attachments.map(\.size), [186_400])
        XCTAssertEqual(thread.webURL?.absoluteString, "https://mail.google.com/mail/?authuser=dana@example.com#all/t-quote")
        XCTAssertTrue(gmail.requests.allSatisfy { $0.method == "GET" }, "Reading changes nothing")

        for change in [MailThreadChange.read(true), .read(false), .starred(true), .archived] {
            try await transport.change("t-quote", change)
        }
        let modifies = gmail.requests.filter { $0.method == "POST" }
        XCTAssertEqual(modifies.map(\.path), Array(repeating: "/gmail/v1/users/me/threads/t-quote/modify", count: 4))
        XCTAssertEqual(modifies.map { $0.labels("addLabelIds") }, [[], ["UNREAD"], ["STARRED"], []])
        XCTAssertEqual(modifies.map { $0.labels("removeLabelIds") }, [["UNREAD"], [], [], ["INBOX"]])
    }

    /// A reply is a draft in its thread with `In-Reply-To` and `References`, addressed as mail apps
    /// address one; saving again replaces that draft, and sending or discarding names it.
    func testARepliesDraftCarriesItsThreadAndIsSentByItsID() async throws {
        let gmail = FakeGmailThreads()
        let account = MailAccount(id: UUID(), address: "dana@example.com", provider: .gmail)
        let session = OAuthAPISession(id: account.id, credentials: InMemoryConnectorCredentialStore(), http: gmail,
                                      now: { Date() })
        await session.use(ConnectorCredential(kind: .oauth, accessToken: "token", expiresAt: .distantFuture))
        let transport = GmailMailTransport(api: GmailAPI(base: URL(string: "https://gmail.googleapis.com/gmail/v1/")!,
                                                         session: session), account: account)
        let thread = try await transport.thread("t-quote")
        let original = thread.messages[1]

        var reply = MailComposition.answering(original, in: thread, as: .replyAll, from: account)
        XCTAssertEqual(reply.to, "김하늘 <haneul@example.com>")
        XCTAssertEqual(reply.cc, #""Lee, Doyun" <doyun@example.com>"#, "Everyone else on the message, never the account itself")
        XCTAssertEqual(reply.subject, "Re: 견적서 회신 부탁드립니다", "An existing Re: is not doubled")
        XCTAssertEqual(reply.inReplyTo, "<q2@example.com>")
        XCTAssertEqual(reply.references, "<q1@example.com> <q2@example.com>")
        XCTAssertTrue(reply.body.contains("> 수정본을 첨부합니다."))
        reply.body = "목요일까지 회신드리겠습니다." + reply.body

        reply.draftID = try await transport.saveDraft(reply)
        reply.body = "금요일까지 회신드리겠습니다."
        _ = try await transport.saveDraft(reply)
        try await transport.sendDraft(try XCTUnwrap(reply.draftID))
        try await transport.discardDraft("d-other")

        let writes = gmail.requests.filter { $0.method != "GET" }
        XCTAssertEqual(writes.map { "\($0.method) \($0.path)" }, [
            "POST /gmail/v1/users/me/drafts", "PUT /gmail/v1/users/me/drafts/d1",
            "POST /gmail/v1/users/me/drafts/send", "DELETE /gmail/v1/users/me/drafts/d-other"])
        let created = try XCTUnwrap(writes.first?.body?["message"])
        XCTAssertEqual(created["threadId"]?.stringValue, "t-quote")
        let mime = try XCTUnwrap(created["raw"]?.stringValue.flatMap(Self.decodedMIME))
        XCTAssertTrue(mime.contains("In-Reply-To: <q2@example.com>\r\n"))
        XCTAssertTrue(mime.contains("References: <q1@example.com> <q2@example.com>\r\n"))
        XCTAssertTrue(mime.contains("Cc: doyun@example.com\r\n"), "A name a header cannot carry is left to the address")
        XCTAssertEqual(writes[2].body?["id"]?.stringValue, "d1")
    }

    private static func decodedMIME(_ raw: String) -> String? {
        var base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
    }

    func testAddressHeadersAsGmailGivesThem() {
        let parsed = MailAddressList.parse(#""Lee, Doyun" <doyun@example.com>, 김하늘 <haneul@example.com>, plain@example.com, Team: a@example.com;"#)
        XCTAssertEqual(parsed, [MailAddress(name: "Lee, Doyun", address: "doyun@example.com"),
                                MailAddress(name: "김하늘", address: "haneul@example.com"),
                                MailAddress(address: "plain@example.com"),
                                MailAddress(address: "a@example.com")])
        XCTAssertEqual(MailAddressList.parse("undisclosed-recipients:;"), [])
    }
}

/// Gmail's thread list, a thread's headers and the full thread, as the API answers them.
private final class FakeGmailThreads: ConnectorHTTPTransport, @unchecked Sendable {
    struct Seen {
        var method: String
        var path: String
        var query: [String: [String]]
        var body: ToolJSON?

        func labels(_ key: String) -> [String] { body?[key]?.arrayValue?.compactMap(\.stringValue) ?? [] }
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
        let body = request.httpBody.flatMap { try? JSONDecoder().decode(ToolJSON.self, from: $0) }
        let call = Seen(method: request.httpMethod ?? "GET", path: url.path, query: query, body: body)
        lock.withLock { seen.append(call) }
        let answer: ToolJSON
        switch (call.method, url.path) {
        case ("GET", "/gmail/v1/users/me/threads"):
            answer = .object(["threads": .array([.object(["id": .string("t-quote")]), .object(["id": .string("t-ci")])]),
                              "nextPageToken": .string("page-2")])
        case ("GET", "/gmail/v1/users/me/threads/t-quote"):
            answer = .object(["id": .string("t-quote"), "messages": .array(Self.quote(full: query["format"] == ["full"]))])
        case ("GET", "/gmail/v1/users/me/threads/t-ci"):
            answer = .object(["id": .string("t-ci"), "messages": .array([
                Self.message("c1", from: "GitHub <ci@example.com>", subject: "CI passed", labels: ["INBOX"],
                             date: 1_762_050_000, snippet: "All checks passed")])])
        case ("POST", "/gmail/v1/users/me/drafts"):
            answer = .object(["id": .string("d1")])
        case ("PUT", _):
            answer = .object(["id": .string(url.lastPathComponent)])
        case ("POST", _), ("DELETE", _):
            answer = .object([:])
        default:
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        return (try JSONEncoder().encode(answer), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private static func quote(full: Bool) -> [ToolJSON] {
        [message("q1", from: "김하늘 <haneul@example.com>", subject: "견적서 회신 부탁드립니다", labels: ["INBOX"],
                 date: 1_762_000_000, snippet: "견적서를 보내 드립니다", body: full ? "안녕하세요. 견적서를 보내 드립니다." : nil),
         message("q2", from: "김하늘 <haneul@example.com>", subject: "Re: 견적서 회신 부탁드립니다", labels: ["INBOX", "UNREAD"],
                 date: 1_762_060_440, snippet: "수정본을 첨부합니다", body: full ? "수정본을 첨부합니다." : nil,
                 cc: #""Lee, Doyun" <doyun@example.com>"#, attachment: true),
         message("q3", from: "Dana Park <dana@example.com>", subject: "Re: 견적서 회신 부탁드립니다", labels: ["DRAFT"],
                 date: 1_762_060_800, snippet: "잘 받았습니다", body: full ? "잘 받았습니다." : nil)]
    }

    private static func message(_ id: String, from: String, subject: String, labels: [String], date: Int,
                                snippet: String, body: String? = nil, cc: String? = nil, attachment: Bool = false) -> ToolJSON {
        func header(_ name: String, _ value: String) -> ToolJSON {
            .object(["name": .string(name), "value": .string(value)])
        }
        var headers = [header("From", from), header("Subject", subject), header("To", "Dana Park <dana@example.com>"),
                       header("Message-ID", "<\(id)@example.com>")]
        if id == "q2" { headers.append(header("References", "<q1@example.com>")) }
        if let cc { headers.append(header("Cc", cc)) }
        var payload: [String: ToolJSON] = ["mimeType": .string(attachment ? "multipart/mixed" : "text/plain"),
                                           "headers": .array(headers)]
        if let body {
            let text = ToolJSON.object(["mimeType": .string("text/plain"),
                                        "body": .object(["data": .string(Data(body.utf8).base64EncodedString())])])
            let file = ToolJSON.object(["mimeType": .string("application/pdf"), "filename": .string("견적서_v3.pdf"),
                                        "body": .object(["attachmentId": .string("att-1"), "size": .integer(186_400)])])
            payload["parts"] = .array(attachment ? [text, file] : [text])
        }
        return .object(["id": .string(id), "threadId": .string("t"), "labelIds": .array(labels.map { .string($0) }),
                        "internalDate": .string(String(date * 1000)), "snippet": .string(snippet),
                        "payload": .object(payload)])
    }
}

