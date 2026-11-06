import Foundation
import XCTest
@testable import NativeHarnessClient

/// A detached Codex task reads its thread a page at a time (docs/NATIVE_SESSION_STORAGE.md): on open,
/// the thread without its turns and the newest page (`CodexThreadPaging.newestTurns`); as the person
/// scrolls up, the earlier pages behind the provider's cursor; as another app writes it, the newest
/// page again, merged into what is loaded. Every read goes through the task's own App Server and
/// none resumes or attaches the task.
@MainActor
final class CodexDetachedThreadPagingTests: XCTestCase {
    private static let threadID = "thread-long"

    /// The first paint asks for one small page whatever the thread's length: the same three requests
    /// and about the same bytes for a thread of 12 turns and one of 1,200, a small part of what a read
    /// of the whole thread took.
    func testOpeningAsksForOneSmallPageWhateverTheThreadsLength() async throws {
        var openingBytes: [Int: Int] = [:]
        for turns in [12, 1_200] {
            let fixture = try LongThreadFixture(turns: turns, in: self)
            await fixture.model.refreshConversationStatus(for: fixture.task)
            let requests = await fixture.transport.requests
            XCTAssertEqual(requests.map(\.method), ["initialize", "thread/read", "thread/turns/list"])
            XCTAssertEqual(requests[1].params["includeTurns"], .bool(false))
            XCTAssertEqual(requests[2].params["sortDirection"], .string("desc"))
            XCTAssertEqual(requests[2].params["itemsView"], .string("full"))
            XCTAssertEqual(requests[2].params["limit"], .integer(CodexThreadPaging.newestTurns))
            XCTAssertNil(requests[2].params["cursor"])
            let state = try XCTUnwrap(fixture.model.codexPresentationBySessionID[fixture.task.id])
            XCTAssertEqual(state.thread?.turns.map(\.id), (turns - 4...turns).map { "turn-\($0)" })
            XCTAssertEqual(state.thread?.turnsNextCursor, "before-\(turns - 5)")
            let presentation = CodexConversationProjection.presentation(
                state, workspaceURL: fixture.task.workspaceURL, historySelection: nil)
            XCTAssertEqual(presentation.earlier, .provider(cursor: "before-\(turns - 5)"))
            XCTAssertFalse(fixture.model.isAttached(fixture.task.id))
            openingBytes[turns] = await fixture.transport.responseBytes.reduce(0, +)
        }
        let short = try XCTUnwrap(openingBytes[12]), long = try XCTUnwrap(openingBytes[1_200])
        XCTAssertLessThan(Double(long), Double(short) * 1.05, "the first paint does not grow with the history")

        let whole = try LongThreadFixture(turns: 1_200, in: self)
        let read = try await whole.adapter.readThreadPresentation(threadID: Self.threadID, newestTurns: nil)
        XCTAssertEqual(read.thread?.turns.count, 1_200)
        let wholeBytes = await whole.transport.responseBytes.reduce(0, +)
        XCTAssertLessThan(long * 50, wholeBytes, "reading every turn took \(wholeBytes) bytes, opening \(long)")
    }

    /// Scrolling up reads the page before the earliest loaded turn through the task's App Server and
    /// puts it first; the cursor moves back; nothing attaches or resumes. With no cursor left, nothing
    /// more is asked.
    func testScrollingUpReadsEarlierPagesWithoutAttaching() async throws {
        let fixture = try LongThreadFixture(turns: 30, in: self)
        let model = fixture.model, task = fixture.task
        await model.refreshConversationStatus(for: task)

        var expected = Array(26...30)
        for cursor in ["before-25", "before-15", "before-5"] {
            await model.loadMoreCodexTurns(for: task)
            let request = await fixture.transport.requests.last
            XCTAssertEqual(request?.method, "thread/turns/list")
            XCTAssertEqual(request?.params["cursor"], .string(cursor))
            XCTAssertEqual(request?.params["limit"], .integer(CodexThreadPaging.earlierTurns))
            XCTAssertEqual(request?.params["sortDirection"], .string("desc"))
            let start = max(1, Int(cursor.dropFirst("before-".count))! - 9)
            expected = Array(start...30)
            XCTAssertEqual(model.codexPresentationBySessionID[task.id]?.thread?.turns.map(\.id),
                           expected.map { "turn-\($0)" })
        }
        XCTAssertNil(model.codexPresentationBySessionID[task.id]?.thread?.turnsNextCursor, "the first turn is loaded")
        let count = await fixture.transport.requests.count
        await model.loadMoreCodexTurns(for: task)
        let after = await fixture.transport.requests.count
        XCTAssertEqual(after, count, "nothing more to ask for")
        let methods = Set(await fixture.transport.requests.map(\.method))
        XCTAssertEqual(methods, ["initialize", "thread/read", "thread/turns/list"], "no resume, no turn")
        XCTAssertFalse(model.isAttached(task.id))
        let presentation = CodexConversationProjection.presentation(
            try XCTUnwrap(model.codexPresentationBySessionID[task.id]), workspaceURL: task.workspaceURL,
            historySelection: nil)
        XCTAssertEqual(presentation.earlier, .none)
    }

