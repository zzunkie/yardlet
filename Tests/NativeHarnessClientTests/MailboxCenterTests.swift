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
}
