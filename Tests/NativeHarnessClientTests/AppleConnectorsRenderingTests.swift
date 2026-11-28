import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Renders the Apple connectors offscreen into `.build/apple-connectors-qa/`, light and dark,
/// without a privacy prompt, keychain item or Xcode.
@MainActor
final class AppleConnectorsRenderingTests: XCTestCase {
    private static let folder = "apple-connectors-qa"

    private func defaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("AppleConnectorsQA")))
    }

    private func center(_ records: [ConnectorRecord] = [], apple: FakeAppStoreConnect = FakeAppStoreConnect(),
                        macData: FakeMacData = FakeMacData(), bridge: FakeStdioServer? = FakeStdioServer(),
                        credentials: InMemoryConnectorCredentialStore = InMemoryConnectorCredentialStore()) -> ConnectorCenter {
        var environment = ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(records: records), credentials: credentials, http: apple,
            userAgent: nil, sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9")
        environment.appStoreConnect = FakeAppStoreConnect.base
        environment.es256 = MacES256Signer()
        environment.macData = macData
        if let bridge {
            environment.xcodeBridge = { FakeStdioServer.path }
            environment.stdioLauncher = { _ in bridge }
        }
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

    /// A transparent window far off screen, ordered in so its buttons take presses; it never
    /// becomes key and the app is not activated.
    private func offScreen<Content: View>(_ content: Content, size: NSSize,
                                          appearance: WindowlessRender.Appearance = .light) -> WindowlessRender.Host<Content> {
        let host = WindowlessRender.Host(content, size: size, appearance: appearance)
        host.window.alphaValue = 0
        host.window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        host.window.orderFrontRegardless()
        host.settle(passes: 10)
        return host
    }

    private func write<Content: View>(_ host: WindowlessRender.Host<Content>, _ name: String,
                                      _ appearance: WindowlessRender.Appearance) throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let capture = try host.capture()
        XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6), name)
        try WindowlessRender.writePNG(capture.bitmap, to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
    }

    /// Reads the connectors' pictures into the shared store first: in an `async` test a view's
    /// `.task` cannot resume on the main actor while the test turns the run loop.
    private func warmIcons(_ records: [ConnectorRecord]) async {
        for record in records {
            for dark in [false, true] { _ = await ConnectorIconStore.shared.image(for: record.iconSources.urls(dark: dark)) }
        }
    }

    // MARK: - The directory

    func testTheDirectoryOffersTheAppleConnectors() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let store = try defaults()
        let size = NSSize(width: 580, height: 660)
        let center = center()
        try WindowlessRender.hostedInBothAppearances("add-search-app", in: directory, size: size, passes: 12) { appearance in
            ConnectorAddSheet(center: center, start: .directory, query: "App", onClose: {})
                .defaultAppStorage(store)
                .environment(\.colorScheme, appearance.colorScheme)
        }
        let app = spoken(ConnectorAddSheet(center: center, start: .directory, query: "App", onClose: {}).defaultAppStorage(store),
                         size: size)
        expect(["Apple Calendar", "Apple Reminders", "Apple Contacts", L10n.string("On this Mac · macOS asks once"),
                "App Store Connect", L10n.string("API key (.p8 file)"), L10n.string("Set up…")], in: app, "App")

        try WindowlessRender.hostedInBothAppearances("add-search-xcode", in: directory, size: size, passes: 12) { appearance in
            ConnectorAddSheet(center: center, start: .directory, query: "Xcode", onClose: {})
                .defaultAppStorage(store)
                .environment(\.colorScheme, appearance.colorScheme)
        }
        let xcode = spoken(ConnectorAddSheet(center: center, start: .directory, query: "Xcode", onClose: {}).defaultAppStorage(store),
                           size: size)
        expect(["Xcode", L10n.string("Needs Xcode open with a project")], in: xcode, "Xcode")

        let withoutXcode = spoken(ConnectorAddSheet(center: self.center(bridge: nil), start: .directory, query: "Xcode", onClose: {})
            .defaultAppStorage(store), size: size)
        XCTAssertFalse(withoutXcode.contains { $0.hasPrefix("Xcode") }, "Not offered without Xcode: \(withoutXcode)")
    }

    // MARK: - App Store Connect

    func testAppStoreConnectsPageTakesAKeyFileAndAsksAboutIt() async throws {
        let store = try defaults()
        let size = NSSize(width: 580, height: 900)
        let empty = center()
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(page(AppStoreConnectSetupPage(center: empty), size: size, appearance: appearance,
                                                  defaults: store), size: size, appearance: appearance)
            host.settle(passes: 10)
            try write(host, "asc-page-empty", appearance)
            host.close()
        }
        let fresh = spoken(page(AppStoreConnectSetupPage(center: empty), size: size, appearance: .light, defaults: store), size: size)
        expect([L10n.string("Set up App Store Connect"), L10n.format("%lld of %lld done", Int64(0), Int64(3)),
                L10n.string("Create an API key in App Store Connect"), L10n.string("Open App Store Connect"),
                L10n.string("Choose the key file and enter its IDs"), L10n.string("Choose .p8 File…"), L10n.string("Key ID"),
                L10n.string("Issuer ID"), L10n.string("Team key"), L10n.string("Individual key"), L10n.string("Connect")],
               in: fresh, "empty")

        // A team key's file, chosen and named as App Store Connect names it.
        let folder = FileManager.default.temporaryDirectory.appending(path: "asc-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let apple = FakeAppStoreConnect()
        let file = folder.appending(path: "AuthKey_2X9R4HXF34.p8")
        try Data(apple.privateKey.pemRepresentation.utf8).write(to: file)
        var trashed: [URL] = []
        func filled(_ center: ConnectorCenter) -> AppStoreConnectSetupPage {
            AppStoreConnectSetupPage(center: center, keyFile: file, keyID: "2X9R4HXF34", issuerID: FakeAppStoreConnect.issuer,
                                     trash: { trashed.append($0) })
        }
        let untouched = center(apple: apple)
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(page(filled(untouched), size: size, appearance: appearance, defaults: store), size: size,
                                             appearance: appearance)
            host.settle(passes: 10)
            try write(host, "asc-page-filled", appearance)
            host.close()
        }
        expect([L10n.format("%lld of %lld done", Int64(2), Int64(3)), "AuthKey_2X9R4HXF34.p8"],
               in: spoken(page(filled(untouched), size: size, appearance: .light, defaults: store), size: size), "filled")

        // Connect, pressed in the off-screen window: the key goes to the keychain, Apple reads it
        // once, and the page asks about the file in a line of its own.
        for appearance in WindowlessRender.Appearance.allCases {
            let credentials = InMemoryConnectorCredentialStore()
            let before = apple.requests.count
            let connecting = center(apple: apple, credentials: credentials)
            let host = offScreen(page(filled(connecting), size: size, appearance: appearance, defaults: store), size: size,
                                 appearance: appearance)
            XCTAssertTrue(host.hosting.pressButton(labeled: L10n.string("Connect")))
            await host.settle(until: { connecting.connectors.first?.status == .connected
                && host.accessibilityElements().contains { $0.label.contains(L10n.string("Move to Trash")) } })
            host.settle(passes: 10)
            try write(host, "asc-page-connected", appearance)
            let text = host.accessibilityElements().map { "\($0.label) \($0.value)" }
            expect([L10n.format("Key %@", "2X9R4HXF34"), L10n.string("Connected"),
                    L10n.format("Move %@ to the Trash?", "AuthKey_2X9R4HXF34.p8"), L10n.string("Keep the File"),
                    L10n.string("Add another key"), L10n.format("%lld of %lld done", Int64(0), Int64(3))], in: text,
                   "connected \(appearance)")
            XCTAssertEqual(try credentials.load(XCTUnwrap(connecting.connectors.first?.id))?.kind, .signingKey)
            XCTAssertEqual(apple.requests.count - before, 1, "One read to check the key")
            if appearance == .light {
                XCTAssertTrue(host.hosting.pressButton(labeled: L10n.string("Move to Trash")))
                host.settle(passes: 6)
                XCTAssertEqual(trashed, [file], "Moved only when asked, and only that file")
            }
            host.close()
        }
    }

    // MARK: - The Mac's data and Xcode, connected from the directory

    func testConnectingTheMacsCalendarFromTheDirectory() async throws {
        let store = try defaults()
        let macData = FakeMacData()
        macData.permissions = [.calendars: .notDetermined, .reminders: .granted, .contacts: .granted]
        let center = center(macData: macData)
        var closed = false
        let sheetSize = NSSize(width: 580, height: 660)
        let host = offScreen(ConnectorAddSheet(center: center, start: .directory, query: "Apple Calendar", onClose: { closed = true })
            .defaultAppStorage(store), size: sheetSize)
        XCTAssertTrue(host.hosting.pressButton(labeled: L10n.string("Connect")))
        await host.settle(until: { closed && center.connectors.first?.status == .connected })
        host.close()
        XCTAssertEqual(macData.prompts, [.calendars], "macOS asked once")
        XCTAssertEqual(center.connectors.map(\.localService), [.appleCalendar])

        await warmIcons(center.connectors)
        let size = NSSize(width: 680, height: 520)
        for appearance in WindowlessRender.Appearance.allCases {
            let settings = WindowlessRender.Host(page(ConnectorSettingsView(center: center), size: size, appearance: appearance,
                                                      defaults: store), size: size, appearance: appearance)
            settings.settle(passes: 12)
            try write(settings, "flow-calendar", appearance)
            settings.close()
        }
        expect(["Apple Calendar", L10n.string("On this Mac"), L10n.format("%lld tools", Int64(7)), L10n.string("Connected")],
               in: spoken(page(ConnectorSettingsView(center: center), size: size, appearance: .light, defaults: store), size: size),
               "calendar")
    }

    func testXcodeSaysWhatItNeedsWhenItsBridgeStops() async throws {
        let store = try defaults()
        let bridge = FakeStdioServer()
        bridge.exitOnStart = "error: Xcode MCP access is disabled; turn it on in Xcode Settings > Intelligence > Model Context Protocol, or run `sudo xcrun mcp-server enable`, then retry.\n"
        let center = center(bridge: bridge)
        var closed = false
        let host = offScreen(ConnectorAddSheet(center: center, start: .directory, query: "Xcode", onClose: { closed = true })
            .defaultAppStorage(store), size: NSSize(width: 580, height: 660))
        XCTAssertTrue(host.hosting.pressButton(labeled: L10n.string("Connect")))
        await host.settle(until: { closed && center.connectors.first.map { center.failures[$0.id] != nil } == true })
        host.close()
        await warmIcons(center.connectors)
        let size = NSSize(width: 680, height: 520)
        for appearance in WindowlessRender.Appearance.allCases {
            let settings = WindowlessRender.Host(page(ConnectorSettingsView(center: center), size: size, appearance: appearance,
                                                      defaults: store), size: size, appearance: appearance)
            settings.settle(passes: 12)
            try write(settings, "flow-xcode-error", appearance)
            settings.close()
        }
        expect(["Xcode", L10n.string("Error"), "Xcode MCP access is disabled", L10n.string("Try again")],
               in: spoken(page(ConnectorSettingsView(center: center), size: size, appearance: .light, defaults: store), size: size),
               "xcode error")
    }

    // MARK: - Settings with all of them

    func testSettingsListEveryAppleConnector() async throws {
        let store = try defaults()
        let macData = FakeMacData()
        macData.permissions = [.calendars: .granted, .reminders: .denied, .contacts: .granted]
        let apple = FakeAppStoreConnect()
        let center = center(apple: apple, macData: macData)
        for service in [LocalConnectorService.xcode, .appleCalendar, .appleReminders, .appleContacts] {
            let record = center.addLocal(service)
            center.connect(record.id)
            await center.waitForConnection(record.id)
        }
        let key = try await center.addAppStoreConnectKey(privateKey: apple.privateKey.pemRepresentation, keyID: "2X9R4HXF34",
                                                         issuerID: FakeAppStoreConnect.issuer)
        await center.waitForConnection(key.id)
        await warmIcons(center.connectors)
        let size = NSSize(width: 680, height: 760)
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(page(ConnectorSettingsView(center: center), size: size, appearance: appearance,
                                                  defaults: store), size: size, appearance: appearance)
            host.settle(passes: 12)
            try write(host, "settings-apple", appearance)
            host.close()
        }
        let text = spoken(page(ConnectorSettingsView(center: center), size: size, appearance: .light, defaults: store), size: size)
        expect(["Xcode", L10n.format("%@ · while it's open with a project", center.xcodeDescription ?? "Xcode"), "Apple Calendar",
                "Apple Contacts", "App Store Connect", L10n.format("Key %@", "2X9R4HXF34"), L10n.format("%lld tools", Int64(14)),
                "Apple Reminders", MacDataError.notAllowed(.reminders, .denied).localizedDescription], in: text, "settings")
    }

    // MARK: - Claude asks

    func testClaudeAsksBeforeASubmissionInYardletsWords() throws {
        let labels = ConnectorToolLabels()
        labels.update([ConnectorRecord(name: "App Store Connect", slug: "app_store_connect", serverURL: FakeAppStoreConnect.base,
                                       presetID: "app-store-connect", localService: .appStoreConnect, account: "2X9R4HXF34")])
        let input: JSONValue = .object(["versionId": .string("6741234567")])
        let text = try XCTUnwrap(GoogleToolApproval.request(toolName: "mcp__yardlet__app_store_connect_submit_for_review",
                                                            input: input, labels: labels))
        let request = PermissionRequest(id: "perm-asc", title: text.title, detail: text.detail, command: nil, toolCallID: "toolu_submit")
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        let entries = [
            TranscriptEntry(createdAt: start, content: .user(text: "Submit 1.2.0 for review")),
            TranscriptEntry(createdAt: start.addingTimeInterval(4),
                            content: .assistant(text: "I'll submit version 1.2.0 for App Review.", isStreaming: false)),
            TranscriptEntry(createdAt: start.addingTimeInterval(6), content: .activity(HarnessActivity(
                id: "toolu_submit", kind: "mcp__yardlet__app_store_connect_submit_for_review",
                title: "mcp__yardlet__app_store_connect_submit_for_review", input: input.readableText), state: .running)),
            TranscriptEntry(createdAt: start.addingTimeInterval(7), content: .permission(request, state: .pending))
        ]
        let directory = try WindowlessRender.directory(Self.folder)
        for appearance in WindowlessRender.Appearance.allCases {
            let drawing = try ConversationDrawing.draw(
                ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .waitingForApproval,
                                                         latestTurnIsComplete: false)),
                size: NSSize(width: 760, height: 460), appearance: appearance)
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "claude-request-asc-submit-\(appearance.suffix).png"))
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains(text.title), texts)
            XCTAssertTrue(texts.contains("6741234567"), texts)
        }
    }
}
