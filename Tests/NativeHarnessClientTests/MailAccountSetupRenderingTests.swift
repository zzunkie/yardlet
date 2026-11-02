import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Adding a mail account over IMAP, drawn into `.build/mailbox-qa/` in both appearances, with what each
/// says checked. No server is reached: the pages are drawn before Connect.
///
/// - `imap-add-search-*`: Add connector searched for "IMAP": Mail (IMAP) with its app password.
/// - `imap-setup-naver-*`: a Naver address, its three steps on Naver's website, then the password.
/// - `imap-setup-other-*`: an address at no known service, with the servers to type.
/// - `imap-setup-gmail-*`: a Gmail address (googlemail.com), sent to Gmail's own connector.
/// - `imap-setup-accounts-*`, `imap-settings-*`: two accounts added, one whose password was refused, on
///   the page and in Settings › Connectors.
@MainActor
final class MailAccountSetupRenderingTests: XCTestCase {
    private static let folder = "mailbox-qa"
    private static let size = NSSize(width: 620, height: 860)

    func testAddingAMailAccountOverIMAP() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let store = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("MailAccountSetupQA")))
        let empty = center()

        try WindowlessRender.hostedInBothAppearances("imap-add-search", in: directory, size: NSSize(width: 580, height: 520),
                                                     passes: 12) { appearance in
            ConnectorAddSheet(center: empty, start: .directory, query: "IMAP", onClose: {})
                .defaultAppStorage(store)
                .environment(\.colorScheme, appearance.colorScheme)
        }
        expect(["Mail (IMAP)", L10n.string("App password · iCloud, Naver, Daum, Kakao and others"), L10n.string("Set up…")],
               in: spoken(ConnectorAddSheet(center: empty, start: .directory, query: "IMAP", onClose: {}).defaultAppStorage(store)),
               "directory")

        try render("imap-setup-naver", MailAccountSetupPage(center: empty, address: "dana@naver.com"), store, directory)
        let naver = try XCTUnwrap(MailServerPreset.preset(id: "naver"))
        expect(naver.steps.map { L10n.string($0.text) } + [L10n.string("Enter the address and the app password"),
                                                            L10n.string("Naver Mail")],
               in: spoken(page(MailAccountSetupPage(center: empty, address: "dana@naver.com"), store)), "Naver")

        try render("imap-setup-other", MailAccountSetupPage(center: empty, address: "dana@example.org"), store, directory)
        expect([L10n.string("Other IMAP server"), L10n.string("IMAP server"), L10n.string("SMTP port"), L10n.string("User name")],
               in: spoken(page(MailAccountSetupPage(center: empty, address: "dana@example.org"), store)), "other")

        try render("imap-setup-gmail", MailAccountSetupPage(center: empty, address: "dana@googlemail.com"), store, directory)
        expect([L10n.format("%@ accounts connect through their own sign-in, which reads them better. Choose %@ in the list of connectors.",
                            "Gmail", "Gmail")],
               in: spoken(page(MailAccountSetupPage(center: empty, address: "dana@googlemail.com"), store)), "Gmail")

        let added = center(Self.records)
        try render("imap-setup-accounts", MailAccountSetupPage(center: added), store, directory)
        expect(["dana@naver.com", "dana@icloud.com", L10n.string("Add another mail account")],
               in: spoken(page(MailAccountSetupPage(center: added), store)), "accounts")
        try render("imap-settings", ConnectorSettingsView(center: added), store, directory)
        let settings = spoken(page(ConnectorSettingsView(center: added), store))
        expect(["dana@naver.com · imap.naver.com", L10n.string("Set up…")], in: settings, "settings")
        XCTAssertFalse(settings.contains { $0.hasPrefix(L10n.string("Reconnect")) },
                       "A refused app password is entered again on its page, not tried again: \(settings)")
    }

    private static let records: [ConnectorRecord] = {
        func record(_ preset: String, _ address: String, _ status: ConnectorRecord.Status, slug: String) -> ConnectorRecord {
            let server = MailServerPreset.preset(id: preset)!
            let settings = server.settings(for: address)
            return ConnectorRecord(name: L10n.string(server.name), slug: slug, serverURL: IMAPMailSession.address(settings),
                                   authorization: .token, status: status, presetID: LocalConnectorService.imapMail.presetID,
                                   localService: .imapMail, account: address, mailServer: settings)
        }
        return [record("naver", "dana@naver.com", .connected, slug: "mail"),
                record("icloud", "dana@icloud.com", .signInRequired, slug: "mail_dana")]
    }()

    private func center(_ records: [ConnectorRecord] = []) -> ConnectorCenter {
        ConnectorCenter(environment: ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(records: records), credentials: InMemoryConnectorCredentialStore(),
            http: FakeAppStoreConnect(), userAgent: nil, sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9"))
    }

    private func page<Content: View>(_ content: Content, _ store: UserDefaults,
                                     appearance: WindowlessRender.Appearance = .light) -> some View {
        ScrollView { content.padding(20) }
            .defaultAppStorage(store)
            .environment(\.colorScheme, appearance.colorScheme)
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .background(ParityTheme.canvas)
    }

    private func render<Content: View>(_ name: String, _ content: @autoclosure () -> Content, _ store: UserDefaults,
                                       _ directory: URL) throws {
        try WindowlessRender.hostedInBothAppearances(name, in: directory, size: Self.size, passes: 12) { appearance in
            page(content(), store, appearance: appearance)
        }
    }

    private func spoken<Content: View>(_ view: Content) -> [String] {
        let host = WindowlessRender.Host(view, size: Self.size)
        defer { host.close() }
        host.settle(passes: 10)
        return host.accessibilityElements().map { "\($0.label) \($0.value)" }
    }

    private func expect(_ texts: [String], in spoken: [String], _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        for text in texts {
            XCTAssertTrue(spoken.contains { $0.contains(text) }, "\(name) has no \(text): \(spoken)", file: file, line: line)
        }
    }
}
