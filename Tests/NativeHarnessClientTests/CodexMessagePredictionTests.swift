import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// A Codex task's next-message prediction, made the way the Codex app 26.1013 makes it: after each
/// turn of a saved thread, `thread/prediction/request` first (App Server 0.163 answers it `-32601
/// "thread/prediction/request is not implemented yet"`, checked against the real binary), then the
/// app's own path — an ephemeral `experimentalPredictionMode` fork with one short turn whose final
/// message is `{"suggestion": …}`. The answer reaches the task as `.nextMessageSuggestion`. Fixtures
/// follow the 0.163 experimental schema (`generate-json-schema --experimental`); no CLI or model runs.
final class CodexMessagePredictionTests: XCTestCase {
    /// `initialize`'s `userAgent` as App Server 0.163.0 writes it.
    static let userAgent = "native-harness-client/0.163.0 (Mac OS 27.0.0; arm64) unknown (native-harness-client; 0.0.1)"
    static let unimplemented: JSONValue = .object([
        "code": .integer(-32601), "message": .string("thread/prediction/request is not implemented yet")
    ])

    // MARK: - Protocol

    func testTheRequestAndTheForkAreTheShapesTheSchemaAndTheAppUse() throws {
        let request = CodexMessagePrediction.request(id: 7, threadID: "thread-1", sourceTurnID: "turn-1")
        XCTAssertEqual(request.method, "thread/prediction/request")
        XCTAssertEqual(request.params, .object(["threadId": .string("thread-1"), "sourceTurnId": .string("turn-1")]),
                       "ThreadPredictionRequestParams: threadId and sourceTurnId, both required")
        XCTAssertEqual(try JSONDecoder().decode(CodexRPCRequest.self, from: JSONEncoder().encode(request)), request,
                       "It goes over the wire as it is")

        let fork = CodexMessagePrediction.forkThread(id: 8, threadID: "thread-1")
        XCTAssertEqual(fork.method, "thread/fork")
        XCTAssertEqual(fork.params, .object([
            "threadId": .string("thread-1"), "experimentalPredictionMode": .bool(true), "ephemeral": .bool(true),
            "excludeTurns": .bool(true), "threadSource": .string("composer_predictions")
        ]), "The app's fork: no overrides, which prediction mode refuses")

        let turn = CodexMessagePrediction.startTurn(id: 9, forkThreadID: "prediction-1", sourceThreadID: "thread-1",
                                                    sourceTurnID: "turn-1", effort: "low", clientUserMessageID: "m-1")
        XCTAssertEqual(turn.method, "turn/start")
        XCTAssertEqual(turn.params["threadId"]?.stringValue, "prediction-1")
        XCTAssertEqual(turn.params["turnTrigger"]?.stringValue, "composer_predictions")
        XCTAssertEqual(turn.params["clientUserMessageId"]?.stringValue, "m-1")
        XCTAssertEqual(turn.params["effort"]?.stringValue, "low")
        XCTAssertEqual(turn.params["responsesapiClientMetadata"], .object([
            "prediction_source_thread_id": .string("thread-1"), "prediction_source_turn_id": .string("turn-1"),
            "prediction_trigger": .string("live")
        ]))
        XCTAssertNil(turn.params["outputSchema"], "As in the app, the schema rides in the prompt")
        XCTAssertNil(turn.params["model"], "The fork keeps the thread's model")
        let input = try XCTUnwrap(turn.params["input"]?.arrayValue?.first)
        XCTAssertEqual(input["type"]?.stringValue, "text")
        XCTAssertTrue(input["text"]?.stringValue?.hasSuffix(
            "Return only JSON matching this schema: \(CodexMessagePrediction.responseSchema).") == true)
        XCTAssertNil(CodexMessagePrediction.startTurn(id: 9, forkThreadID: "p", sourceThreadID: "t", sourceTurnID: "u",
                                                      effort: nil).params["effort"])
    }

