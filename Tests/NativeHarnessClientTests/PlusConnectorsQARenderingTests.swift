import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// The composer's "+" menu and Settings → Connectors after the 2026-10-17 redesign, drawn offscreen
/// into `.build/plus-connectors-qa/after`, light and dark, with what each says checked. Fixture
/// connectors and a fake server only: no network, sign-in, provider, or window on screen.
///
/// - `plus-menu-*`: the "+" menu (files or photos, folder | slash commands, connectors with its
///   hint) beside the connector list it opens.
/// - `plus-menu-keyboard-*`: the menu opened from the keyboard, its first row highlighted.
/// - `settings-empty-*`, `settings-connected-*`: the page with no connectors, and with connectors in
///   every state — connected first, then needs sign-in and error with its reason.
/// - `add-*`: the add sheet: the directory as it opens, a key (GitHub, Browserbase), an OAuth app of
///   one's own (Slack, Gmail with the Google note), and a server by URL.
/// - `add-search-*`, `add-builtin-google-*`: the directory searched (one service, and none), and a
///   build with Yardlet's own Google app, where Google connects in one click.
@MainActor
final class PlusConnectorsQARenderingTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func center(_ records: [ConnectorRecord], googleBuiltIn: Bool = false, gitHubApp: Bool = false) throws -> ConnectorCenter {
        let root = FileManager.default.temporaryDirectory.appending(path: "plus-connectors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        let claude = root.appending(path: "claude.json")
        try Data(ConnectorDirectoryTests.claudeFixture.utf8).write(to: claude)
        var environment = ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(records: records), credentials: InMemoryConnectorCredentialStore(),
            http: FakeConnectorServer(), userAgent: FakeUserAgent(), sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9")
        environment.nativeHomes = { [NativeMCPHome(kind: .claude(file: claude), account: "developer@example.test")] }
        if googleBuiltIn {
            environment.googleBuiltInApp = .init(clientID: FakeGoogle.clientID, clientSecret: FakeGoogle.clientSecret)
        }
        if gitHubApp { environment.gitHubClientID = "Ov23liTestClient" }
        return ConnectorCenter(environment: environment)
    }

    private static let directory = "plus-connectors-qa/after"

    private static var menuList: ComposerConnectorList {
        ComposerConnectorList.make(
            ComposerConnectorsSlot(sessionServers: [
                HarnessMCPServerStatus(name: "yardlet", state: .connected, toolCount: 120),
                HarnessMCPServerStatus(name: "github", state: .needsAuthentication, toolCount: nil),
                HarnessMCPServerStatus(name: "claude.ai Gmail", state: .connected, toolCount: 9)
            ], carriesYardletConnectors: true),
            connectors: ConnectorsRenderingTests.records,
            taskState: { $0.name == "Notion" ? .off : .on })!
    }

    private static let noActions = ComposerPlusMenu.Actions(addFiles: {}, addFolder: {}, openCommands: {},
                                                           openConnectors: {})

