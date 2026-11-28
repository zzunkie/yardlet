import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Renders Add connector with the MCP registries offscreen into `.build/connector-registry-qa/`,
/// light and dark, from recorded fixtures.
@MainActor
final class ConnectorRegistryRenderingTests: XCTestCase {
    private static let folder = "connector-registry-qa"
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func fixture(_ name: String, source: MCPRegistryEntry.Source) throws -> [MCPRegistryEntry] {
        let data = try Data(contentsOf: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name)"))
        return try XCTUnwrap(MCPRegistryFormat.page(data, source: source)).entries
    }

    private func center(homes: [NativeMCPHome] = []) -> ConnectorCenter {
        var environment = ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(), credentials: InMemoryConnectorCredentialStore(),
            http: ScriptedRegistry { _ in (500, Data()) }, userAgent: nil, sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9")
        environment.nativeHomes = { homes }
        return ConnectorCenter(environment: environment)
    }

    private func defaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("ConnectorRegistryQA")))
    }

    private func spoken<Content: View>(_ view: Content, size: NSSize) -> [String] {
        let host = WindowlessRender.Host(view, size: size)
        defer { host.close() }
        host.settle(passes: 12)
        return host.accessibilityElements().map { "\($0.label) \($0.value)" }
    }

    private func expect(_ texts: [String], in spoken: [String], _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        for text in texts {
            XCTAssertTrue(spoken.contains { $0.contains(text) }, "\(name) has no \(text): \(spoken)", file: file, line: line)
        }
    }

    func testTheAddSheetListsRegistryServersAndSearchesBothRegistries() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let github = try fixture("mcp-registry-github-page.json", source: .github)
        let official = try fixture("mcp-registry-official-search.json", source: .official)
        let store = try defaults()
        let sheetSize = NSSize(width: 580, height: 660)

        // Without a search: the sheet as the person scrolls to the registry list.
        let browsing = center()
        browsing.registry.show(github)
        let browse = ConnectorRegistrySection(center: browsing, query: "", onProgram: { _ in }, onAdded: {})
            .padding(20)
            .frame(width: 580, alignment: .topLeading)
        let listSize = NSSize(width: 580, height: 660)
        let captures = try WindowlessRender.hostedInBothAppearances("add-registry-browse", in: directory, size: listSize,
                                                                     passes: 12) { appearance in
            browse
                .frame(width: listSize.width, height: listSize.height, alignment: .topLeading)
                .background(ParityTheme.canvas)
                .defaultAppStorage(store)
                .environment(\.colorScheme, appearance.colorScheme)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        let listed = spoken(browse.frame(width: listSize.width, height: listSize.height, alignment: .topLeading), size: listSize)
        expect([L10n.string("From MCP registries"), "Omnara", "omnara.com", "Netdata", "Skyvern",
                L10n.format("API key in the %@ header", "x-api-key"), L10n.string("API key"), L10n.string("Connect")],
               in: listed, "browse")
        XCTAssertFalse(listed.contains { $0.contains("MarkItDown") || $0.contains("markitdown") }, "Programs show only in a search")

        // A search: the directory's Notion first, then both registries' matches.
        let searching = center()
        searching.registry.show(github, search: ("notion", MCPRegistryEntry.merged([official])))
        try WindowlessRender.hostedInBothAppearances("add-registry-search", in: directory, size: sheetSize, passes: 14) { appearance in
            ConnectorAddSheet(center: searching, start: .directory, query: "notion", onClose: {})
                .defaultAppStorage(store)
                .environment(\.colorScheme, appearance.colorScheme)
        }
        let found = spoken(ConnectorAddSheet(center: searching, start: .directory, query: "notion", onClose: {})
            .defaultAppStorage(store), size: NSSize(width: 580, height: 1_400))
        expect(["Notion", L10n.string("From MCP registries"), "Notion MCP by InsightfulPipe", L10n.string("Review…"),
                L10n.format("Runs on this Mac with %@ · %@", "npx", "@foreverworks/mcp-notion")], in: found, "search")
    }

    func testAProgramsPageShowsWhatRunsBeforeAnythingDoes() throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let github = try fixture("mcp-registry-github-page.json", source: .github)
        let terraform = try XCTUnwrap(github.first { $0.name == "io.github.hashicorp/terraform-mcp-server" })
        let draft = ConnectorProgramDraft.registry(terraform, package: try XCTUnwrap(terraform.package))
        let store = try defaults()
        let sheetSize = NSSize(width: 580, height: 660)
        let center = center()
        let captures = try WindowlessRender.hostedInBothAppearances("program-page", in: directory, size: sheetSize,
                                                                     passes: 12) { appearance in
            ConnectorAddSheet(center: center, start: .program(draft), onClose: {})
                .defaultAppStorage(store)
                .environment(\.colorScheme, appearance.colorScheme)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        let text = spoken(ConnectorAddSheet(center: center, start: .program(draft), onClose: {}).defaultAppStorage(store),
                          size: NSSize(width: 580, height: 1_000))
        expect([L10n.format("Run %@ on this Mac?", draft.name), L10n.format("From %@", terraform.name), L10n.string("What runs"),
                "docker run -i --rm -e TFE_ADDRESS", L10n.string("Values it needs"), "address", "token",
                L10n.string("Run on this Mac"), L10n.string("Cancel")], in: text, "program page")
        XCTAssertTrue(center.connectors.isEmpty, "Drawing the page adds nothing")
    }

    func testSettingsOfferProgramsFromOtherApps() async throws {
        let directory = try WindowlessRender.directory(Self.folder)
        let root = FileManager.default.temporaryDirectory.appending(path: "registry-qa-\(UUID().uuidString)")
        roots.append(root)
        let cursor = root.appending(path: ".cursor/mcp.json")
        let vscode = root.appending(path: "Code/User/mcp.json")
        for file in [cursor, vscode] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data(#"{"mcpServers": {"Notes": {"command": "npx", "args": ["-y", "@example/notes-mcp"], "env": {"NOTES_TOKEN": "fake"}}}}"#.utf8)
            .write(to: cursor)
        try Data("{\n // comment\n \"servers\": {\"fetch\": {\"type\": \"stdio\", \"command\": \"uvx\", \"args\": [\"mcp-server-fetch\"]},}\n}".utf8)
            .write(to: vscode)
        let center = center(homes: [NativeMCPHome(kind: .app(.cursor, file: cursor)), NativeMCPHome(kind: .app(.vscode, file: vscode))])
        await center.loadNativeInventory()
        XCTAssertEqual(center.importSuggestions.map(\.name), ["Notes", "fetch"])
        let store = try defaults()
        let size = NSSize(width: 680, height: 560)
        try WindowlessRender.hostedInBothAppearances("settings-import-programs", in: directory, size: size, passes: 12) { appearance in
            ConnectorSettingsView(center: center)
                .padding(20)
                .defaultAppStorage(store)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(ParityTheme.canvas)
        }
        let text = spoken(ConnectorSettingsView(center: center).padding(20).defaultAppStorage(store)
            .frame(width: size.width, height: size.height, alignment: .topLeading), size: size)
        expect([L10n.string("You use these elsewhere"), "Notes", "fetch", "Cursor", "VS Code", L10n.string("Review…")],
               in: text, "import")
    }
}
