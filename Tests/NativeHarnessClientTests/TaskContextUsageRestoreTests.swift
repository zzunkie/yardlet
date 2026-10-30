import AppKit
import CSQLite
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The composer's context ring and the session rail's Context card after Yardlet restarts: what the
/// index kept for the task (`sessions.context_usage`), then the provider's own history when the task
/// opens (Claude Code's transcript, Codex's rollout), and a live report over both. Nothing here
/// starts a provider process or a turn. Fixtures use the providers' real key shapes with made-up
/// numbers; renders go to `.build/context-restore-qa/`.
@MainActor
final class TaskContextUsageRestoreTests: XCTestCase {
    private static let claudeSessionID = "6B1D3F0A-2C4E-4A57-8E9F-0A1B2C3D4E5F"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "context-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Claude Code's transcript

    /// CLI 2.1.299 counts the last main-chain response's `input_tokens + cache_creation_input_tokens +
    /// cache_read_input_tokens` (`rGn`), not its output; a sidechain, a `<synthetic>` notice and an
    /// API error after it are not that response.
    func testClaudeUsageIsTheLastResponsesInputAndCache() throws {
        let chain: [JSONValue] = [
            Self.user("Fix the flaky test", uuid: "u-1", parent: nil),
            Self.assistant(uuid: "a-1", parent: "u-1", input: 3, cacheCreation: 1_000, cacheRead: 20_000, output: 400),
            Self.user("Run it again", uuid: "u-2", parent: "a-1"),
            Self.assistant(uuid: "a-2", parent: "u-2", input: 6, cacheCreation: 2_400, cacheRead: 410_000, output: 900,
                           timestamp: "2026-10-17T03:00:05.123Z"),
            Self.assistant(uuid: "side", parent: "a-2", input: 9, cacheCreation: 9, cacheRead: 9, output: 9, sidechain: true),
            Self.assistant(uuid: "notice", parent: "a-2", input: 0, cacheCreation: 0, cacheRead: 0, output: 0,
                           model: "<synthetic>"),
            Self.assistant(uuid: "error", parent: "a-2", input: 1, cacheCreation: 1, cacheRead: 1, output: 1,
                           apiError: true)
        ]
        let usage = try XCTUnwrap(ClaudeTranscriptContextUsage.latest(in: chain))
        XCTAssertEqual(usage.usedTokens, 6 + 2_400 + 410_000, "Output is not in the window's count")
        XCTAssertEqual(usage.model, "claude-opus-5-5")
        XCTAssertEqual(try XCTUnwrap(usage.timestamp).timeIntervalSince1970,
                       ISO8601DateFormatter().date(from: "2026-10-17T03:00:05Z")!.timeIntervalSince1970 + 0.123,
                       accuracy: 0.001)
    }

    /// A response with iterations counts its last one that is not a compaction (`Y8`); a compaction
    /// after the last response leaves no count, as the CLI has none until the next response.
    func testIterationsAndCompactionsCountAsTheCLICountsThem() throws {
        var iterated = Self.assistant(uuid: "a-1", parent: "u-1", input: 50, cacheCreation: 50, cacheRead: 50, output: 5)
        iterated = Self.with(iterated, iterations: [
            .object(["type": .string("message"), "input_tokens": .integer(4), "output_tokens": .integer(70),
                     "cache_creation_input_tokens": .integer(300), "cache_read_input_tokens": .integer(88_000)]),
            .object(["type": .string("compaction"), "input_tokens": .integer(1), "output_tokens": .integer(1),
                     "cache_creation_input_tokens": .integer(1), "cache_read_input_tokens": .integer(1)])
        ])
        XCTAssertEqual(ClaudeTranscriptContextUsage.latest(in: [iterated])?.usedTokens, 4 + 300 + 88_000)

        let compacted: [JSONValue] = [
            Self.assistant(uuid: "a-1", parent: "u-1", input: 5, cacheCreation: 5, cacheRead: 150_000, output: 5),
            .object(["type": .string("system"), "subtype": .string("compact_boundary"), "uuid": .string("c"),
                     "parentUuid": .null, "logicalParentUuid": .string("a-1")]),
            Self.user("Summary", uuid: "s", parent: "c")
        ]
        XCTAssertNil(ClaudeTranscriptContextUsage.latest(in: compacted))
        XCTAssertNil(ClaudeTranscriptContextUsage.latest(in: [
            Self.assistant(uuid: "a", parent: nil, input: 0, cacheCreation: 0, cacheRead: 0, output: 12)
        ]), "A response that counts nothing in the window gives no count")
    }

    /// The reader opening a detached task already uses carries the count with the entries it reads.
    func testTheTranscriptReaderCarriesTheCount() throws {
        let config = root.appending(path: "config")
        let workspace = root.appending(path: "project")
        try writeTranscript(in: config, workspace: workspace, records: Self.conversation(cacheRead: 410_000))
        let reader = ClaudeSubagentTranscriptReader(configDirectory: config)
        let read = try XCTUnwrap(try reader.readNewest(sessionID: Self.claudeSessionID, bytes: ClaudeTranscriptTail.initialBytes))
        XCTAssertFalse(read.entries.isEmpty)
        XCTAssertEqual(read.contextUsage?.usedTokens, 6 + 2_400 + 410_000)
        XCTAssertEqual(read.contextUsage?.model, "claude-opus-5-5")
    }

