import Foundation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The suggested next message after a turn: Claude Code's `prompt_suggestion` asked for per process
/// and carried to the composer (Codex's prediction is in `CodexMessagePredictionTests`), the draft's
/// rules (shown while nothing is typed, typing lets it go, Tab or → takes it, never sent or kept) and
/// the setting.
/// Fixtures are the frames CLI 2.1.299 writes (`qF` in its SDK schema); no CLI or model runs.
final class NextMessageSuggestionTests: XCTestCase {
    // MARK: - Claude Code stream-json

    /// `{type:"prompt_suggestion", suggestion, uuid, session_id}` as the 2.1.299 SDK schema has it.
    private static let suggestionFrame: JSONValue = .object([
        "type": .string("prompt_suggestion"),
        "suggestion": .string("run the tests"),
        "uuid": .string("6f1d1f39-6a0b-4c55-9b44-0d7a3c1f9e21"),
        "session_id": .string("session-1")
    ])

    private static let resultFrame: JSONValue = .object([
        "type": .string("result"), "subtype": .string("success"), "is_error": .bool(false),
        "result": .string("Fixed."), "session_id": .string("session-1")
    ])

    func testTheInitializeRequestAsksOnlyWhenTheSettingIsOn() {
        let plain = ClaudeProtocol.initialize(id: "init-1")
        XCTAssertEqual(plain["request"]?.objectValue?.keys.sorted(), ["hooks", "subtype"],
                       "Without the setting the request is the one every session sent")
        let asked = ClaudeProtocol.initialize(id: "init-1", promptSuggestions: true)
        XCTAssertEqual(asked["type"]?.stringValue, "control_request")
        XCTAssertEqual(asked["request_id"]?.stringValue, "init-1")
        XCTAssertEqual(asked["request"]?["subtype"]?.stringValue, "initialize")
        XCTAssertEqual(asked["request"]?["hooks"], .null)
        XCTAssertEqual(asked["request"]?["promptSuggestions"], .bool(true))
    }

    func testThePromptSuggestionFrameIsReadAndOthersAreNot() {
        XCTAssertEqual(ClaudeProtocol.promptSuggestion(in: Self.suggestionFrame), "run the tests")

        func frame(_ suggestion: JSONValue, parent: JSONValue = .null, type: String = "prompt_suggestion") -> JSONValue {
            .object(["type": .string(type), "suggestion": suggestion, "parent_tool_use_id": parent,
                     "uuid": .string("u"), "session_id": .string("s")])
        }
        XCTAssertEqual(ClaudeProtocol.promptSuggestion(in: frame(.string("  commit this \n"))), "commit this",
                       "Surrounding space is trimmed")
        XCTAssertNil(ClaudeProtocol.promptSuggestion(in: frame(.string(""))))
        XCTAssertNil(ClaudeProtocol.promptSuggestion(in: frame(.string("   "))))
        XCTAssertNil(ClaudeProtocol.promptSuggestion(in: frame(.string("run the tests\nthen commit"))),
                     "One line only: the chip and the composer take a single message")
        XCTAssertNil(ClaudeProtocol.promptSuggestion(in: frame(.string(String(repeating: "a", count: 301)))))
        XCTAssertNil(ClaudeProtocol.promptSuggestion(in: frame(.null)))
        XCTAssertNil(ClaudeProtocol.promptSuggestion(in: frame(.string("x y"), parent: .string("toolu_1"))),
                     "A subagent's frame is not the conversation's")
        XCTAssertNil(ClaudeProtocol.promptSuggestion(in: frame(.string("x y"), type: "assistant")))
    }

    func testTheProjectionCarriesTheSuggestionAndNothingElse() {
        var projection = ClaudeSessionProjection()
        XCTAssertEqual(projection.payloads(from: Self.suggestionFrame), [.nextMessageSuggestion("run the tests")])
        XCTAssertEqual(projection.payloads(from: .object([
            "type": .string("prompt_suggestion"), "suggestion": .string(""), "session_id": .string("s")
        ])), [], "An empty suggestion is no payload")
    }

    func testTheAdapterAsksPerSessionAndPassesTheSuggestionOn() async throws {
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"),
                                    transportFactory: { _ in transport }, asksForNextMessageSuggestions: { true })
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/workspace"), initialPrompt: nil))
        let requested = await transport.requestedValues
        let initialize = try XCTUnwrap(requested.first)
        XCTAssertEqual(initialize["request"]?["subtype"]?.stringValue, "initialize")
        XCTAssertEqual(initialize["request"]?["promptSuggestions"], .bool(true))
        let configuration = await transport.configuration
        XCTAssertFalse(ClaudeProcessTransport.arguments(for: try XCTUnwrap(configuration))
            .contains("--prompt-suggestions"), "The ask is the handshake's, not a launch flag an older CLI refuses")

