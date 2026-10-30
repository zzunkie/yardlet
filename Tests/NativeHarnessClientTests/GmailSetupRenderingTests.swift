import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Gmail's setup in Settings → Connectors, drawn offscreen into `.build/gmail-qa/`, light and dark,
/// with what each says checked. Fixture records and a fake Google only: no network or sign-in.
///
/// - `add-gmail-sheet-*`: Add connector opened at Gmail, as the sheet shows it, before an app is saved.
/// - `gmail-page-empty-*`: the whole Gmail page then: the Google OAuth app's steps and fields.
/// - `gmail-page-accounts-*`: an app saved, a personal and a Workspace account connected, and one
///   that needs signing in again.
/// - `gmail-page-steps-*`: the same with the app's steps opened again.
/// - `gmail-page-builtin-empty-*`, `gmail-page-builtin-accounts-*`: a build with Yardlet's own Google
///   app, before and after accounts sign in.
/// - `add-directory-own-apps-*`: the directory's own-app group, Gmail with its account count.
/// - `settings-gmail-*`: Settings → Connectors with the Gmail accounts among the connectors.
/// - `claude-request-send-*`: Claude Code asking before a send, on the request card.
@MainActor
final class GmailSetupRenderingTests: XCTestCase {
    private static let folder = "gmail-qa"

    private static func record(_ account: String?, slug: String, status: ConnectorRecord.Status) -> ConnectorRecord {
        ConnectorRecord(name: "Gmail", slug: slug, serverURL: GoogleOAuth.Endpoints.live.gmailAPI, authorization: .oauth,
                        status: status, presetID: "gmail", scope: GmailToolCatalog.scope, localService: .gmail,
                        account: account)
    }

    static let accounts: [ConnectorRecord] = [
        record("person@example.test", slug: "gmail", status: .connected),
        record("developer@company.test", slug: "gmail_developer", status: .connected),
        record("old.address@example.test", slug: "gmail_old_address", status: .signInRequired)
    ]

    private func center(_ records: [ConnectorRecord], app: Bool, builtIn: Bool = false) -> ConnectorCenter {
        var environment = ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(records: records,
                                                    googleAppClientID: app ? FakeGoogle.clientID : nil),
            credentials: InMemoryConnectorCredentialStore(), http: FakeGoogle(), userAgent: FakeUserAgent(),
            sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9")
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

    func testTheGmailPageDrawsBeforeAndAfterTheAppIsSaved() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let gmail = try XCTUnwrap(ConnectorPreset.preset(id: "gmail"))

        // As the sheet opens on Gmail with nothing saved.
        let empty = center([], app: false)
        let sheetSize = NSSize(width: 580, height: 660)
        let sheets = try WindowlessRender.hostedInBothAppearances("add-gmail-sheet", in: directory, size: sheetSize,
                                                                  passes: 10) { appearance in
            ConnectorAddSheet(center: empty, start: .preset(gmail), onClose: {})
                .environment(\.colorScheme, appearance.colorScheme)
        }
        for capture in sheets { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }

        // The whole page: what Google asks for, step by step, with its links.
        let size = NSSize(width: 580, height: 1180)
        try WindowlessRender.hostedInBothAppearances("gmail-page-empty", in: directory, size: size, passes: 10) { appearance in
            page(GoogleSetupPage(center: empty), size: size, appearance: appearance)
        }
        let emptyText = spoken(page(GoogleSetupPage(center: empty), size: size, appearance: .light), size: size)
        for text in [L10n.string("Set up Google"), L10n.string("Create a Google Cloud project"),
                     L10n.string("Turn on the Gmail, Calendar, and Drive APIs"), L10n.string("New project"),
                     L10n.string("Enable APIs"), L10n.string("Audience"), L10n.string("Data Access"),
                     L10n.string("Create client"), L10n.format("Copy %@", L10n.string("Scopes")),
                     L10n.format("Copy %@", L10n.string("Redirect URL")), L10n.string("OAuth client ID"),
                     L10n.string("Client secret"), L10n.string("Save the Google OAuth app first."),
                     L10n.string("Sign in with Google")] {
            XCTAssertTrue(emptyText.contains { $0.contains(text) }, "No \(text): \(emptyText)")
        }
        XCTAssertTrue(emptyText.contains { $0.contains("hasn't verified this app") || $0.contains("확인하지 않은 앱") },
                      "The unverified-app note")

        // Saved, with accounts: the app in a line, each account with its state.
        let saved = center(Self.accounts, app: true)
        let savedSize = NSSize(width: 580, height: 640)
        try WindowlessRender.hostedInBothAppearances("gmail-page-accounts", in: directory, size: savedSize,
                                                     passes: 10) { appearance in
            page(GoogleSetupPage(center: saved), size: savedSize, appearance: appearance)
        }
        let savedText = spoken(page(GoogleSetupPage(center: saved), size: savedSize, appearance: .light), size: savedSize)
        for text in [L10n.string("Google OAuth app saved in your keychain"), FakeGoogle.clientID, L10n.string("Change…"),
                     "person@example.test", "developer@company.test", "old.address@example.test", L10n.string("Connected"),
                     L10n.string("Needs sign-in"), L10n.string("Reconnect"), L10n.string("Add another Google account")] {
            XCTAssertTrue(savedText.contains { $0.contains(text) }, "No \(text): \(savedText)")
        }
        XCTAssertFalse(savedText.contains { $0.contains(L10n.string("Turn on the Gmail, Calendar, and Drive APIs")) },
                       "The steps fold away once the app is saved")

        let stepsSize = NSSize(width: 580, height: 900)
        try WindowlessRender.hostedInBothAppearances("gmail-page-steps", in: directory, size: stepsSize, passes: 10) { appearance in
            page(GoogleSetupPage(center: saved, showsSteps: true), size: stepsSize, appearance: appearance)
        }
    }

