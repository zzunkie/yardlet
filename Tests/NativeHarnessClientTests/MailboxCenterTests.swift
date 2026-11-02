import Foundation
import XCTest
@testable import NativeHarnessClient

/// The mailbox's watch for new mail: the first run only learns where the account stands, a change
/// reads that inbox again and tells of the threads mail arrived in, and turning the mailbox off forgets
/// where each account was read up to.
@MainActor
final class MailboxCenterTests: XCTestCase {
    func testNewMailReadsTheInboxAgainAndIsToldOnce() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("MailboxWatch")))
        let fixture = MailFixture()
        let transport = try XCTUnwrap(fixture.transports().first)
        let center = MailboxCenter(defaults: defaults)
        center.watchInterval = .milliseconds(20)
        var told: [[MailThreadSummary]] = []
        center.announce = { told.append($0) }
        center.setEnabled(true)
        center.setAccounts([(transport.account, transport)])
        await center.refresh()
        center.startWatching()
        try await waitUntil { defaults.dictionary(forKey: MailboxPreference.cursorsKey)?.isEmpty == false }

        let arrived = fixture.single(MailFixture.work.id, "thread-new", from: MailAddress(name: "Mina", address: "mina@acme.example"),
                                     date: .now, subject: "Lunch on Friday?", text: "Are you free on Friday?", isUnread: true)
        await transport.deliver(arrived)
        try await waitUntil { !told.isEmpty }
        XCTAssertEqual(told.map { $0.map(\.id.threadID) }, [["thread-new"]], "Only the thread mail arrived in is told")
        XCTAssertEqual(center.threads.first?.id.threadID, "thread-new", "The inbox was read again")
        XCTAssertTrue(center.hasUnseenMail, "No window shows the mailbox, so the Mail word is marked")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(told.count, 1, "Nothing more arrived, so nothing more is told")

        center.setVisible(true, window: UUID())
        XCTAssertFalse(center.hasUnseenMail)
        center.setEnabled(false)
        XCTAssertNil(defaults.object(forKey: MailboxPreference.cursorsKey), "Turning the mailbox off forgets the cursors")
        XCTAssertTrue(center.threads.isEmpty)
    }

    /// A list goes on from the page token its service gave, without repeating what was read.
    func testTheInboxGoesOnPageByPage() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("MailboxPages")))
        let transport = try XCTUnwrap(MailFixture().transports().first)
        await transport.setPageSize(3)
        let center = MailboxCenter(defaults: defaults)
        center.setEnabled(true)
        center.setAccounts([(transport.account, transport)])
        await center.refresh()
        XCTAssertEqual(center.threads.count, 3)
        XCTAssertTrue(center.hasMore(.allInboxes))
        await center.loadMore(.allInboxes)
        XCTAssertEqual(center.threads.count, 4)
        XCTAssertEqual(Set(center.threads.map(\.id)).count, 4)
        XCTAssertFalse(center.hasMore(.allInboxes))

        // New mail reads the first page again without taking the list back to it, and a first read of
        // the inbox that fails leaves the cursor where it was, so the mail is still told.
        var told: [[MailThreadSummary]] = []
        center.announce = { told.append($0) }
        center.watchInterval = .milliseconds(20)
        center.startWatching()
        try await waitUntil { defaults.dictionary(forKey: MailboxPreference.cursorsKey)?.isEmpty == false }
        await transport.failNextInboxRead()
        await transport.deliver(MailFixture().single(MailFixture.work.id, "thread-late", from: MailAddress(address: "mina@acme.example"),
                                                     date: .now, subject: "One more thing", text: "Before Friday.", isUnread: true))
        try await waitUntil { !told.isEmpty }
        XCTAssertEqual(told.first?.map(\.id.threadID), ["thread-late"])
        XCTAssertEqual(center.threads.count, 5, "The thread read on the second page stays")
        center.stopWatching()
    }

    /// A reply goes out through a draft once the undo time passes; Undo keeps it from leaving, and
    /// closing what was written keeps it in Drafts.
    func testAReplyIsSentAfterTheUndoTimeAndUndoKeepsItBack() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("MailboxWrite")))
        let transport = try XCTUnwrap(MailFixture().transports().first)
        let center = MailboxCenter(defaults: defaults)
        center.setEnabled(true)
        center.setAccounts([(transport.account, transport)])
        let thread = try await transport.thread(MailFixture.quoteThread)
        let message = try XCTUnwrap(thread.messages.last { !$0.isDraft })
        let window = MailWindowState()
        window.undoWindow = .milliseconds(50)

        window.write(.reply, account: MailFixture.work, message: message, in: thread)
        XCTAssertEqual(window.composition?.to, "김하늘 <haneul@vendor.example>")
        let quoted = window.composition?.body ?? ""
        window.composition?.body = "목요일까지 회신드리겠습니다." + quoted
        window.send(in: center)
        window.undoSend()
        try await Task.sleep(for: .milliseconds(150))
        let keptBack = await transport.sent
        XCTAssertTrue(keptBack.isEmpty, "Undo keeps the message from leaving")
        XCTAssertNotNil(window.composition)

        window.send(in: center)
        try await waitUntil { await !transport.sent.isEmpty }
        try await waitUntil { window.composition == nil }
        let drafts = await transport.drafts
        XCTAssertTrue(drafts.isEmpty, "The draft it went through left with it")

        window.write(.new, account: MailFixture.work)
        window.composition?.to = "jordan@acme.example"
        window.close(in: center)
        try await waitUntil { await transport.drafts.count == 1 }
        XCTAssertNil(window.composition)

        // An agent's draft sent as it is goes without being saved over, so its HTML stays.
        let agentDraft = try XCTUnwrap(thread.messages.first { $0.isDraft })
        window.sendDraft(agentDraft, in: thread, center: center)
        try await waitUntil { await transport.sent.contains("draft-of-\(agentDraft.id)") }
        let afterAgentDraft = await transport.drafts
        XCTAssertEqual(afterAgentDraft.count, 1, "Nothing was saved for the agent's draft")
    }
}