    func testTheUpdateNotificationIsReadAsTheSchemaHasIt() throws {
        let completed = try decode(#"{"method":"thread/prediction/updated","params":{"threadId":"thread-1","sourceTurnId":"turn-1","result":{"type":"completed","text":"Run the tests"}}}"#)
        XCTAssertEqual(CodexMessagePrediction.update(from: completed.params),
                       .init(threadID: "thread-1", sourceTurnID: "turn-1", result: .completed(text: "Run the tests")))
        let abstained = try decode(#"{"method":"thread/prediction/updated","params":{"threadId":"thread-1","sourceTurnId":"turn-1","result":{"type":"completed","text":null}}}"#)
        XCTAssertEqual(CodexMessagePrediction.update(from: abstained.params)?.result, .completed(text: nil))
        let failed = try decode(#"{"method":"thread/prediction/updated","params":{"threadId":"thread-1","sourceTurnId":"turn-1","result":{"type":"failed"}}}"#)
        XCTAssertEqual(CodexMessagePrediction.update(from: failed.params)?.result, .failed)
        let unknown = try decode(#"{"method":"thread/prediction/updated","params":{"threadId":"thread-1","sourceTurnId":"turn-1","result":{"type":"pending"}}}"#)
        XCTAssertNil(CodexMessagePrediction.update(from: unknown.params), "An unknown result type is no update")
        let partial = try decode(#"{"method":"thread/prediction/updated","params":{"threadId":"thread-1","result":{"type":"completed","text":"x"}}}"#)
        XCTAssertNil(CodexMessagePrediction.update(from: partial.params), "sourceTurnId is required")
    }

    func testOnlyAMissingMethodSendsTheTaskToTheFork() {
        XCTAssertTrue(CodexMessagePrediction.isUnimplemented(CodexRPCRequestFailure(requestID: 1, payload: Self.unimplemented)))
        XCTAssertTrue(CodexMessagePrediction.isUnimplemented(CodexRPCRequestFailure(requestID: 1, payload: .object([
            "code": .integer(-32600), "message": .string("unknown variant `thread/prediction/request`")]))))
        XCTAssertFalse(CodexMessagePrediction.isUnimplemented(CodexRPCRequestFailure(requestID: 1, payload: .object([
            "code": .integer(-32600), "message": .string("thread not loaded")]))))
    }

    func testTheForkModeNeedsTheAppServerThatHasIt() {
        XCTAssertEqual(CodexMessagePrediction.appServerVersion(fromUserAgent: Self.userAgent), "0.163.0")
        XCTAssertEqual(CodexMessagePrediction.appServerVersion(
            fromUserAgent: "prediction-probe/0.163.0 (Mac OS 27.0.0; arm64) unknown (prediction-probe; 0.0.1)"), "0.163.0")
        XCTAssertNil(CodexMessagePrediction.appServerVersion(fromUserAgent: nil))
        XCTAssertNil(CodexMessagePrediction.appServerVersion(fromUserAgent: "codex"))
        XCTAssertTrue(CodexMessagePrediction.supportsForkMode(appServerVersion: "0.163.0"))
        XCTAssertTrue(CodexMessagePrediction.supportsForkMode(appServerVersion: "0.162.0"))
        XCTAssertTrue(CodexMessagePrediction.supportsForkMode(appServerVersion: "0.162.0-alpha.20"))
        XCTAssertFalse(CodexMessagePrediction.supportsForkMode(appServerVersion: "0.162.0-alpha.19"))
        XCTAssertFalse(CodexMessagePrediction.supportsForkMode(appServerVersion: "0.161.2"))
        XCTAssertFalse(CodexMessagePrediction.supportsForkMode(appServerVersion: nil))
    }

    func testTheSuggestionIsReadFromTheWholeFinalMessage() {
        XCTAssertEqual(CodexMessagePrediction.suggestion(fromFinalMessage: #" {"suggestion":"  Run the tests again "} "#), "Run the tests again")
        XCTAssertNil(CodexMessagePrediction.suggestion(fromFinalMessage: #"{"suggestion":null}"#), "The model abstained")
        XCTAssertNil(CodexMessagePrediction.suggestion(fromFinalMessage: "Run the tests"), "Not the JSON")
        XCTAssertNil(CodexMessagePrediction.suggestion(fromFinalMessage: #"{"suggestion":"Run\nthe tests"}"#), "One line only")
        XCTAssertNil(CodexMessagePrediction.suggestion(fromFinalMessage: nil))
        XCTAssertEqual(CodexMessagePrediction.effort(for: model(efforts: ["low", "medium"])), "low")
        XCTAssertNil(CodexMessagePrediction.effort(for: model(efforts: ["medium", "high"])), "Keeps the thread's effort")
        XCTAssertNil(CodexMessagePrediction.effort(for: nil))
    }

    // MARK: - The adapter

    func testAfterATurnTheAdapterForksThreadAndShowsWhatItPredicts() async throws {
        let transport = Self.scriptedTransport()
        let adapter = predictingAdapter(transport)
        let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/sandbox"),
                                                           initialPrompt: nil))
        let recorder = CodexPredictionEventRecorder(adapter: adapter, handle: handle)
        await recorder.start()

        try await adapter.send("Fix the failing test", to: handle)
        await Self.finishTurn("turn-1", on: transport)
        try await waitUntil { await transport.requestMethods.filter { $0 == "turn/start" }.count == 2 }

        let requests = await transport.requests
        XCTAssertEqual(Array(requests.map(\.method).drop { $0 != "turn/start" }), [
            "turn/start", "thread/prediction/request", "thread/fork", "model/list", "turn/start"
        ])
        let asked = try XCTUnwrap(requests.first { $0.method == "thread/prediction/request" })
        XCTAssertEqual(asked.params, .object(["threadId": .string("thread-1"), "sourceTurnId": .string("turn-1")]))
        let fork = try XCTUnwrap(requests.first { $0.method == "thread/fork" })
        XCTAssertEqual(fork.params["experimentalPredictionMode"], .bool(true))
        XCTAssertEqual(fork.params["ephemeral"], .bool(true))
        XCTAssertEqual(fork.params["threadId"]?.stringValue, "thread-1")
        let predictionTurn = try XCTUnwrap(requests.last { $0.method == "turn/start" })
        XCTAssertEqual(predictionTurn.params["threadId"]?.stringValue, "prediction-1")
        XCTAssertEqual(predictionTurn.params["effort"]?.stringValue, "low", "The thread's model offers low")
        XCTAssertEqual(predictionTurn.params["responsesapiClientMetadata"]?["prediction_source_turn_id"]?.stringValue, "turn-1")

        await Self.finishPrediction(thread: "prediction-1", turn: "p-turn-1", message: #"{"suggestion":"Run the whole test suite"}"#,
                               on: transport)
        try await waitUntil { await recorder.payloads.contains(.nextMessageSuggestion("Run the whole test suite")) }
        try await waitUntil { await transport.requestMethods.contains("thread/unsubscribe") }
        let afterFirst = await transport.requests
        XCTAssertEqual(afterFirst.last { $0.method == "thread/unsubscribe" }?.params["threadId"]?.stringValue, "prediction-1")
        XCTAssertFalse(afterFirst.contains { $0.method == "turn/interrupt" }, "It ended by itself")
        let state = try await adapter.presentationState(for: handle)
        XCTAssertEqual(state.thread?.turns.map(\.id), ["turn-1"], "The fork's turn never reaches the task")
        let sent = afterFirst.filter { $0.method == "turn/start" && $0.params["threadId"]?.stringValue == "thread-1" }
        XCTAssertEqual(sent.count, 1, "Nothing is sent for it")

        // The runtime said it has no request, so the next turn forks straight away; the model list is kept.
        try await adapter.send("Run the whole test suite", to: handle)
        await Self.finishTurn("turn-2", on: transport)
        try await waitUntil { await transport.requestMethods.filter { $0 == "turn/start" }.count == 4 }
        let methods = await transport.requestMethods
        XCTAssertEqual(methods.filter { $0 == "thread/prediction/request" }.count, 1)
        XCTAssertEqual(methods.filter { $0 == "thread/fork" }.count, 2)
        XCTAssertEqual(methods.filter { $0 == "model/list" }.count, 1)
        await Self.finishPrediction(thread: "prediction-2", turn: "p-turn-2", message: #"{"suggestion":null}"#, on: transport)
        try await waitUntil { await transport.requestMethods.filter { $0 == "thread/unsubscribe" }.count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        let suggestions = await recorder.payloads.filter { if case .nextMessageSuggestion = $0 { true } else { false } }
        XCTAssertEqual(suggestions, [.nextMessageSuggestion("Run the whole test suite")], "A null prediction shows nothing")
        let errors = await recorder.payloads.filter { if case .error = $0 { true } else { false } }
        XCTAssertTrue(errors.isEmpty)
        await recorder.stop()
        await adapter.close(handle)
    }

    func testARuntimeThatAnswersTheRequestDeliversThroughItsNotification() async throws {
        let transport = Self.scriptedTransport(predictionRequests: 2)
        let adapter = predictingAdapter(transport)
        let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/sandbox"),
                                                           initialPrompt: nil))
        let recorder = CodexPredictionEventRecorder(adapter: adapter, handle: handle)
        await recorder.start()

        try await adapter.send("Fix the failing test", to: handle)
        await Self.finishTurn("turn-1", on: transport)
        try await waitUntil { await transport.requestMethods.contains("thread/prediction/request") }
        await transport.emit(method: "thread/prediction/updated", params: update(turn: "turn-0", text: "An older turn's"))
        await transport.emit(method: "thread/prediction/updated", params: .object([
            "threadId": .string("thread-1"), "sourceTurnId": .string("turn-1"), "result": .object(["type": .string("pending")])]))
        await transport.emit(method: "thread/prediction/updated", params: .object([
            "threadId": .string("thread-1"), "sourceTurnId": .string("turn-1"), "result": .object(["type": .string("failed")])]))
        await transport.emit(method: "thread/prediction/updated", params: update(turn: "turn-1", text: "Too late after the failure"))
        try await Task.sleep(for: .milliseconds(80))
        var payloads = await recorder.payloads
        XCTAssertFalse(payloads.contains { if case .nextMessageSuggestion = $0 { true } else { false } },
                       "A stale, unknown, or failed result shows nothing")
        XCTAssertFalse(payloads.contains { if case .error = $0 { true } else { false } }, "and reports nothing")

        try await adapter.send("Explain the fix", to: handle)
        await Self.finishTurn("turn-2", on: transport)
        try await waitUntil { await transport.requestMethods.filter { $0 == "thread/prediction/request" }.count == 2 }
        await transport.emit(method: "thread/prediction/updated", params: update(turn: "turn-2", text: "  Commit the fix "))
        try await waitUntil { await recorder.payloads.contains(.nextMessageSuggestion("Commit the fix")) }
        let methods = await transport.requestMethods
        XCTAssertFalse(methods.contains("thread/fork"), "The runtime predicts; nothing is forked")
        payloads = await recorder.payloads
        XCTAssertFalse(payloads.contains { if case .error = $0 { true } else { false } })
        await recorder.stop()
        await adapter.close(handle)
    }

    func testANewTurnStopsThePredictionAndDropsItsAnswer() async throws {
        let transport = Self.scriptedTransport()
        let adapter = predictingAdapter(transport)
        let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/sandbox"),
                                                           initialPrompt: nil))
        let recorder = CodexPredictionEventRecorder(adapter: adapter, handle: handle)
        await recorder.start()
        try await adapter.send("Fix the failing test", to: handle)
        await Self.finishTurn("turn-1", on: transport)
        try await waitUntil { await transport.requestMethods.filter { $0 == "turn/start" }.count == 2 }
        await transport.emit(method: "turn/started", params: .object(["threadId": .string("prediction-1"),
            "turn": .object(["id": .string("p-turn-1"), "status": .string("inProgress"), "items": .array([])])]))

        // The person (or a queued follow-up) starts the next turn before the prediction is back.
        await transport.emit(method: "turn/started", params: .object(["threadId": .string("thread-1"),
            "turn": .object(["id": .string("turn-2"), "status": .string("inProgress"), "items": .array([])])]))
        try await waitUntil { await transport.requestMethods.contains("thread/unsubscribe") }
        let requests = await transport.requests
        let interrupt = try XCTUnwrap(requests.first { $0.method == "turn/interrupt" })
        XCTAssertEqual(interrupt.params, .object(["threadId": .string("prediction-1"), "turnId": .string("p-turn-1")]))

        await Self.finishPrediction(thread: "prediction-1", turn: "p-turn-1", message: #"{"suggestion":"Too late"}"#,
                               on: transport, startsTurn: false)
        try await Task.sleep(for: .milliseconds(80))
        let payloads = await recorder.payloads
        XCTAssertFalse(payloads.contains { if case .nextMessageSuggestion = $0 { true } else { false } })
        await recorder.stop()
        await adapter.close(handle)
    }

    func testAFailedOrActingPredictionShowsNothing() async throws {
        let transport = Self.scriptedTransport()
        let adapter = predictingAdapter(transport)
        let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/sandbox"),
                                                           initialPrompt: nil))
        let recorder = CodexPredictionEventRecorder(adapter: adapter, handle: handle)
        await recorder.start()
        try await adapter.send("Fix the failing test", to: handle)
        await Self.finishTurn("turn-1", on: transport)
        try await waitUntil { await transport.requestMethods.filter { $0 == "turn/start" }.count == 2 }
        await Self.finishPrediction(thread: "prediction-1", turn: "p-turn-1", message: #"{"suggestion":"Unseen"}"#,
                               on: transport, status: "failed")
        try await waitUntil { await transport.requestMethods.contains("thread/unsubscribe") }

        // The model runs a command instead of predicting: the turn is stopped at once.
        try await adapter.send("Try again", to: handle)
        await Self.finishTurn("turn-2", on: transport)
        try await waitUntil { await transport.requestMethods.filter { $0 == "turn/start" }.count == 4 }
        await transport.emit(method: "turn/started", params: .object(["threadId": .string("prediction-2"),
            "turn": .object(["id": .string("p-turn-2"), "status": .string("inProgress"), "items": .array([])])]))
        await transport.emit(method: "item/started", params: .object(["threadId": .string("prediction-2"),
            "turnId": .string("p-turn-2"), "item": .object(["id": .string("cmd"), "type": .string("commandExecution"),
                                                            "command": .string("swift test")])]))
        try await waitUntil { await transport.requestMethods.contains("turn/interrupt") }
        await Self.finishPrediction(thread: "prediction-2", turn: "p-turn-2", message: #"{"suggestion":"Unseen"}"#,
                               on: transport, startsTurn: false)
        try await waitUntil { await transport.requestMethods.filter { $0 == "thread/unsubscribe" }.count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.method == "turn/interrupt" }.map { $0.params["threadId"]?.stringValue }, ["prediction-2"],
                       "The failed turn had ended; only the acting one is stopped")
        let payloads = await recorder.payloads
        XCTAssertFalse(payloads.contains { if case .nextMessageSuggestion = $0 { true } else { false } })
        XCTAssertFalse(payloads.contains { if case .error = $0 { true } else { false } }, "A prediction never reports an error")
        let state = try await adapter.presentationState(for: handle)
        XCTAssertEqual(state.thread?.turns.map(\.id), ["turn-1", "turn-2"])
        await recorder.stop()
        await adapter.close(handle)
    }

    /// Nor for a task no one has looked at within `NextMessageSuggestionPreference.unseenWindow`, as Claude Code's
    /// terminal suggests only while it has focus; one off screen for less still asks.
    func testNothingIsAskedWithTheSettingOffForAThreadKeptNowhereInPlanModeOrOnAnotherProvider() async throws {
        func turnEnds(asks: Bool = true, provider: String = "openai",
                      prepare: (CodexAdapter, UUID) async throws -> Void = { _, _ in }) async throws -> [String] {
            let transport = Self.scriptedTransport(provider: provider)
            let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport,
                                       predictsNextMessages: true, asksForNextMessageSuggestions: { asks })
            let id = UUID()
            try await prepare(adapter, id)
            let handle = try await adapter.createSession(.init(localSessionID: id, workspaceURL: URL(filePath: "/tmp/sandbox"),
                                                               initialPrompt: nil))
            try await adapter.send("Fix the failing test", to: handle)
            await Self.finishTurn("turn-1", on: transport)
            try await Task.sleep(for: .milliseconds(80))
            let methods = await transport.requestMethods
            await adapter.close(handle)
            return methods
        }
        let asked = try await turnEnds()
        XCTAssertTrue(asked.contains("thread/prediction/request"), "The fixture does ask when nothing stops it")

        let off = try await turnEnds(asks: false)
        XCTAssertEqual(off, ["initialize", "thread/start", "turn/start"], "Setting off: no request, no fork, no usage")
        let keptNowhere = try await turnEnds { adapter, id in _ = await adapter.keepNoHistory(for: id) }
        XCTAssertEqual(keptNowhere, ["initialize", "thread/start", "turn/start"], "A run_agent thread is never predicted")
        let otherProvider = try await turnEnds(provider: "ollama")
        XCTAssertEqual(otherProvider, ["initialize", "thread/start", "turn/start"], "The app predicts only on OpenAI's provider")
        let unseen = try await turnEnds { adapter, id in
            await adapter.setUnseen(since: Date().addingTimeInterval(-NextMessageSuggestionPreference.unseenWindow), for: id)
        }
        XCTAssertEqual(unseen, ["initialize", "thread/start", "turn/start"], "Not seen for the window: no prediction")
        let recentlySeen = try await turnEnds { adapter, id in
            await adapter.setUnseen(since: Date().addingTimeInterval(-60), for: id)
        }
        XCTAssertTrue(recentlySeen.contains("thread/prediction/request"), "Seen a minute ago: it still asks")

        // Plan mode, as the app leaves it out.
        let transport = Self.scriptedTransport()
        let adapter = predictingAdapter(transport)
        let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/sandbox"),
                                                           initialPrompt: nil))
        try await adapter.selectCollaborationMode(CodexCollaborationPreset(name: "Plan", mode: "plan", model: nil,
                                                                           reasoningEffort: nil), for: handle)
        try await adapter.send("Plan the fix", to: handle)
        await Self.finishTurn("turn-1", on: transport)
        try await Task.sleep(for: .milliseconds(80))
        let methods = await transport.requestMethods
        XCTAssertFalse(methods.contains("thread/prediction/request"))
        XCTAssertFalse(methods.contains("thread/fork"))
        await adapter.close(handle)
    }

    // MARK: - Fixtures

    func predictingAdapter(_ transport: FakeCodexTransport) -> CodexAdapter {
        CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport,
                     predictsNextMessages: true, asksForNextMessageSuggestions: { true })
    }

