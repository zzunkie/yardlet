import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Renders the easier connector setup offscreen into `.build/connectors-easy-qa/`, light and dark,
/// from fixtures only.
@MainActor
final class ConnectorsEasyQARenderingTests: XCTestCase {
    private static let folder = "connectors-easy-qa"
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    /// A defaults suite for the assistants' opened steps, so the test never writes the app's own.
    private func defaults(opened: Set<ConnectorSetupAssistant.StepID>) throws -> UserDefaults {
        let name = testDefaultsSuite("ConnectorsEasyQA")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(ConnectorSetupProgress.encode(opened), forKey: ConnectorSetupProgress.key)
        return defaults
    }

    static let personal = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
    static let work = UUID(uuidString: "00000000-0000-4000-8000-0000000000B1")!

    private static func google(_ service: LocalConnectorService, _ address: String, slug: String, id: UUID = UUID(),
                               account: UUID?, status: ConnectorRecord.Status = .connected) -> ConnectorRecord {
        ConnectorRecord(id: id, name: service.name, slug: slug, serverURL: GoogleOAuth.Endpoints.live.base(for: service),
                        authorization: .oauth, status: status, presetID: service.presetID,
                        scope: service.scopes.joined(separator: " "), localService: service, account: address,
                        accountSignInID: account)
    }

    static let googleRecords: [ConnectorRecord] = [
        google(.gmail, "person@example.test", slug: "gmail", id: personal, account: nil),
        google(.googleCalendar, "person@example.test", slug: "calendar", account: personal),
        google(.googleDrive, "person@example.test", slug: "drive", account: personal),
        google(.googleCalendar, "developer@company.test", slug: "calendar_developer", id: work, account: nil),
        google(.googleDrive, "developer@company.test", slug: "drive_developer", account: work, status: .signInRequired)
    ]

    private func center(_ records: [ConnectorRecord], app: Bool, homes: [NativeMCPHome] = []) -> ConnectorCenter {
        var environment = ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(records: records.map(FakeGoogle.withCachedTools), googleAppClientID: app ? FakeGoogle.clientID : nil),
            credentials: InMemoryConnectorCredentialStore(), http: FakeGoogleWorkspace(), userAgent: FakeUserAgent(),
            sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9")
        environment.googleWorkspaceTransport = environment.http
        environment.google = FakeGoogleWorkspace.endpoints
        environment.nativeHomes = { homes }
        return ConnectorCenter(environment: environment)
    }

    private func page<Content: View>(_ content: Content, size: NSSize, appearance: WindowlessRender.Appearance,
                                     defaults: UserDefaults) -> some View {
        content
            .padding(20)
            .defaultAppStorage(defaults)
            .environment(\.colorScheme, appearance.colorScheme)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(ParityTheme.canvas)
    }

    private func spoken<Content: View>(_ view: Content, size: NSSize) -> [String] {
        let host = WindowlessRender.Host(view, size: size)
        defer { host.close() }
        host.settle(passes: 10)
        return host.accessibilityElements().map { "\($0.label) \($0.value)" }
    }

    private func expect(_ texts: [String], in spoken: [String], _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        for text in texts {
            XCTAssertTrue(spoken.contains { $0.contains(text) }, "\(name) has no \(text): \(spoken)", file: file, line: line)
        }
    }

    // MARK: - The assistants

    func testGoogleValidatesThePersonalClientInline() throws {
        let empty = center([], app: false)
        let size = NSSize(width: 540, height: 590)
        let content = GoogleSetupPage(center: empty, clientID: "GOC" + "SPX-pasted-in-the-wrong-field")
        let text = spoken(page(content, size: size, appearance: .light, defaults: try defaults(opened: [])), size: size)
        expect([L10n.string("OAuth client ID"),
                L10n.string("That is the client secret; the client ID ends with .apps.googleusercontent.com.")],
               in: text, "personal client")
    }

    func testTheSlackAssistantDrawsFreshAndFilledIn() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let empty = center([], app: false)
        let fresh = try defaults(opened: [])
        let size = NSSize(width: 580, height: 620)
        try WindowlessRender.hostedInBothAppearances("assistant-slack", in: directory, size: size, passes: 10) { appearance in
            page(SlackSetupPage(center: empty), size: size, appearance: appearance, defaults: fresh)
        }
        let text = spoken(page(SlackSetupPage(center: empty), size: size, appearance: .light, defaults: fresh), size: size)
        expect([L10n.string("Set up Slack"), L10n.string("Create the Yardlet app in Slack"), L10n.string("Create in Slack"),
                L10n.format("Copy %@", L10n.string("Manifest")), L10n.format("Copy %@", L10n.string("Redirect URL")),
                L10n.string("Paste the client ID"), L10n.string("Slack client ID"), L10n.string("Sign in to Slack"),
                L10n.string("Your Slack apps")], in: text, "slack")

