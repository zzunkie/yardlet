import Foundation
import XCTest
@testable import NativeHarnessClient

/// Codex CLI 0.163.0's App Server, as recorded on 2026-10-16 through Yardlet's adapter (a resume of
/// a copied 190 MB thread, and one steered turn on a new sandbox thread). The shapes are the
/// recorded ones; the text, IDs and paths are made up. New in 0.163 against 0.157.1:
/// `thread/readState/changed`, `thread/prediction/updated`, `Turn.rootTurnId`, the
/// `partial_answer` message phase, the `flexUnavailable` and `tooManyDenials` error kinds (and any
/// other kind as a bare string or object), and a sub-agent's `model` and `reasoningEffort`. None of
/// these, and no notification or item type Yardlet does not know, may end a turn.
final class CodexRuntime0163ShapeTests: XCTestCase {
    private let threadID = "0000bbbb-0000-0000-0000-000000000163"
    private let turnID = "0000bbbb-0000-0000-0000-0000000000t1"

    func testA0163TurnWithEveryRecordedNotificationEndsReadyWithoutAnError() async throws {
        let (adapter, transport, handle) = try await startedThread()
        let collected = collect(from: await adapter.events(for: handle))
        try await adapter.send("Run the check", to: handle)
        for (method, params) in recordedTurn() {
            await transport.emit(method: method, params: params)
        }
        let payloads = try await finished(collected)

        let errors = payloads.compactMap { payload -> String? in
            if case let .error(message, _, _) = payload { return message }
            return nil
        }
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertTrue(payloads.contains(.assistantDelta("The check ")))
        XCTAssertTrue(payloads.contains { payload in
            if case let .activityStarted(activity) = payload { return activity.kind == "commandExecution" }
            return false
        })
        XCTAssertEqual(payloads.last, .sessionStatusChanged(.ready))

        let state = try await adapter.presentationState(for: handle)
        let turn = try XCTUnwrap(state.thread?.turns.last)
        XCTAssertEqual(turn.id, turnID)
        XCTAssertEqual(turn.status, .completed)
        let texts = turn.items.compactMap { item -> String? in
            if case let .agentMessage(message) = item.content { return message.text }
            return nil
        }
        XCTAssertTrue(texts.contains("The check passed."), "\(texts)")
        XCTAssertTrue(texts.contains("Done."), "\(texts)")
        let activeTurnID = await adapter.activeTurnID(for: handle)
        XCTAssertNil(activeTurnID)
    }

    /// A turn that fails says so in the provider's words, whatever kind of error 0.163 names.
    func testA0163TurnErrorOfANewKindStillSaysWhatHappened() async throws {
        let (adapter, transport, handle) = try await startedThread()
        let collected = collect(from: await adapter.events(for: handle))
        try await adapter.send("Run the check", to: handle)
        let error: JSONValue = .object([
            "message": .string("Too many actions were denied in this turn."),
            "codexErrorInfo": .string("tooManyDenials"),
            "additionalDetails": .null
        ])
        await transport.emit(method: "turn/started", params: .object([
            "threadId": .string(threadID), "turn": turn(status: "inProgress", items: [], error: .null)
        ]))
        await transport.emit(method: "error", params: .object([
            "threadId": .string(threadID), "turnId": .string(turnID), "willRetry": .bool(false), "error": error
        ]))
        await transport.emit(method: "turn/completed", params: .object([
            "threadId": .string(threadID), "turn": turn(status: "failed", items: [], error: error)
        ]))
        let payloads = try await finished(collected)

        XCTAssertTrue(payloads.contains(.error(message: "Too many actions were denied in this turn.", recoverable: false)))
        let state = try await adapter.presentationState(for: handle)
        XCTAssertEqual(CodexTurnErrorPresentation(state.thread?.turns.last?.error)?.text,
                       "Too many actions were denied in this turn.")
        // Any kind 0.163 may add, as a bare string or an object, keeps the provider's words.
        for kind: JSONValue in [.string("flexUnavailable"), .object(["somethingNew": .object(["httpStatusCode": .integer(503)])])] {
            let presented = CodexTurnErrorPresentation(.object(["message": .string("Flex processing is unavailable."),
                                                                "codexErrorInfo": kind]))
            XCTAssertEqual(presented?.text, "Flex processing is unavailable.")
        }
    }