        let recorder = PayloadRecorder()
        let received = expectation(description: "the suggestion arrives")
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
                if case .nextMessageSuggestion = event.payload { received.fulfill(); break }
            }
        }
        try await adapter.send("fix the bug", to: handle)
        await transport.emit(Self.resultFrame)
        await transport.emit(Self.suggestionFrame)
        await fulfillment(of: [received], timeout: 2)
        collector.cancel()
        let payloads = await recorder.payloads
        let turnEnd = try XCTUnwrap(payloads.firstIndex(of: .turnCompleted))
        let suggestion = try XCTUnwrap(payloads.firstIndex(of: .nextMessageSuggestion("run the tests")))
        XCTAssertLessThan(turnEnd, suggestion)
        XCTAssertEqual(payloads.last, .nextMessageSuggestion("run the tests"),
                       "The suggestion changes no status: the task stays ready")
        let sent = await transport.sentValues
        XCTAssertEqual(sent.compactMap { $0["message"]?["content"]?.stringValue }, ["fix the bug"],
                       "Nothing is sent for it")
    }

    func testTheSettingOffOrASubagentLaunchDoesNotAsk() async throws {
        let transport = FakeClaudeTransport()
        let off = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"),
                                transportFactory: { _ in transport }, asksForNextMessageSuggestions: { false })
        _ = try await off.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/workspace"), initialPrompt: nil))
        let unaskedValues = await transport.requestedValues
        let unasked = try XCTUnwrap(unaskedValues.first)
        XCTAssertNil(unasked["request"]?["promptSuggestions"])

        let subagentTransport = FakeClaudeTransport()
        let on = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"),
                               transportFactory: { _ in subagentTransport }, asksForNextMessageSuggestions: { true })
        let subagentID = UUID()
        await on.setLaunchOptions([ClaudeLaunchOption.nextMessageSuggestions: ClaudeLaunchOption.off], for: subagentID)
        _ = try await on.createSession(CreateHarnessSessionRequest(
            localSessionID: subagentID, workspaceURL: URL(filePath: "/tmp/workspace"), initialPrompt: nil))
        let subagentValues = await subagentTransport.requestedValues
        let subagent = try XCTUnwrap(subagentValues.first)
        XCTAssertNil(subagent["request"]?["promptSuggestions"], "No one types into a subagent")
    }

    func testTheSuggestionCrossesTheProductRoute() {
        XCTAssertEqual(LegacyProviderStatusExtension.payload(
            name: LegacyProviderStatusExtension.nextMessageSuggestion, value: .object(["text": .string("push it")])),
            .nextMessageSuggestion("push it"))
        XCTAssertNil(LegacyProviderStatusExtension.payload(
            name: LegacyProviderStatusExtension.nextMessageSuggestion, value: .object([:])))
    }

    // MARK: - Codex App Server

    /// A Codex turn's end is the turn's end and nothing more: the prediction the Codex app makes
    /// comes from a turn of its own on an ephemeral fork, a moment later (`CodexMessagePredictionTests`).
    func testACodexTurnEndCarriesNoSuggestion() throws {
        let fixture = Data(#"{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed","items":[]}}}"#.utf8)
        let message = try CodexRPCCodec().decodeLine(fixture)
        let envelope = try XCTUnwrap(CodexEventProjector().project(message, rawData: fixture,
                                                                   localSessionID: UUID(), sequence: 0))
        XCTAssertEqual(envelope.payload, .turnCompleted)
    }

    // MARK: - The draft

    @MainActor func testTheDraftShowsTheSuggestionOnlyWhileNothingIsTypedAndNoTurnRuns() {
        let draft = TaskComposerDraft()
        XCTAssertNil(draft.shownNextMessageSuggestion(isEnabled: true, isRunning: false))
        draft.nextMessageSuggestion = "run the tests"
        XCTAssertEqual(draft.shownNextMessageSuggestion(isEnabled: true, isRunning: false), "run the tests")
        XCTAssertNil(draft.shownNextMessageSuggestion(isEnabled: false, isRunning: false), "The setting is off")
        XCTAssertNil(draft.shownNextMessageSuggestion(isEnabled: true, isRunning: true), "A turn runs")
        draft.isBashMode = true
        XCTAssertNil(draft.shownNextMessageSuggestion(isEnabled: true, isRunning: false), "Bash mode")
        draft.isBashMode = false
        let session = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Test", providerSessionID: UUID().uuidString)
        draft.editState = ConversationEditState(session: session, targetID: UUID().uuidString, previousID: nil,
            originalText: "Earlier", draft: .init(text: ""), entries: [])
        XCTAssertNil(draft.shownNextMessageSuggestion(isEnabled: true, isRunning: false), "An edit of an earlier message")
        draft.editState = nil
        XCTAssertEqual(draft.nextMessageSuggestion, "run the tests", "Hiding it is not letting it go")
    }

    @MainActor func testTypingLetsTheSuggestionGoAndTakingItPutsItInTheText() {
        let draft = TaskComposerDraft()
        draft.nextMessageSuggestion = "run the tests"
        draft.text = "c"
        XCTAssertNil(draft.nextMessageSuggestion, "Typing lets it go")
        draft.text = ""
        XCTAssertNil(draft.shownNextMessageSuggestion(isEnabled: true, isRunning: false), "and it does not come back")

        draft.nextMessageSuggestion = "commit this"
        XCTAssertNil(draft.takeNextMessageSuggestion(isEnabled: true, isRunning: true), "Not while a turn runs")
        XCTAssertNil(draft.takeNextMessageSuggestion(isEnabled: false, isRunning: false), "Not with the setting off")
        XCTAssertEqual(draft.text, "")
        XCTAssertEqual(draft.takeNextMessageSuggestion(isEnabled: true, isRunning: false), "commit this")
        XCTAssertEqual(draft.text, "commit this")
        XCTAssertNil(draft.nextMessageSuggestion, "Taken, it is the text now")
        XCTAssertNil(draft.takeNextMessageSuggestion(isEnabled: true, isRunning: false), "Nothing is left to take")

        draft.text = ""
        draft.nextMessageSuggestion = "push it"
        draft.clear()
        XCTAssertNil(draft.nextMessageSuggestion, "A sent message lets it go")
    }

    @MainActor func testTheSuggestionIsNeverPartOfTheSavedDraft() throws {
        let draft = TaskComposerDraft()
        var changes = 0
        draft.onChange = { changes += 1 }
        draft.nextMessageSuggestion = "run the tests"
        XCTAssertEqual(changes, 0, "A suggestion arriving saves nothing")
        XCTAssertTrue(draft.snapshot.isEmpty, "The saved draft has no trace of it")
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(draft.snapshot), encoding: .utf8))
        XCTAssertFalse(encoded.contains("run the tests"))
    }

    // MARK: - Tab

    func testTabTakesTheSuggestionOnlyAsAPlainKeyWithNoComposition() {
        var taken = 0
        let take = { taken += 1; return true }
        XCTAssertTrue(ComposerTypedLists.takesSuggestion(modifiers: [], isRepeat: false, hasMarkedText: false, take: take))
        XCTAssertEqual(taken, 1)
        XCTAssertFalse(ComposerTypedLists.takesSuggestion(modifiers: [], isRepeat: false, hasMarkedText: true, take: take),
                       "A Korean syllable being composed keeps Tab")
        XCTAssertFalse(ComposerTypedLists.takesSuggestion(modifiers: .shift, isRepeat: false, hasMarkedText: false, take: take))
        XCTAssertFalse(ComposerTypedLists.takesSuggestion(modifiers: .option, isRepeat: false, hasMarkedText: false, take: take))
        XCTAssertFalse(ComposerTypedLists.takesSuggestion(modifiers: .command, isRepeat: false, hasMarkedText: false, take: take))
        XCTAssertFalse(ComposerTypedLists.takesSuggestion(modifiers: [], isRepeat: true, hasMarkedText: false, take: take))
        XCTAssertEqual(taken, 1, "None of those asked the composer")
        XCTAssertTrue(ComposerTypedLists.takesSuggestion(modifiers: .capsLock, isRepeat: false, hasMarkedText: false, take: take),
                      "Caps Lock does not count")
        XCTAssertFalse(ComposerTypedLists.takesSuggestion(modifiers: [], isRepeat: false, hasMarkedText: false, take: { false }),
                       "With nothing to take, Tab moves focus as before")
        XCTAssertFalse(ComposerTypedLists.takesSuggestion(modifiers: [], isRepeat: false, hasMarkedText: false, take: nil))
    }

    // MARK: - The setting

    func testTheSettingIsOnUntilTurnedOff() throws {
        let suite = testDefaultsSuite("NextMessageSuggestion")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertTrue(NextMessageSuggestionPreference.isOn(in: defaults), "On, as the Claude app's is")
        defaults.set(false, forKey: NextMessageSuggestionPreference.key)
        XCTAssertFalse(NextMessageSuggestionPreference.isOn(in: defaults))
        defaults.set(true, forKey: NextMessageSuggestionPreference.key)
        XCTAssertTrue(NextMessageSuggestionPreference.isOn(in: defaults))
    }

    func testTheSettingReadsInBothLanguages() {
        XCTAssertEqual(L10n.string("Next message suggestions", languageCode: "ko"), "다음 메시지 추천")
        XCTAssertNotEqual(L10n.string("Puts this message in the message box without sending it", languageCode: "ko"),
                          "Puts this message in the message box without sending it")
    }
}