        let opened = try defaults(opened: [.slackCreate])
        try WindowlessRender.hostedInBothAppearances("assistant-slack-filled", in: directory, size: size,
                                                     passes: 10) { appearance in
            page(SlackSetupPage(center: empty, clientID: "1234567890123.9876543210987"), size: size, appearance: appearance,
                 defaults: opened)
        }
        let filled = spoken(page(SlackSetupPage(center: empty, clientID: "1234567890123.9876543210987"), size: size,
                                 appearance: .light, defaults: opened), size: size)
        expect([L10n.format("%lld of %lld done", Int64(2), Int64(3)), L10n.string("Sign in to Slack")], in: filled, "filled")
    }

    // MARK: - Accounts with three services

    func testTheGoogleAccountsShowEachServicePerAccount() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let saved = center(Self.googleRecords, app: true)
        XCTAssertEqual(saved.googleAccounts.map(\.address), ["person@example.test", "developer@company.test"])
        XCTAssertEqual(saved.googleAccounts.map(\.enabled), [[.gmail, .googleCalendar, .googleDrive], [.googleCalendar, .googleDrive]])
        let store = try defaults(opened: [])
        let size = NSSize(width: 580, height: 560)
        try WindowlessRender.hostedInBothAppearances("google-accounts", in: directory, size: size, passes: 10) { appearance in
            page(GoogleSetupPage(center: saved), size: size, appearance: appearance, defaults: store)
        }
        let text = spoken(page(GoogleSetupPage(center: saved), size: size, appearance: .light, defaults: store), size: size)
        expect(["person@example.test", "developer@company.test", "Google Calendar \(L10n.string("Connected"))",
                "Gmail \(L10n.string("Off"))", "Google Drive \(L10n.string("Needs sign-in"))", L10n.string("Reconnect")],
               in: text, "accounts")

        // The settings list has a row per service and account.
        let settingsSize = NSSize(width: 680, height: 900)
        try WindowlessRender.hostedInBothAppearances("settings-google-services", in: directory, size: settingsSize,
                                                     passes: 12) { appearance in
            page(ConnectorSettingsView(center: saved), size: settingsSize, appearance: appearance, defaults: store)
        }
        let settings = spoken(page(ConnectorSettingsView(center: saved), size: settingsSize, appearance: .light,
                                   defaults: store), size: settingsSize)
        expect(["Google Calendar · person@example.test", "Google Drive · developer@company.test",
                L10n.format("%lld tools", Int64(saved.connectors[0].tools.count)), L10n.string("Set up in one go")], in: settings, "settings")
    }

    // MARK: - Used elsewhere

    func testSettingsSuggestServicesUsedInClaudeAIAndCodexApps() async throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let root = FileManager.default.temporaryDirectory.appending(path: "connectors-easy-\(UUID().uuidString)")
        roots.append(root)
        let claude = root.appending(path: "account/.claude.json")
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(ConnectorSetupAssistantTests.claudeAccount.utf8).write(to: claude)
        let codex = root.appending(path: "codex", directoryHint: .isDirectory)
        let cache = codex.appending(path: "cache/codex_apps_tools", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(ConnectorSetupAssistantTests.codexConfig.utf8).write(to: codex.appending(path: "config.toml"))
        try Data(ConnectorSetupAssistantTests.appsCacheNew.utf8).write(to: cache.appending(path: "bbb222.json"))
        let linear = ConnectorRecord(name: "Linear", slug: "linear", serverURL: URL(string: "https://mcp.linear.app/mcp")!,
                                     authorization: .oauth, status: .connected,
                                     tools: (0..<23).map { .object(["name": .string("tool_\($0)")]) }, presetID: "linear")
        let center = center([linear], app: false, homes: [
            NativeMCPHome(kind: .claude(file: claude), account: "Session Switch e0824000"),
            NativeMCPHome(kind: .codex(home: codex))
        ])
        await center.loadNativeInventory()
        XCTAssertEqual(center.importSuggestions.map(\.name), ["Notion", "Slack", "Gmail", "Google Calendar", "Google Drive", "GitHub"])
        let store = try defaults(opened: [])
        let size = NSSize(width: 680, height: 980)
        try WindowlessRender.hostedInBothAppearances("settings-suggestions", in: directory, size: size, passes: 12) { appearance in
            page(ConnectorSettingsView(center: center), size: size, appearance: appearance, defaults: store)
        }
        let text = spoken(page(ConnectorSettingsView(center: center), size: size, appearance: .light, defaults: store), size: size)
        expect([L10n.string("You use these elsewhere"), "Slack", "Gmail", "Google Calendar", "Google Drive", "GitHub",
                L10n.string("Connect in Yardlet"), L10n.format("claude.ai · %@", "person@fake.test"),
                L10n.string("Codex app"), L10n.string("Set up in one go"), L10n.format("Set up %@", "Google"),
                L10n.format("Set up %@", "Slack"), L10n.string("Not set up")], in: text, "suggestions")
    }

    /// Not `async`: the sheet's scroll to the opened group is a `.task`, which runs only while the
    /// test is not itself holding the main actor.
    func testTheAddSheetHasGoogleInOneRow() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let center = center(Array(Self.googleRecords.prefix(3)), app: true)
        let store = try defaults(opened: [])
        let sheetSize = NSSize(width: 580, height: 660)
        try WindowlessRender.hostedInBothAppearances("add-own-apps", in: directory, size: sheetSize, passes: 12) { appearance in
            ConnectorAddSheet(center: center, start: .directory, showsOwnApps: true, onClose: {})
                .defaultAppStorage(store)
                .environment(\.colorScheme, appearance.colorScheme)
        }
        let sheet = spoken(ConnectorAddSheet(center: center, start: .directory, showsOwnApps: true, onClose: {})
            .defaultAppStorage(store), size: sheetSize)
        expect([L10n.string("Google · Gmail, Calendar, Drive"), L10n.format("%lld Google accounts", Int64(1)), "Slack",
                L10n.string("A Slack app made from Yardlet's manifest"), L10n.string("Set up…")], in: sheet, "own apps")
        XCTAssertFalse(sheet.contains { $0.hasPrefix("Google Calendar") || $0.hasPrefix("Google Drive") },
                       "One Google row, not one per Google service")
    }
}
