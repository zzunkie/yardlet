import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletRemote
@testable import YardletRemoteFixtureSupport

extension RemoteHostWindowRenderingTests {
    func testRemainingConversationBodiesDrawFromTheSameHost() async throws {
        let folder = URL(filePath: "/tmp/remote-render/yardlet", directoryHint: .isDirectory)
        let session = SessionRecord(harness: .codex, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/codex"),
                                    title: "Check the migration", status: .running, providerSessionID: "body-thread")
        let picture = try Self.picture(color: .systemBlue, label: "Migration preview")
        let largeDiff = String(repeating: "x", count: CodexFileChangeCardProjection.fileByteLimit + 1)
        let wire = """
        {"id":"body-thread","turns":[{"id":"body-turn","status":"inProgress","items":[
          {"id":"u","type":"userMessage","content":[{"type":"text","text":"Check the migration and show the preview"}]},
          {"id":"reason","type":"reasoning","summary":["Checking the migration"],"content":["The new schema must preserve existing records and keep the index valid."]},
          {"id":"files","type":"fileChange","status":"completed","changes":[
            {"path":"Sources/Migration.swift","kind":{"type":"update"},"diff":"@@ -1 +1 @@\\n-let schema = 3\\n+let schema = 4"},
            {"path":"Tests/MigrationTests.swift","kind":{"type":"add"},"diff":"@@ -0,0 +1 @@\\n+assert(schema == 4)"},
            {"path":"Sources/Big.swift","kind":{"type":"update"},"diff":"\(largeDiff)"}]},
          {"id":"mcp","type":"mcpToolCall","server":"preview","tool":"screenshot","status":"completed","arguments":{},"result":{"content":[
            {"type":"text","text":"The migration preview preserves all records."},
            {"type":"image","mimeType":"image/png","data":"\(picture.base64EncodedString())"}]}},
          {"id":"cmd","type":"commandExecution","cwd":"/tmp/remote-render/yardlet","command":"swift test --filter MigrationTests","status":"inProgress","aggregatedOutput":"Building…\\nMigrationTests: 12 tests passed\\nChecking compatibility…"}
        ]}]}
        """
        var thread = try XCTUnwrap(CodexTaskDecoder().thread(from: JSONDecoder().decode(JSONValue.self, from: Data(wire.utf8))))
        let commandIndex = try XCTUnwrap(thread.turns[0].items.firstIndex { $0.id == "cmd" })
        thread.turns[0].items[commandIndex].lifecycle = .inProgress
        let state = CodexTaskState(thread: thread)
        let shell = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                                  title: "Check shell output", status: .completed)
        let entries = [TranscriptEntry(content: .user(text: ClaudeBashMessage.text(command: "swift --version", stdout: "Apple Swift version 6.3")))]
        let sessions = [session, shell]
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("RemoteBodiesRendering")))
        let host = AppModel(store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
                            runtimeSelections: RuntimeSelectionStore(defaults: defaults), initialTranscripts: [shell.id: entries],
                            initialCodexPresentation: [session.id: state], restoresIndexOnLaunch: false)
        let stack = try await LoopbackStack(name: "Host", bridge: AppModelRemoteBridge(model: host, makePreview: RemoteImagePreviewMaker.make))
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let link = try XCTUnwrap(RemoteSecurePairingURL(macKey: stack.identity.noise.publicKey, secret: ticket.secret,
                                                       name: "Host", hosts: ["127.0.0.1:\(stack.port)"]).url)
        let hosts = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                        hello: RemoteHandshakeHello(name: "Client", platform: "macos", appVersion: "test"))
        let paired = try await hosts.pair(link: link.absoluteString)
        defer { hosts.close(paired.id) }
        let model = try XCTUnwrap(hosts.model(for: paired.id))
        try await waitUntil { model.hasSnapshot && model.sendsFullConversation }
        model.select(.task(session.id.uuidString))
        let conversation = try XCTUnwrap(model.conversations[session.id.uuidString])
        try await waitUntil {
            conversation.presentation.turns.flatMap(\.work).contains { item in
                if case let .tool(tool) = item.kind { return tool.mcpResult?.imageBlockCount == 1 }
                return false
            }
        }
        let size = NSSize(width: 1280, height: 1000)
        let column = NSSize(width: size.width - ParityTheme.sidebarWidth - 21, height: size.height - ParityTheme.paneToolbarHeight)
        try await render("remote-bodies", size: size, model: model, hosts: hosts, opensDetails: true)
        try await render("local-bodies", size: column, titled: false) {
            ConversationTimeline(source: .codex(state, workspaceURL: folder, historySelection: nil))
                .environment(\.opensDetailsForReview, true)
                .background(ParityTheme.canvas)
        }
        // Draw each opened card from the same host and its loopback projection, so group folding cannot hide a body.
        let localItems = CodexConversationProjection.presentation(state, workspaceURL: folder, historySelection: nil).turns.flatMap(\.work)
        let remoteItems = conversation.presentation.turns.flatMap(\.work)
        for local in localItems {
            let name: String
            switch local.kind {
            case .command: name = "command"
            case .fileChange: name = "files"
            case .tool: name = "mcp"
            case .reasoning: name = "reasoning"
            default: continue
            }
            let remote = try XCTUnwrap(remoteItems.first { $0.id == "i:" + local.id })
            for (prefix, item) in [("local", local), ("remote", remote)] {
                let choices = ConversationDisclosureChoices()
                choices.record(item.id, isOpen: true)
                var openedPath: String?
                let press: ((String) -> Bool)? = name == "files" ? { $0 == L10n.string("Open in Changes") } : nil
                try await render("\(prefix)-body-\(name)", size: NSSize(width: 900, height: 650), titled: false, press: press) {
                    ConversationWorkLine(item: item, harness: .codex, workspaceURL: prefix == "local" ? folder : nil)
                        .environment(\.conversationDisclosureChoices, choices)
                        .environment(\.openTaskFileChanges, { openedPath = $0 })
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .environment(\.opensDetailsForReview, true)
                        .background(ParityTheme.canvas)
                }
                if name == "files" { XCTAssertEqual(openedPath, "Sources/Big.swift") }
            }
        }
        model.select(.task(shell.id.uuidString))
        let shellConversation = try XCTUnwrap(model.conversations[shell.id.uuidString])
        try await waitUntil { shellConversation.isLoaded }
        try await render("remote-shell-body", size: size, model: model, hosts: hosts, opensDetails: true)
        try await render("local-shell-body", size: column, titled: false) {
            ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .completed, latestTurnIsComplete: true))
                .environment(\.opensDetailsForReview, true)
                .background(ParityTheme.canvas)
        }
        await host.shutdown()
    }
}