private actor PayloadRecorder {
    private(set) var payloads: [HarnessEventPayload] = []
    func append(_ payload: HarnessEventPayload) { payloads.append(payload) }
}

/// The suggestion through the app model on the product route to a fake Claude Code: it waits in
/// the task's draft after the turn ends, the next send or turn lets it go, and one that arrives
/// once the next turn is running is dropped.
@MainActor final class NextMessageSuggestionAppModelTests: XCTestCase {
    func testTheSuggestionWaitsInTheDraftUntilTheNextTurn() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model, task = fixture.task, transport = fixture.transport
        let requested = await transport.requestedValues
        let initialize = try XCTUnwrap(requested.first)
        XCTAssertEqual(initialize["request"]?["promptSuggestions"], .bool(true))

        await transport.emit(try json(#"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s"}"#))
        try await waitUntil { model.store.sessions.first?.status == .ready }
        await transport.emit(try json(#"{"type":"prompt_suggestion","suggestion":"run the tests","uuid":"u1","session_id":"s"}"#))
        let draft = model.composerDrafts.tasks.draft(for: task.id)
        try await waitUntil { draft.nextMessageSuggestion == "run the tests" }
        XCTAssertFalse(model.transcriptBySessionID[task.id]?.contains {
            if case let .assistant(text, _) = $0.content { return text.contains("run the tests") }
            if case let .user(text, _) = $0.content { return text.contains("run the tests") }
            return false
        } ?? false, "It never joins the conversation")
        XCTAssertTrue(draft.snapshot.isEmpty, "Nor the saved draft")
        let sentBefore = await transport.sentValues.count

        await model.send(HarnessUserInput(text: "Explain the fix first"), to: task)
        XCTAssertNil(draft.nextMessageSuggestion, "Sending something else lets it go")
        let sent = await transport.sentValues.dropFirst(sentBefore).compactMap { $0["message"]?["content"]?.stringValue }
        XCTAssertEqual(sent, ["Explain the fix first"], "The suggestion itself was never sent")

        // A suggestion written just before the CLI read the new message arrives late: it is dropped.
        try await waitUntil { model.store.sessions.first?.status == .running }
        await transport.emit(try json(#"{"type":"prompt_suggestion","suggestion":"commit this","uuid":"u2","session_id":"s"}"#))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(draft.nextMessageSuggestion)

        await transport.emit(try json(#"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s"}"#))
        try await waitUntil { model.store.sessions.first?.status == .ready }
        await transport.emit(try json(#"{"type":"prompt_suggestion","suggestion":"commit this","uuid":"u3","session_id":"s"}"#))
        try await waitUntil { draft.nextMessageSuggestion == "commit this" }
        // A turn the CLI starts by itself (a background command finished) lets it go too.
        await transport.emit(try json(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"The build finished."}]},"session_id":"s"}"#))
        try await waitUntil { draft.nextMessageSuggestion == nil }
    }

    // MARK: - Fixture

    private struct Fixture {
        let model: AppModel
        let task: SessionRecord
        let transport: FakeClaudeTransport
    }

    private final class TransportLog: @unchecked Sendable {
        private let lock = NSLock()
        private var transports: [FakeClaudeTransport] = []
        func make() -> FakeClaudeTransport {
            let transport = FakeClaudeTransport()
            lock.withLock { transports.append(transport) }
            return transport
        }
        var all: [FakeClaudeTransport] { lock.withLock { transports } }
    }

    /// A Claude task on the product route whose first turn is running.
    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "next-message-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cli = root.appending(path: "claude-fixture")
        try Data("""
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo '2.1.299 (Claude Code)'; exit 0; fi

        """.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let workspace = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let suite = testDefaultsSuite("NextMessageSuggestionAppModel")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let transports = TransportLog()
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, url in
                YHPProviderCompatibilityAdapter(
                    adapter: ClaudeAdapter(executableURL: url, transportFactory: { _ in transports.make() },
                                           asksForNextMessageSuggestions: { true }),
                    manifest: HarnessProtocolCompatibilityManifest.claude()
                )
            },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults, keyPrefix: "transcript."),
            restoresIndexOnLaunch: false
        )
        addTeardownBlock { await model.shutdown() }
        let created = await model.createSession(harness: .claudeCode, workspaceURL: workspace,
                                                runtimeExecutableURL: cli, title: "Suggestion")
        let task = try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Missing task")
        let transport = try XCTUnwrap(transports.all.first)
        await model.send(HarnessUserInput(text: "Fix the bug"), to: task)
        try await waitUntil { model.store.sessions.first?.status == .running }
        return Fixture(model: model, task: try XCTUnwrap(model.store.sessions.first), transport: transport)
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}