    /// App Server 0.163 for one thread on `gpt-6-luna`, with two turns and two prediction forks.
    /// `predictionRequests` > 0 is a runtime that implements `thread/prediction/request`.
    static func scriptedTransport(provider: String = "openai", predictionRequests: Int = 0) -> FakeCodexTransport {
        var responses: [String: [JSONValue]] = [
            "initialize": [.object(["platformOs": .string("macos"), "userAgent": .string(Self.userAgent)])],
            "thread/start": [.object(["thread": .object(["id": .string("thread-1")]), "model": .string("gpt-6-luna"),
                                      "modelProvider": .string(provider), "reasoningEffort": .string("high")])],
            "turn/start": [turn("turn-1"), turn("p-turn-1"), turn("turn-2"), turn("p-turn-2")],
            "thread/fork": [.object(["thread": .object(["id": .string("prediction-1"), "ephemeral": .bool(true)])]),
                            .object(["thread": .object(["id": .string("prediction-2"), "ephemeral": .bool(true)])])],
            "model/list": [.object(["data": .array([model(id: "gpt-6-luna", efforts: ["low", "medium", "high"])])])],
            "thread/unsubscribe": [.object(["status": .string("unsubscribed")]), .object(["status": .string("unsubscribed")])],
            "turn/interrupt": [.object([:]), .object([:])]
        ]
        if predictionRequests > 0 {
            responses["thread/prediction/request"] = Array(repeating: .object([:]), count: predictionRequests)
            responses["turn/start"] = [turn("turn-1"), turn("turn-2")]
            return FakeCodexTransport(responses: responses)
        }
        return FakeCodexTransport(responses: responses, errorResponses: ["thread/prediction/request": [Self.unimplemented]])
    }

