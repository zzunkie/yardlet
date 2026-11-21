import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote

extension RemoteHostWindowRenderingTests {
    /// The host's mailbox in its window (§15.38), with the device's Mail and Calendar permission: the local mailbox's list
    /// and thread over the host's accounts, a thread opened marked read on the host's service, and a draft saved there with
    /// a file sent up from this Mac. Drawn as `remote-mail-list-*.png`, `remote-mail-thread-*.png` and
    /// `local-mail-thread-*.png`.
    func testHostMailboxDrawsAsTheLocalOneAndWritesThroughTheHost() async throws {
        let fixture = MailFixture()
        let transports = fixture.transports()
        let gmail = try XCTUnwrap(transports.first)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteMailRender")))
        let host = AppModel(store: SessionStore(sessions: [], repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults), preferences: defaults, restoresIndexOnLaunch: false)
        host.mailbox.setEnabled(true)
        host.mailbox.setAccounts(transports.map { ($0.account, $0) })
        defer { host.mailbox.setEnabled(false) }
        let stack = try await LoopbackStack(name: "Mac Studio", bridge: AppModelRemoteBridge(model: host))
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
            name: "Mac Studio", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let hosts = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
            hello: RemoteHandshakeHello(name: "MacBook Air", platform: "macos", appVersion: "test"))
        let paired = try await hosts.pair(link: link.absoluteString)
        defer { hosts.close(paired.id) }
        let model = try XCTUnwrap(hosts.model(for: paired.id))
        try await waitUntil { model.mailCalendarState?.mailbox == true }
        let refused = await model.response(to: .mail(action: "accounts", data: nil))
        XCTAssertEqual(refused.error?.reason, .mailCalendar)
        try await stack.server.setPermission(.mailCalendar, allowed: true, for: try XCTUnwrap(model.host.deviceID))
        try await waitUntil { model.mailbox.accounts == transports.map(\.account) && !model.mailbox.threads.isEmpty }

        let shell = RemoteHostShell()
        shell.section = .mail
        let drafts = RemoteComposerDrafts()
        let size = NSSize(width: 1_280, height: 800)
        let quote = MailFixture.haneul.displayName
        try await render("remote-mail-list", size: size, titled: true, title: model.name,
                         ready: { elements in elements.contains { $0.label.hasPrefix(quote) } }) {
            RemoteHostView(model: model, directory: hosts, drafts: drafts, shell: shell)
        } check: { elements in
            XCTAssertTrue(elements.contains { $0.label == L10n.string("Mail") }, elements.description)
            XCTAssertFalse(elements.contains { $0.label == L10n.string("Personal agents") }, elements.description)
        }

        // A thread opened here is marked read on the host's service, as opening it there does.
        let key = MailThreadKey(accountID: MailFixture.work.id, threadID: MailFixture.quoteThread)
        shell.mailWindow.select(key, in: model.mailbox)
        try await waitUntil { await gmail.changes.contains { $0.0 == MailFixture.quoteThread && $0.1 == .read(true) } }
        try await render("remote-mail-thread", size: size, titled: true, title: model.name,
                         ready: { elements in elements.contains { $0.label == L10n.string("Ask an agent") } }) {
            RemoteHostView(model: model, directory: hosts, drafts: drafts, shell: shell)
        }
        let local = MailWindowState()
        await host.mailbox.refresh()
        local.select(key, in: host.mailbox)
        try await render("local-mail-thread", size: NSSize(width: size.width - 240, height: size.height), titled: false,
                         ready: { elements in elements.contains { $0.label == L10n.string("Ask an agent") } }) {
            MailWorkspace(center: host.mailbox, window: local, actions: MailActions(), panel: nil)
                .background(ParityTheme.canvas)
        }

        // A reply saved as a draft on the host's service, with a file sent up from this Mac, under its own name.
        let file = FileManager.default.temporaryDirectory.appending(path: "remote-mail-\(UUID().uuidString)/quote.txt")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("Revised quote".utf8).write(to: file)
        let thread = try XCTUnwrap(model.mailbox.openedThread(key))
        var reply = MailComposition.answering(try XCTUnwrap(thread.messages.last), in: thread, as: .reply, from: MailFixture.work)
        reply.body = "Thanks, attached." + reply.body
        reply.attachments = [file]
        let saved = try await model.mailbox.save(reply)
        let draftID = try XCTUnwrap(saved.draftID)
        let savedDrafts = await gmail.drafts
        let draft = try XCTUnwrap(savedDrafts[draftID])
        XCTAssertEqual(draft.attachments.map(\.lastPathComponent), ["quote.txt"])
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(draft.attachments.first)), Data("Revised quote".utf8))
        XCTAssertEqual(draft.threadID, MailFixture.quoteThread)
        XCTAssertTrue(draft.body.hasPrefix("Thanks, attached."))

        await host.shutdown()
    }
}