    private func menuCard<Content: View>(_ content: Content) -> some View {
        // A popover's card: its shadow is the card's, not the text's.
        content
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(ParityTheme.elevated)
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            }
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(ParityTheme.separator) }
    }

    // MARK: The "+" menu

    func testThePlusMenuFollowsTheClaudeAppsOrder() {
        let entries = ComposerPlusMenu.entries(carriesImages: true, connectors: Self.menuList, actions: Self.noActions)
        XCTAssertEqual(entries.map(\.title), [L10n.string("Add files or photos"), L10n.string("Add folder"),
                                              L10n.string("Slash commands"), L10n.string("Connectors")])
        XCTAssertEqual(entries.map(\.startsGroup), [false, false, true, false], "What is added, then the tools")
        XCTAssertEqual(entries.map(\.opensList), [false, false, true, true])
        if case let .submenu(hint) = entries[3].accessory {
            XCTAssertEqual(hint, L10n.format("%lld need reconnection", Int64(2)))
        } else {
            XCTFail("Connectors opens its list")
        }

        // Without image input the first row adds files; without commands or connectors those rows go.
        let bare = ComposerPlusMenu.entries(carriesImages: false, connectors: nil,
                                            actions: .init(addFiles: {}, addFolder: {}, openCommands: nil,
                                                           openConnectors: nil))
        XCTAssertEqual(bare.map(\.title), [L10n.string("Add files"), L10n.string("Add folder")])
        XCTAssertFalse(bare.contains(where: \.startsGroup))
    }

    func testTheConnectorListIsSwitchesThenSignInsThenTheHarnesssOwn() {
        var switched: [(UUID, Bool)] = []
        var reconnected: [UUID] = []
        let entries = ComposerConnectorsMenu.entries(list: Self.menuList, onManage: {},
                                                     onSwitch: { switched.append(($0, $1)) },
                                                     onReconnect: { reconnected.append($0) })
        XCTAssertEqual(entries.map(\.title), [L10n.string("Manage connectors"), "Linear", "Notion", "GitHub",
                                              "Browserbase", "Slack", "Gmail", "github", "claude.ai Gmail"])
        XCTAssertEqual(entries.first { $0.title == "github" }?.groupTitle, L10n.string("The harness's own servers"))
        XCTAssertEqual(entries.first { $0.title == "Slack" }?.subtitle, L10n.string("Needs sign-in"))
        XCTAssertEqual(entries.first { $0.title == "github" }?.subtitle, L10n.string("Needs sign-in"))
        XCTAssertNil(entries.first { $0.title == "github" }?.action, "The harness's own servers are read-only")
        guard case let .toggle(isOn, _)? = entries.first(where: { $0.title == "Notion" })?.accessory else {
            return XCTFail("Notion has this task's switch")
        }
        XCTAssertFalse(isOn)
        entries.first { $0.title == "Notion" }?.action?()
        XCTAssertEqual(switched.map(\.1), [true], "Choosing the row flips the switch")
        entries.first { $0.title == "Slack" }?.action?()
        XCTAssertEqual(reconnected.count, 1)
        XCTAssertEqual(ComposerConnectorsMenu.footnotes(list: Self.menuList, switches: true),
                       [L10n.string("A connector turned off here stops at once; the task's tool list follows when it next starts or resumes.")])
    }

    func testThePlusMenuDraws() throws {
        let directory = try WindowlessRender.directory(Self.directory)
        let list = Self.menuList
        let size = NSSize(width: 640, height: 470)
        let content = HStack(alignment: .top, spacing: 18) {
            menuCard(ComposerMenuList(entries: ComposerPlusMenu.entries(carriesImages: true, connectors: list,
                                                                        actions: Self.noActions),
                                      onDismiss: {}))
            menuCard(ComposerConnectorsMenu(list: list, onManage: {}, onSwitch: { _, _ in }, onReconnect: { _ in },
                                            onBack: {}))
        }
        .padding(16)
        let captures = try WindowlessRender.hostedInBothAppearances("plus-menu", in: directory, size: size) { appearance in
            content
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(ParityTheme.canvas)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        let host = WindowlessRender.Host(content.frame(width: size.width, height: size.height, alignment: .topLeading),
                                         size: size)
        defer { host.close() }
        host.settle()
        let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
        for text in [L10n.string("Add files or photos"), L10n.string("Add folder"), L10n.string("Slash commands"),
                     L10n.string("Manage connectors"), L10n.string("Reconnect"), L10n.format("Use %@ in this task", "Linear"),
                     L10n.string("Off for this task"), L10n.string("Back")] {
            XCTAssertTrue(spoken.contains { $0.contains(text) }, "No \(text): \(spoken)")
        }

        let keyboardSize = NSSize(width: 300, height: 200)
        try WindowlessRender.hostedInBothAppearances("plus-menu-keyboard", in: directory, size: keyboardSize) { appearance in
            menuCard(ComposerMenuList(entries: ComposerPlusMenu.entries(carriesImages: true, connectors: list,
                                                                        actions: Self.noActions),
                                      highlightsFirstRow: true, onDismiss: {}))
                .padding(16)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: keyboardSize.width, height: keyboardSize.height, alignment: .topLeading)
                .background(ParityTheme.canvas)
        }
    }

    // MARK: Settings → Connectors

    private func page<Content: View>(_ content: Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "powerplug").font(.system(size: 14, weight: .semibold)).foregroundStyle(ParityTheme.accent)
                Text(L10n.string("Connectors")).font(.system(size: 18, weight: .semibold))
            }
            content
        }
        .padding(20)
    }

    func testTheSettingsPageDrawsEmptyAndConnected() async throws {
        let directory = try WindowlessRender.directory(Self.directory)

        let empty = try center([])
        await empty.loadNativeInventory()
        let emptySize = NSSize(width: 680, height: 640)
        try WindowlessRender.hostedInBothAppearances("settings-empty", in: directory, size: emptySize, passes: 12) { appearance in
            page(ConnectorSettingsView(center: empty))
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: emptySize.width, height: emptySize.height, alignment: .topLeading)
                .background(ParityTheme.canvas)
        }
        let emptyHost = WindowlessRender.Host(page(ConnectorSettingsView(center: empty))
            .frame(width: emptySize.width, height: emptySize.height, alignment: .topLeading), size: emptySize)
        emptyHost.settle(passes: 12)
        let emptySpoken = emptyHost.accessibilityElements().map { "\($0.label) \($0.value)" }
        emptyHost.close()
        for text in [L10n.string("No connectors yet"), L10n.string("Add connector"),
                     L10n.string("Use claude.ai account connectors"), L10n.string("You use these elsewhere"),
                     L10n.string("Set up in one go")] {
            XCTAssertTrue(emptySpoken.contains { $0.contains(text) }, "No \(text): \(emptySpoken)")
        }

        // Figma's desktop server is not running here, so connecting it fails with a reason.
        let figma = ConnectorRecord(name: "Figma", slug: "figma", serverURL: URL(string: "http://127.0.0.1:3845/mcp")!,
                                    authorization: .none, status: .notConnected, presetID: "figma-desktop")
        let connected = try center([figma] + ConnectorsRenderingTests.records)
        await connected.loadNativeInventory()
        connected.connect(figma.id)
        await connected.waitForConnection(figma.id)
        XCTAssertNotNil(connected.failures[figma.id])
        XCTAssertEqual(ConnectorSettingsState.ordered(connected).map(\.name),
                       ["Linear", "Notion", "GitHub", "Browserbase", "Slack", "Gmail", "Figma"],
                       "Connected first, then needs sign-in, then error")
        let size = NSSize(width: 680, height: 980)
        try WindowlessRender.hostedInBothAppearances("settings-connected", in: directory, size: size, passes: 12) { appearance in
            page(ConnectorSettingsView(center: connected))
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(ParityTheme.canvas)
        }
        let host = WindowlessRender.Host(page(ConnectorSettingsView(center: connected))
            .frame(width: size.width, height: size.height, alignment: .topLeading), size: size)
        defer { host.close() }
        host.settle(passes: 12)
        let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
        for text in [L10n.string("Your connectors"), L10n.string("Connected"), L10n.string("Needs sign-in"),
                     L10n.string("Error"), L10n.string("Reconnect"), L10n.string("Try again"), L10n.string("Set up…"), "docs"] {
            XCTAssertTrue(spoken.contains { $0.contains(text) }, "No \(text): \(spoken)")
        }
        XCTAssertFalse(spoken.contains { $0.contains("mcp.example.test/mcp") },
                       "The read-only list of each harness's own servers and their addresses is gone")
    }

    // MARK: Adding

    func testTheAddSheetDrawsEachKindOfService() throws {
        let directory = try WindowlessRender.directory(Self.directory)
        let center = try center([ConnectorsRenderingTests.records[0]])
        XCTAssertEqual(ConnectorSetupGuide.Kind.oneClick.presets.map(\.id),
                       ["linear", "notion", "apple-calendar", "apple-reminders", "apple-contacts", "atlassian", "sentry", "asana",
                        "clickup", "monday", "todoist", "airtable", "miro", "dropbox", "intercom", "zapier", "pipedream", "composio",
                        "make", "granola", "fireflies", "gamma",
                        "basecamp", "teamwork", "lucid", "pandadoc", "fathom", "deepl", "mobbin",
                        "apollo-io", "attio", "customer-io", "klaviyo", "mailerlite", "ahrefs", "semrush", "similarweb", "amplitude",
                        "mixpanel",
                        "xcode", "gitlab", "supabase", "neon", "prisma", "netlify", "cloudflare", "posthog", "semgrep", "postman", "jam",
                        "circleci", "browserstack", "bugsnag", "swagger", "zephyr", "grafana", "honeycomb", "axiom", "statsig", "port",
                        "aiven", "upstash", "algolia", "contentful", "sanity", "workos", "apify", "mapbox",
                        "stripe", "paypal", "square", "mercury", "webflow", "wix", "ramp", "brex", "paddle", "beancount-io", "hostinger",
                        "figma-desktop", "tavily", "exa", "huggingface", "context7", "deepwiki", "openai-docs",
                        "microsoft-learn", "aws-knowledge", "cloudflare-docs", "twilio-docs"])
        XCTAssertEqual(ConnectorSetupGuide.Kind.key.presets.map(\.id), ["github", "browserbase", "app-store-connect"])
        XCTAssertEqual(ConnectorSetupGuide.Kind.ownApp.presets.map(\.id),
                       ["slack", "gmail", "google-calendar", "google-drive", "google-analytics", "google-ads", "outlook-mail",
                        "outlook-calendar", "onedrive", "microsoft-teams", "zoom-meetings", "zoom-team-chat", "zoom-docs"])
        for preset in ConnectorSetupGuide.Kind.ownApp.presets {
            XCTAssertFalse(ConnectorSetupGuide.guide(for: preset)?.steps.isEmpty ?? true, preset.id)
            XCTAssertFalse(ConnectorSetupGuide.guide(for: preset)?.links.isEmpty ?? true, preset.id)
        }

        struct Case {
            let name: String
            var start: ConnectorAddSheet.Start = .directory
            var showsOwnApps = false
            var expandedRow: String? = nil
            var query = ""
            let expected: [String]
        }
        let github = try XCTUnwrap(ConnectorPreset.preset(id: "github"))
        let browserbase = try XCTUnwrap(ConnectorPreset.preset(id: "browserbase"))
        let slack = try XCTUnwrap(ConnectorPreset.preset(id: "slack"))
        let gmail = try XCTUnwrap(ConnectorPreset.preset(id: "gmail"))
        let cases = [
            // As it opens: one-click services, keys, the OAuth-app heading folded, and a URL.
            Case(name: "add-directory", expected: [L10n.string("Connect in one click"), L10n.string("Paste a key or token"),
                                                   L10n.string("Needs an OAuth app of your own"), L10n.string("Collapsed"),
                                                   L10n.string("Added")]),
            // The heading opened: the Google note with the claude.ai switch, then Slack and Google.
            Case(name: "add-directory-own-apps", showsOwnApps: true,
                 expected: [L10n.string("Gmail, Google Calendar, and Google Drive can't be connected with a plain Google sign-in."),
                            L10n.string("Use claude.ai account connectors"), "Slack", L10n.string("Google · Gmail, Calendar, Drive"),
                            L10n.string("Set up…")]),
            // A key in the directory row itself.
            Case(name: "add-key-github-inline", expandedRow: github.id,
                 expected: [L10n.string("Paste a personal access token"), L10n.string("Create a token on GitHub")]),
            Case(name: "add-key-github", start: .preset(github),
                 expected: [L10n.format("Connect %@", "GitHub"), L10n.string("Paste a personal access token"),
                            L10n.string("Create a token on GitHub"), L10n.string("All services")]),
            Case(name: "add-key-browserbase", start: .preset(browserbase),
                 expected: [L10n.string("Paste your API key"), L10n.string("Find your API key")]),
            // Slack's setup assistant since 2026-10-19: Yardlet's manifest, the client ID, the sign-in.
            Case(name: "add-oauth-app-slack", start: .preset(slack),
                 expected: [L10n.string("Set up Slack"), L10n.string("Create the Yardlet app in Slack"),
                            L10n.string("Create in Slack"), L10n.format("Copy %@", L10n.string("Manifest")),
                            L10n.string("Slack client ID"), L10n.string("Sign in to Slack")]),
            // Google's: one OAuth app for Gmail, Calendar, and Drive, then accounts.
            Case(name: "add-oauth-app-gmail", start: .preset(gmail),
                 expected: [L10n.string("Set up Google"), L10n.string("Create a Google Cloud project"),
                            L10n.string("Turn on the Gmail, Calendar, and Drive APIs"),
                            L10n.format("Copy %@", L10n.string("Redirect URL")), L10n.string("Save"),
                            L10n.string("Sign in with Google")]),
            // Mercury, read only: its row says so under its name.
            Case(name: "add-directory-mercury", query: "Mercury", expected: ["Mercury", L10n.string("Read-only")]),
            Case(name: "add-custom-url", expandedRow: ConnectorAddSheet.customID,
                 expected: [L10n.string("Add by URL"), L10n.string("Sign-in details (optional)"), L10n.string("Add and connect")])
        ]
        let size = NSSize(width: 580, height: 660)
        for item in cases {
            func sheet() -> ConnectorAddSheet {
                ConnectorAddSheet(center: center, start: item.start, showsOwnApps: item.showsOwnApps,
                                  expandedRow: item.expandedRow, query: item.query, onClose: {})
            }
            let captures = try WindowlessRender.hostedInBothAppearances(item.name, in: directory, size: size, passes: 10) { appearance in
                sheet().environment(\.colorScheme, appearance.colorScheme)
            }
            for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
            let host = WindowlessRender.Host(sheet(), size: size)
            host.settle(passes: 10)
            let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
            host.close()
            for text in item.expected {
                XCTAssertTrue(spoken.contains { $0.contains(text) }, "\(item.name) has no \(text): \(spoken)")
            }
        }
    }

    /// The directory of 2026-10-21 is long: a search narrows it, and a build with Yardlet's own
    /// Google app lists Google with the one-click services instead of under an app of one's own.
    func testTheDirectorySearchesAndGoogleConnectsInOneClickWithTheBuiltInApp() throws {
        let directory = try WindowlessRender.directory(Self.directory)
        let size = NSSize(width: 580, height: 660)
        let stripe = try XCTUnwrap(ConnectorPreset.preset(id: "stripe"))
        XCTAssertTrue(ConnectorSetupGuide.matches(stripe, query: " STR "))
        XCTAssertFalse(ConnectorSetupGuide.matches(stripe, query: "notion"))
        XCTAssertTrue(ConnectorSetupGuide.matchesGoogle(query: "drive"))
        XCTAssertFalse(ConnectorSetupGuide.matchesGoogle(query: "dropbox"))

        struct Case {
            let name: String
            let googleBuiltIn: Bool
            var gitHubApp = false
            let query: String
            let expected: [String]
            let absent: [String]
        }
        let cases = [
            Case(name: "add-search-stripe", googleBuiltIn: false, query: "stripe",
                 expected: ["Stripe", L10n.string("Connect in one click"), L10n.string("Search services")],
                 absent: ["Linear", "Notion", L10n.string("Paste a key or token"), L10n.string("Needs an OAuth app of your own")]),
            Case(name: "add-search-none", googleBuiltIn: false, query: "nothing-like-this",
                 expected: [L10n.string("No service in the directory has that name. Add it by its address below."),
                            L10n.string("Another MCP server")],
                 absent: [L10n.string("Connect in one click")]),
            // A build with Yardlet's GitHub app: GitHub signs in with one click instead of a token.
            Case(name: "add-github-signin", googleBuiltIn: false, gitHubApp: true, query: "git",
                 expected: ["GitHub", L10n.string("Sign in with GitHub"), L10n.string("Connect in one click")],
                 absent: [L10n.string("Paste a key or token")]),
            Case(name: "add-builtin-google", googleBuiltIn: true, query: "",
                 expected: [L10n.string("Google · Gmail, Calendar, Drive"),
                            L10n.string("Sign in with Google · personal and Workspace accounts"),
                            L10n.string("Needs an OAuth app of your own")],
                 absent: [L10n.string("Gmail, Google Calendar, and Google Drive can't be connected with a plain Google sign-in.")])
        ]
        for item in cases {
            let center = try center([], googleBuiltIn: item.googleBuiltIn, gitHubApp: item.gitHubApp)
            func sheet() -> ConnectorAddSheet {
                ConnectorAddSheet(center: center, start: .directory, query: item.query, onClose: {})
            }
            let captures = try WindowlessRender.hostedInBothAppearances(item.name, in: directory, size: size, passes: 10) { appearance in
                sheet().environment(\.colorScheme, appearance.colorScheme)
            }
            for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
            let host = WindowlessRender.Host(sheet(), size: size)
            host.settle(passes: 10)
            let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
            host.close()
            for text in item.expected {
                XCTAssertTrue(spoken.contains { $0.contains(text) }, "\(item.name) has no \(text): \(spoken)")
            }
            for text in item.absent {
                XCTAssertFalse(spoken.contains { $0.contains(text) }, "\(item.name) has \(text): \(spoken)")
            }
        }
    }
}