    static func finishTurn(_ id: String, on transport: FakeCodexTransport, thread: String = "thread-1") async {
        await transport.emit(method: "turn/started", params: .object(["threadId": .string(thread),
            "turn": .object(["id": .string(id), "status": .string("inProgress"), "items": .array([])])]))
        await transport.emit(method: "turn/completed", params: .object(["threadId": .string(thread),
            "turn": .object(["id": .string(id), "status": .string("completed"), "items": .array([])])]))
    }

    /// The fork's notifications in the order the real 0.163 run sent them (2026-10-17, one turn on a
    /// new sandbox thread): its MCP servers starting, the turn, the prompt as a `userMessage`, the
    /// answer, moderation metadata, token usage, and the turn's end.
    static func finishPrediction(thread: String, turn: String, message: String, on transport: FakeCodexTransport,
                          status: String = "completed", startsTurn: Bool = true) async {
        let ids: [String: JSONValue] = ["threadId": .string(thread), "turnId": .string(turn)]
        func with(_ extra: [String: JSONValue]) -> JSONValue { .object(ids.merging(extra) { $1 }) }
        if startsTurn {
            await transport.emit(method: "mcpServer/startupStatus/updated", params: .object([
                "threadId": .string(thread), "name": .string("openaiDeveloperDocs"), "status": .string("starting")]))
            await transport.emit(method: "thread/status/changed", params: .object([
                "threadId": .string(thread), "status": .object(["type": .string("active"), "activeFlags": .array([])])]))
            await transport.emit(method: "turn/started", params: .object(["threadId": .string(thread),
                "turn": .object(["id": .string(turn), "status": .string("inProgress"), "items": .array([])])]))
            let prompt: JSONValue = .object(["type": .string("userMessage"), "id": .string("prompt"),
                "content": .array([.object(["type": .string("text"), "text": .string(CodexMessagePrediction.prompt)])])])
            await transport.emit(method: "item/started", params: with(["item": prompt]))
            await transport.emit(method: "item/completed", params: with(["item": prompt]))
        }
        await transport.emit(method: "item/started", params: with(["item": .object([
            "type": .string("agentMessage"), "id": .string("answer"), "text": .string(""), "phase": .string("final_answer")])]))
        await transport.emit(method: "turn/moderationMetadata", params: with(["metadata": .object([
            "prompt": .object([:]), "generation": .object([:])])]))
        await transport.emit(method: "item/completed", params: with(["item": .object([
            "type": .string("agentMessage"), "id": .string("answer"), "text": .string(message), "phase": .string("final_answer")])]))
        await transport.emit(method: "thread/tokenUsage/updated", params: with(["tokenUsage": .object([
            "last": .object(["inputTokens": .integer(21704), "cachedInputTokens": .integer(7168), "outputTokens": .integer(23)])])]))
        await transport.emit(method: "turn/completed", params: .object(["threadId": .string(thread),
            "turn": .object(["id": .string(turn), "status": .string(status), "items": .array([])])]))
    }