    /// `get_context_usage` names the model its window is for, and the name crosses the protocol's
    /// codec with the rest of the usage, as the product route (YHP) carries it.
    func testTheReportedModelCrossesTheProtocol() throws {
        let usage = try XCTUnwrap(ClaudeProtocol.contextUsage(from: Self.contextUsageResponse(total: 480_000)))
        XCTAssertEqual(usage.contextWindowModel, "claude-opus-5-5")
        XCTAssertEqual(usage.contextWindowTokens, 1_000_000)
        let codec = HarnessProtocolPayloadCodec()
        XCTAssertEqual(try codec.decode(HarnessProtocolUsage.self, from: try codec.encode(usage)), usage)
        var older = try codec.encode(usage).objectValue ?? [:]
        older.removeValue(forKey: "contextWindowModel")
        XCTAssertNil(try codec.decode(HarnessProtocolUsage.self, from: .object(older)).contextWindowModel,
                     "A payload from before it reads without it")
    }

    // MARK: - Codex's rollout

    /// The last `token_count` with `info` in the rollout, as Codex's App Server replays it on resume;
    /// a later one with only rate limits is not usage.
    func testCodexUsageIsTheRolloutsLatestTokenCount() throws {
        let file = root.appending(path: "rollout.jsonl")
        try Self.rollout([
            Self.sessionMeta,
            Self.tokenCount(lastTotal: 40_000, window: 258_400),
            Self.responseItem,
            Self.tokenCount(lastTotal: 64_600, window: 258_400),
            Self.tokenCountWithoutInfo
        ]).write(to: file)
        let usage = try XCTUnwrap(CodexRolloutTokenUsage.latest(in: file))
        XCTAssertEqual(usage, Self.codexUsage(lastTotal: 64_600, window: 258_400))
        let summary = try XCTUnwrap(ComposerContextSummary.make(
            usage: ComposerSessionOptionsProjection.codexContextUsage(usage), reportsContextWindow: true))
        XCTAssertEqual(summary.summaryText, "64.6k / 258.4k (25%)")
    }

