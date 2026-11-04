import Foundation
import XCTest
@testable import NativeHarnessClient

/// An IMAP mail account behind the mailbox's contract, against a fake IMAP server that answers as Korean
/// webmail does (no special-use attributes, folder names in Korean) and a fake SMTP server: folders by
/// role, a list page and a message read without marking it, flags and an archive made on first use, a
/// draft saved and saved over, a send without its Bcc line and its copy in Sent unless the server filed
/// one, new mail from the inbox's STATUS and its newest messages' flags, a search where the server's TEXT
/// finds less than it should, and adding an account through Settings › Connectors with its password in
/// the secure store only.
final class IMAPMailTransportTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_793_620_800) // 2026-11-02 12:00 UTC
    private static let drafts = "&x4TC3Lz0rQDVaA-"   // 임시보관함
    private static let sent = "&vPSwuNO4ycDVaA-"     // 보낸편지함
    private static let settings = MailServerSettings(
        preset: nil, imapHost: "imap.example.com", imapPort: 993, imapSecurity: .tls, imapUsername: "dana@example.com",
        smtpHost: "smtp.example.com", smtpPort: 465, smtpSecurity: .tls, smtpUsername: "dana@example.com")

    func testFoldersListAndMessageOfAKoreanServerAndChangesAsFlagsAndMoves() async throws {
        let state = FakeMailState()
        let opener = FakeMailOpener(imap: { FakeIMAPServer(answer: state.answer) })
        let session = makeSession(opener)
        let transport = IMAPMailTransport(session: session, account: MailAccount(id: session.id, address: "dana@example.com",
                                                                                 provider: .imap))

        let folders = try await transport.folders()
        XCTAssertEqual(folders.map(\.name), [L10n.string("Mail inbox"), "보낸편지함", "임시보관함", "스팸편지함", "휴지통", "거래처", "2026"])
        XCTAssertEqual(folders.map(\.role), [.inbox, .sent, .drafts, .spam, .trash, .label, .label])
        XCTAssertEqual(folders.map(\.depth), [0, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual(folders.map(\.unreadCount), [1, nil, 0, 3, nil, nil, nil], "Unread in the inbox and spam; how many drafts")

        let page = try await transport.inbox(pageToken: nil)
        XCTAssertEqual(page.threads.map(\.subject), ["Price inside", "회의 자료"], "Newest first")
        XCTAssertEqual(page.threads.map(\.id.threadID), ["7:11:INBOX", "7:10:INBOX"])
        XCTAssertEqual(page.threads[1].senders, [MailAddress(name: "김철수", address: "chulsoo@example.kr")])
        XCTAssertEqual(page.threads[1].snippet, "내일 회의 자료 보내 드립니다.")
        XCTAssertEqual(page.threads[0].snippet, "Quote attached")
        XCTAssertEqual(page.threads.map(\.isUnread), [true, false])
        XCTAssertEqual(page.threads.map(\.isStarred), [true, false])
        XCTAssertEqual(page.threads.map(\.hasAttachments), [true, false])
        XCTAssertNil(page.nextPageToken)

        let thread = try await transport.thread("7:10:INBOX")
        let message = try XCTUnwrap(thread.messages.first)
        XCTAssertEqual(message.subject, "회의 자료")
        XCTAssertEqual(message.from, MailAddress(name: "김철수", address: "chulsoo@example.kr"))
        XCTAssertEqual(message.text, "내일 회의 자료 보내 드립니다.\n")
        XCTAssertEqual(message.messageID, "<a1@example.kr>")
        XCTAssertNil(thread.webURL)

        try await transport.change("7:11:INBOX", .read(true))
        try await transport.change("7:11:INBOX", .starred(false))
        try await transport.change("7:10:INBOX", .archived)

        let server = try XCTUnwrap(opener.imapServers.first)
        XCTAssertEqual(opener.opened, ["imap.example.com:993 tls"], "One connection for everything")
        XCTAssertEqual(server.commands, [
            "AUTHENTICATE PLAIN AGRhbmFAZXhhbXBsZS5jb20AY29ycmVjdCBob3JzZQ==",
            #"LIST "" "*""#,
            #"STATUS "INBOX" (MESSAGES UNSEEN UIDNEXT UIDVALIDITY)"#,
            #"STATUS "&x4TC3Lz0rQDVaA-" (MESSAGES UNSEEN UIDNEXT UIDVALIDITY)"#,
            #"STATUS "&wqTTONO4ycDVaA-" (MESSAGES UNSEEN UIDNEXT UIDVALIDITY)"#,
            #"SELECT "INBOX""#,
            "FETCH 1:2 (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE BODY.PEEK[TEXT]<0.2048>)",
            "UID FETCH 10 (UID FLAGS INTERNALDATE RFC822.SIZE BODYSTRUCTURE)",
            "UID FETCH 10 (BODY.PEEK[])",
            #"UID STORE 11 +FLAGS.SILENT (\Seen)"#,
            #"UID STORE 11 -FLAGS.SILENT (\Flagged)"#,
            #"CREATE "Archive""#,
            #"LIST "" "*""#,
            #"UID MOVE 10 "Archive""#,
        ], "Reading peeks, so only the mailbox's own change marks a message read")
    }

    func testADraftIsSavedInDraftsAndSentWithoutItsBccWithACopyInSent() async throws {
        let state = FakeMailState()
        let opener = FakeMailOpener(imap: { FakeIMAPServer(answer: state.answer) }, sent: { state.sent($0) })
        let session = makeSession(opener)
        let transport = IMAPMailTransport(session: session, account: MailAccount(id: session.id, address: "dana@example.com",
                                                                                 provider: .imap))
        var composition = MailComposition(accountID: session.id, to: "Haneul <haneul@example.com>", bcc: "min@example.com",
                                          subject: "견적", body: "첨부 확인 부탁드립니다.")
        let first = try await transport.saveDraft(composition)
        XCTAssertEqual(first, "9:1:\(Self.drafts)")
        composition.draftID = first
        composition.body = "첨부 확인 부탁드립니다. 금요일까지요."
        let second = try await transport.saveDraft(composition)
        XCTAssertEqual(second, "9:2:\(Self.drafts)")

        let draft = String(decoding: try XCTUnwrap(state.appended.last), as: UTF8.self)
        for line in ["From: dana@example.com", "To: Haneul <haneul@example.com>", "Bcc: min@example.com",
                     "Subject: =?UTF-8?B?6rKs7KCB?="] {
            XCTAssertTrue(draft.contains(line + "\r\n"), line)
        }
        XCTAssertNotNil(draft.range(of: #"Message-ID: <[0-9a-f-]+@example\.com>\r\n"#, options: .regularExpression))
        XCTAssertTrue(draft.hasPrefix("From: "), "The account sends it, so the draft says so")

        try await transport.sendDraft(second)

        let smtp = try XCTUnwrap(opener.smtpServers.first)
        XCTAssertEqual(smtp.commands, ["EHLO [127.0.0.1]", "AUTH PLAIN AGRhbmFAZXhhbXBsZS5jb20AY29ycmVjdCBob3JzZQ==",
                                       "MAIL FROM:<dana@example.com>", "RCPT TO:<haneul@example.com>",
                                       "RCPT TO:<min@example.com>", "DATA", "QUIT"])
        XCTAssertFalse(smtp.message.contains("Bcc:"), "The Bcc goes in the envelope only")
        XCTAssertTrue(smtp.message.contains("To: Haneul <haneul@example.com>"))
        XCTAssertEqual(state.appended.count, 3, "Two saves and the Sent copy")
        XCTAssertEqual(state.appended.last, state.appended[1], "Sent keeps the message as saved, its Bcc with it")

        let server = try XCTUnwrap(opener.imapServers.first)
        let date = "\"02-Nov-2026 12:00:00 +0000\""
        XCTAssertEqual(server.commands.map { $0.replacingOccurrences(of: #"<[0-9a-f-]+@example\.com>"#, with: "<id>",
                                                                     options: .regularExpression) }, [
            "AUTHENTICATE PLAIN AGRhbmFAZXhhbXBsZS5jb20AY29ycmVjdCBob3JzZQ==",
            #"LIST "" "*""#,
            #"APPEND "\#(Self.drafts)" (\Draft \Seen) \#(date) {literal}"#,
            #"SELECT "\#(Self.drafts)""#,
            #"APPEND "\#(Self.drafts)" (\Draft \Seen) \#(date) {literal}"#,
            #"SELECT "\#(Self.drafts)""#,
            #"UID STORE 1 +FLAGS.SILENT (\Deleted)"#,
            "UID EXPUNGE 1",
            "UID FETCH 2 (BODY.PEEK[])",
            #"SELECT "\#(Self.sent)""#,
            #"APPEND "\#(Self.sent)" (\Seen) \#(date) {literal}"#,
            #"SELECT "\#(Self.drafts)""#,
            #"UID STORE 2 +FLAGS.SILENT (\Deleted)"#,
            "UID EXPUNGE 2",
        ], "Sent was empty, so there was no copy to look for")

        // A server that files its own copy of what it sends, as webmail services do, gets no second one;
        // the copy is found among Sent's newest messages, not by the server's search.
        state.filesSentCopies = true
        composition.draftID = nil
        let third = try await transport.saveDraft(composition)
        let before = server.commands.count
        try await transport.sendDraft(third)
        XCTAssertEqual(state.folder(Self.sent).count, 2, "The client's copy of the first, the server's of this one")
        XCTAssertEqual(Array(server.commands[before...]), [
            "UID FETCH 4 (BODY.PEEK[])",
            #"SELECT "\#(Self.sent)""#,
            "FETCH 1:2 (UID ENVELOPE)",
            #"SELECT "\#(Self.drafts)""#,
            #"UID STORE 4 +FLAGS.SILENT (\Deleted)"#,
            "UID EXPUNGE 4",
        ])
    }

    /// New mail is read from the inbox's newest messages and their flags, the FETCH its list makes, not
    /// from UID SEARCH, which some servers answer without the messages.
    func testNewMailIsTheInboxStatusAndTheUnreadMessagesAfterTheLastUID() async throws {
        let state = FakeMailState()
        let opener = FakeMailOpener(imap: { FakeIMAPServer(answer: state.answer) })
        let transport = IMAPMailTransport(session: makeSession(opener), account: MailAccount(id: UUID(), address: "dana@example.com",
                                                                                             provider: .imap))
        let cursor = try await transport.changeCursor()
        XCTAssertEqual(cursor, "7:12:2:1")
        let quiet = try await transport.changes(since: cursor)
        XCTAssertEqual(quiet, MailChanges(cursor: cursor, changed: false, arrivedThreadIDs: []))

        state.inbox = (validity: 7, next: 14, messages: 4, unseen: 2)
        let arrived = try await transport.changes(since: cursor)
        XCTAssertEqual(arrived, MailChanges(cursor: "7:14:4:2", changed: true, arrivedThreadIDs: ["7:13:INBOX"]))

        state.inbox = (validity: 8, next: 3, messages: 2, unseen: 0)
        let renumbered = try await transport.changes(since: "7:14:4:2")
        XCTAssertEqual(renumbered, MailChanges(cursor: "8:3:2:0", changed: true, arrivedThreadIDs: []),
                       "New UIDs read the inbox again and tell nothing")
        let server = try XCTUnwrap(opener.imapServers.first)
        XCTAssertTrue(server.commands.contains("FETCH 3:4 (UID FLAGS)"), "UIDs 12 and 13 at most, the last two")
        XCTAssertFalse(server.commands.contains { $0.contains("SEARCH") })
    }

    /// The server's search in the inbox and Sent, numbers read as sequence numbers by the list's FETCH:
    /// what TEXT misses is found by subject and sender; nothing found is no results when the server finds
    /// its last message by number, and a failure when it cannot.
    func testSearchFallsBackToSubjectAndSenderAndSaysWhenTheServerCannotSearch() async throws {
        let state = FakeMailState()
        let opener = FakeMailOpener(imap: { FakeIMAPServer(answer: state.answer) })
        let transport = IMAPMailTransport(session: makeSession(opener), account: MailAccount(id: UUID(), address: "dana@example.com",
                                                                                             provider: .imap))
        let found = try await transport.search("Price", pageToken: nil)
        XCTAssertEqual(found.threads.map(\.id.threadID), ["7:11:INBOX"])
        XCTAssertEqual(found.threads.map(\.subject), ["Price inside"])
        let none = try await transport.search("Invoice", pageToken: nil)
        XCTAssertTrue(none.threads.isEmpty)

        let server = try XCTUnwrap(opener.imapServers.first)
        XCTAssertEqual(server.commands.dropFirst(2), [
            #"SELECT "INBOX""#,
            #"SEARCH TEXT "Price""#,
            #"SEARCH OR SUBJECT "Price" FROM "Price""#,
            "FETCH 2 (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE BODY.PEEK[TEXT]<0.2048>)",
            #"SELECT "\#(Self.sent)""#,
            #"SELECT "INBOX""#,
            #"SEARCH TEXT "Invoice""#,
            #"SEARCH OR SUBJECT "Invoice" FROM "Invoice""#,
            "SEARCH 2",
            #"SELECT "\#(Self.sent)""#,
        ], "Sent is empty, so it is not searched")

        state.searchesNothing = true
        do {
            _ = try await transport.search("Price", pageToken: nil)
            XCTFail("A server that finds nothing, not even its last message, has no search to offer")
        } catch {
            XCTAssertEqual((error as? MailFailure)?.kind, .unavailable)
        }
    }

    /// The setup's check signs in to both servers before anything is stored; the password then lives in
    /// the secure store only, and the account is a connector and a mailbox account under one connection.
    @MainActor
    func testAddingAnAccountChecksBothServersAndKeepsThePasswordInTheSecureStoreOnly() async throws {
        let state = FakeMailState()
        let opener = FakeMailOpener(imap: { FakeIMAPServer(answer: state.answer) })
        let credentials = InMemoryConnectorCredentialStore()
        let repository = InMemoryConnectorRepository()
        var environment = ConnectorCenter.Environment(
            repository: repository, credentials: credentials, http: FakeAppStoreConnect(), userAgent: nil,
            sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9", now: { Self.now })
        environment.mailSockets = opener
        let center = ConnectorCenter(environment: environment)

        state.refusesSignIn = true
        do {
            _ = try await center.addMailAccount(address: "dana@example.com", password: "correct horse", settings: Self.settings,
                                                name: "Example Mail")
            XCTFail("A refused password adds no account")
        } catch {
            XCTAssertEqual((error as? MailFailure)?.kind, .signInRequired)
        }
        XCTAssertTrue(center.connectors.isEmpty, "A refused password stores nothing")
        XCTAssertTrue(opener.smtpServers.isEmpty, "SMTP is checked only once IMAP accepted the password")

        state.refusesSignIn = false
        let record = try await center.addMailAccount(address: "dana@example.com", password: "correct horse",
                                                     settings: Self.settings, name: "Example Mail")
        await center.waitForConnection(record.id)
        let connected = try XCTUnwrap(center.record(record.id))
        XCTAssertEqual(connected.status, .connected, center.failures[record.id] ?? "")
        XCTAssertEqual(connected.slug, "mail")
        XCTAssertEqual(connected.mailServer, Self.settings)
        XCTAssertEqual(try credentials.load(record.id), ConnectorCredential.password("correct horse"))
        let file = String(decoding: try JSONEncoder().encode(repository.records), as: UTF8.self)
        XCTAssertFalse(file.contains("correct horse"), "No password in connectors.json")
        XCTAssertEqual(opener.smtpServers.first?.commands, ["EHLO [127.0.0.1]",
                                                            "AUTH PLAIN AGRhbmFAZXhhbXBsZS5jb20AY29ycmVjdCBob3JzZQ==", "QUIT"],
                       "The check sends nothing")

        let names = await center.connectorTools(for: ConnectorToolContext()).compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(names, MailAccountToolCatalog.tools.compactMap { $0["name"]?.stringValue }.map { "mail_\($0)" })
        let accounts = center.mailAccounts()
        XCTAssertEqual(accounts.map(\.0.provider), [.imap])
        XCTAssertEqual(accounts.map(\.0.serviceName), ["Example Mail"])

        center.remove(record.id)
        try await waitUntil { (try? credentials.load(record.id)) == nil }
        XCTAssertTrue(center.mailAccounts().isEmpty)
    }

    private func makeSession(_ opener: FakeMailOpener) -> IMAPMailSession {
        let id = UUID()
        return IMAPMailSession(id: id, address: "dana@example.com", settings: Self.settings,
                               credentials: InMemoryConnectorCredentialStore([id: .password("correct horse")]),
                               sockets: opener, now: { Self.now })
    }
}
