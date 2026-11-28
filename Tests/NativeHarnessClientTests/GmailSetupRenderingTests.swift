import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Renders Gmail's setup offscreen into `.build/gmail-qa/`, light and dark, with fixture records
/// and a fake Google.
@MainActor
final class GmailSetupRenderingTests: XCTestCase {
    private static let folder = "gmail-qa"

    private static func record(_ account: String?, slug: String, status: ConnectorRecord.Status) -> ConnectorRecord {
        ConnectorRecord(name: "Gmail", slug: slug, serverURL: GoogleOAuth.Endpoints.live.gmailAPI, authorization: .oauth,
                        status: status, presetID: "gmail", scope: LocalConnectorService.gmail.scopes.joined(separator: " "), localService: .gmail,
                        account: account)
    }

    static let accounts: [ConnectorRecord] = [
        record("person@example.test", slug: "gmail", status: .connected),
        record("developer@company.test", slug: "gmail_developer", status: .connected),
        record("old.address@example.test", slug: "gmail_old_address", status: .signInRequired)
    ]

    private func center(_ records: [ConnectorRecord], app: Bool, builtIn: Bool = false,
                        credentials: InMemoryConnectorCredentialStore = InMemoryConnectorCredentialStore()) -> ConnectorCenter {
        var environment = ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(records: records,
                                                    googleAppClientID: app ? FakeGoogle.clientID : nil),
            credentials: credentials, http: FakeGoogle(), userAgent: FakeUserAgent(),
            sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9")
        environment.googleWorkspaceTransport = environment.http
        environment.google = FakeGoogle.endpoints
        if builtIn {
            environment.googleBuiltInApp = .init(clientID: FakeGoogle.clientID, clientSecret: FakeGoogle.clientSecret)
        }
        return ConnectorCenter(environment: environment)
    }

    private func spoken<Content: View>(_ view: Content, size: NSSize) -> [String] {
        let host = WindowlessRender.Host(view, size: size)
        defer { host.close() }
        host.settle(passes: 10)
        return host.accessibilityElements().map { "\($0.label) \($0.value)" }
    }

    private func page<Content: View>(_ content: Content, size: NSSize, appearance: WindowlessRender.Appearance) -> some View {
        content
            .padding(20)
            .environment(\.colorScheme, appearance.colorScheme)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(ParityTheme.canvas)
    }

    func testGoogleSetupShowsPersonalModeAndNativeUIAtTheSettingsSheetWidth() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let gmail = try XCTUnwrap(ConnectorPreset.preset(id: "gmail"))
        let sheetSize = NSSize(width: 580, height: 660)
        let empty = center([], app: false, builtIn: true)
        let captures = try WindowlessRender.hostedInBothAppearances("google-personal-mode", in: directory, size: sheetSize,
                                                                     passes: 10) { appearance in
            ConnectorAddSheet(center: empty, start: .preset(gmail), onClose: {})
                .environment(\.colorScheme, appearance.colorScheme)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        let text = spoken(page(GoogleSetupPage(center: empty), size: sheetSize, appearance: .light), size: sheetSize)
        for title in [L10n.string("Agent tools"), L10n.string("Create a Personal Mode client"), L10n.string("OAuth client ID"),
                      L10n.string("Client secret"), L10n.string("Sign in with Google"),
                      L10n.string("Sign in to Google for Yardlet Calendar"),
                      L10n.string("Connect Gmail with an app password in Mail (IMAP)")] {
            XCTAssertTrue(text.contains { $0.contains(title) }, "Missing \(title)")
        }
    }

    func testGoogleAccountRowsRenderWithIndependentCalendarStatus() throws {
        var accounts = Self.accounts
        accounts[0].hasGoogleUISignIn = true
        let saved = center(accounts, app: true)
        let size = NSSize(width: 540, height: 470)
        let directory = try WindowlessRender.directory(Self.folder)
        func rows() -> some View {
            ServiceAccountList(center: saved, provider: .google, newAccountServices: .constant([.gmail]))
        }
        try WindowlessRender.hostedInBothAppearances("google-account-rows", in: directory, size: size, passes: 10) {
            page(rows(), size: size, appearance: $0)
        }
        let text = spoken(page(rows(), size: size, appearance: .light), size: size)
        for title in ["person@example.test", "developer@company.test", "old.address@example.test",
                      L10n.string("Reconnect"), L10n.string("Yardlet Calendar connected")] {
            XCTAssertTrue(text.contains { $0.contains(title) }, "Missing \(title)")
        }
    }

    /// Not `async`: the sheet's scroll to the opened group is a `.task`, which runs only while the
    /// test is not itself holding the main actor.
    func testTheDirectoryAndSettingsShowEachAccount() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let saved = center(ConnectorsRenderingTests.records.filter { $0.presetID != "gmail" } + Self.accounts, app: true)

        let sheetSize = NSSize(width: 580, height: 660)
        try WindowlessRender.hostedInBothAppearances("add-directory-own-apps", in: directory, size: sheetSize,
                                                     passes: 12) { appearance in
            ConnectorAddSheet(center: saved, start: .directory, showsOwnApps: true, onClose: {})
                .environment(\.colorScheme, appearance.colorScheme)
        }
        let sheetText = spoken(ConnectorAddSheet(center: saved, start: .directory, showsOwnApps: true, onClose: {}),
                               size: sheetSize)
        XCTAssertTrue(sheetText.contains { $0.contains(L10n.format("%lld Google accounts", Int64(3))) }, "\(sheetText)")

        let settingsSize = NSSize(width: 680, height: 1000)
        try WindowlessRender.hostedInBothAppearances("settings-gmail", in: directory, size: settingsSize,
                                                     passes: 12) { appearance in
            page(ConnectorSettingsView(center: saved), size: settingsSize, appearance: appearance)
        }
        let settingsText = spoken(page(ConnectorSettingsView(center: saved), size: settingsSize, appearance: .light),
                                  size: settingsSize)
        // A connected account's row counts the tools Yardlet's Gmail server lists.
        for text in ["Gmail · person@example.test", "Gmail · developer@company.test", "Gmail · old.address@example.test",
                     L10n.string("Reconnect")] {
            XCTAssertTrue(settingsText.contains { $0.contains(text) }, "No \(text): \(settingsText)")
        }
        XCTAssertEqual(ConnectorSettingsState.ordered(saved).filter { $0.localService == .gmail }.map(\.account),
                       ["person@example.test", "developer@company.test", "old.address@example.test"], "Connected first")
    }
}
