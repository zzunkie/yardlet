import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Microsoft 365's and Zoom's setup in Settings → Connectors, drawn offscreen into
/// `.build/microsoft-zoom-qa/`, light and dark, with what each says checked. Fixture records and
/// fakes only: no network or sign-in.
///
/// - `microsoft-page-empty-*`: the Microsoft page before an app is saved: the Entra steps and fields.
/// - `microsoft-page-builtin-accounts-*`: a build with Yardlet's own Microsoft app, a personal and a
///   work account signed in, one needing sign-in again.
/// - `zoom-page-*`: the Zoom page, all three products picked.
/// - `add-directory-microsoft-zoom-*`: the directory's own-app group with Microsoft 365 and Zoom.
/// - `setup-tiles-*`: "Set up in one go" with its four services.
@MainActor
final class MicrosoftZoomRenderingTests: XCTestCase {
    private static let folder = "microsoft-zoom-qa"

    private static func record(_ service: LocalConnectorService, _ account: String, slug: String, accountID: UUID?,
                               id: UUID = UUID(), status: ConnectorRecord.Status = .connected) -> ConnectorRecord {
        ConnectorRecord(id: id, name: service.name, slug: slug, serverURL: service.address, authorization: .oauth, status: status,
                        presetID: service.presetID, scope: service.scopes.joined(separator: " "), localService: service,
                        account: account, accountSignInID: accountID)
    }

    static let personal = UUID()
    static let work = UUID()
    static let accounts: [ConnectorRecord] = [
        record(.outlookMail, "person@outlook.test", slug: "outlook", accountID: nil, id: personal),
        record(.oneDrive, "person@outlook.test", slug: "onedrive", accountID: personal),
        record(.outlookMail, "developer@company.test", slug: "outlook_developer", accountID: nil, id: work),
        record(.outlookCalendar, "developer@company.test", slug: "outlook_calendar", accountID: work),
        record(.teams, "developer@company.test", slug: "teams", accountID: work, status: .signInRequired)
    ]

    private func center(_ records: [ConnectorRecord], builtIn: Bool) -> ConnectorCenter {
        var environment = ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(records: records), credentials: InMemoryConnectorCredentialStore(),
            http: FakeMicrosoft(), userAgent: FakeUserAgent(), sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9")
        environment.microsoft = FakeMicrosoft.endpoints
        if builtIn { environment.microsoftBuiltInApp = MicrosoftOAuth.BuiltInApp(clientID: FakeMicrosoft.clientID) }
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

    private func expect(_ texts: [String], in spoken: [String], file: StaticString = #filePath, line: UInt = #line) {
        for text in texts {
            XCTAssertTrue(spoken.contains { $0.contains(text) }, "No \(text): \(spoken)", file: file, line: line)
        }
    }

    func testTheMicrosoftPageDrawsTheEntraStepsAndTheAccounts() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let empty = center([], builtIn: false)
        let size = NSSize(width: 580, height: 1240)
        let captures = try WindowlessRender.hostedInBothAppearances("microsoft-page-empty", in: directory, size: size,
                                                                    passes: 10) { appearance in
            page(MicrosoftSetupPage(center: empty), size: size, appearance: appearance)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        expect([L10n.string("Set up Microsoft 365"), L10n.string("Register an app in Microsoft Entra"),
                L10n.string("App registrations"), L10n.string("Add Yardlet's redirect in the manifest"),
                L10n.format("Copy %@", L10n.string("Manifest entry")), L10n.string("Add the Microsoft Graph permissions"),
                L10n.format("Copy %@", L10n.string("Permissions")), L10n.string("Application (client) ID"),
                L10n.string("Directory ID (optional)"), L10n.string("Save the Microsoft app first."),
                L10n.string("Sign in with Microsoft")],
               in: spoken(page(MicrosoftSetupPage(center: empty), size: size, appearance: .light), size: size))

        let signedIn = center(Self.accounts, builtIn: true)
        let accountsSize = NSSize(width: 580, height: 760)
        try WindowlessRender.hostedInBothAppearances("microsoft-page-builtin-accounts", in: directory, size: accountsSize,
                                                     passes: 10) { appearance in
            page(MicrosoftSetupPage(center: signedIn), size: accountsSize, appearance: appearance)
        }
        let text = spoken(page(MicrosoftSetupPage(center: signedIn), size: accountsSize, appearance: .light), size: accountsSize)
        expect(["person@outlook.test", "developer@company.test", L10n.string("Reconnect"), L10n.string("Needs sign-in"),
                L10n.string("Add another Microsoft account"), L10n.string("Use a Microsoft app of your own…")], in: text)
        XCTAssertFalse(text.contains { $0.contains(L10n.string("Register an app in Microsoft Entra")) },
                       "A build with its own app shows only the sign-in")
    }

    func testTheZoomPageAndTheDirectoryOfferEachOnce() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let empty = center([], builtIn: false)
        let size = NSSize(width: 580, height: 980)
        try WindowlessRender.hostedInBothAppearances("zoom-page", in: directory, size: size, passes: 10) { appearance in
            page(ZoomSetupPage(center: empty), size: size, appearance: appearance)
        }
        expect([L10n.string("Set up Zoom"), L10n.string("Create a Zoom app"), L10n.string("Build an app on Zoom"),
                L10n.format("Copy %@", L10n.string("Scopes")), L10n.format("Copy %@", L10n.string("Redirect URL")),
                L10n.string("Zoom client ID"), L10n.string("Sign in to Zoom"), "Meetings", "Team Chat", "Docs"],
               in: spoken(page(ZoomSetupPage(center: empty), size: size, appearance: .light), size: size))

        let sheetSize = NSSize(width: 580, height: 660)
        try WindowlessRender.hostedInBothAppearances("add-directory-microsoft-zoom", in: directory, size: sheetSize,
                                                     passes: 12) { appearance in
            ConnectorAddSheet(center: empty, start: .directory, showsOwnApps: true, query: "o", onClose: {})
                .environment(\.colorScheme, appearance.colorScheme)
        }
        let sheet = spoken(ConnectorAddSheet(center: empty, start: .directory, showsOwnApps: true, onClose: {}), size: sheetSize)
        expect([L10n.string("Microsoft 365 · Outlook, OneDrive, Teams"), L10n.string("Zoom · Meetings, Team Chat, Docs")], in: sheet)

        let tilesSize = NSSize(width: 580, height: 300)
        try WindowlessRender.hostedInBothAppearances("setup-tiles", in: directory, size: tilesSize, passes: 10) { appearance in
            page(ConnectorSetupTiles(center: center(Self.accounts, builtIn: true), onOpen: { _ in }), size: tilesSize,
                 appearance: appearance)
        }
        let tiles = spoken(ConnectorSetupTiles(center: center(Self.accounts, builtIn: true), onOpen: { _ in }), size: tilesSize)
        expect([L10n.format("Set up %@", "Microsoft 365"), L10n.format("%lld Microsoft accounts", Int64(2)),
                L10n.format("Set up %@", "Zoom")], in: tiles)
    }
}