    private func update(turn: String, text: String) -> JSONValue {
        .object(["threadId": .string("thread-1"), "sourceTurnId": .string(turn),
                 "result": .object(["type": .string("completed"), "text": .string(text)])])
    }

    private static func turn(_ id: String) -> JSONValue { .object(["turn": .object(["id": .string(id)])]) }

    private static func model(id: String, efforts: [String]) -> JSONValue {
        .object(["id": .string(id), "model": .string(id), "displayName": .string(id),
                 "defaultReasoningEffort": .string("medium"), "hidden": .bool(false),
                 "supportedReasoningEfforts": .array(efforts.map { .object(["reasoningEffort": .string($0)]) })])
    }

    private func model(efforts: [String]) -> CodexModelOption {
        CodexModelOption(id: "m", model: "m", displayName: "m", defaultReasoningEffort: "medium",
                         supportedReasoningEfforts: efforts, isDefault: true)
    }

    private func decode(_ line: String) throws -> CodexRPCIncomingMessage {
        try CodexRPCCodec().decodeLine(Data(line.utf8))
    }
}

/// The prediction through the app model on the product route (YHP) to a scripted App Server 0.163:
/// it waits in the Codex task's draft after the turn ends, never joins the conversation or the saved
/// draft, and the next send lets it go without sending it.
@MainActor final class CodexMessagePredictionAppModelTests: XCTestCase {
    private static let prediction = "Rerun only the failing tests and check that they pass"

