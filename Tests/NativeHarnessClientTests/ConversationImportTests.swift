import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Importing a conversation another app started: Claude's are read from the account's own
/// history folder and continue as a Yardlet task with the same session ID.
@MainActor final class ConversationImportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "conversation-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testFolderNamesFollowClaudesProjectNaming() {
        XCTAssertEqual(ClaudeConversationCatalog.projectFolderName(for: URL(filePath: "/Users/me/Desktop/workspace/yardlet/")),
            "-Users-me-Desktop-workspace-yardlet")
        XCTAssertEqual(ClaudeConversationCatalog.projectFolderName(for: URL(filePath: "/Users/me/w/app/.claude/worktrees/x")),
            "-Users-me-w-app--claude-worktrees-x")
        XCTAssertEqual(ClaudeConversationCatalog.projectFolderName(for: URL(filePath: "/tmp/한글 폴더")), "-tmp------")
    }

    func testListingNamesEachConversationAndMarksOnesStillRunning() throws {
        let workspace = URL(filePath: "/Users/me/project")
        let config = root.appending(path: "config")
        let named = "11111111-2222-4333-8444-555555555555"
        let plain = "22222222-2222-4333-8444-555555555555"
        try transcript(config, workspace, named, lines: [
            user("<command-name>/clear</command-name>"), user("Build the importer"),
            ["type": .string("custom-title"), "customTitle": .string("Old name")],
            ["type": .string("custom-title"), "customTitle": .string("Importer work")]])
        try transcript(config, workspace, plain, lines: [
            ["type": .string("user"), "isMeta": .bool(true), "message": .object(["content": .string("meta")])],
            user("Fix the sidebar\nwith details")], modified: Date(timeIntervalSinceNow: -3_600))
        try transcript(config, workspace, "33333333-2222-4333-8444-555555555555", lines: [
            ["type": .string("summary"), "summary": .string("nothing asked yet")]])
        try Data("not a session".utf8).write(to: config.appending(path: "projects/-Users-me-project/notes.jsonl"))
        try FileManager.default.createDirectory(at: config.appending(path: "sessions"), withIntermediateDirectories: true)
        try JSONEncoder().encode(JSONValue.object(["pid": .integer(Int64(getpid())), "sessionId": .string(named)]))
            .write(to: config.appending(path: "sessions/\(getpid()).json"))
        try JSONEncoder().encode(JSONValue.object(["pid": .integer(999_999), "sessionId": .string(plain)]))
            .write(to: config.appending(path: "sessions/999999.json"))

        let found = ClaudeConversationCatalog.conversations(in: workspace, configDirectory: config)
        XCTAssertEqual(found.map(\.providerSessionID), [named, plain], "Newest first; a transcript without a request is left out")
        XCTAssertEqual(found.map(\.title), ["Importer work", "Fix the sidebar"])
        XCTAssertEqual(found.map(\.isOpenElsewhere), [true, false], "Only a live process's session counts as running")
        XCTAssertTrue(found.allSatisfy { $0.workspaceURL == workspace && $0.harness == .claudeCode })
    }

    func testListingUsesClaudesGeneratedTitleBeforeTheFirstRequest() throws {
        let workspace = URL(filePath: "/Users/me/project")
        let config = root.appending(path: "config")
        let generated = "66666666-2222-4333-8444-555555555555"
        let renamed = "77777777-2222-4333-8444-555555555555"
        let aiTitle: [String: JSONValue] = ["type": .string("ai-title"), "aiTitle": .string("Fix the calculator tests")]
        try transcript(config, workspace, generated, lines: [aiTitle, user("Run test_calc.py and fix calc.py")])
        try transcript(config, workspace, renamed, lines: [
            user("Run test_calc.py and fix calc.py"),
            ["type": .string("custom-title"), "customTitle": .string("Calculator")], aiTitle
        ], modified: Date(timeIntervalSinceNow: -3_600))
        // A long last turn can push the generated title out of the tail that is read.
        let long = "88888888-2222-4333-8444-555555555555"
        try transcript(config, workspace, long, lines: [
            ["type": .string("ai-title"), "aiTitle": .string("Profile the importer")], user("Profile it")
        ] + Array(repeating: user(String(repeating: "x", count: 1_000)), count: 300),
            modified: Date(timeIntervalSinceNow: -7_200))

        let found = ClaudeConversationCatalog.conversations(in: workspace, configDirectory: config)
        XCTAssertEqual(found.map(\.title), ["Fix the calculator tests", "Calculator", "Profile the importer"])
    }

    /// Importing adds a detached task: no runtime starts until the person sends. One still open in
    /// another app comes in the same way.
    func testImportAddsTheSameSessionDetachedOnceAndTakesOneOpenElsewhere() async throws {
        let workspace = root.appending(path: "project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let config = root.appending(path: "config")
        let id = "44444444-2222-4333-8444-555555555555"
        try transcript(config, workspace, id, lines: [user("Continue me")])
        let cli = root.appending(path: "claude")
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let adapter = ResumeRecorder()
        let model = AppModel(store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(discoversRuntimes: false),
            registry: HarnessRegistry { _, _ in adapter }, restoresIndexOnLaunch: false)
        addTeardownBlock { await model.shutdown() }
        model.runtimeSelections.select(cli, for: .claudeCode)
        let account = ProviderConnection(id: "work", name: "work@example.test", harness: .claudeCode, providerID: nil,
            homePath: config.path, credentialSelector: nil)
        let conversation = try XCTUnwrap(ClaudeConversationCatalog.conversations(in: workspace, configDirectory: config).first)

        let result = await model.importConversation(conversation, connection: account)
        let imported = try XCTUnwrap(result)
        XCTAssertEqual(imported.providerSessionID, id)
        XCTAssertEqual(imported.connection, account)
        XCTAssertEqual(imported.title, "Continue me")
        XCTAssertEqual(model.store.selectedSessionID, imported.id)
        XCTAssertFalse(model.isAttached(imported.id), "Importing starts no runtime")
        let resumed = await adapter.resumed
        XCTAssertEqual(resumed, [])

        let again = await model.importConversation(conversation, connection: account)
        XCTAssertEqual(again?.id, imported.id, "An imported conversation opens its task instead of a second one")
        XCTAssertEqual(model.store.sessions.count, 1)

        let other = "55555555-2222-4333-8444-555555555555"
        try transcript(config, workspace, other, lines: [user("Still open")])
        try FileManager.default.createDirectory(at: config.appending(path: "sessions"), withIntermediateDirectories: true)
        try JSONEncoder().encode(JSONValue.object(["pid": .integer(Int64(getpid())), "sessionId": .string(other)]))
            .write(to: config.appending(path: "sessions/\(getpid()).json"))
        let running = try XCTUnwrap(ClaudeConversationCatalog.conversations(in: workspace, configDirectory: config)
            .first { $0.providerSessionID == other })
        XCTAssertTrue(running.isOpenElsewhere)
        let held = try unwrap(await model.importConversation(running, connection: account))
        XCTAssertEqual(held.providerSessionID, other)
        XCTAssertEqual(model.store.sessions.count, 2)
        XCTAssertNil(model.bootstrapError)
        XCTAssertTrue(model.isHeldElsewhere(held))
        XCTAssertFalse(model.isHeldElsewhere(imported))
        let stillResumed = await adapter.resumed
        XCTAssertEqual(stillResumed, [])
    }

    /// Opt-in: `NHC_CONVERSATION_IMPORT_LIVE=<folder>` lists that folder's real Claude conversations
    /// from `~/.claude` without writing anything.
    func testLiveListingReadsRealConversations() throws {
        guard let folder = ProcessInfo.processInfo.environment["NHC_CONVERSATION_IMPORT_LIVE"] else {
            throw XCTSkip("Set NHC_CONVERSATION_IMPORT_LIVE to a project folder")
        }
        let found = ClaudeConversationCatalog.conversations(in: URL(filePath: folder),
            configDirectory: URL(filePath: NSHomeDirectory()).appending(path: ".claude"))
        XCTAssertFalse(found.isEmpty)
        for item in found.prefix(8) {
            print("conversation", item.providerSessionID.prefix(8), item.isOpenElsewhere ? "running" : "idle", item.title)
        }
    }

    // MARK: - Codex in the same sheet (B18)

    /// Codex's list and search come from the account's App Server, filtered to the folder, without
    /// a thread, a turn or a task.
    func testCodexListAndSearchReadTheFoldersHistoryWithoutATurn() async throws {
        let fixture = try codexImport()
        let other = root.appending(path: "elsewhere")
        await fixture.transport.enqueue(method: "thread/list", result: .object([
            "data": .array([thread("t-1", "Fix the importer", in: fixture.workspace), thread("t-2", "Elsewhere", in: other),
                            thread("t-3", "", preview: "Profile the list", in: fixture.workspace)]),
            "nextCursor": .string("cursor-2")]))
        await fixture.transport.enqueue(method: "thread/search", result: .object([
            "data": .array([
                .object(["thread": thread("t-1", "Fix the importer", in: fixture.workspace), "snippet": .string("find the needle here")]),
                .object(["thread": thread("t-2", "Elsewhere", in: other), "snippet": .string("needle elsewhere")])]),
            "nextCursor": .null]))

        let recent = try await fixture.model.importableConversations(harness: .codex, workspaceURL: fixture.workspace,
                                                                     connection: fixture.account)
        XCTAssertEqual(recent.conversations.map(\.providerSessionID), ["t-1", "t-3"], "Only this folder's threads")
        XCTAssertEqual(recent.conversations.map(\.title), ["Fix the importer", "Profile the list"])
        XCTAssertEqual(recent.conversations.map(\.snippet), [nil, nil])
        XCTAssertEqual(recent.nextCursor, "cursor-2")
        XCTAssertTrue(recent.conversations.allSatisfy { $0.harness == .codex && !$0.isOpenElsewhere })

        let found = try await fixture.model.importableConversations(harness: .codex, workspaceURL: fixture.workspace,
                                                                    connection: fixture.account, searchTerm: "  needle ")
        XCTAssertEqual(found.conversations.map(\.providerSessionID), ["t-1"])
        XCTAssertEqual(found.conversations.first?.snippet, "find the needle here")
        XCTAssertNil(found.nextCursor)

        let requests = await fixture.transport.requests
        XCTAssertEqual(requests.first { $0.method == "thread/list" }?.params["cwd"]?.stringValue,
                       fixture.workspace.standardizedFileURL.path)
        XCTAssertEqual(requests.first { $0.method == "thread/search" }?.params["searchTerm"]?.stringValue, "needle")
        XCTAssertFalse(requests.contains { ["thread/start", "thread/resume", "turn/start", "thread/fork"].contains($0.method) })
        XCTAssertTrue(fixture.model.store.sessions.isEmpty)
        await fixture.model.shutdown()
    }

    /// A search result opens as a task that continues the same thread under the chosen account, in
    /// the native scope, at the match the provider names. Opening it again selects that task; opened
    /// without a search, it forgets the match. The account's folder is left as it was.
    func testOpeningASearchResultContinuesTheSameThreadAtTheMatch() async throws {
        let fixture = try codexImport()
        await fixture.transport.enqueue(method: "thread/searchOccurrences", result: .object([
            "data": .array([.object(["turnId": .string("turn-7"), "itemId": .string("item-3"),
                "snippet": .string("find the needle here"), "turnCursor": .string("turn-cursor-7"),
                "snippetMatchRange": .object(["start": .integer(9), "end": .integer(15)])])]),
            "nextCursor": .null]))
        let homeBefore = try FileManager.default.contentsOfDirectory(atPath: fixture.home.path)
        let conversation = ImportableConversation(codex: CodexThreadSummary(id: "t-1", title: "Fix the importer",
            preview: "Fix the importer", workspaceURL: fixture.workspace, updatedAt: Date(), forkedFromID: nil),
            snippet: "find the needle here")
        let selection = CodexHistorySearchSelection(query: "needle", snippet: conversation.snippet, threadID: "t-1")

        let opened = await fixture.model.importConversation(conversation, connection: fixture.account,
                                                            historySelection: selection)
        let imported = try XCTUnwrap(opened)
        XCTAssertEqual(imported.providerSessionID, "t-1")
        XCTAssertEqual(imported.environmentScope, .native)
        XCTAssertEqual(imported.connection, fixture.account)
        XCTAssertEqual(imported.titleOrigin, .provider)
        XCTAssertEqual(fixture.model.store.selectedSessionID, imported.id)
        XCTAssertFalse(fixture.model.isAttached(imported.id), "Importing starts no thread")
        let resolved = try XCTUnwrap(fixture.model.codexHistorySelectionBySessionID[imported.id])
        XCTAssertEqual(resolved.query, "needle")
        XCTAssertEqual(resolved.threadID, "t-1")
        XCTAssertEqual(resolved.turnID, "turn-7")
        XCTAssertEqual(resolved.itemID, "item-3")
        XCTAssertEqual(resolved.snippetMatchRange, CodexTextRange(start: 9, end: 15))
        let requests = await fixture.transport.requests
        XCTAssertEqual(requests.first { $0.method == "thread/searchOccurrences" }?.params["searchTerm"]?.stringValue,
                       "needle")
        XCTAssertFalse(requests.contains { ["thread/start", "thread/resume", "turn/start", "thread/fork"].contains($0.method) })

        XCTAssertEqual(fixture.model.existingTask(for: conversation, connection: fixture.account)?.id, imported.id)
        XCTAssertNil(fixture.model.existingTask(for: conversation, connection: nil),
                     "Another account's history is another conversation")
        let again = await fixture.model.importConversation(conversation, connection: fixture.account)
        XCTAssertEqual(again?.id, imported.id)
        XCTAssertEqual(fixture.model.store.sessions.count, 1)
        XCTAssertNil(fixture.model.codexHistorySelectionBySessionID[imported.id])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path), homeBefore,
                       "Nothing is copied into the account's folder")
        await fixture.model.shutdown()
    }

    /// The sheet's one import path refuses what it cannot continue without creating a task: a
    /// Codex conversation with no Codex runtime. A Claude conversation still open elsewhere (even
    /// opened from a list that had a search) is imported, not refused.
    func testTheImportPathRefusesWhatItCannotContinue() async throws {
        let workspace = root.appending(path: "project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let config = root.appending(path: "config")
        let running = "99999999-2222-4333-8444-555555555555"
        try transcript(config, workspace, running, lines: [user("Still open")])
        try FileManager.default.createDirectory(at: config.appending(path: "sessions"), withIntermediateDirectories: true)
        try JSONEncoder().encode(JSONValue.object(["pid": .integer(Int64(getpid())), "sessionId": .string(running)]))
            .write(to: config.appending(path: "sessions/\(getpid()).json"))
        let cli = root.appending(path: "claude")
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let adapter = ResumeRecorder()
        let model = AppModel(store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(discoversRuntimes: false),
            registry: HarnessRegistry { _, _ in adapter }, restoresIndexOnLaunch: false)
        addTeardownBlock { await model.shutdown() }
        model.runtimeSelections.select(cli, for: .claudeCode)
        let account = ProviderConnection(id: "work", name: "work@example.test", harness: .claudeCode, providerID: nil,
            homePath: config.path, credentialSelector: nil)
        let listed = try await model.importableConversations(harness: .claudeCode, workspaceURL: workspace,
                                                             connection: account, searchTerm: "ignored for Claude")
        let conversation = try XCTUnwrap(listed.conversations.first)
        XCTAssertTrue(conversation.isOpenElsewhere)

        let held = await model.importConversation(conversation, connection: account,
            historySelection: CodexHistorySearchSelection(query: "open", snippet: nil))
        XCTAssertNotNil(held)
        XCTAssertNil(model.bootstrapError)
        let resumed = await adapter.resumed
        XCTAssertEqual(resumed, [])

        let codex = ImportableConversation(codex: CodexThreadSummary(id: "t-9", title: "No runtime", preview: "",
            workspaceURL: workspace, updatedAt: Date(), forkedFromID: nil))
        let noRuntime = await model.importConversation(codex, connection: nil)
        XCTAssertNil(noRuntime)
        XCTAssertEqual(model.bootstrapError, L10n.format("%@ is not installed.", HarnessKind.codex.displayName))
        XCTAssertEqual(model.store.sessions.map(\.providerSessionID), [running])
        XCTAssertTrue(model.codexHistorySelectionBySessionID.isEmpty)
    }

    /// The import sheet drawn without a window into `.build/import-qa/`, light and dark: Codex's
    /// search with its matches marked and the already-imported row's "Open", and Claude's list with
    /// a conversation still running elsewhere.
    func testWindowlessImportSheetRenders() async throws {
        let directory = try WindowlessRender.directory("import-qa")
        let fixture = try codexImport()
        let model = fixture.model
        model.connections.usesFixtureSnapshots = true
        try model.connections.save(fixture.account)
        model.connections.selection[.codex] = fixture.account.id
        let now = Date()
        for _ in 0..<3 {
            await fixture.transport.enqueue(method: "thread/search", result: .object([
                "data": .array([
                    .object(["thread": thread("t-1", "Fix the importer", in: fixture.workspace, updatedAt: now.addingTimeInterval(-3_600)),
                             "snippet": .string("Read the needle from the account's own App Server")]),
                    .object(["thread": thread("t-4", "Search Codex history in one sheet", in: fixture.workspace,
                                              updatedAt: now.addingTimeInterval(-86_400 * 2)),
                             "snippet": .string("Keep the needle search where the import list is")])]),
                "nextCursor": .string("next")]))
        }
        _ = await model.importConversation(ImportableConversation(codex: CodexThreadSummary(id: "t-1",
            title: "Fix the importer", preview: "", workspaceURL: fixture.workspace, updatedAt: now, forkedFromID: nil)),
            connection: fixture.account)
        XCTAssertEqual(model.store.sessions.count, 1)
        let project = Project(name: "project", primaryRoot: fixture.workspace)

        // Claude's list under a saved account whose history has a conversation running elsewhere.
        let config = root.appending(path: "claude-config")
        try transcript(config, fixture.workspace, "aaaaaaaa-2222-4333-8444-555555555555", lines: [user("Polish the sidebar")],
                       modified: now.addingTimeInterval(-600))
        try transcript(config, fixture.workspace, "bbbbbbbb-2222-4333-8444-555555555555", lines: [user("Keep this one running")])
        try FileManager.default.createDirectory(at: config.appending(path: "sessions"), withIntermediateDirectories: true)
        try JSONEncoder().encode(JSONValue.object(["pid": .integer(Int64(getpid())),
                                                   "sessionId": .string("bbbbbbbb-2222-4333-8444-555555555555")]))
            .write(to: config.appending(path: "sessions/\(getpid()).json"))
        let claude = ProviderConnection(id: "claude-work", name: "claude@example.test", harness: .claudeCode, providerID: nil,
                                        homePath: config.path, credentialSelector: nil)
        try model.connections.save(claude)
        model.connections.selection[.claudeCode] = claude.id

        let sheets: [(String, HarnessKind, String?, String)] = [
            ("codex-search", .codex, "needle", "Search Codex history in one sheet"),
            ("claude", .claudeCode, nil, "Keep this one running")
        ]
        for (name, harness, search, lastRow) in sheets {
            for appearance in WindowlessRender.Appearance.allCases {
                let host = WindowlessRender.Host(ImportConversationSheet(model: model, projects: [project],
                    initialWorkspace: fixture.workspace, initialHarness: harness, initialSearchTerm: search, onDismiss: {})
                    .background(ParityTheme.canvas)
                    .environment(\.colorScheme, appearance.colorScheme),
                    size: NSSize(width: 660, height: 540), appearance: appearance)
                defer { host.close() }
                // The list loads in the sheet's own tasks, which run between the window's layout passes.
                let deadline = ContinuousClock.now + .seconds(20)
                var listed = false
                while !listed, ContinuousClock.now < deadline {
                    host.settle(passes: 2)
                    try await Task.sleep(for: .milliseconds(50))
                    listed = host.accessibilityElements().contains { $0.label.contains(lastRow) }
                }
                XCTAssertTrue(listed, "\(name) lists “\(lastRow)”")
                host.settle(passes: 6)
                let capture = try host.capture()
                XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 4, from: 4, background: (1, 1)), name)
                try WindowlessRender.writePNG(capture.bitmap, to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
            }
        }
        let searches = await fixture.transport.requests.filter { $0.method == "thread/search" }
        XCTAssertEqual(searches.map { $0.params["searchTerm"]?.stringValue }, ["needle", "needle"],
                       "The sheet opened on Codex's search runs it at once")
        XCTAssertEqual(model.store.sessions.count, 1, "Drawing the sheet imported nothing")

        // Choosing a conversation opens its task in the window, whichever sidebar section it showed.
        let imported = try XCTUnwrap(model.store.sessions.first)
        model.splits.showNewTask()
        let reveals = model.taskSurfaceRevealRequest
        var dismissed = false
        let host = WindowlessRender.Host(ImportConversationSheet(model: model, projects: [project],
            initialWorkspace: fixture.workspace, initialHarness: .codex, initialSearchTerm: "needle",
            onDismiss: { dismissed = true }), size: NSSize(width: 660, height: 540))
        defer { host.close() }
        try await waitUntil {
            host.settle(passes: 2)
            return host.hosting.pressAccessibilityElement { $0.contains("Fix the importer") }
        }
        try await waitUntil { dismissed }
        XCTAssertEqual(model.splits.selection, .session(imported.id))
        XCTAssertEqual(model.taskSurfaceRevealRequest, reveals + 1)
        await model.shutdown()
    }

    // MARK: - Fixtures

    /// An AppModel whose Codex runtime is a fake App Server, with a saved Codex account whose
    /// folder exists.
    private struct CodexImport {
        let transport: FakeCodexTransport
        let model: AppModel
        let account: ProviderConnection
        let workspace: URL
        let home: URL
    }

    private func codexImport() throws -> CodexImport {
        // The folder as a project root names it, which the App Server's `cwd` is compared with.
        let workspace = Project.canonical(root.appending(path: "project"))
        let home = root.appending(path: "codex-work")
        for folder in [workspace, home] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let executable = root.appending(path: "codex")
        try Data("#!/bin/sh\nprintf 'codex-cli 0.160.0\\n'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let resumed = JSONValue.object(["thread": .object(["id": .string("t-1"), "status": .object(["type": .string("idle")]),
            "historyMode": .string("paginated"), "turns": .array([])]), "model": .string("gpt-test"),
            "reasoningEffort": .string("high")])
        let empty = JSONValue.object(["data": .array([]), "nextCursor": .null])
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/resume": [resumed], "thread/read": Array(repeating: resumed, count: 6),
            "thread/items/list": Array(repeating: empty, count: 4), "thread/turns/list": Array(repeating: empty, count: 4),
            "model/list": [empty], "collaborationMode/list": Array(repeating: empty, count: 4)
        ])
        let adapter = CodexAdapter(executableURL: executable, transport: transport)
        let suite = testDefaultsSuite("NativeHarnessClientTests.ConversationImport")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, _ in adapter },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            restoresIndexOnLaunch: false)
        model.runtimeSelections.select(executable, for: .codex)
        let account = ProviderConnection(id: "codex-work", name: "work@example.test", harness: .codex, providerID: nil,
                                         homePath: home.path, credentialSelector: nil)
        return CodexImport(transport: transport, model: model, account: account, workspace: workspace, home: home)
    }

    /// A thread as the App Server lists it.
    private func thread(_ id: String, _ name: String, preview: String? = nil, in workspace: URL,
                        updatedAt: Date = Date(timeIntervalSince1970: 1_791_000_000)) -> JSONValue {
        .object(["id": .string(id), "name": name.isEmpty ? .null : .string(name), "preview": .string(preview ?? name),
                 "cwd": .string(workspace.standardizedFileURL.path),
                 "updatedAt": .integer(Int64(updatedAt.timeIntervalSince1970))])
    }

    private actor ResumeRecorder: HarnessAdapter {
        nonisolated let kind = HarnessKind.claudeCode
        private(set) var resumed: [String] = []
        func probeRuntime() async throws -> HarnessRuntimeDescriptor {
            HarnessRuntimeDescriptor(harness: kind, executableURL: URL(filePath: "/tmp/stub"), version: "stub",
                                     capabilities: .unavailable, fingerprint: "stub")
        }
        func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
            HarnessSessionHandle(harness: kind, localSessionID: request.localSessionID,
                                 providerSessionID: UUID().uuidString, workspaceURL: request.workspaceURL)
        }
        func resumeSession(providerSessionID: String, localSessionID: UUID, workspaceURL: URL) async throws -> HarnessSessionHandle {
            resumed.append(providerSessionID)
            return HarnessSessionHandle(harness: kind, localSessionID: localSessionID, providerSessionID: providerSessionID,
                                        workspaceURL: workspaceURL)
        }
        func send(_ prompt: String, to session: HarnessSessionHandle) async throws {}
        func interrupt(_ session: HarnessSessionHandle) async throws {}
        func respond(to permissionRequestID: String, decision: PermissionDecision, in session: HarnessSessionHandle) async throws {}
        func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> { AsyncStream { $0.finish() } }
        func close(_ session: HarnessSessionHandle) async {}
    }

    /// `XCTUnwrap` for a value an `await` produced (its autoclosure cannot await).
    private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    private func user(_ text: String) -> [String: JSONValue] {
        ["type": .string("user"), "isSidechain": .bool(false), "message": .object(["content": .string(text)])]
    }

    private func transcript(_ config: URL, _ workspace: URL, _ id: String, lines: [[String: JSONValue]],
                            modified: Date = Date()) throws {
        let folder = config.appending(path: "projects/\(ClaudeConversationCatalog.projectFolderName(for: workspace))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(id).jsonl")
        let data = try lines.reduce(into: Data()) { result, line in
            result.append(try JSONEncoder().encode(JSONValue.object(line))); result.append(10)
        }
        try data.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }
}