    /// When the rollout changes, the task reads the newest page again, not the thread: the new turn
    /// arrives, and the earlier page the person brought in stays with its cursor.
    func testFollowingReadsOnlyTheNewestPageAndKeepsEarlierPages() async throws {
        let fixture = try LongThreadFixture(turns: 30, in: self)
        let model = fixture.model, task = fixture.task
        await model.refreshConversationStatus(for: task)
        await model.loadMoreCodexTurns(for: task)
        XCTAssertEqual(model.codexPresentationBySessionID[task.id]?.thread?.turns.count, 15)

        model.detachedFollowInterval = .milliseconds(40)
        let follow = Task { await model.followDetachedConversation(for: task) }
        defer { follow.cancel() }
        try await Task.sleep(for: .milliseconds(150))
        let before = await fixture.transport.requests.count
        await fixture.transport.appendTurn()
        let handle = try FileHandle(forWritingTo: fixture.rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"event_msg\"}\n".utf8))
        try handle.close()

        let followed = await eventually {
            model.codexPresentationBySessionID[task.id]?.thread?.turns.last?.id == "turn-31"
        }
        XCTAssertTrue(followed)
        let requests = await fixture.transport.requests.dropFirst(before)
        XCTAssertEqual(requests.map(\.method), ["thread/turns/list"], "only the newest page is read again")
        XCTAssertNil(requests.first?.params["cursor"])
        XCTAssertEqual(requests.first?.params["limit"], .integer(CodexThreadPaging.newestTurns))
        let state = try XCTUnwrap(model.codexPresentationBySessionID[task.id])
        XCTAssertEqual(state.thread?.turns.map(\.id), (16...31).map { "turn-\($0)" })
        XCTAssertEqual(state.thread?.turnsNextCursor, "before-15", "the earlier page keeps its cursor")
        XCTAssertFalse(model.isAttached(task.id))
    }

    // MARK: - Merging the newest page

    func testTheNewestPageReplacesItsTurnsAndKeepsTheEarlierOnes() {
        var state = Self.state(turns: 11...30, cursor: "before-10")
        CodexTaskReducer().mergeNewestTurnPage(Self.page(turns: 27...31, cursor: "before-26"), into: &state)
        XCTAssertEqual(state.thread?.turns.map(\.id), (11...31).map { "turn-\($0)" })
        XCTAssertEqual(state.thread?.turnsNextCursor, "before-10")
        XCTAssertEqual(state.thread?.turns.last?.status, .completed)
    }

    /// A turn the provider no longer holds after the oldest of the page (a rollback) is gone.
    func testATurnThePageNoLongerHoldsIsRemoved() {
        var state = Self.state(turns: 11...30, cursor: "before-10")
        CodexTaskReducer().mergeNewestTurnPage(Self.page(turns: 24...28, cursor: "before-23"), into: &state)
        XCTAssertEqual(state.thread?.turns.map(\.id), (11...28).map { "turn-\($0)" })
        XCTAssertEqual(state.thread?.turnsNextCursor, "before-10")
    }

    /// A page that shares no turn with the loaded ones (more turns arrived than a page holds), or
    /// covers every loaded turn, starts the turns over from it with its cursor.
    func testAPageOverlappingNoLoadedTurnStartsOver() {
        var gap = Self.state(turns: 11...30, cursor: "before-10")
        CodexTaskReducer().mergeNewestTurnPage(Self.page(turns: 41...45, cursor: "before-40"), into: &gap)
        XCTAssertEqual(gap.thread?.turns.map(\.id), (41...45).map { "turn-\($0)" })
        XCTAssertEqual(gap.thread?.turnsNextCursor, "before-40")

        var covered = Self.state(turns: 28...30, cursor: "before-27")
        CodexTaskReducer().mergeNewestTurnPage(Self.page(turns: 27...31, cursor: "before-26"), into: &covered)
        XCTAssertEqual(covered.thread?.turns.map(\.id), (27...31).map { "turn-\($0)" })
        XCTAssertEqual(covered.thread?.turnsNextCursor, "before-26")
    }

    /// An older peer's request without `newestTurns` still reads the whole thread; a host that asks
    /// for a page sends the field.
    func testTheThreadReadParamsKeepOlderPeersReadingTheWholeThread() throws {
        let older = try JSONDecoder().decode(HarnessProtocolCodexThreadReadParams.self,
                                             from: Data(#"{"threadID":"t"}"#.utf8))
        XCTAssertNil(older.newestTurns)
        let paged = try JSONEncoder().encode(HarnessProtocolCodexThreadReadParams(threadID: "t", newestTurns: 5))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: paged)["newestTurns"], .integer(5))
        let whole = try JSONEncoder().encode(HarnessProtocolCodexThreadReadParams(threadID: "t"))
        XCTAssertNil(try JSONDecoder().decode(JSONValue.self, from: whole)["newestTurns"])
    }

    // MARK: - Fixtures

    private static func turn(_ index: Int) -> CodexTurnState {
        CodexTaskDecoder().turn(from: LongCodexThreadTransport.turn(index), fallbackID: "turn-\(index)")!
    }

    private static func state(turns: ClosedRange<Int>, cursor: String?) -> CodexTaskState {
        var thread = CodexTaskDecoder().thread(from: .object(["id": .string(threadID)]))!
        thread.turns = turns.map(turn)
        thread.turnsNextCursor = cursor
        return CodexTaskState(thread: thread)
    }

    private static func page(turns: ClosedRange<Int>, cursor: String?) -> CodexTurnPage {
        CodexTurnPage(turns: turns.map(turn), nextCursor: cursor, backwardsCursor: nil)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + testWaitLimit
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// A saved, detached Codex task behind the product route (the YHP Codex adapter over the App
    /// Server adapter) whose App Server holds a long thread.
    @MainActor
    struct LongThreadFixture {
        let transport: LongCodexThreadTransport
        let adapter: YHPCodexCompatibilityAdapter
        let model: AppModel
        let task: SessionRecord
        let rollout: URL

        init(turns: Int, in test: XCTestCase) throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "codex-paging-\(UUID().uuidString)")
            test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let executable = root.appending(path: "codex")
            try Data("#!/bin/sh\nprintf 'codex-cli 0.160.0\\n'\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            rollout = root.appending(path: "rollout.jsonl")
            try Data("{}\n".utf8).write(to: rollout)
            let transport = LongCodexThreadTransport(threadID: CodexDetachedThreadPagingTests.threadID,
                                                     turns: turns, rollout: rollout.path)
            self.transport = transport
            let adapter = YHPCodexCompatibilityAdapter(
                adapter: CodexAdapter(executableURL: executable, transport: transport),
                manifest: HarnessProtocolCompatibilityManifest.codex())
            self.adapter = adapter
            task = SessionRecord(harness: .codex, workspaceURL: root, runtimeExecutableURL: executable,
                title: "Long", status: .completed, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                providerSessionID: CodexDetachedThreadPagingTests.threadID)
            let suite = testDefaultsSuite("CodexPaging")
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let task = task
            let model = AppModel(
                store: SessionStore(sessions: [task], repository: InMemorySessionRepository(sessions: [task])),
                runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
                registry: HarnessRegistry { _, _ in adapter },
                modelCatalogs: HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
                    claudeConfigDirectory: root.appending(path: "claude"), codexHome: root.appending(path: "codex-home"),
                    codexYardletHome: root.appending(path: "codex-yardlet")), environment: [:]),
                codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
                preferences: defaults,
                codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
                codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
                codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
                transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
                restoresIndexOnLaunch: false)
            self.model = model
            test.addTeardownBlock { await model.shutdown() }
        }
    }
}