    func testThePredictionWaitsInTheCodexTaskDraftUntilTheNextTurn() async throws {
        let (model, task, transport) = try await makeTaskWithAPrediction()
        let draft = model.composerDrafts.tasks.draft(for: task.id)
        XCTAssertEqual(draft.nextMessageSuggestion, Self.prediction)
        XCTAssertTrue(draft.snapshot.isEmpty, "Never part of the saved draft")
        XCTAssertFalse(model.transcriptBySessionID[task.id]?.contains {
            if case let .assistant(text, _) = $0.content { return text.contains(Self.prediction) }
            if case let .user(text, _) = $0.content { return text.contains(Self.prediction) }
            return false
        } ?? false, "It never joins the conversation")
        XCTAssertEqual(model.codexPresentationBySessionID[task.id]?.thread?.turns.map(\.id), ["turn-1"],
                       "The fork's turn is not the task's")
        XCTAssertNil(model.errorBySessionID[task.id])

        await model.send(HarnessUserInput(text: "Explain the fix first"), to: task)
        XCTAssertNil(draft.nextMessageSuggestion, "Sending something else lets it go")
        let sent = await transport.requests.filter {
            $0.method == "turn/start" && $0.params["threadId"]?.stringValue == "thread-1"
        }.compactMap { $0.params["input"]?.arrayValue?.first?["text"]?.stringValue }
        XCTAssertEqual(sent, ["Fix the failing tests in calc.py", "Explain the fix first"],
                       "The prediction itself was never sent")
    }