    /// The resume Yardlet sends (bootstrap page of three, full items) answered in 0.163's shape.
    func testA0163ResumeAnswerBringsItsLatestTurns() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos"), "platformFamily": .string("unix"),
                                    "codexHome": .string("/tmp/codex-home"), "userAgent": .string("codex/0.163.0")])],
            "thread/resume": [.object([
                "thread": thread(),
                "initialTurnsPage": .object([
                    "data": .array([
                        turn(id: "turn-new", status: "completed", items: [
                            item("userMessage", id: "ask-new", ["content": .array([.object([
                                "type": .string("text"), "text": .string("Apply the prices"), "text_elements": .array([])
                            ])])]),
                            item("agentMessage", id: "note", ["text": .string("Checking the store."), "phase": .string("commentary")]),
                            item("imageView", id: "shot", ["path": .string("/tmp/qa/shot.png")]),
                            item("agentMessage", id: "answer", ["text": .string("Prices applied."), "phase": .string("final_answer")])
                        ], error: .null),
                        turn(id: "turn-old", status: "completed", items: [
                            item("agentMessage", id: "old-answer", ["text": .string("Earlier answer."), "phase": .string("final_answer")])
                        ], error: .null)
                    ]),
                    "nextCursor": .null,
                    "backwardsCursor": .string("turns-head")
                ]),
                "model": .string("gpt-fake"), "modelProvider": .string("openai"), "reasoningEffort": .string("low"),
                "approvalPolicy": .string("on-request"), "approvalsReviewer": .string("user"),
                "sandbox": .object(["type": .string("workspaceWrite"), "writableRoots": .array([]),
                                    "networkAccess": .bool(false), "excludeSlashTmp": .bool(false),
                                    "excludeTmpdirEnvVar": .bool(false)]),
                "cwd": .string("/tmp/qa"), "runtimeWorkspaceRoots": .array([.string("/tmp/qa")]),
                "instructionSources": .array([.string("/tmp/qa/AGENTS.md")]), "disabledPluginIds": .array([]),
                "multiAgentMode": .string("explicitRequestOnly"), "activePermissionProfile": .null, "serviceTier": .null,
                "turnsBackwardsCursor": .string("turns-head"), "itemsBackwardsCursor": .string("items-head")
            ])],
            "thread/items/list": [.object(["data": .array([]), "nextCursor": .null, "backwardsCursor": .null])]
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport)
        let handle = try await adapter.resumeSession(providerSessionID: threadID, localSessionID: UUID(),
                                                     workspaceURL: URL(filePath: "/tmp/qa"))
        let state = try await adapter.presentationState(for: handle)
        XCTAssertEqual(state.thread?.turns.map(\.id), ["turn-old", "turn-new"])
        let latest = try XCTUnwrap(state.thread?.turns.last)
        XCTAssertEqual(latest.items.map(\.id), ["ask-new", "note", "shot", "answer"])
        let instructionSources = await adapter.instructionSources(for: handle.localSessionID)
        XCTAssertEqual(instructionSources, ["/tmp/qa/AGENTS.md"])
    }

    // MARK: - Recorded shapes

    private func recordedTurn() -> [(String, JSONValue)] {
        let thread: JSONValue = .string(threadID)
        let turn: JSONValue = .string(turnID)
        let ask = item("userMessage", id: "ask-1", ["clientId": .null, "content": .array([.object([
            "type": .string("text"), "text": .string("Run the check"), "text_elements": .array([])
        ])])])
        let command: (JSONValue, JSONValue, JSONValue) -> JSONValue = { status, exitCode, duration in
            self.item("commandExecution", id: "exec-1", [
                "command": .string("/bin/zsh -lc 'make check'"), "cwd": .string("/tmp/qa"), "processId": .string("4242"),
                "source": .string("unifiedExecStartup"), "status": status, "exitCode": exitCode, "durationMs": duration,
                "aggregatedOutput": .null, "pluginId": .null, "scriptPath": .null,
                "commandActions": .array([.object(["type": .string("unknown"), "command": .string("make check")])])
            ])
        }
        let partial = item("agentMessage", id: "msg-1", ["text": .string("The check passed."), "phase": .string("partial_answer"),
                                                         "memoryCitation": .null, "delivery": .null, "questions": .null])
        let final = item("agentMessage", id: "msg-2", ["text": .string("Done."), "phase": .string("final_answer"),
                                                       "memoryCitation": .null, "delivery": .null, "questions": .null])
        let usage: JSONValue = .object(["inputTokens": .integer(25_787), "cachedInputTokens": .integer(9088),
                                        "cacheWriteInputTokens": .integer(0), "outputTokens": .integer(53),
                                        "reasoningOutputTokens": .integer(0), "totalTokens": .integer(25_840)])
        return [
            ("thread/started", .object(["thread": self.thread()])),
            ("mcpServer/startupStatus/updated", .object(["threadId": thread, "name": .string("yardlet"),
                "status": .string("starting"), "error": .null, "failureReason": .null])),
            ("mcpServer/startupStatus/updated", .object(["threadId": thread, "name": .string("yardlet"),
                "status": .string("failed"), "error": .string("MCP client for `yardlet` failed to start: handshake ended"),
                "failureReason": .null])),
            ("thread/settings/updated", .object(["threadId": thread, "threadSettings": .object([
                "model": .string("gpt-fake-mini"), "effort": .string("low"), "approvalPolicy": .string("on-request"),
                "approvalsReviewer": .string("user"), "cwd": .string("/tmp/qa"), "personality": .string("pragmatic"),
                "multiAgentMode": .string("explicitRequestOnly"), "serviceTier": .string("default"),
                "collaborationMode": .object(["mode": .string("default"), "settings": .object([
                    "model": .string("gpt-fake-mini"), "reasoning_effort": .string("low"), "developer_instructions": .null])])
            ])])),
            ("thread/status/changed", .object(["threadId": thread, "status": .object([
                "type": .string("active"), "activeFlags": .array([])])])),
            ("turn/started", .object(["threadId": thread, "turn": self.turn(status: "inProgress", items: [], error: .null)])),
            ("account/updated", .object(["authMode": .string("chatgpt"), "planType": .string("plus")])),
            ("item/started", .object(["threadId": thread, "turnId": turn, "startedAtMs": .integer(1_792_151_949_412), "item": ask])),
            ("item/completed", .object(["threadId": thread, "turnId": turn, "completedAtMs": .integer(1_792_151_949_417), "item": ask])),
            ("turn/moderationMetadata", .object(["threadId": thread, "turnId": turn, "metadata": .object([
                "prompt": .object(["omnimod": .object(["outputs": .array([]), "protection_type": .string("omnimod")])]),
                "generation": .object([:]), "tool_call": .object([:]), "tool_response": .object([:])])])),
            ("item/started", .object(["threadId": thread, "turnId": turn, "startedAtMs": .integer(1_792_151_952_797),
                                      "item": command(.string("inProgress"), .null, .null)])),
            ("thread/tokenUsage/updated", .object(["threadId": thread, "turnId": turn, "tokenUsage": .object([
                "last": usage, "total": usage, "modelContextWindow": .integer(828_400)])])),
            ("account/rateLimits/updated", .object(["rateLimits": .object([
                "limitId": .string("codex"), "primary": .object(["usedPercent": .integer(7), "windowDurationMins": .integer(10080),
                                                                 "resetsAt": .integer(1_792_649_634)]),
                "secondary": .null, "credits": .object(["balance": .string("10.0"), "unlimited": .bool(false),
                                                        "hasCredits": .bool(true)]),
                "planType": .string("plus"), "rateLimitReachedType": .null, "spendControlReached": .null,
                "individualLimit": .null, "normalModelSlug": .null, "limitName": .null])])),
            ("item/completed", .object(["threadId": thread, "turnId": turn, "completedAtMs": .integer(1_792_151_958_681),
                                        "item": command(.string("completed"), .integer(0), .integer(5883))])),
            ("item/started", .object(["threadId": thread, "turnId": turn, "startedAtMs": .integer(1_792_151_959_523),
                                      "item": item("agentMessage", id: "msg-1", ["text": .string(""),
                                                                                  "phase": .string("partial_answer")])])),
            ("item/agentMessage/delta", .object(["threadId": thread, "turnId": turn, "itemId": .string("msg-1"),
                                                 "delta": .string("The check ")])),
            ("item/completed", .object(["threadId": thread, "turnId": turn, "item": partial])),
            // An item and a notification no Yardlet knows yet.
            ("item/started", .object(["threadId": thread, "turnId": turn, "item": item("futureThing", id: "future-1", [:])])),
            ("item/completed", .object(["threadId": thread, "turnId": turn, "item": item("futureThing", id: "future-1", [:])])),
            ("thread/somethingNew/changed", .object(["threadId": thread, "detail": .object(["any": .bool(true)])])),
            // A retried stream error is the turn reconnecting, not its end.
            ("error", .object(["threadId": thread, "turnId": turn, "willRetry": .bool(true), "error": .object([
                "message": .string("Reconnecting... 1/5"), "codexErrorInfo": .string("flexUnavailable")])])),
            ("item/completed", .object(["threadId": thread, "turnId": turn, "item": item("subAgentActivity", id: "agent-1", [
                "kind": .string("spawned"), "agentPath": .string("/tmp/qa/agent"), "model": .string("gpt-fake-mini"),
                "reasoningEffort": .string("low")])])),
            ("item/completed", .object(["threadId": thread, "turnId": turn, "item": final])),
            ("thread/readState/changed", .object(["threadId": thread, "readState": .object([
                "firstUnread": .object(["type": .string("turn"), "turnId": turn]), "revision": .string("rev-1")])])),
            ("thread/prediction/updated", .object(["threadId": thread, "sourceTurnId": turn, "result": .object([
                "type": .string("completed"), "text": .string("Ship the change")])])),
            ("thread/goal/cleared", .object(["threadId": thread])),
            ("turn/completed", .object(["threadId": thread, "turn": self.turn(status: "completed", items: [final],
                                                                               error: .null, itemsView: "summary")]))
        ]
    }

    private func thread() -> JSONValue {
        .object([
            "id": .string(threadID), "sessionId": .string(threadID), "cwd": .string("/tmp/qa"), "preview": .string(""),
            "status": .object(["type": .string("idle")]), "turns": .array([]), "ephemeral": .bool(false),
            "historyMode": .string("paginated"), "modelProvider": .string("openai"), "model": .string("gpt-fake"),
            "reasoningEffort": .string("low"), "cliVersion": .string("0.163.0"), "source": .string("vscode"),
            "originator": .string("native-harness-client"), "canAcceptDirectInput": .bool(true),
            "createdAt": .integer(1_792_151_947), "updatedAt": .integer(1_792_151_947), "recencyAt": .integer(1_792_151_947),
            "environments": .array([.object(["cwd": .string("/tmp/qa"), "environmentId": .string("local"),
                                             "runtimeWorkspaceRoots": .array([.string("/tmp/qa")])])]),
            "path": .string("/tmp/qa/rollout.jsonl"), "gitInfo": .null, "projectId": .null, "agentNickname": .null,
            "agentRole": .null, "threadSource": .null, "parentThreadId": .null, "forkedFromId": .null, "extra": .null,
            "daybreakEnabled": .null, "section": .null, "sectionEnteredAt": .null, "name": .null
        ])
    }

    private func turn(id: String? = nil, status: String, items: [JSONValue], error: JSONValue,
                      itemsView: String = "full") -> JSONValue {
        let id = id ?? turnID
        return .object([
            "id": .string(id), "rootTurnId": .string(id), "status": .string(status), "itemsView": .string(itemsView),
            "items": .array(items), "error": error, "startedAt": .integer(1_792_151_947),
            "completedAt": status == "inProgress" ? .null : .integer(1_792_151_959),
            "durationMs": status == "inProgress" ? .null : .integer(12_096)
        ])
    }

    private func item(_ type: String, id: String, _ fields: [String: JSONValue]) -> JSONValue {
        .object(fields.merging(["type": .string(type), "id": .string(id)]) { _, new in new })
    }

    // MARK: - Driving the adapter

    private func startedThread() async throws -> (CodexAdapter, FakeCodexTransport, HarnessSessionHandle) {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [.object(["thread": .object(["id": .string(threadID)])])],
            "turn/start": [.object(["turn": turn(status: "inProgress", items: [], error: .null, itemsView: "notLoaded")])]
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport)
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/qa"), initialPrompt: nil)
        )
        return (adapter, transport, handle)
    }

    /// Everything the task hears until its turn ends and it is ready again.
    private func collect(from stream: AsyncStream<HarnessEventEnvelope>) -> Task<[HarnessEventPayload], Never> {
        Task {
            var payloads: [HarnessEventPayload] = []
            var completed = false
            for await event in stream {
                payloads.append(event.payload)
                if event.payload == .turnCompleted { completed = true }
                if completed, event.payload == .sessionStatusChanged(.ready) { break }
            }
            return payloads
        }
    }

    private func finished(_ task: Task<[HarnessEventPayload], Never>) async throws -> [HarnessEventPayload] {
        try await withThrowingTaskGroup(of: [HarnessEventPayload].self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw HarnessAdapterError.invalidProviderEvent("The turn did not end")
            }
            let result = try await group.next() ?? []
            group.cancelAll()
            task.cancel()
            return result
        }
    }
}