    /// A build with Yardlet's own Google app: the page is the sign-in alone, with the way to an app
    /// of the person's own below it, and no console steps.
    func testWithTheBuiltInAppThePageIsOnlyTheSignIn() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let size = NSSize(width: 580, height: 560)
        for (name, records) in [("gmail-page-builtin-empty", [ConnectorRecord]()), ("gmail-page-builtin-accounts", Self.accounts)] {
            let builtIn = center(records, app: false, builtIn: true)
            let captures = try WindowlessRender.hostedInBothAppearances(name, in: directory, size: size, passes: 10) { appearance in
                page(GoogleSetupPage(center: builtIn), size: size, appearance: appearance)
            }
            for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
            let text = spoken(page(GoogleSetupPage(center: builtIn), size: size, appearance: .light), size: size)
            let signIn = records.isEmpty ? L10n.string("Sign in with Google") : L10n.string("Add another Google account")
            for expected in [L10n.string("Sign in with each Google account"), signIn,
                             L10n.string("Use a Google OAuth app of your own…")] {
                XCTAssertTrue(text.contains { $0.contains(expected) }, "No \(expected): \(text)")
            }
            for absent in [L10n.string("Create a Google Cloud project"), L10n.string("OAuth client ID"),
                           L10n.string("Save the Google OAuth app first.")] {
                XCTAssertFalse(text.contains { $0.contains(absent) }, "Unexpected \(absent): \(text)")
            }
        }
        let tiles = spoken(ConnectorSetupTiles(center: center([], app: false, builtIn: true), onOpen: { _ in }),
                           size: NSSize(width: 580, height: 160))
        XCTAssertTrue(tiles.contains { $0.contains(L10n.string("Sign in to start")) }, "\(tiles)")
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
                     L10n.format("%lld tools", Int64(GmailToolCatalog.tools.count)), L10n.string("Reconnect")] {
            XCTAssertTrue(settingsText.contains { $0.contains(text) }, "No \(text): \(settingsText)")
        }
        XCTAssertEqual(ConnectorSettingsState.ordered(saved).filter { $0.localService == .gmail }.map(\.account),
                       ["person@example.test", "developer@company.test", "old.address@example.test"], "Connected first")
    }

    func testClaudeAsksBeforeASendInYardletsWords() throws {
        _ = center(Self.accounts, app: true)  // the tool names' labels, with each account
        let input: JSONValue = .object([
            "to": .array([.string("bob@example.com")]), "cc": .array([.string("carol@example.com")]),
            "subject": .string("Q3 numbers"), "body": .string("Hi Bob,\nThe numbers are attached to the thread.\nThanks")
        ])
        let text = try XCTUnwrap(GmailToolApproval.request(toolName: "mcp__yardlet__gmail_developer_send_message", input: input))
        XCTAssertEqual(text.title, L10n.format("Allow Claude to send an email from %@?", "developer@company.test"))
        let request = PermissionRequest(id: "perm-gmail", title: text.title, detail: text.detail, command: nil,
                                        toolCallID: "toolu_send")
        let start = Date(timeIntervalSince1970: 1_792_220_400)
        let entries = [
            TranscriptEntry(createdAt: start, content: .user(text: "Email Bob the Q3 numbers")),
            TranscriptEntry(createdAt: start.addingTimeInterval(4),
                            content: .assistant(text: "I'll send it from your work account.", isStreaming: false)),
            TranscriptEntry(createdAt: start.addingTimeInterval(6), content: .activity(HarnessActivity(
                id: "toolu_send", kind: "mcp__yardlet__gmail_developer_send_message",
                title: "mcp__yardlet__gmail_developer_send_message", input: input.readableText), state: .running)),
            TranscriptEntry(createdAt: start.addingTimeInterval(7), content: .permission(request, state: .pending))
        ]
        let directory = try WindowlessRender.directory(Self.folder)
        for appearance in WindowlessRender.Appearance.allCases {
            let drawing = try ConversationDrawing.draw(
                ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .waitingForApproval,
                                                         latestTurnIsComplete: false)),
                size: NSSize(width: 760, height: 460), appearance: appearance)
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "claude-request-send-\(appearance.suffix).png"))
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains(text.title), texts)
            XCTAssertTrue(texts.contains("bob@example.com"), texts)
        }
    }
}