    /// The whole window on a Codex task whose turn ended, with the prediction as the empty
    /// composer's faint text: `.build/next-prompt-qa/codex-task-prediction-{light,dark}.png`.
    func testACodexTaskWithAPredictionDraws() async throws {
        let (model, task, _) = try await makeTaskWithAPrediction()
        model.splits.activate(.session(task.id))
        let directory = try WindowlessRender.directory("next-prompt-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(AnyView(MainWindow(model: model).environment(\.colorScheme, appearance.colorScheme)),
                                             size: NSSize(width: 1180, height: 760), appearance: appearance)
            host.settle(passes: 12)
            func fields(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
            }
            XCTAssertTrue(fields(host.hosting).contains { $0.isEditable && $0.placeholderString == Self.prediction },
                          "The Codex task's composer shows the prediction as its faint text")
            try WindowlessRender.writePNG(try host.capture().bitmap,
                to: directory.appending(path: "codex-task-prediction-\(appearance.suffix).png"))
            host.close()
        }
    }

    /// A Codex task on the product route whose first turn ended with an answer and whose prediction
    /// arrived from the fork.
    private func makeTaskWithAPrediction() async throws -> (AppModel, SessionRecord, FakeCodexTransport) {
        let root = FileManager.default.temporaryDirectory.appending(path: "codex-prediction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "codex")
        try Data("#!/bin/sh\nprintf 'codex-cli 0.163.0\\n'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let workspace = root.appending(path: "calculator")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let suite = testDefaultsSuite("CodexMessagePrediction")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))

        let transport = CodexMessagePredictionTests.scriptedTransport()
        let adapter = YHPCodexCompatibilityAdapter(
            adapter: CodexAdapter(executableURL: executable, transport: transport, predictsNextMessages: true,
                                  asksForNextMessageSuggestions: { true }),
            manifest: HarnessProtocolCompatibilityManifest.codex())
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, _ in adapter },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults, keyPrefix: "transcript."),
            restoresIndexOnLaunch: false)
        addTeardownBlock { await model.shutdown() }
        let created = await model.createSession(harness: .codex, workspaceURL: workspace, runtimeExecutableURL: executable,
                                                title: "Fix failing calc.py tests")
        let task = try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Missing task")

        let request = "Fix the failing tests in calc.py"
        await model.send(HarnessUserInput(text: request), to: task)
        try await waitUntil { await transport.requestMethods.contains("turn/start") }
        await transport.emit(method: "turn/started", params: .object(["threadId": .string("thread-1"),
            "turn": .object(["id": .string("turn-1"), "status": .string("inProgress"), "items": .array([])])]))
        await transport.emit(method: "item/completed", params: .object(["threadId": .string("thread-1"), "turnId": .string("turn-1"),
            "item": .object(["id": .string("user-1"), "type": .string("userMessage"),
                             "content": .array([.object(["type": .string("text"), "text": .string(request)])])])]))
        await transport.emit(method: "item/completed", params: .object(["threadId": .string("thread-1"), "turnId": .string("turn-1"),
            "item": .object(["id": .string("answer-1"), "type": .string("agentMessage"), "text": .string(
                "`divide` returned `None` instead of raising on division by zero, so `test_divide_by_zero` failed. "
                    + "It now raises `ZeroDivisionError`, and that test passes.")])]))
        await transport.emit(method: "turn/completed", params: .object(["threadId": .string("thread-1"),
            "turn": .object(["id": .string("turn-1"), "status": .string("completed"), "items": .array([])])]))
        try await waitUntil { model.store.sessions.first?.status == .ready }
        try await waitUntil { await transport.requestMethods.filter { $0 == "turn/start" }.count == 2 }
        await CodexMessagePredictionTests.finishPrediction(thread: "prediction-1", turn: "p-turn-1",
            message: #"{"suggestion":"\#(Self.prediction)"}"#, on: transport)
        let draft = model.composerDrafts.tasks.draft(for: task.id)
        try await waitUntil { draft.nextMessageSuggestion == Self.prediction }
        return (model, try XCTUnwrap(model.store.sessions.first { $0.id == task.id }), transport)
    }
}

/// Every event a session's stream carries, in order.
private actor CodexPredictionEventRecorder {
    private let adapter: any HarnessAdapter
    private let handle: HarnessSessionHandle
    private(set) var payloads: [HarnessEventPayload] = []
    private var task: Task<Void, Never>?

    init(adapter: any HarnessAdapter, handle: HarnessSessionHandle) {
        self.adapter = adapter
        self.handle = handle
    }

    func start() async {
        let stream = await adapter.events(for: handle)
        task = Task { [weak self] in
            for await event in stream { await self?.append(event.payload) }
        }
    }

    func stop() { task?.cancel() }

    private func append(_ payload: HarnessEventPayload) { payloads.append(payload) }
}
