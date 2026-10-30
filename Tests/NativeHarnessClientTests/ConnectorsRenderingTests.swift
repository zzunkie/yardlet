import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Settings → Connectors and the composer's connector list, drawn offscreen into
/// `.build/connectors-qa`, light and dark. Fixture connectors and fixture harness files only: no
/// network, sign-in, provider, or window on screen.
///
/// - `settings-connectors-*`: the page with connectors in each state (connected first), the claude.ai
///   switch, and the import suggestions.
/// - `settings-add-slack-*`: the add sheet opened at Slack: its steps and the OAuth client fields.
/// - `composer-connectors-*`: a task's list: switches, "Reconnect", a connector left to the
///   harness's own server, one turned off here, and the harness's servers.
@MainActor
final class ConnectorsRenderingTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private static func tools(_ count: Int) -> [ToolJSON] {
        (0..<count).map { .object(["name": .string("tool_\($0)")]) }
    }

    static let records: [ConnectorRecord] = [
        ConnectorRecord(name: "Linear", slug: "linear", serverURL: URL(string: "https://mcp.linear.app/mcp")!,
                        authorization: .oauth, status: .connected, tools: tools(23), presetID: "linear"),
        ConnectorRecord(name: "Notion", slug: "notion", serverURL: URL(string: "https://mcp.notion.com/mcp")!,
                        authorization: .oauth, status: .connected, tools: tools(14), presetID: "notion"),
        ConnectorRecord(name: "Slack", slug: "slack", serverURL: URL(string: "https://mcp.slack.com/mcp")!,
                        authorization: .oauth, status: .signInRequired, presetID: "slack", oauthClientID: "1234.5678"),
        ConnectorRecord(name: "Gmail", slug: "gmail", serverURL: GoogleOAuth.Endpoints.live.gmailAPI,
                        authorization: .oauth, status: .notConnected, presetID: "gmail", localService: .gmail),
        ConnectorRecord(name: "GitHub", slug: "github", serverURL: URL(string: "https://api.githubcopilot.com/mcp/")!,
                        authorization: .token, status: .connected, tools: tools(41), presetID: "github"),
        ConnectorRecord(name: "Browserbase", slug: "browserbase", serverURL: URL(string: "https://mcp.browserbase.com/mcp")!,
                        authorization: .token, status: .connected, tools: tools(6), presetID: "browserbase",
                        tokenQueryParameter: "browserbaseApiKey")
    ]

    private func center() throws -> ConnectorCenter {
        let root = FileManager.default.temporaryDirectory.appending(path: "connectors-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        let claude = root.appending(path: "claude.json")
        try Data(ConnectorDirectoryTests.claudeFixture.utf8).write(to: claude)
        let codex = root.appending(path: "codex", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try Data(ConnectorDirectoryTests.codexFixture.utf8).write(to: codex.appending(path: "config.toml"))
        var environment = ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(records: Self.records), credentials: InMemoryConnectorCredentialStore(),
            http: FakeConnectorServer(), userAgent: FakeUserAgent(), sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9")
        environment.nativeHomes = {
            [NativeMCPHome(kind: .claude(file: claude), account: "developer@example.test"), NativeMCPHome(kind: .codex(home: codex))]
        }
        return ConnectorCenter(environment: environment)
    }

    func testTheSettingsPageDraws() async throws {
        let directory = try WindowlessRender.directory("connectors-qa")
        let center = try center()
        await center.loadNativeInventory()
        XCTAssertEqual(center.importSuggestions.map(\.name), ["docs", "clobe", "docs.v2"],
                       "Linear, Gmail, GitHub and Browserbase are added already")
        let size = NSSize(width: 820, height: 1500)
        let captures = try WindowlessRender.hostedInBothAppearances("settings-connectors", in: directory, size: size,
                                                                     passes: 12) { appearance in
            SettingsCenterView(size: CGSize(width: size.width, height: size.height),
                               initialSection: SettingsSection.connectors.rawValue,
                               notificationCenter: SilentNotificationCenter(), connectors: center)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }

        let host = WindowlessRender.Host(ConnectorSettingsView(center: center).padding(20)
            .frame(width: 640, height: 1400, alignment: .top), size: NSSize(width: 640, height: 1400))
        defer { host.close() }
        host.settle(passes: 12)
        let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
        for text in ["Linear", "Slack", L10n.string("Reconnect"), L10n.string("Use claude.ai account connectors"),
                     L10n.string("You use these elsewhere"), "clobe", L10n.string("Your connectors"),
                     L10n.string("Needs sign-in")] {
            XCTAssertTrue(spoken.contains { $0.contains(text) }, "No \(text): \(spoken)")
        }
    }

    /// `settings-connectors-unreadable-*`: saved settings Yardlet cannot read show none of their
    /// connectors and say that changes here are not kept; once a save is kept again, the line goes.
    func testTheSettingsPageSaysWhenSavedConnectorsCannotBeRead() throws {
        let directory = try WindowlessRender.directory("connectors-qa")
        let root = FileManager.default.temporaryDirectory.appending(path: "connectors-unreadable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        let file = root.appending(path: "connectors.json")
        try Data(#"{"version": 1, "connectors": [{"name": "Linear", "kind": "from-a-newer-yardlet"}]}"#.utf8).write(to: file)
        let center = ConnectorCenter(environment: ConnectorCenter.Environment(
            repository: FileConnectorRepository(fileURL: file), credentials: InMemoryConnectorCredentialStore(),
            http: FakeConnectorServer(), userAgent: FakeUserAgent(), sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9"))
        XCTAssertTrue(center.cannotReadSavedSettings)
        let size = NSSize(width: 820, height: 640)
        let captures = try WindowlessRender.hostedInBothAppearances("settings-connectors-unreadable", in: directory, size: size,
                                                                     passes: 12) { appearance in
            SettingsCenterView(size: CGSize(width: size.width, height: size.height),
                               initialSection: SettingsSection.connectors.rawValue,
                               notificationCenter: SilentNotificationCenter(), connectors: center)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }

        let host = WindowlessRender.Host(ConnectorSettingsView(center: center).padding(20)
            .frame(width: 640, height: 600, alignment: .top), size: NSSize(width: 640, height: 600))
        defer { host.close() }
        host.settle(passes: 12)
        let notice = L10n.format("Yardlet couldn't read %@, so your saved connectors aren't shown. The file is left as it is, and changes made here are lost when Yardlet quits.",
                                 "~/.yardlet/connectors.json")
        let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
        XCTAssertTrue(spoken.contains { $0.contains(notice) }, "No notice: \(spoken)")

        try FileManager.default.removeItem(at: file)
        center.setConnector(UUID(), on: false, inTask: UUID())
        XCTAssertFalse(center.cannotReadSavedSettings, "A kept save takes the line away")
    }

    func testTheAddFormWithARegisteredClientDraws() throws {
        let directory = try WindowlessRender.directory("connectors-qa")
        let center = try center()
        let slack = try XCTUnwrap(ConnectorPreset.preset(id: "slack"))
        let size = NSSize(width: 580, height: 660)
        let captures = try WindowlessRender.hostedInBothAppearances("settings-add-slack", in: directory, size: size) { appearance in
            ConnectorAddSheet(center: center, start: .preset(slack), onClose: {})
                .environment(\.colorScheme, appearance.colorScheme)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
    }

    func testTheComposerListDraws() throws {
        let directory = try WindowlessRender.directory("connectors-qa")
        let states: [String: ConnectorTaskState] = ["Linear": .harnessHasIt, "Notion": .off]
        let list = try XCTUnwrap(ComposerConnectorList.make(
            ComposerConnectorsSlot(sessionServers: [
                HarnessMCPServerStatus(name: "yardlet", state: .connected, toolCount: 120),
                HarnessMCPServerStatus(name: "linear", state: .connected, toolCount: 23),
                HarnessMCPServerStatus(name: "browserbase", state: .failed, toolCount: nil)
            ], carriesYardletConnectors: true),
            connectors: Self.records, taskState: { states[$0.name] ?? .on }))
        let size = NSSize(width: 360, height: 560)
        let content = ComposerConnectorsMenu(list: list, onManage: {}, onSwitch: { _, _ in }, onReconnect: { _ in })
            .background(ParityTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        let captures = try WindowlessRender.hostedInBothAppearances("composer-connectors", in: directory, size: size) { appearance in
            content
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(ParityTheme.canvas)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        let host = WindowlessRender.Host(content.frame(width: size.width, height: size.height, alignment: .topLeading), size: size)
        defer { host.close() }
        host.settle()
        let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
        for text in [L10n.string("Uses the harness's own server"), L10n.string("Off for this task"), L10n.string("Reconnect"),
                     L10n.format("Use %@ in this task", "GitHub")] {
            XCTAssertTrue(spoken.contains { $0.contains(text) }, "No \(text): \(spoken)")
        }
    }

    /// A Claude task where Yardlet's Linear stands in for the folder's own: Yardlet's row has its
    /// switch, and the harness's row under "The harness's own servers" says Yardlet's connector is
    /// used, in the plain secondary style, not as an error.
    func testAStoodInServerDrawsAsUsingYardletsConnector() throws {
        let directory = try WindowlessRender.directory("connectors-qa")
        let list = try XCTUnwrap(ComposerConnectorList.make(
            ComposerConnectorsSlot(sessionServers: [
                HarnessMCPServerStatus(name: "yardlet", state: .connected, toolCount: 120),
                HarnessMCPServerStatus(name: "linear", state: .failed, toolCount: nil),
                HarnessMCPServerStatus(name: "sentry", state: .connected, toolCount: 9)
            ], carriesYardletConnectors: true),
            connectors: Array(Self.records.prefix(2)), standInServerNames: ["linear"]))
        XCTAssertEqual(list.needsReconnectionCount, 0)
        let size = NSSize(width: 360, height: 420)
        let content = ComposerConnectorsMenu(list: list, onManage: {}, onSwitch: { _, _ in }, onReconnect: { _ in })
            .background(ParityTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        let captures = try WindowlessRender.hostedInBothAppearances("composer-connectors-stand-in", in: directory, size: size) { appearance in
            content
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(ParityTheme.canvas)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        let host = WindowlessRender.Host(content.frame(width: size.width, height: size.height, alignment: .topLeading), size: size)
        defer { host.close() }
        host.settle()
        let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
        XCTAssertTrue(spoken.contains { $0.contains(L10n.string("Uses Yardlet's connector")) }, "\(spoken)")
        XCTAssertFalse(spoken.contains { $0.contains(L10n.string("Error")) }, "\(spoken)")
    }

    /// The session rail's Connectors card: "Add connectors" opens the directory without Settings,
    /// beside "Manage connectors", and a server still connecting is read again until it settles.
    func testTheRailCardAddsConnectorsAndFollowsAServerStillConnecting() async throws {
        let directory = try WindowlessRender.directory("connectors-qa")
        let list = try XCTUnwrap(ComposerConnectorList.make(
            ComposerConnectorsSlot(sessionServers: [
                HarnessMCPServerStatus(name: "yardlet", state: .connected, toolCount: 120),
                HarnessMCPServerStatus(name: "sentry", state: .pending, toolCount: nil)
            ], carriesYardletConnectors: true),
            connectors: Array(Self.records.prefix(3))))
        var added = 0
        var actions = SessionRailActions()
        actions.connectors = ComposerConnectorEnvironment(
            records: Array(Self.records.prefix(3)), setOn: { _, _ in }, reconnect: { _ in }, openSettings: {},
            addConnector: { added += 1 })
        let size = NSSize(width: 280, height: 260)
        let content = SessionRailConnectorsCard(list: list, actions: actions).padding(12)
        let captures = try WindowlessRender.hostedInBothAppearances("rail-connectors", in: directory, size: size) { appearance in
            content
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(ParityTheme.canvas)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        let host = WindowlessRender.Host(content.frame(width: size.width, height: size.height, alignment: .topLeading), size: size)
        defer { host.close() }
        host.settle()
        let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
        for text in [L10n.string("Add connectors"), L10n.string("Manage connectors")] {
            XCTAssertTrue(spoken.contains { $0.contains(text) }, "No \(text): \(spoken)")
        }

        let entries = ComposerConnectorsMenu.entries(list: list, onManage: {}, onAdd: { added += 1 },
                                                     onSwitch: nil, onReconnect: nil)
        XCTAssertEqual(entries.prefix(2).map(\.id), ["manage", "add"])
        entries[1].action?()
        XCTAssertEqual(added, 1)

        var reads = 0
        var pauses: [Duration] = []
        await SessionRailConnectorsCard.follow(list, refresh: { reads += 1 }, pause: { pauses.append($0) })
        XCTAssertEqual(reads, 3, "A server still connecting is read again after one and two more seconds")
        XCTAssertEqual(pauses, [.seconds(1), .seconds(2)])
        reads = 0
        await SessionRailConnectorsCard.follow(list, refresh: { reads += 1 }, pause: { _ in throw CancellationError() })
        XCTAssertEqual(reads, 1, "A cancelled pause stops reading")
        let settled = try XCTUnwrap(ComposerConnectorList.make(
            ComposerConnectorsSlot(sessionServers: [HarnessMCPServerStatus(name: "sentry", state: .connected, toolCount: 3)],
                                   carriesYardletConnectors: false),
            connectors: []))
        reads = 0
        await SessionRailConnectorsCard.follow(settled, refresh: { reads += 1 }, pause: { _ in })
        XCTAssertEqual(reads, 1, "A list with nothing connecting is read once")
    }
}

private final class SilentNotificationCenter: SystemNotificationCenter {
    func authorization() async -> SystemNotificationAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func post(title: String, body: String, identifier: String) async {}
}
