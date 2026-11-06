import CSQLite
import Foundation
import XCTest
@testable import NativeHarnessClient

/// Antigravity CLI's own conversation files as Yardlet reads them: the `/resume` index, the
/// per-folder last conversation, and each conversation's log. The fixtures have the keys, columns
/// and value types `agy` 1.4.0 wrote on this Mac (read 2026-10-16, names only) and made-up values.
@MainActor
final class AntigravityImportAndHistoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-antigravity-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let a = "0a000000-0000-4000-8000-00000000000a"
    private static let b = "0b000000-0000-4000-8000-00000000000b"
    private static let c = "0c000000-0000-4000-8000-00000000000c"
    private static let d = "0d000000-0000-4000-8000-00000000000d"
    private static let e = "0e000000-0000-4000-8000-00000000000e"
    private static let f = "0f000000-0000-4000-8000-00000000000f"
    private static let g = "01000000-0000-4000-8000-000000000001"

    // MARK: - The index

    /// What the CLI can continue by ID is offered: its own conversations (not the desktop app's,
    /// which it copies before continuing), not subagents', with steps and a folder — from the row
    /// or, for a row the CLI kept without one, from `last_conversations.json`.
    func testTheIndexOffersWhatTheCLICanContinue() throws {
        let fixture = try makeStore()
        let listed = try fixture.store.conversations()
        XCTAssertEqual(listed.map(\.providerSessionID), [Self.e, Self.a, Self.b])
        let first = try XCTUnwrap(listed.first { $0.providerSessionID == Self.a })
        XCTAssertEqual(first.harness, .antigravityCLI)
        XCTAssertEqual(first.title, "Fixture conversation title")
        XCTAssertEqual(first.workspaceURL, fixture.project)
        XCTAssertNil(first.parentProviderSessionID)
        XCTAssertFalse(first.isOpenElsewhere)
        XCTAssertEqual(first.updatedAt, AntigravityConversationStore.date("2026-10-16 05:41:41.331209+00:00"))
        // No title: the preview's first line.
        XCTAssertEqual(listed.first { $0.providerSessionID == Self.b }?.title, "Fixture preview line")
        XCTAssertEqual(listed.first { $0.providerSessionID == Self.b }?.workspaceURL, fixture.otherProject)
        // A conversation the CLI started from another names it.
        XCTAssertEqual(listed.first { $0.providerSessionID == Self.e }?.parentProviderSessionID, Self.a)

        XCTAssertEqual(try fixture.store.conversations(in: fixture.project).map(\.providerSessionID), [Self.e, Self.a])
        XCTAssertEqual(try fixture.store.conversations(in: fixture.otherProject).map(\.providerSessionID), [Self.b])
        XCTAssertEqual(fixture.store.title(conversationID: Self.a), "Fixture conversation title")
        XCTAssertNil(fixture.store.title(conversationID: Self.b))
    }

    /// The index is read from a private copy: Antigravity's folder gets no new file (no `-wal`,
    /// no `-shm`) and keeps every byte and time.
    func testReadingTheIndexWritesNothingInAntigravitysFolder() throws {
        let fixture = try makeStore()
        let before = try listing(fixture.store.root)
        _ = try fixture.store.conversations()
        _ = try fixture.store.readTranscript(conversationID: Self.a)
        _ = fixture.store.title(conversationID: Self.a)
        XCTAssertEqual(try listing(fixture.store.root), before)
    }

    func testAMissingOrForeignIndexListsNothing() throws {
        let store = AntigravityConversationStore(root: root.appending(path: "absent"))
        XCTAssertEqual(try store.conversations(), [])
        XCTAssertNil(store.transcriptURL(conversationID: "../escape"))
    }

    /// The removed `--add-dir` folder a development run may have left goes at launch; the rest of
    /// Yardlet's caches stay, and a launch with nothing left behind does nothing.
    func testLaunchRemovesTheLeftoverAddDirFolderOnly() throws {
        let caches = root.appending(path: "Caches", directoryHint: .isDirectory)
        let leftover = AntigravityLeftoverFolder.url(cachesDirectory: caches)
        let agents = leftover.appending(path: "\(Self.a)/.agents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: agents.appending(path: "hooks.json"))
        let sibling = caches.appending(path: "\(YardletProduct.bundleIdentifier)/Cache.db")
        try Data("keep".utf8).write(to: sibling)

        XCTAssertEqual(leftover.lastPathComponent, "antigravity")
        XCTAssertTrue(AntigravityLeftoverFolder.removeIfPresent(cachesDirectory: caches))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path(percentEncoded: false)))
        XCTAssertEqual(try Data(contentsOf: sibling), Data("keep".utf8))
        XCTAssertFalse(AntigravityLeftoverFolder.removeIfPresent(cachesDirectory: caches))
        XCTAssertFalse(AntigravityLeftoverFolder.removeIfPresent(cachesDirectory: nil))
    }

    /// Only the copies `agy` names `yardlet_<hex>` go, and only once no running `agy` can have written
    /// them: `mcp/yardlet/`, other servers' folders, other names and a copy with a file written since
    /// stay, and nothing goes while the process table does not list Yardlet itself.
    func testSchemaCopiesGoOnlyOnceNoRunningAgyCanHaveWrittenThem() throws {
        let mcp = root.appending(path: "mcp", directoryHint: .isDirectory)
        let now = Date()
        let old = now.addingTimeInterval(-3_600)
        func copy(_ name: String, written: Date, rewritten: Date? = nil) throws {
            let folder = mcp.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (file, date) in [("list_tasks.json", written), ("instructions.md", rewritten ?? written)] {
                try Data("{}".utf8).write(to: folder.appending(path: file))
                try FileManager.default.setAttributes([.modificationDate: date],
                                                      ofItemAtPath: folder.appending(path: file).path(percentEncoded: false))
            }
            try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: folder.path(percentEncoded: false))
        }
        let unused = ["yardlet_963b6c4b", "yardlet_0123456789abcdef", "yardlet_" + String(repeating: "a", count: 64)]
        let kept = ["yardlet", "github_963b6c4b", "yardlet_963b6c4g", "yardlet_963b6c4", "yardletprobe_probeplugin"]
        for name in unused + kept { try copy(name, written: old) }
        try copy("yardlet_8f50b571", written: old, rewritten: now)
        try copy("yardlet_921068d5", written: now)
        func listing() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: mcp.path(percentEncoded: false)))
        }
        func microseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000_000) }

        let table = FakeProcessTable()
        let own = ProcessInfo.processInfo.processIdentifier
        let agy = own &+ 1
        table.set(agy, parent: 1, start: microseconds(now.addingTimeInterval(-60)), name: "agy")
        let copies = AntigravitySchemaCopies(directory: mcp, table: table, executableNames: ["agy"])
        XCTAssertEqual(copies.removeUnused(), [])

        table.set(own, parent: 1, start: microseconds(old.addingTimeInterval(-60)), name: "Yardlet")
        XCTAssertEqual(copies.removeUnused(), unused.sorted())
        XCTAssertEqual(try listing(), Set(kept + ["yardlet_8f50b571", "yardlet_921068d5"]))

        // A process of the executable Yardlet runs counts as `agy` too; with none running, every copy goes.
        table.remove(agy)
        table.set(agy &+ 1, parent: 1, start: microseconds(old.addingTimeInterval(-60)), name: "agy-nightly")
        XCTAssertEqual(copies.counting(URL(filePath: "/opt/bin/agy-nightly")).removeUnused(), [])
        XCTAssertEqual(copies.removeUnused(), ["yardlet_8f50b571", "yardlet_921068d5"])
        XCTAssertEqual(try listing(), Set(kept))
    }

    // MARK: - The log

    /// The log's records as the conversation: the request inside `<USER_REQUEST>` (not the CLI's
    /// metadata), thinking, each tool call with its command, the failed step after it, and the
    /// answer; the CLI's system messages are not shown. A second read gives the same IDs.
    func testTheLogBecomesTheConversation() throws {
        let fixture = try makeStore()
        let read = try fixture.store.readTranscript(conversationID: Self.a)
        let contents = read.entries.map(\.content)
        XCTAssertEqual(read.requestCount, 2)
        XCTAssertEqual(contents.first, .user(text: "Fixture request one"))
        XCTAssertTrue(contents.contains(.reasoning(text: "Fixture thinking", isStreaming: false)))
        let tools = read.entries.compactMap { entry -> (HarnessActivity, TranscriptActivityState)? in
            guard case let .activity(activity, state) = entry.content else { return nil }
            return (activity, state)
        }
        XCTAssertEqual(tools.map(\.0.kind), ["list_dir", "run_command"])
        XCTAssertEqual(tools[0].1, .completed)
        XCTAssertEqual(tools[1].0.input, "echo fixture")
        XCTAssertEqual(tools[1].0.detail, "Fixture summary")
        XCTAssertEqual(tools[1].1, .failed)
        XCTAssertEqual(tools[1].0.output, "fixture tool error")
        XCTAssertTrue(contents.contains(.assistant(text: "Fixture answer", isStreaming: false)))
        XCTAssertTrue(contents.contains(.user(text: "Fixture request two")))
        XCTAssertFalse(contents.contains { if case let .user(text, _) = $0 { text.contains("ADDITIONAL_METADATA") || text.contains("local time") } else { false } })
        XCTAssertFalse(contents.contains { if case let .assistant(text, _) = $0 { text.contains("SYSTEM_MESSAGE") } else { false } })
        XCTAssertEqual(try fixture.store.readTranscript(conversationID: Self.a).entries.map(\.id), read.entries.map(\.id))
        // The untruncated log is preferred to the cut one.
        XCTAssertEqual(fixture.store.transcriptURL(conversationID: Self.a)?.lastPathComponent, "transcript_full.jsonl")
    }

    // MARK: - Import, open and follow

    /// Importing adds a detached task with the conversation's ID and the native scope, and starts
    /// nothing; opening it reads the log; another client's writes are followed while it is shown.
    func testImportingAddsADetachedTaskAndOpeningAndFollowingReadTheLog() async throws {
        let fixture = try makeStore()
        let app = try makeModel(store: fixture.store)
        let listed = try await app.model.importableConversations(
            harness: .antigravityCLI, workspaceURL: fixture.project, connection: nil)
        XCTAssertEqual(listed.conversations.map(\.providerSessionID), [Self.e, Self.a])
        let conversation = try XCTUnwrap(listed.conversations.first { $0.providerSessionID == Self.a })
        let imported = await app.model.importConversation(conversation, connection: nil)
        let task = try XCTUnwrap(imported)
        XCTAssertEqual(task.harness, .antigravityCLI)
        XCTAssertEqual(task.providerSessionID, Self.a)
        XCTAssertEqual(task.environmentScope, .native)
        XCTAssertNil(task.connection)
        XCTAssertEqual(task.workspaceURL, fixture.project)
        XCTAssertFalse(app.model.isAttached(task.id))
        // Importing again opens the same task.
        let reimported = await app.model.importConversation(conversation, connection: nil)
        let again = try XCTUnwrap(reimported)
        XCTAssertEqual(again.id, task.id)

        await app.model.refreshConversationStatus(for: task)
        let shown = app.model.transcriptBySessionID[task.id] ?? []
        XCTAssertEqual(shown.first?.content, .user(text: "Fixture request one"))
        XCTAssertTrue(shown.contains { $0.content == .assistant(text: "Fixture answer", isStreaming: false) })
        let calls = await app.recorder.calls
        XCTAssertEqual(calls, [], "Importing and reading started no Antigravity process")

        app.model.detachedFollowInterval = .milliseconds(40)
        let follower = Task { await app.model.followDetachedConversation(for: task) }
        defer { follower.cancel() }
        try await Task.sleep(for: .milliseconds(120))
        try append(fixture.log, [
            Self.record(index: 9, type: "USER_INPUT", source: "USER_EXPLICIT",
                        content: "<USER_REQUEST>\nFixture request three\n</USER_REQUEST>"),
            Self.record(index: 10, type: "PLANNER_RESPONSE", source: "MODEL", content: "Fixture answer three")
        ])
        try await waitUntil {
            (app.model.transcriptBySessionID[task.id] ?? []).contains { $0.content == .assistant(text: "Fixture answer three", isStreaming: false) }
        }
        let after = await app.recorder.calls
        XCTAssertEqual(after, [])
    }

    /// A conversation the CLI started from another one, imported after it, sits under its task.
    func testAnImportedConversationIsNestedUnderTheOneItCameFrom() async throws {
        let fixture = try makeStore()
        let app = try makeModel(store: fixture.store)
        let listed = try await app.model.importableConversations(
            harness: .antigravityCLI, workspaceURL: fixture.project, connection: nil).conversations
        let parentConversation = try XCTUnwrap(listed.first { $0.providerSessionID == Self.a })
        let childConversation = try XCTUnwrap(listed.first { $0.providerSessionID == Self.e })
        let importedParent = await app.model.importConversation(parentConversation, connection: nil)
        let importedChild = await app.model.importConversation(childConversation, connection: nil)
        let parent = try XCTUnwrap(importedParent)
        let child = try XCTUnwrap(importedChild)
        XCTAssertEqual(app.model.store.sessions.first { $0.id == child.id }?.parentTaskID, parent.id)
    }

    /// Yardlet's own cache has the tool output the log lacks, so it stays while the log has no
    /// more requests; once the conversation goes on elsewhere, the log replaces it.
    func testYardletsOwnConversationStaysUntilTheLogHasMore() async throws {
        let fixture = try makeStore()
        let cached = [
            TranscriptEntry(content: .user(text: "Fixture request one")),
            TranscriptEntry(content: .activity(HarnessActivity(id: "cached", kind: "run_command", title: "run command",
                                                               output: "cached output"), state: .completed)),
            TranscriptEntry(content: .user(text: "Fixture request two")),
            TranscriptEntry(content: .assistant(text: "Cached answer", isStreaming: false))
        ]
        let task = SessionRecord(harness: .antigravityCLI, workspaceURL: fixture.project,
                                 runtimeExecutableURL: root.appending(path: "agy"), title: "Cached",
                                 titleOrigin: .provider, providerSessionID: Self.a)
        let app = try makeModel(store: fixture.store, sessions: [task], transcripts: [task.id: cached])

        await app.model.refreshConversationStatus(for: task)
        XCTAssertEqual(app.model.transcriptBySessionID[task.id]?.map(\.content), cached.map(\.content))

        try append(fixture.log, [Self.record(index: 9, type: "USER_INPUT", source: "USER_EXPLICIT",
                                             content: "<USER_REQUEST>\nFixture request three\n</USER_REQUEST>")])
        await app.model.refreshConversationStatus(for: task)
        XCTAssertEqual(app.model.transcriptBySessionID[task.id]?.last?.content, .user(text: "Fixture request three"))
    }

    /// The bulk sheet lists Antigravity's conversations beside the Claude and Codex apps'.
    func testTheOtherAppsListHasAntigravitysConversations() async throws {
        let fixture = try makeStore()
        let app = try makeModel(store: fixture.store)
        let listing = await app.model.otherAppConversations(claudeConnection: nil)
        XCTAssertEqual(listing.antigravity.map(\.providerSessionID), [Self.e, Self.a, Self.b])
        XCTAssertNil(listing.antigravityError)
        XCTAssertTrue(listing.all.contains { $0.providerSessionID == Self.b })
        XCTAssertEqual(L10n.string("Conversations from the Claude and Codex apps, Claude Code and Codex run elsewhere, and Antigravity CLI. Their history stays where it is.",
                                   languageCode: "ko"),
                       "Claude 앱과 Codex 앱, 그 밖에서 실행한 Claude Code·Codex, Antigravity CLI의 대화입니다. 기록은 원래 자리에 그대로 둡니다.")
    }

    /// The task's title is the one the CLI generated, read from the index.
    func testTheTaskTitleIsTheOneTheCLIGenerated() throws {
        let fixture = try makeStore()
        let session = SessionRecord(harness: .antigravityCLI, workspaceURL: fixture.project,
                                    runtimeExecutableURL: URL(filePath: "/tmp/agy"), title: "Local", providerSessionID: Self.a)
        let paths = ProviderSessionTitlePaths(grokSessionsRoot: root, claudeProjectsRoot: root,
                                              openCodeDatabaseURL: root.appending(path: "none.db"),
                                              kimiSessionsRoot: root, antigravityRoot: fixture.store.root)
        XCTAssertEqual(ProviderSessionTitleResolver.title(for: session, paths: paths), "Fixture conversation title")
        // Before its first prompt a task has only its stand-in ID and no conversation.
        let freshID = UUID()
        let fresh = SessionRecord(id: freshID, harness: .antigravityCLI, workspaceURL: fixture.project,
                                  runtimeExecutableURL: URL(filePath: "/tmp/agy"), title: "Local",
                                  providerSessionID: freshID.uuidString.lowercased())
        XCTAssertNil(ProviderSessionTitleResolver.title(for: fresh, paths: paths))
    }

    /// The new-task screen's list is read through the runtime's own listing commands — no prompt —
    /// and kept folded; a detached task's menu names its saved choice until it attaches.
    func testTheNewTaskListIsReadWithoutAPromptAndDetachedTasksNameTheirChoice() async throws {
        let fixture = try makeStore()
        let runtime = root.appending(path: "agy-lists")
        let log = runtime.appendingPathExtension("log")
        try Data("""
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(log.path(percentEncoded: false))"
            case "$1" in
              --version) printf '%s\\n' '1.4.0'; exit 0 ;;
              models) printf '%s\\t%s\\n' 'fixture-flash-high' 'Fixture Flash (High)' 'fixture-flash-low' 'Fixture Flash (Low)' 'fixture-pro' 'Fixture Pro'; exit 0 ;;
              agents) exit 0 ;;
            esac
            printf '%s\\n' '{"event":"result","result":{"conversation_id":"","status":"SUCCESS","response":""}}'
            """.utf8).write(to: runtime)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
        let suite = testDefaultsSuite("NativeHarnessClientTests.AntigravityLists")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let task = SessionRecord(harness: .antigravityCLI, workspaceURL: fixture.project, runtimeExecutableURL: runtime,
                                 title: "Saved choice", providerSessionID: Self.a,
                                 providerOptions: ["model": "fixture-flash", "reasoningEffort": "low", "permissionMode": "bypass"])
        let model = AppModel(store: SessionStore(sessions: [task], repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry(),
            modelCatalogs: HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
                claudeConfigDirectory: root.appending(path: "claude"), codexHome: root.appending(path: "codex-home"),
                codexYardletHome: root.appending(path: "codex-yardlet")), environment: [:]),
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
            preferences: defaults,
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            sessionTitleResolver: { _ in nil },
            restoresIndexOnLaunch: false)
        addTeardownBlock { await model.shutdown() }

        await model.loadNewTaskModels(harness: .antigravityCLI, runtimeURL: runtime, connection: nil,
                                      workspaceURL: fixture.project)
        XCTAssertEqual(model.modelCatalogs.antigravity, [
            HarnessModelOption(value: "fixture-flash", name: "Fixture Flash", effortLevels: ["low", "high"]),
            HarnessModelOption(value: "fixture-pro", name: "Fixture Pro")
        ])
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertFalse(lines.contains { $0.hasPrefix("--print") && !$0.hasPrefix("--print /model") },
                       "Only the CLI's own listing commands ran: \(lines)")

        let detached = try XCTUnwrap(model.composerProviderCapabilities(for: task))
        XCTAssertEqual(detached.selectors.first { $0.id == "model" }?.currentValue, "fixture-flash")
        XCTAssertEqual(detached.selectors.first { $0.id == "reasoningEffort" }?.currentValue, "low")
        let options = ComposerSessionOptionsProjection.make(harness: .antigravityCLI, session: task,
            providerCapabilities: detached, providerUsage: nil, isAttached: false)
        XCTAssertEqual(options.permission?.title, L10n.string("Bypass permissions"))
        XCTAssertEqual(options.permission?.isElevated, true)
        XCTAssertEqual(options.model?.menu.canChoose, false)
    }

    // MARK: - Fixtures

    private struct StoreFixture {
        let store: AntigravityConversationStore
        let project: URL
        let otherProject: URL
        let log: URL
    }

    /// `agy`'s data folder with the index's real table, its last-conversation cache and one log.
    private func makeStore() throws -> StoreFixture {
        let cli = root.appending(path: "antigravity-cli", directoryHint: .isDirectory)
        let project = root.appending(path: "project", directoryHint: .isDirectory).standardizedFileURL
        let otherProject = root.appending(path: "other", directoryHint: .isDirectory).standardizedFileURL
        for folder in [cli.appending(path: "cache"), project, otherProject] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let uri = #"["\#(project.absoluteString)"]"#
        try writeIndex(cli.appending(path: "conversation_summaries.db"), rows: [
            // conversation_id, title, preview, step_count, last_modified_time, workspace_uris,
            // parent_conversation_id, nesting_depth, app_data_dir
            (Self.a, "Fixture conversation title", "Fixture preview", 10, "2026-10-16 05:41:41.331209+00:00", uri, "", 0, "antigravity-cli"),
            (Self.b, "", "Fixture preview line\nsecond line", 5, "2026-09-02 09:52:23.66662+00:00", "", "", 0, "antigravity-cli"),
            (Self.c, "", "App preview", 238, "2025-12-30 09:47:12.564415+00:00", uri, "", 0, "antigravity"),
            (Self.d, "Subagent", "Subagent preview", 3, "2026-10-16 05:42:00.000000+00:00", uri, Self.a, 1, "antigravity-cli"),
            (Self.e, "Fixture follow-up", "Follow-up preview", 4, "2026-10-16 06:00:00.000000+00:00", uri, Self.a, 0, "antigravity-cli"),
            (Self.f, "Empty", "", 0, "2026-10-16 06:10:00.000000+00:00", uri, "", 0, "antigravity-cli"),
            (Self.g, "No folder", "No folder", 2, "2026-09-01 00:00:00.000000+00:00", "", "", 0, "antigravity-cli")
        ])
        try JSONSerialization.data(withJSONObject: [otherProject.path(percentEncoded: false): Self.b])
            .write(to: cli.appending(path: "cache/last_conversations.json"))
        let logs = cli.appending(path: "brain/\(Self.a)/.system_generated/logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appending(path: "transcript_full.jsonl")
        try Data().write(to: logs.appending(path: "transcript.jsonl"))
        try Data().write(to: log)
        try append(log, [
            Self.record(index: 0, type: "USER_INPUT", source: "USER_EXPLICIT", content: """
                <USER_REQUEST>
                Fixture request one
                </USER_REQUEST>
                <ADDITIONAL_METADATA>
                The current local time is: 2026-10-16T14:37:00+09:00.
                </ADDITIONAL_METADATA>
                <USER_SETTINGS_CHANGE>
                The user changed setting `Model Selection` from None to fixture.
                </USER_SETTINGS_CHANGE>
                """),
            Self.record(index: 1, type: "PLANNER_RESPONSE", source: "MODEL", thinking: "Fixture thinking", toolCalls: [
                ["name": .string("list_dir"), "args": .object(["DirectoryPath": .string("/tmp/fixture"),
                    "toolAction": .string("Listing"), "toolSummary": .string("Listing fixture")])],
                ["name": .string("run_command"), "args": .object(["CommandLine": .string("echo fixture"),
                    "Cwd": .string("/tmp/fixture"), "WaitMsBeforeAsync": .string("1000"),
                    "toolAction": .string("Running"), "toolSummary": .string("Fixture summary")])]
            ], usage: true),
            // Step 2 was `list_dir`'s result, which succeeded and is not logged; step 3 is the second call's.
            Self.record(index: 3, type: "GENERIC", source: "MODEL", status: "ERROR", content: "fixture step content",
                        error: "fixture tool error"),
            Self.record(index: 4, type: "SYSTEM_MESSAGE", source: "SYSTEM", content: "<SYSTEM_MESSAGE>fixture</SYSTEM_MESSAGE>"),
            Self.record(index: 5, type: "PLANNER_RESPONSE", source: "MODEL", content: "Fixture answer"),
            Self.record(index: 6, type: "USER_INPUT", source: "USER_EXPLICIT",
                        content: "<USER_REQUEST>\nFixture request two\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nfixture\n</ADDITIONAL_METADATA>")
        ])
        return StoreFixture(store: AntigravityConversationStore(root: cli), project: project,
                            otherProject: otherProject, log: log)
    }

    private static func record(index: Int, type: String, source: String, status: String = "DONE",
                               content: String? = nil, thinking: String? = nil,
                               toolCalls: [[String: JSONValue]] = [], error: String? = nil,
                               usage: Bool = false) -> JSONValue {
        var value: [String: JSONValue] = [
            "step_index": .integer(Int64(index)), "type": .string(type), "source": .string(source),
            "status": .string(status), "created_at": .string("2026-10-16T05:37:0\(index % 10)Z")
        ]
        if let content { value["content"] = .string(content) }
        if let thinking { value["thinking"] = .string(thinking) }
        if !toolCalls.isEmpty { value["tool_calls"] = .array(toolCalls.map(JSONValue.object)) }
        if let error { value["error"] = .string(error) }
        if usage {
            value["input_tokens"] = .integer(100)
            value["output_tokens"] = .integer(5)
            value["cache_read_tokens"] = .integer(0)
        }
        return .object(value)
    }

    private func append(_ log: URL, _ records: [JSONValue]) throws {
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for record in records {
            try handle.write(contentsOf: try JSONEncoder().encode(record) + Data([0x0A]))
        }
    }

    /// The index with the table `agy` 1.4.0 creates (its CREATE statement, verbatim).
    private func writeIndex(
        _ url: URL,
        rows: [(String, String, String, Int, String, String, String, Int, String)]
    ) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path(percentEncoded: false), &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let schema = """
            CREATE TABLE `conversation_summaries` (`conversation_id` text,`title` text NOT NULL DEFAULT "",`preview` text NOT NULL DEFAULT "",`step_count` integer NOT NULL DEFAULT 0,`last_modified_time` datetime NOT NULL,`workspace_uris` text NOT NULL,`status` text NOT NULL DEFAULT "",`source` text NOT NULL DEFAULT "",`project_id` text NOT NULL DEFAULT "",`agent_name` text NOT NULL DEFAULT "",`parent_conversation_id` text NOT NULL DEFAULT "",`nesting_depth` integer NOT NULL DEFAULT 0,`battle_id` text NOT NULL DEFAULT "",`winning_conversation_id` text NOT NULL DEFAULT "",`not_fully_idle` numeric NOT NULL DEFAULT false,`killed` numeric NOT NULL DEFAULT false,`last_user_input_time` datetime NOT NULL,`last_user_input_step_index` integer NOT NULL DEFAULT -1,`app_data_dir` text NOT NULL DEFAULT "", raw_summary BLOB, group_id TEXT NOT NULL DEFAULT '',PRIMARY KEY (`conversation_id`));
            CREATE INDEX `idx_conversation_summaries_last_user_input_time` ON `conversation_summaries`(`last_user_input_time`);
            CREATE INDEX `idx_conversation_summaries_last_modified_time` ON `conversation_summaries`(`last_modified_time`);
            """
        XCTAssertEqual(sqlite3_exec(handle, schema, nil, nil, nil), SQLITE_OK)
        for row in rows {
            var statement: OpaquePointer?
            let insert = """
                INSERT INTO conversation_summaries (conversation_id, title, preview, step_count, last_modified_time,
                    workspace_uris, status, project_id, parent_conversation_id, nesting_depth, last_user_input_time,
                    app_data_dir, raw_summary)
                VALUES (?, ?, ?, ?, ?, ?, 'CASCADE_RUN_STATUS_IDLE', 'default-cli-project', ?, ?, ?, ?, x'0a00')
                """
            XCTAssertEqual(sqlite3_prepare_v2(handle, insert, -1, &statement, nil), SQLITE_OK)
            let texts: [(Int32, String)] = [(1, row.0), (2, row.1), (3, row.2), (5, row.4), (6, row.5), (7, row.6),
                                            (9, row.4), (10, row.8)]
            for (index, text) in texts { sqlite3_bind_text(statement, index, text, -1, antigravityTestTransient) }
            sqlite3_bind_int64(statement, 4, Int64(row.3))
            sqlite3_bind_int64(statement, 8, Int64(row.7))
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        // `agy` keeps its index in WAL mode.
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil), SQLITE_OK)
    }

    private func listing(_ folder: URL) throws -> [String: String] {
        var files: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
            let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            files[url.path(percentEncoded: false)] = "\(size)|\(modified)"
        }
        return files
    }

    private struct ModelFixture {
        let model: AppModel
        let recorder: AntigravityRecorder
        let runtime: URL
    }

    private func makeModel(store: AntigravityConversationStore, sessions: [SessionRecord] = [],
                           transcripts: [UUID: [TranscriptEntry]] = [:]) throws -> ModelFixture {
        let runtime = root.appending(path: "agy")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: runtime)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
        let recorder = AntigravityRecorder()
        let suite = testDefaultsSuite("NativeHarnessClientTests.AntigravityImport")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(store: SessionStore(sessions: sessions, repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, _ in recorder },
            modelCatalogs: HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
                claudeConfigDirectory: root.appending(path: "claude"), codexHome: root.appending(path: "codex-home"),
                codexYardletHome: root.appending(path: "codex-yardlet")), environment: [:]),
            initialTranscripts: transcripts,
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
            preferences: defaults,
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            sessionTitleResolver: { _ in nil },
            restoresIndexOnLaunch: false)
        addTeardownBlock { await model.shutdown() }
        model.runtimeSelections.select(runtime, for: .antigravityCLI)
        model.antigravityConversationStore = store
        // The Claude app's folder is empty, and Codex is not installed here.
        model.claudeDesktopSessionsRoot = root.appending(path: "claude-desktop")
        return ModelFixture(model: model, recorder: recorder, runtime: runtime)
    }
}