/// An App Server holding one long saved thread: `thread/read` with or without its turns, and
/// `thread/turns/list` pages newest first behind "before-<index>" cursors. It counts the bytes it
/// answers with.
actor LongCodexThreadTransport: CodexTransport {
    private let threadID: String
    private var turnCount: Int
    private let rollout: String
    private let stream: AsyncStream<CodexRawFrame>
    private(set) var requests: [CodexRPCRequest] = []
    private(set) var responseBytes: [Int] = []

    init(threadID: String, turns: Int, rollout: String) {
        self.threadID = threadID
        turnCount = turns
        self.rollout = rollout
        stream = AsyncStream { _ in }
    }

    /// A turn another app finished.
    func appendTurn() { turnCount += 1 }

    /// One finished turn with a request, a command and its output, and an answer: about 2 KB.
    static func turn(_ index: Int) -> JSONValue {
        .object([
            "id": .string("turn-\(index)"), "status": .string("completed"), "durationMs": .integer(4_000),
            "startedAt": .integer(1_700_000_000 + Int64(index) * 60), "completedAt": .integer(1_700_000_004 + Int64(index) * 60),
            "itemsView": .string("full"), "error": .null,
            "items": .array([
                .object(["id": .string("user-\(index)"), "type": .string("userMessage"),
                         "content": .array([.object(["type": .string("text"), "text": .string("Request \(index)")])])]),
                .object(["id": .string("command-\(index)"), "type": .string("commandExecution"),
                         "command": .string("swift test --filter Case\(index)"), "cwd": .string("/tmp/qa"),
                         "status": .string("completed"), "exitCode": .integer(0), "durationMs": .integer(1_200),
                         "aggregatedOutput": .string(String(repeating: "Test Case passed.\n", count: 90)),
                         "commandActions": .array([]), "processId": .null, "source": .string("agent")]),
                .object(["id": .string("answer-\(index)"), "type": .string("agentMessage"),
                         "text": .string("Answer \(index)"), "phase": .string("final_answer")])
            ])
        ])
    }

    func start() async throws {}

    func request(_ request: CodexRPCRequest) async throws -> CodexRPCIncomingMessage {
        requests.append(request)
        let result: JSONValue
        switch request.method {
        case "initialize":
            result = .object(["platformOs": .string("macos")])
        case "thread/read":
            let turns: [JSONValue] = request.params["includeTurns"] == .bool(true) ? (1...turnCount).map(Self.turn) : []
            result = .object(["thread": .object([
                "id": .string(threadID), "status": .object(["type": .string("notLoaded")]),
                "historyMode": .string("paginated"), "cwd": .string("/tmp/qa"), "preview": .string("Request 1"),
                "path": .string(rollout), "turns": .array(turns)
            ])])
        case "thread/turns/list":
            guard request.params["sortDirection"] == .string("desc"),
                  let limit = request.params["limit"]?.integerValue else {
                throw HarnessAdapterError.invalidProviderEvent("Unexpected turn page request")
            }
            let end = request.params["cursor"]?.stringValue.flatMap { Int($0.dropFirst("before-".count)) } ?? turnCount
            let start = max(0, end - Int(limit))
            result = .object([
                "data": .array((start..<end).reversed().map { Self.turn($0 + 1) }),
                "nextCursor": start > 0 ? .string("before-\(start)") : .null,
                "backwardsCursor": .string("after-\(end)")
            ])
        default:
            throw HarnessAdapterError.invalidProviderEvent("Unexpected \(request.method)")
        }
        responseBytes.append(try JSONEncoder().encode(result).count)
        return CodexRPCIncomingMessage(id: request.id, method: nil, params: nil, result: result, error: nil, emittedAtMs: nil)
    }

    func sendResponse(_ response: CodexRPCResponse) async throws {}
    func sendErrorResponse(_ response: CodexRPCErrorResponse) async throws {}
    func notifications() async -> AsyncStream<CodexRawFrame> { stream }
    func stop() async {}
}