    /// Only the newest part of a long rollout is read, further back while it holds no usage, up to a
    /// bound; a first line cut by the read is skipped.
    func testALongRolloutIsReadFromItsEnd() throws {
        let filler = Data((String(repeating: #"{"type":"response_item","payload":{"type":"message","text":"x"}}"#, count: 1)
                           + "\n").utf8)
        var data = Self.rollout([Self.sessionMeta, Self.tokenCount(lastTotal: 12_000, window: 200_000)])
        for _ in 0..<(3 << 20) / filler.count { data.append(filler) }
        let file = root.appending(path: "long.jsonl")
        try data.write(to: file)
        XCTAssertEqual(CodexRolloutTokenUsage.latest(in: file), Self.codexUsage(lastTotal: 12_000, window: 200_000),
                       "Further back than the first megabyte")
        for _ in 0..<(8 << 20) / filler.count { data.append(filler) }
        try data.write(to: file)
        XCTAssertNil(CodexRolloutTokenUsage.latest(in: file), "Not past the bound")

        let cut = Data(#"_tokens":1}},"model_context_window":5}}}"#.utf8) + Data("\n".utf8)
            + Self.rollout([Self.responseItem])
        XCTAssertNil(CodexRolloutTokenUsage.latest(inLines: cut, startsMidLine: true))
    }

    // MARK: - The index

    /// An index from before the column gains it with every row intact; a saved value reads back,
    /// survives a save of the task's own fields, and stays with an archived task.
    func testAnOlderIndexGainsTheColumnAndKeepsItsRows() async throws {
        let database = root.appending(path: "session-index.sqlite3")
        let id = UUID()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path(percentEncoded: false), &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, """
            CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL, harness TEXT NOT NULL, workspace_path TEXT NOT NULL,
                runtime_path TEXT NOT NULL, title TEXT NOT NULL, status TEXT NOT NULL, created_at REAL NOT NULL,
                updated_at REAL NOT NULL, provider_session_id TEXT, archived INTEGER NOT NULL DEFAULT 0,
                lineage_detached INTEGER NOT NULL DEFAULT 0);
            INSERT INTO sessions (id, harness, workspace_path, runtime_path, title, status, created_at, updated_at,
                provider_session_id) VALUES ('\(id.uuidString)', 'claude-code', '/tmp/context-qa/project',
                '/tmp/claude', 'Before the column', 'ready', 1, 2, '\(Self.claudeSessionID)');
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let repository = try SQLiteSessionRepository(databaseURL: database)
        let loaded = try await repository.loadSessions()
        XCTAssertEqual(loaded.map(\.id), [id])
        XCTAssertEqual(loaded.first?.title, "Before the column")
        let none = try await repository.loadContextUsage()
        XCTAssertEqual(none, [:], "Old rows have none")
        XCTAssertEqual(try Self.columns(of: database).filter { $0 == "context_usage" }, ["context_usage"])

        let snapshot = Self.claudeSnapshot(used: 95_100, window: 200_000, at: Date(timeIntervalSince1970: 1_800_000_000))
        try await repository.saveContextUsage(snapshot, for: id)
        var renamed = try XCTUnwrap(loaded.first)
        renamed.title = "Renamed"
        try await repository.upsert(renamed)
        let reopened = try SQLiteSessionRepository(databaseURL: database)
        let kept = try await reopened.loadContextUsage()
        XCTAssertEqual(kept, [id: snapshot], "A save of the task's fields keeps it")
        let rows = try await reopened.loadSessions()
        XCTAssertEqual(rows.first?.title, "Renamed")
        XCTAssertEqual(rows.first?.updatedAt, renamed.updatedAt, "Not activity")

        try await reopened.archive(id: id)
        let whileArchived = try await reopened.loadContextUsage()
        XCTAssertEqual(whileArchived, [:], "An archived task is not restored")
        _ = try await reopened.unarchive(id: id)
        let unarchived = try await reopened.loadContextUsage()
        XCTAssertEqual(unarchived, [id: snapshot])
        XCTAssertNil(TaskContextUsageSnapshot.decoded(#"{"version":99}"#), "A shape this build cannot read reads as none")
    }

    // MARK: - After a restart

    /// A Claude task's report is kept; after a restart the ring and the rail read it back before the
    /// task connects, with no process started; the window its model had is kept in the model
    /// catalog; and the next live report replaces the kept value through the usual merge.
    func testAKeptReportShowsAfterARestartAndALiveReportReplacesIt() async throws {
        let database = root.appending(path: "session-index.sqlite3")
        let catalogFile = root.appending(path: "model-catalogs.json")
        let first = FakeHarnessAdapter(kind: .claudeCode)
        let before = try makeModel(repository: try SQLiteSessionRepository(databaseURL: database), adapter: first,
                                   catalogFile: catalogFile, restores: false)
        try FileManager.default.createDirectory(at: root.appending(path: "project"), withIntermediateDirectories: true)
        await before.createSession(harness: .claudeCode, workspaceURL: root.appending(path: "project"),
                                   runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Context")
        let task = try XCTUnwrap(before.store.selectedSession)
        let live = try XCTUnwrap(ClaudeProtocol.contextUsage(from: Self.contextUsageResponse(total: 480_000)))
        await first.emit(.usageUpdated(live), for: task.id, sequence: 1)
        let repository = try SQLiteSessionRepository(databaseURL: database)
        try await waitUntil { (try? await repository.loadContextUsage()[task.id]) != nil }
        XCTAssertEqual(before.modelCatalogs.claudeContextWindows, ["claude-opus-5-5": 1_000_000])
        await before.shutdown()

        // The restart: a new model over the same index, and a runtime that has not been asked anything.
        let second = FakeHarnessAdapter(kind: .claudeCode)
        let after = try makeModel(repository: repository, adapter: second, catalogFile: catalogFile, restores: true)
        await after.restoreIndex()
        let restored = try XCTUnwrap(after.store.sessions.first { $0.id == task.id })
        XCTAssertEqual(after.providerUsageBySessionID[task.id], live, "The ring has what it showed before")
        XCTAssertEqual(Self.ringText(after, restored), "480k / 1M (48%)")
        XCTAssertEqual(after.modelCatalogs.claudeContextWindow(forResponseModel: "claude-opus-5-5", chosenModel: nil),
                       1_000_000, "The window is kept across the restart")
        XCTAssertFalse(after.isAttached(task.id))
        let untouched = await (second.probeCount, second.createCount, second.resumeCount, second.sentPrompts)
        XCTAssertEqual(untouched.0 + untouched.1 + untouched.2, 0, "Nothing started")
        XCTAssertEqual(untouched.3, [])

        // Live beats kept: the task connects and reports.
        await after.resume(restored)
        let newer = HarnessProtocolUsage(inputTokens: 10, cachedInputTokens: 500_000, outputTokens: 900, reasoningTokens: nil,
                                         totalCostUSD: 0.5, contextWindowTokens: 1_000_000, contextUsedTokens: 510_000,
                                         extensionValues: [:])
        await second.emit(.usageUpdated(newer), for: task.id, sequence: 1)
        try await waitUntil { after.providerUsageBySessionID[task.id]?.contextUsedTokens == 510_000 }
        XCTAssertEqual(Self.ringText(after, restored), "510k / 1M (51%)")
        XCTAssertEqual(after.providerUsageBySessionID[task.id]?.contextBreakdown, live.contextBreakdown,
                       "Fields the report leaves out stay from before, as the merge keeps them")
        await after.shutdown()
    }

    /// A detached Claude task never seen live: opening it reads its transcript's last response and
    /// gives it the window its model last had here, without starting anything. A task that chose the
    /// `[1m]` suffix looks the model up with it; a model with no window known leaves the ring as before.
    func testOpeningADetachedClaudeTaskReadsItsTranscript() async throws {
        let fixture = try await makeDetachedClaudeTask(records: Self.conversation(cacheRead: 410_000))
        fixture.model.modelCatalogs.recordClaudeContextWindow(1_000_000, model: "claude-opus-5-5")
        await fixture.model.refreshConversationStatus(for: fixture.task)
        XCTAssertEqual(fixture.model.providerUsageBySessionID[fixture.task.id]?.contextUsedTokens, 412_406)
        XCTAssertEqual(Self.ringText(fixture.model, fixture.task), "412.4k / 1M (41%)")
        let calls = await (fixture.adapter.probeCount, fixture.adapter.createCount, fixture.adapter.resumeCount)
        XCTAssertEqual(calls.0 + calls.1 + calls.2, 0, "Reading starts nothing")
        try await waitUntil { (try? await fixture.repository.loadContextUsage()[fixture.task.id]) != nil }

        let unknown = try await makeDetachedClaudeTask(records: Self.conversation(cacheRead: 410_000))
        await unknown.model.refreshConversationStatus(for: unknown.task)
        XCTAssertNil(unknown.model.providerUsageBySessionID[unknown.task.id], "No window known: the ring is as it was")

        let million = try await makeDetachedClaudeTask(records: Self.conversation(cacheRead: 410_000),
                                                 chosenModel: "claude-opus-4-8[1m]", responseModel: "claude-opus-4-8")
        million.model.modelCatalogs.recordClaudeContextWindow(200_000, model: "claude-opus-4-8")
        million.model.modelCatalogs.recordClaudeContextWindow(1_000_000, model: "claude-opus-4-8[1m]")
        await million.model.refreshConversationStatus(for: million.task)
        XCTAssertEqual(million.model.providerUsageBySessionID[million.task.id]?.contextWindowTokens, 1_000_000)
    }

    /// What the index kept is the CLI's own `/context` count taken after the transcript's last
    /// response, so it stays; a conversation that went on after it (in another app) reads again.
    func testAKeptCountStaysUntilTheConversationGoesOnElsewhere() async throws {
        let kept = Self.claudeSnapshot(used: 480_000, window: 1_000_000,
                                       at: ISO8601DateFormatter().date(from: "2026-10-17T04:00:00Z")!)
        let fixture = try await makeDetachedClaudeTask(records: Self.conversation(cacheRead: 410_000), kept: kept)
        await fixture.model.restoreIndex()
        XCTAssertEqual(Self.ringText(fixture.model, fixture.task), "480k / 1M (48%)")
        await fixture.model.refreshConversationStatus(for: fixture.task)
        XCTAssertEqual(fixture.model.providerUsageBySessionID[fixture.task.id], kept.provider,
                       "The transcript's response is older than what was kept")

        var records = Self.conversation(cacheRead: 410_000)
        records.append(Self.user("And the docs", uuid: "u-3", parent: "a-2"))
        records.append(Self.assistant(uuid: "a-3", parent: "u-3", input: 8, cacheCreation: 1_200, cacheRead: 520_000,
                                      output: 300, timestamp: "2026-10-17T05:10:00.000Z"))
        try writeTranscript(in: fixture.config, workspace: fixture.task.workspaceURL, records: records)
        await fixture.model.refreshConversationStatus(for: fixture.task)
        XCTAssertEqual(Self.ringText(fixture.model, fixture.task), "521.2k / 1M (52%)",
                       "The conversation went on after it, with the window the task last showed")
        XCTAssertNil(fixture.model.providerUsageBySessionID[fixture.task.id]?.contextBreakdown,
                     "The old breakdown is not the new count's")
    }

    /// A detached Codex task: opening it reads its thread as before and, from the rollout that read
    /// names, the latest token usage, which shows until the thread reports its own. Nothing is
    /// resumed and no turn starts; after a restart the index has it before the thread is read.
    /// Restoring selects the task, and choosing a task starts reading it (docs/NATIVE_SESSION_STORAGE.md,
    /// "Reading long histories in parts"), so the restarted App Server holds that read until the index's
    /// value is seen.
    func testOpeningADetachedCodexTaskReadsItsRollout() async throws {
        let rollout = root.appending(path: "rollout-2026-10-17T03-00-00-thread-saved.jsonl")
        try Self.rollout([Self.sessionMeta, Self.tokenCount(lastTotal: 64_600, window: 258_400),
                          Self.tokenCountWithoutInfo]).write(to: rollout)
        let database = root.appending(path: "codex-index.sqlite3")
        let fixture = try await makeDetachedCodexTask(rollout: rollout, repository: try SQLiteSessionRepository(databaseURL: database))
        await fixture.model.refreshConversationStatus(for: fixture.session)
        let methods = await fixture.transport.requestMethods
        XCTAssertEqual(methods, ["initialize", "thread/read", "thread/turns/list"], "Nothing resumed, no turn")
        XCTAssertEqual(fixture.model.restoredCodexTokenUsageBySessionID[fixture.session.id],
                       Self.codexUsage(lastTotal: 64_600, window: 258_400))
        XCTAssertFalse(fixture.model.isAttached(fixture.session.id))
        let repository = try SQLiteSessionRepository(databaseURL: database)
        try await waitUntil { (try? await repository.loadContextUsage()[fixture.session.id]?.codex) != nil }
        await fixture.model.shutdown()

        let restarted = try await makeDetachedCodexTask(rollout: rollout, repository: repository, restores: true)
        await restarted.transport.suspendNextRequest("thread/read")
        await restarted.model.restoreIndex()
        XCTAssertEqual(restarted.model.restoredCodexTokenUsageBySessionID[restarted.session.id],
                       Self.codexUsage(lastTotal: 64_600, window: 258_400), "Shown before the thread is read")
        try await waitUntil { await restarted.transport.isRequestSuspended }
        XCTAssertEqual(restarted.model.restoredCodexTokenUsageBySessionID[restarted.session.id],
                       Self.codexUsage(lastTotal: 64_600, window: 258_400), "Shown while the App Server has not answered")
        await restarted.transport.releaseSuspendedRequest()
        try await waitUntil { !restarted.model.isReadingSavedConversation(restarted.session.id) }
        let opened = await restarted.transport.requestMethods
        XCTAssertEqual(opened, ["initialize", "thread/read", "thread/turns/list"],
                       "Opening the restored task reads its thread: nothing resumed, no turn")
        XCTAssertFalse(restarted.model.isAttached(restarted.session.id))
    }

    /// The composer and the rail show the thread's own usage once it has some; what was read back is
    /// only what shows until then.
    func testACodexThreadsOwnUsageBeatsWhatWasReadBack() throws {
        let restored = Self.codexUsage(lastTotal: 64_600, window: 258_400)
        let live = Self.codexUsage(lastTotal: 129_200, window: 258_400)
        let session = SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/context-restore-qa"),
                                    runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Codex",
                                    status: .ready, providerSessionID: "thread-saved")
        var thread = CodexTaskDecoder().thread(from: .object([
            "id": .string("thread-saved"), "status": .object(["type": .string("idle")]),
            "turns": .array([.object(["id": .string("turn-1"), "status": .string("completed"), "items": .array([])])])
        ]))
        thread?.turns[0].tokenUsage = live
        for (state, expected) in [(nil as CodexTaskState?, "64.6k / 258.4k (25%)"),
                                  (CodexTaskState(thread: thread), "129.2k / 258.4k (50%)")] {
            let host = WindowlessRender.Host(
                RestoredCodexDetail(session: session, state: state, restored: restored)
                    .frame(width: 1100, height: 640),
                size: NSSize(width: 1100, height: 640))
            host.settle(passes: 20)
            let values = host.accessibilityElements().map(\.value)
            XCTAssertTrue(values.contains(expected), "\(expected) not in \(values)")
            host.close()
        }
    }

    /// The whole window after a simulated restart, a Claude task and a Codex task, light and dark:
    /// the ring beside the model menu and the rail's Context card, before either task connects.
    func testTheRingAndTheCardDrawAfterARestart() async throws {
        let directory = try WindowlessRender.directory("context-restore-qa")
        let kept = Self.claudeSnapshot(used: 480_000, window: 1_000_000, at: Date())
        let claude = try await makeDetachedClaudeTask(records: Self.conversation(cacheRead: 410_000), kept: kept,
                                                title: "Restore the context window")
        await claude.model.restoreIndex()
        let rollout = root.appending(path: "rollout-2026-10-17T03-00-00-thread-saved.jsonl")
        try Self.rollout([Self.sessionMeta, Self.tokenCount(lastTotal: 64_600, window: 258_400)]).write(to: rollout)
        let codexRepository = InMemorySessionRepository()
        let codex = try await makeDetachedCodexTask(rollout: rollout, repository: codexRepository)
        await codex.model.refreshConversationStatus(for: codex.session)
        // The conversation the window opens on; what the index kept was taken after its last response.
        await claude.model.refreshConversationStatus(for: claude.task)
        XCTAssertEqual(claude.model.providerUsageBySessionID[claude.task.id], kept.provider)
        for (name, model, task, expected, percent) in [
            ("claude-task", claude.model, claude.task, "480k / 1M (48%)", "48%"),
            ("codex-task", codex.model, codex.session, "64.6k / 258.4k (25%)", "25%")
        ] {
            model.splits.activate(.session(task.id))
            for cardOpen in [false, true] {
                // The card starts folded with its percentage; opened, it lists the numbers.
                model.taskWorkspaces.state(for: task.id).railFolds.setFolded(.context, !cardOpen)
                for appearance in WindowlessRender.Appearance.allCases {
                    let host = WindowlessRender.Host(
                        AnyView(MainWindow(model: model).environment(\.colorScheme, appearance.colorScheme)),
                        size: NSSize(width: 1280, height: 780), appearance: appearance)
                    host.settle(passes: 24, interval: 0.04)
                    let elements = host.accessibilityElements()
                    XCTAssertTrue(elements.contains { $0.label == L10n.string("Context window") && $0.value == expected },
                                  "\(name): the ring shows \(expected): \(elements.filter { $0.label.contains("Context") })")
                    if !cardOpen {
                        XCTAssertTrue(elements.contains { $0.label == L10n.string("Context") && $0.value.hasSuffix(percent) },
                                      "\(name): the rail's folded Context card shows \(percent): \(elements)")
                    } else {
                        XCTAssertTrue(elements.contains { $0.label.contains(expected) || $0.value.contains(expected) },
                                      "\(name): the open card lists \(expected): \(elements)")
                    }
                    let file = "\(name)\(cardOpen ? "-card-open" : "")-\(appearance.suffix).png"
                    try WindowlessRender.writePNG(try host.capture().bitmap, to: directory.appending(path: file))
                    host.close()
                }
            }
        }
    }

    // MARK: - Fixtures

    private struct RestoredCodexDetail: View {
        let session: SessionRecord
        let state: CodexTaskState?
        let restored: CodexThreadTokenUsage
        @State private var workspace = TaskWorkspaceState()
        @FocusState private var focused: TaskSurface?

        var body: some View {
            TaskDetail(
                session: session, composerDraft: TaskComposerDraft(), workspaceState: workspace,
                panelState: Binding(get: { workspace.panels }, set: { workspace.setPanels($0) }),
                focusedSurface: $focused, entries: [], errorMessage: nil, codexTaskState: state,
                codexHistorySelection: nil, codexQueue: [], codexCapabilities: .empty, providerCapabilities: nil,
                providerUsage: nil, restoredCodexTokenUsage: restored, isProviderAttached: false,
                onShowCodexCapabilities: {}, conversationActions: ConversationActions(),
                composerActions: ComposerActions(send: { _ in }, interrupt: {}))
            .environment(\.taskKeyboardFocus, workspace.keyboardFocus)
        }
    }

    private func makeModel(repository: any SessionRepository, adapter: FakeHarnessAdapter, catalogFile: URL? = nil,
                           sessions: [SessionRecord] = [], restores: Bool) throws -> AppModel {
        let suite = testDefaultsSuite("TaskContextUsageRestore")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let config = root.appending(path: "config")
        return AppModel(
            store: SessionStore(sessions: sessions, repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, _ in adapter },
            modelCatalogs: HarnessModelCatalogStore(fileURL: catalogFile, locations: HarnessModelSettingsLocations(
                claudeConfigDirectory: config, codexHome: root.appending(path: "codex-home"),
                codexYardletHome: root.appending(path: "codex-yardlet")), environment: [:]),
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
            preferences: defaults,
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            sessionTitleResolver: { _ in nil },
            restoresIndexOnLaunch: restores)
    }

    private struct ClaudeTask {
        let model: AppModel
        let task: SessionRecord
        let adapter: FakeHarnessAdapter
        let repository: InMemorySessionRepository
        let config: URL
    }

    /// A saved Claude task on an account whose config holds its transcript, not connected this launch.
    private func makeDetachedClaudeTask(records: [JSONValue], kept: TaskContextUsageSnapshot? = nil,
                                        chosenModel: String? = nil, responseModel: String = "claude-opus-5-5",
                                        title: String = "Context") async throws -> ClaudeTask {
        let base = root.appending(path: UUID().uuidString)
        let config = base.appending(path: "config")
        let workspace = base.appending(path: "project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let shaped = records.map { record -> JSONValue in
            guard record["type"]?.stringValue == "assistant", var object = record.objectValue,
                  var message = object["message"]?.objectValue else { return record }
            message["model"] = .string(responseModel)
            object["message"] = .object(message)
            return .object(object)
        }
        try writeTranscript(in: config, workspace: workspace, records: shaped)
        let account = ProviderConnection(id: "claude-context-\(UUID().uuidString)", name: "context@example.test",
                                         harness: .claudeCode, providerID: nil, homePath: config.path,
                                         credentialSelector: nil)
        let task = SessionRecord(harness: .claudeCode, workspaceURL: workspace, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
            title: title, status: .completed, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000), providerSessionID: Self.claudeSessionID,
            providerOptions: chosenModel.map { [ClaudeLaunchOption.model: $0] } ?? [:], connection: account)
        let repository = InMemorySessionRepository(sessions: [task])
        let adapter = FakeHarnessAdapter(kind: .claudeCode)
        let model = try makeModel(repository: repository, adapter: adapter, sessions: [task], restores: kept != nil)
        addTeardownBlock { await model.shutdown() }
        if let kept { try await repository.saveContextUsage(kept, for: task.id) }
        return ClaudeTask(model: model, task: task, adapter: adapter, repository: repository, config: config)
    }

    private struct CodexTask {
        let model: AppModel
        let session: SessionRecord
        let transport: FakeCodexTransport
    }

    /// A saved Codex task behind the product route (YHP over the App Server adapter) and a fake App
    /// Server whose `thread/read` names `rollout`.
    private func makeDetachedCodexTask(rollout: URL, repository: any SessionRepository,
                                       restores: Bool = false) async throws -> CodexTask {
        let base = root.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let executable = base.appending(path: "codex")
        try Data("#!/bin/sh\nprintf 'codex-cli 0.163.0\\n'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var thread = CodexDetachedThreadReadTests.savedThread.objectValue ?? [:]
        thread["path"] = .string(rollout.path(percentEncoded: false))
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/read": [CodexSavedThreadResponses.metadata(.object(thread))],
            "thread/turns/list": [CodexSavedThreadResponses.page(.object(thread))]
        ])
        let adapter = YHPCodexCompatibilityAdapter(
            adapter: CodexAdapter(executableURL: executable, transport: transport),
            manifest: HarnessProtocolCompatibilityManifest.codex())
        let id = UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-8E9F0A1B2C3D")!
        let workspace = base.appending(path: "calculator")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let session = SessionRecord(id: id, harness: .codex, workspaceURL: workspace, runtimeExecutableURL: executable,
            title: "Fix the tests", status: .completed, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000), providerSessionID: "thread-saved")
        try await repository.upsert(session)
        let suite = testDefaultsSuite("TaskContextUsageRestore.codex")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(
            store: SessionStore(sessions: restores ? [] : [session], repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, _ in adapter },
            modelCatalogs: HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
                claudeConfigDirectory: base.appending(path: "claude"), codexHome: base.appending(path: "codex-home"),
                codexYardletHome: base.appending(path: "codex-yardlet")), environment: [:]),
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
            preferences: defaults,
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            sessionTitleResolver: { _ in nil },
            restoresIndexOnLaunch: restores)
        addTeardownBlock { await model.shutdown() }
        return CodexTask(model: model, session: session, transport: transport)
    }

    private func writeTranscript(in config: URL, workspace: URL, records: [JSONValue]) throws {
        let folder = config.appending(path: "projects/\(ClaudeConversationCatalog.projectFolderName(for: workspace))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var data = Data()
        for record in records {
            data.append(try JSONEncoder().encode(record))
            data.append(10)
        }
        try data.write(to: folder.appending(path: "\(Self.claudeSessionID).jsonl"))
    }

    /// The deadline only bounds a failure: a check that holds goes on at once, however busy the machine is.
    private func waitUntil(timeout: Duration = .seconds(10), _ condition: @escaping () async -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        if await condition() { return }
        XCTFail("Condition was not met within \(timeout)", file: file, line: line)
    }

    private static func ringText(_ model: AppModel, _ task: SessionRecord) -> String? {
        let options = ComposerSessionOptionsProjection.make(
            harness: task.harness, session: task, providerCapabilities: nil,
            providerUsage: model.providerUsageBySessionID[task.id],
            codexTokenUsage: model.restoredCodexTokenUsageBySessionID[task.id], isAttached: model.isAttached(task.id))
        return ComposerContextSummary.make(usage: options.contextUsage,
                                           reportsContextWindow: options.reportsContextWindow)?.summaryText
    }

    private static func columns(of database: URL) throws -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path(percentEncoded: false), &handle) == SQLITE_OK else { return [] }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(sessions);", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            names.append(String(cString: sqlite3_column_text(statement, 1)))
        }
        return names
    }

    // MARK: Claude Code records (2.1.299 key shapes, made-up values)

    private static func conversation(cacheRead: Int64) -> [JSONValue] {
        [user("Fix the flaky test", uuid: "u-1", parent: nil),
         assistant(uuid: "a-1", parent: "u-1", input: 3, cacheCreation: 1_000, cacheRead: 20_000, output: 400,
                   timestamp: "2026-10-17T02:59:00.000Z"),
         user("Run it again", uuid: "u-2", parent: "a-1"),
         assistant(uuid: "a-2", parent: "u-2", input: 6, cacheCreation: 2_400, cacheRead: cacheRead, output: 900,
                   timestamp: "2026-10-17T03:00:05.123Z")]
    }

    private static func user(_ text: String, uuid: String, parent: String?) -> JSONValue {
        .object(["parentUuid": parent.map(JSONValue.string) ?? .null, "isSidechain": .bool(false),
                 "userType": .string("external"), "cwd": .string("/tmp/context-restore-qa/project"),
                 "sessionId": .string(claudeSessionID), "version": .string("2.1.299"), "gitBranch": .string("main"),
                 "type": .string("user"), "message": .object(["role": .string("user"), "content": .string(text)]),
                 "uuid": .string(uuid), "timestamp": .string("2026-10-17T02:58:00.000Z")])
    }

    private static func assistant(uuid: String, parent: String?, input: Int64, cacheCreation: Int64, cacheRead: Int64,
                                  output: Int64, timestamp: String = "2026-10-17T03:00:00.000Z",
                                  model: String = "claude-opus-5-5", sidechain: Bool = false,
                                  apiError: Bool = false) -> JSONValue {
        var record: [String: JSONValue] = [
            "parentUuid": parent.map(JSONValue.string) ?? .null, "isSidechain": .bool(sidechain),
            "userType": .string("external"), "cwd": .string("/tmp/context-restore-qa/project"),
            "sessionId": .string(claudeSessionID), "version": .string("2.1.299"), "gitBranch": .string("main"),
            "entrypoint": .string("sdk-cli"), "requestId": .string("req_\(uuid)"), "requestedModel": .string(model),
            "type": .string("assistant"), "uuid": .string(uuid), "timestamp": .string(timestamp),
            "message": .object([
                "model": .string(model), "id": .string("msg_\(uuid)"), "type": .string("message"),
                "role": .string("assistant"),
                "content": .array([.object(["type": .string("text"), "text": .string("Done with \(uuid).")])]),
                "stop_reason": .string("end_turn"), "stop_sequence": .null,
                "usage": .object([
                    "input_tokens": .integer(input), "cache_creation_input_tokens": .integer(cacheCreation),
                    "cache_read_input_tokens": .integer(cacheRead), "output_tokens": .integer(output),
                    "output_tokens_details": .object(["thinking_tokens": .integer(output / 4)]),
                    "server_tool_use": .object(["web_search_requests": .integer(0), "web_fetch_requests": .integer(0)]),
                    "service_tier": .string("standard"),
                    "cache_creation": .object(["ephemeral_1h_input_tokens": .integer(cacheCreation),
                                               "ephemeral_5m_input_tokens": .integer(0)]),
                    "inference_geo": .string("global"), "iterations": .array([]), "speed": .string("standard"),
                    "fallback_credit": .null
                ])
            ])
        ]
        if apiError { record["isApiErrorMessage"] = .bool(true) }
        return .object(record)
    }

    private static func with(_ record: JSONValue, iterations: [JSONValue]) -> JSONValue {
        guard var object = record.objectValue, var message = object["message"]?.objectValue,
              var usage = message["usage"]?.objectValue else { return record }
        usage["iterations"] = .array(iterations)
        message["usage"] = .object(usage)
        object["message"] = .object(message)
        return .object(object)
    }

    /// `get_context_usage` as CLI 2.1.299 answers it (the summary detail), made-up numbers.
    private static func contextUsageResponse(total: Int64) -> JSONValue {
        .object([
            "categories": .array([
                .object(["name": .string("System prompt"), "tokens": .integer(4_400), "kind": .string("used")]),
                .object(["name": .string("System tools"), "tokens": .integer(18_200), "kind": .string("used")]),
                .object(["name": .string("Messages"), "tokens": .integer(total - 22_600), "kind": .string("used")]),
                .object(["name": .string("Autocompact buffer"), "tokens": .integer(33_000), "kind": .string("buffer")]),
                .object(["name": .string("Free space"), "tokens": .integer(1_000_000 - total - 33_000), "kind": .string("free")])
            ]),
            "totalTokens": .integer(total), "maxTokens": .integer(1_000_000), "rawMaxTokens": .integer(1_000_000),
            "percentage": .integer(total * 100 / 1_000_000), "model": .string("claude-opus-5-5"),
            "autoCompactThreshold": .integer(967_000), "isAutoCompactEnabled": .bool(true), "apiUsage": .null
        ])
    }

    private static func claudeSnapshot(used: UInt64, window: UInt64, at date: Date) -> TaskContextUsageSnapshot {
        TaskContextUsageSnapshot(
            providerSessionID: claudeSessionID, recordedAt: date,
            provider: HarnessProtocolUsage(
                inputTokens: 6, cachedInputTokens: 410_000, outputTokens: 900, reasoningTokens: nil, totalCostUSD: 0.42,
                contextWindowTokens: window, contextUsedTokens: used, extensionValues: [:],
                contextBreakdown: HarnessContextBreakdown(
                    categories: [.init(name: "Messages", tokens: used, kind: .used)], windowTokens: window,
                    autoCompactThresholdTokens: window - 33_000, isAutoCompactEnabled: true, autoCompactSource: nil),
                contextWindowModel: "claude-opus-5-5"),
            codex: nil)
    }

    // MARK: Codex rollout lines (0.163 key shapes, made-up values)

    private static func rollout(_ lines: [JSONValue]) -> Data {
        var data = Data()
        for line in lines {
            data.append(try! JSONEncoder().encode(line))
            data.append(10)
        }
        return data
    }

    private static let sessionMeta: JSONValue = .object([
        "timestamp": .string("2026-10-17T03:00:00.000Z"), "ordinal": .integer(0), "type": .string("session_meta"),
        "payload": .object(["id": .string("thread-saved"), "cwd": .string("/tmp/context-restore-qa"),
                            "originator": .string("codex_vscode"), "cli_version": .string("0.163.0")])
    ])

    private static let responseItem: JSONValue = .object([
        "timestamp": .string("2026-10-17T03:00:02.000Z"), "ordinal": .integer(4), "type": .string("response_item"),
        "payload": .object(["type": .string("message"), "role": .string("assistant"),
                            "content": .array([.object(["type": .string("output_text"), "text": .string("Done.")])])])
    ])

    private static let rateLimits: JSONValue = .object([
        "limit_id": .string("codex"), "limit_name": .null,
        "primary": .object(["used_percent": .number(12.5), "window_minutes": .integer(300), "resets_at": .integer(1_800_003_600)]),
        "secondary": .null,
        "credits": .object(["has_credits": .bool(false), "unlimited": .bool(false), "balance": .string("0")]),
        "individual_limit": .null, "spend_control_reached": .null, "plan_type": .string("pro"),
        "rate_limit_reached_type": .null
    ])

    private static func breakdown(_ total: Int64) -> JSONValue {
        .object(["input_tokens": .integer(total - 1_600), "cached_input_tokens": .integer(total / 2),
                 "cache_write_input_tokens": .integer(0), "output_tokens": .integer(1_600),
                 "reasoning_output_tokens": .integer(400), "total_tokens": .integer(total)])
    }

    private static func tokenCount(lastTotal: Int64, window: Int64) -> JSONValue {
        .object([
            "timestamp": .string("2026-10-17T03:00:03.000Z"), "ordinal": .integer(5), "type": .string("event_msg"),
            "payload": .object([
                "type": .string("token_count"),
                "info": .object(["total_token_usage": breakdown(lastTotal * 3), "last_token_usage": breakdown(lastTotal),
                                 "model_context_window": .integer(window)]),
                "rate_limits": rateLimits
            ])
        ])
    }

    private static let tokenCountWithoutInfo: JSONValue = .object([
        "timestamp": .string("2026-10-17T03:00:09.000Z"), "ordinal": .integer(9), "type": .string("event_msg"),
        "payload": .object(["type": .string("token_count"), "info": .null, "rate_limits": rateLimits])
    ])

    private static func codexUsage(lastTotal: Int64, window: Int64) -> CodexThreadTokenUsage {
        func breakdown(_ total: Int64) -> CodexTokenUsageBreakdown {
            CodexTokenUsageBreakdown(inputTokens: total - 1_600, cachedInputTokens: total / 2, cacheWriteInputTokens: 0,
                                     outputTokens: 1_600, reasoningOutputTokens: 400, totalTokens: total)
        }
        return CodexThreadTokenUsage(total: breakdown(lastTotal * 3), last: breakdown(lastTotal), modelContextWindow: window)
    }
}