private let antigravityTestTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Records whatever Yardlet asks of an Antigravity runtime; the tests expect nothing.
private actor AntigravityRecorder: HarnessAdapter {
    nonisolated let kind = HarnessKind.antigravityCLI
    private(set) var calls: [String] = []

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        calls.append("probe")
        return HarnessRuntimeDescriptor(harness: kind, executableURL: URL(filePath: "/tmp/stub"), version: "stub",
                                        capabilities: .unavailable, fingerprint: "stub")
    }
    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        calls.append("create")
        return HarnessSessionHandle(harness: kind, localSessionID: request.localSessionID,
                                    providerSessionID: request.localSessionID.uuidString, workspaceURL: request.workspaceURL)
    }
    func resumeSession(providerSessionID: String, localSessionID: UUID, workspaceURL: URL) async throws -> HarnessSessionHandle {
        calls.append("resume \(providerSessionID)")
        return HarnessSessionHandle(harness: kind, localSessionID: localSessionID, providerSessionID: providerSessionID,
                                    workspaceURL: workspaceURL)
    }
    func send(_ prompt: String, to session: HarnessSessionHandle) async throws { calls.append("send") }
    func interrupt(_ session: HarnessSessionHandle) async throws {}
    func respond(to permissionRequestID: String, decision: PermissionDecision, in session: HarnessSessionHandle) async throws {}
    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> { AsyncStream { _ in } }
    func close(_ session: HarnessSessionHandle) async {}
}
