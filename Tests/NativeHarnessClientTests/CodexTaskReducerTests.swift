import Foundation
import XCTest
@testable import NativeHarnessClient

final class CodexTaskReducerTests: XCTestCase {
    /// Every state these sequences pass through also goes through the conversation projection's
    /// cache (`CodexReducerSteps`).
    private let steps = CodexReducerSteps()

    override func tearDown() {
        steps.assertCacheFollowsEveryStep()
        super.tearDown()
    }

    func testTurnCompletionExpiresOnlyItsOwnPendingApprovals() throws {
        let reducer = steps.recording
        var state = CodexTaskState.empty
        for (index, pair) in [("side-approval", "side-turn"), ("other-approval", "other-turn")].enumerated() {
            let (request, turn) = pair
            XCTAssertTrue(reducer.applyServerRequest(id: .string(request), method: "item/commandExecution/requestApproval",
                params: .object(["threadId": .string("thread-1"), "turnId": .string(turn), "itemId": .string(request)]),
                sequence: UInt64(index + 1), to: &state))
        }
        XCTAssertTrue(reducer.applyNotification(method: "turn/completed", params: .object([
            "threadId": .string("thread-1"),
            "turn": .object(["id": .string("side-turn"), "status": .string("interrupted"), "items": .array([])])
        ]), sequence: 3, to: &state))
        guard case .rejected(let code, _) = state.serverRequestsByID["s:side-approval"]?.resolution else {
            return XCTFail("A stopped turn must not retain an answerable approval")
        }
        XCTAssertEqual(code, CodexPendingServerRequest.expiredRuntimeCode)
        XCTAssertEqual(state.serverRequestsByID["s:other-approval"]?.resolution, .pending)
    }

    func testUserMessageDisplayTextProjectsTypedInputsWithoutChangingWireShape() {
        let message = CodexUserMessageItem(
            content: [
                .object(["type": .string("text"), "text": .string("Check this screen")]),
                .object(["type": .string("mention"), "name": .string("AppTitleBar.swift"), "path": .string("file:///tmp/AppTitleBar.swift")]),
                .object(["type": .string("futureInput"), "value": .string("preserve")])
            ],
            clientID: "client-1"
        )

        XCTAssertEqual(message.displayText, "Check this screen\n@AppTitleBar.swift")
        XCTAssertEqual(message.content[2]["value"]?.stringValue, "preserve")
    }

    func testRuntimeVersionNoteReportsVerifiedUnverifiedAndBelowMinimum() {
        let codex = CodexRuntimeCompatibility.restorationBaseline
        let verified = HarnessRuntimeVersionNote.note(
            versionOutput: "codex-cli 0.153.4",
            compatibility: codex
        )
        XCTAssertEqual(verified?.version, "0.153.4")
        XCTAssertEqual(verified?.standing, .verified)

        let newer = HarnessRuntimeVersionNote.note(
            versionOutput: "codex-cli 0.156.0-alpha.1",
            compatibility: codex
        )
        XCTAssertEqual(newer?.version, "0.156.0-alpha.1")
        XCTAssertEqual(newer?.standing, .unverified)

        let old = HarnessRuntimeVersionNote.note(
            versionOutput: "codex-cli 0.146.0",
            compatibility: codex
        )
        XCTAssertEqual(old?.standing, .belowMinimum)
        XCTAssertEqual(old?.minimum, "0.147.0")

        XCTAssertNil(HarnessRuntimeVersionNote.note(
            versionOutput: "codex 0.153.4",
            compatibility: codex
        ))
        XCTAssertNil(HarnessRuntimeVersionNote.read(
            executableURL: URL(filePath: "/nonexistent/codex"),
            compatibility: codex
        ))

        // The note is harness neutral: the same standings come from the Claude policy.
        let claude = ClaudeRuntimeCompatibility.restorationBaseline
        XCTAssertEqual(
            HarnessRuntimeVersionNote.note(
                versionOutput: "2.1.275 (Claude Code)",
                compatibility: claude
            ),
            HarnessRuntimeVersionNote(version: "2.1.275", standing: .verified, minimum: "2.1.0")
        )
        XCTAssertEqual(
            HarnessRuntimeVersionNote.note(
                versionOutput: "2.2.0 (Claude Code)",
                compatibility: claude
            )?.standing,
            .unverified
        )
        XCTAssertEqual(
            HarnessRuntimeVersionNote.note(
                versionOutput: "2.0.9 (Claude Code)",
                compatibility: claude
            )?.standing,
            .belowMinimum
        )
        XCTAssertNil(HarnessRuntimeVersionNote.note(
            versionOutput: "2.1.275",
            compatibility: claude
        ))

        // Only the two harnesses with a published floor report a version line.
        XCTAssertNotNil(HarnessRuntimeVersionNote.compatibility(for: .codex))
        XCTAssertNotNil(HarnessRuntimeVersionNote.compatibility(for: .claudeCode))
        XCTAssertNil(HarnessRuntimeVersionNote.compatibility(for: .museCode))
    }

    func testRestorationCompatibilityAcceptsMinimumFloorAndReportsVerification() {
        let compatibility = CodexRuntimeCompatibility.restorationBaseline

        // At or above the floor connects, including newer alphas Yardlet has not exercised yet.
        XCTAssertTrue(compatibility.accepts(versionOutput: "codex-cli 0.147.0"))
        XCTAssertTrue(compatibility.accepts(versionOutput: "codex-cli 0.147.0-alpha.9"))
        XCTAssertTrue(compatibility.accepts(versionOutput: "codex-cli 0.153.4"))
        XCTAssertTrue(compatibility.accepts(versionOutput: "codex-cli 0.155.0-alpha.2.6"))
        XCTAssertTrue(compatibility.accepts(versionOutput: "codex-cli 0.155.0-alpha.9.2"))
        XCTAssertTrue(compatibility.accepts(versionOutput: "codex-cli 0.155.0-alpha.16.4"))
        XCTAssertTrue(compatibility.accepts(versionOutput: "codex-cli 0.158.0-alpha.2.1"))
        XCTAssertTrue(compatibility.accepts(versionOutput: "codex-cli 0.155.0"))
        XCTAssertTrue(compatibility.accepts(versionOutput: "codex-cli 0.160.3"))
        XCTAssertTrue(compatibility.accepts(versionOutput: "codex-cli 1.0.0"))

        // Below the floor, a missing marker, or an unparsable version is refused.
        XCTAssertFalse(compatibility.accepts(versionOutput: "codex-cli 0.146.9"))
        XCTAssertFalse(compatibility.accepts(versionOutput: "codex-cli 0.146.9-alpha.1"))
        XCTAssertFalse(compatibility.accepts(versionOutput: "codex-cli 0.99.0"))
        XCTAssertFalse(compatibility.accepts(versionOutput: "codex 0.148.0-alpha.9"))
        XCTAssertFalse(compatibility.accepts(versionOutput: "codex-cli main"))
        XCTAssertFalse(compatibility.accepts(versionOutput: ""))

        // Verification only reflects versions exercised against this source.
        XCTAssertTrue(compatibility.isVerified(versionOutput: "codex-cli 0.147.0-alpha.9"))
        XCTAssertTrue(compatibility.isVerified(versionOutput: "codex-cli 0.153.4"))
        XCTAssertTrue(compatibility.isVerified(versionOutput: "codex-cli 0.154.0-alpha.6.2"))
        XCTAssertTrue(compatibility.isVerified(versionOutput: "codex-cli 0.155.0-alpha.2.6"))
        XCTAssertTrue(compatibility.isVerified(versionOutput: "codex-cli 0.155.0-alpha.9.2"))
        XCTAssertTrue(compatibility.isVerified(versionOutput: "codex-cli 0.155.0-alpha.16.4"))
        XCTAssertTrue(compatibility.isVerified(versionOutput: "codex-cli 0.158.0-alpha.2.1"))
        XCTAssertFalse(compatibility.isVerified(versionOutput: "codex-cli 0.155.0-alpha.9.3"))
        XCTAssertFalse(compatibility.isVerified(versionOutput: "codex-cli 0.155.0-alpha.16.5"))
        XCTAssertFalse(compatibility.isVerified(versionOutput: "codex-cli 0.158.0-alpha.2.2"))
        XCTAssertFalse(compatibility.isVerified(versionOutput: "codex-cli 0.158.0"))
        XCTAssertFalse(compatibility.isVerified(versionOutput: "codex-cli 0.153.5"))
        XCTAssertFalse(compatibility.isVerified(versionOutput: "codex-cli 0.155.0"))
        XCTAssertFalse(compatibility.isVerified(versionOutput: "codex-cli 0.160.3"))
        XCTAssertFalse(compatibility.isVerified(versionOutput: "codex 0.153.4"))

        XCTAssertEqual(
            CodexRuntimeCompatibility.version(from: "codex-cli 0.148.0-alpha.9"),
            "0.148.0-alpha.9"
        )
        let parsed = CodexRuntimeCompatibility.Version("0.155.0-alpha.9.2")
        XCTAssertEqual(parsed?.major, 0)
        XCTAssertEqual(parsed?.minor, 155)
        XCTAssertEqual(parsed?.patch, 0)
        XCTAssertEqual(parsed?.prerelease, "alpha.9.2")
        XCTAssertNil(CodexRuntimeCompatibility.Version("0.155"))
    }

    func testDescendingHistoryPageIsPrependedInChronologicalOrder() {
        var state = CodexTaskState.empty
        XCTAssertTrue(steps.recording.applySnapshot(.object([
            "id": .string("thread-1"),
            "turns": .array([.object([
                "id": .string("latest"),
                "status": .string("completed"),
                "itemsView": .string("full"),
                "items": .array([])
            ])])
        ]), to: &state))
        let descendingProviderPage = CodexTaskDecoder().turnPage(from: .object([
            "data": .array([
                .object([
                    "id": .string("middle"),
                    "status": .string("completed"),
                    "itemsView": .string("full"),
                    "items": .array([])
                ]),
                .object([
                    "id": .string("oldest"),
                    "status": .string("completed"),
                    "itemsView": .string("full"),
                    "items": .array([])
                ])
            ]),
            "nextCursor": .string("older")
        ]))
        let chronologicalPage = CodexTurnPage(
            turns: Array(descendingProviderPage.turns.reversed()),
            nextCursor: descendingProviderPage.nextCursor,
            backwardsCursor: descendingProviderPage.backwardsCursor
        )

        steps.recording.mergeTurnPage(chronologicalPage, prepending: true, into: &state)

        XCTAssertEqual(state.thread?.turns.map(\.id), ["oldest", "middle", "latest"])
        XCTAssertEqual(state.thread?.turnsNextCursor, "older")
    }

    func testSnapshotDecodesStableTurnsAllKnownItemKindsAndUnknownFallback() throws {
        let thread = makeThreadSnapshot(items: [
            ["id": .string("user"), "type": .string("userMessage"), "content": .array([])],
            ["id": .string("hook"), "type": .string("hookPrompt"), "fragments": .array([])],
            ["id": .string("agent"), "type": .string("agentMessage"), "text": .string("answer")],
            ["id": .string("plan"), "type": .string("plan"), "text": .string("step")],
            ["id": .string("reasoning"), "type": .string("reasoning")],
            [
                "id": .string("command"), "type": .string("commandExecution"),
                "command": .string("swift test"), "cwd": .string("/tmp/workspace"),
                "status": .string("completed")
            ],
            ["id": .string("file"), "type": .string("fileChange"), "changes": .array([]), "status": .string("completed")],
            [
                "id": .string("mcp"), "type": .string("mcpToolCall"), "server": .string("docs"),
                "tool": .string("search"), "status": .string("completed"), "arguments": .object([:])
            ],
            [
                "id": .string("dynamic"), "type": .string("dynamicToolCall"), "tool": .string("lookup"),
                "status": .string("completed"), "arguments": .object([:])
            ],
            [
                "id": .string("collab"), "type": .string("collabAgentToolCall"), "tool": .string("wait"),
                "status": .string("completed"), "senderThreadId": .string("thread-1"),
                "receiverThreadIds": .array([.string("child")]), "agentsStates": .object([:])
            ],
            [
                "id": .string("subagent"), "type": .string("subAgentActivity"),
                "agentThreadId": .string("child"), "agentPath": .string("0"), "kind": .string("started")
            ],
            ["id": .string("web"), "type": .string("webSearch"), "query": .string("Codex")],
            ["id": .string("image"), "type": .string("imageView"), "path": .string("/tmp/a.png")],
            ["id": .string("sleep"), "type": .string("sleep"), "durationMs": .integer(10)],
            [
                "id": .string("generation"), "type": .string("imageGeneration"),
                "status": .string("completed"), "result": .string("/tmp/a.png")
            ],
            ["id": .string("entered"), "type": .string("enteredReviewMode"), "review": .string("uncommittedChanges")],
            ["id": .string("exited"), "type": .string("exitedReviewMode"), "review": .string("uncommittedChanges")],
            ["id": .string("compact"), "type": .string("contextCompaction")],
            ["id": .string("future"), "type": .string("futureItem"), "newField": .string("preserve")]
        ])

        var state = CodexTaskState.empty
        XCTAssertTrue(steps.recording.applySnapshot(thread, to: &state))
        let turn = try XCTUnwrap(state.thread?.turns.first)
        XCTAssertEqual(turn.items.map(\.id), [
            "user", "hook", "agent", "plan", "reasoning", "command", "file", "mcp", "dynamic",
            "collab", "subagent", "web", "image", "sleep", "generation", "entered", "exited",
            "compact", "future"
        ])
        XCTAssertEqual(turn.items.last?.content.typeName, "futureItem")
        guard case let .unknown(_, raw) = turn.items.last?.content else {
            return XCTFail("future item should remain inspectable")
        }
        XCTAssertEqual(raw["newField"]?.stringValue, "preserve")
    }

    func testReducerReplayIsDeterministicAndProtectsTerminalOrdering() throws {
        let reducer = steps.recording
        let snapshot = makeThreadSnapshot(items: [])
        var first = CodexTaskState.empty
        var second = CodexTaskState.empty
        XCTAssertTrue(reducer.applySnapshot(snapshot, to: &first))
        XCTAssertTrue(reducer.applySnapshot(snapshot, to: &second))

        let events: [(String, JSONValue)] = [
            (
                "turn/started",
                object([
                    "threadId": .string("thread-1"),
                    "turn": object(["id": .string("turn-2"), "status": .string("inProgress")])
                ])
            ),
            (
                "item/agentMessage/delta",
                object([
                    "threadId": .string("thread-1"), "turnId": .string("turn-2"),
                    "itemId": .string("assistant-2"), "delta": .string("hello")
                ])
            ),
            (
                "turn/plan/updated",
                object([
                    "threadId": .string("thread-1"), "turnId": .string("turn-2"),
                    "plan": .array([object(["step": .string("Verify"), "status": .string("inProgress")])])
                ])
            ),
            (
                "thread/tokenUsage/updated",
                object([
                    "threadId": .string("thread-1"), "turnId": .string("turn-2"),
                    "tokenUsage": usageValue()
                ])
            ),
            (
                "item/completed",
                object([
                    "threadId": .string("thread-1"), "turnId": .string("turn-2"),
                    "item": object([
                        "id": .string("assistant-2"), "type": .string("agentMessage"),
                        "text": .string("hello world"), "phase": .string("final_answer")
                    ])
                ])
            ),
            (
                "turn/completed",
                object([
                    "threadId": .string("thread-1"),
                    "turn": object(["id": .string("turn-2"), "status": .string("completed")])
                ])
            )
        ]

        for (index, event) in events.enumerated() {
            XCTAssertTrue(reducer.applyNotification(
                method: event.0,
                params: event.1,
                sequence: UInt64(index + 1),
                to: &first
            ))
            XCTAssertTrue(reducer.applyNotification(
                method: event.0,
                params: event.1,
                sequence: UInt64(index + 1),
                to: &second
            ))
        }
        XCTAssertFalse(reducer.applyNotification(
            method: events[1].0,
            params: events[1].1,
            sequence: 2,
            to: &first
        ))
        XCTAssertEqual(first, second)

        let turn = try XCTUnwrap(first.thread?.turns.first(where: { $0.id == "turn-2" }))
        XCTAssertEqual(turn.status, .completed)
        XCTAssertEqual(turn.plan?.steps.first?.status, .inProgress)
        XCTAssertEqual(turn.tokenUsage?.total.totalTokens, 12)
        XCTAssertEqual(turn.items.first?.lifecycle, .completed)
        guard case let .agentMessage(message) = turn.items.first?.content else {
            return XCTFail("agent delta should create an agent item")
        }
        XCTAssertEqual(message.text, "hello world")

        let lateDelta: JSONValue = object([
            "threadId": .string("thread-1"), "turnId": .string("turn-2"),
            "itemId": .string("assistant-2"), "delta": .string(" ignored")
        ])
        XCTAssertTrue(reducer.applyNotification(
            method: "item/agentMessage/delta",
            params: lateDelta,
            sequence: 10,
            to: &first
        ))
        let unchanged = try XCTUnwrap(first.thread?.turns.first(where: { $0.id == "turn-2" }))
        guard case let .agentMessage(unchangedMessage) = unchanged.items.first?.content else {
            return XCTFail("terminal agent item disappeared")
        }
        XCTAssertEqual(unchangedMessage.text, "hello world")
    }

    func testActiveTurnIdentityOnlyExposesAnInProgressTurn() throws {
        let reducer = steps.recording
        var state = CodexTaskState.empty
        XCTAssertTrue(reducer.applySnapshot(makeThreadSnapshot(items: []), to: &state))
        XCTAssertNil(state.activeTurnID)

        XCTAssertTrue(reducer.applyNotification(
            method: "turn/started",
            params: object([
                "threadId": .string("thread-1"),
                "turn": object(["id": .string("turn-active"), "status": .string("inProgress")])
            ]),
            sequence: 1,
            to: &state
        ))
        XCTAssertEqual(state.activeTurnID, "turn-active")

        XCTAssertTrue(reducer.applyNotification(
            method: "turn/completed",
            params: object([
                "threadId": .string("thread-1"),
                "turn": object(["id": .string("turn-active"), "status": .string("completed")])
            ]),
            sequence: 2,
            to: &state
        ))
        XCTAssertNil(state.activeTurnID)
    }

    func testCompletionBeforeStartDoesNotRegressLifecycle() throws {
        var state = CodexTaskState.empty
        let reducer = steps.recording
        XCTAssertTrue(reducer.applySnapshot(makeThreadSnapshot(items: []), to: &state))
        let complete: JSONValue = object([
            "threadId": .string("thread-1"), "turnId": .string("turn-3"),
            "item": object(["id": .string("item-3"), "type": .string("contextCompaction")])
        ])
        XCTAssertTrue(reducer.applyNotification(
            method: "item/completed", params: complete, sequence: 1, to: &state
        ))
        XCTAssertTrue(reducer.applyNotification(
            method: "item/started", params: object([
                "threadId": .string("thread-1"), "turnId": .string("turn-3"),
                "item": object(["id": .string("item-3"), "type": .string("contextCompaction")])
            ]), sequence: 2, to: &state
        ))
        let item = try XCTUnwrap(
            state.thread?.turns.first(where: { $0.id == "turn-3" })?.items.first
        )
        XCTAssertEqual(item.lifecycle, .completed)
    }

    func testAllLockedServerRequestKindsAreRetainedAndUnknownCanBeRejected() throws {
        let reducer = steps.recording
        var state = CodexTaskState.empty
        let methods = [
            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
            "item/tool/requestUserInput",
            "mcpServer/elicitation/request",
            "item/permissions/requestApproval",
            "item/tool/call",
            "account/chatgptAuthTokens/refresh",
            "attestation/generate",
            "currentTime/read",
            "applyPatchApproval",
            "execCommandApproval",
            "future/serverRequest"
        ]
        for (index, method) in methods.enumerated() {
            XCTAssertTrue(reducer.applyServerRequest(
                id: .string("request-\(index)"),
                method: method,
                params: .object([
                    "threadId": .string("thread-1"),
                    "turnId": .string("turn-1"),
                    "itemId": .string("item-\(index)")
                ]),
                sequence: UInt64(index + 1),
                to: &state
            ))
        }

        XCTAssertEqual(state.serverRequestsByID.count, methods.count)
        XCTAssertEqual(
            state.serverRequestsByID["s:request-0"]?.kind,
            .commandExecutionApproval
        )
        XCTAssertEqual(
            state.serverRequestsByID["s:request-3"]?.kind,
            .mcpElicitation
        )
        XCTAssertEqual(
            state.serverRequestsByID["s:request-11"]?.kind,
            .unknown("future/serverRequest")
        )
        XCTAssertEqual(state.approvalsByID.count, 5)

        XCTAssertTrue(reducer.rejectServerRequest(
            id: "s:request-11",
            code: -32001,
            message: "unsupported",
            in: &state
        ))
        XCTAssertEqual(
            state.serverRequestsByID["s:request-11"]?.resolution,
            .rejected(code: -32001, message: "unsupported")
        )
    }

    func testTypedServerRequestResponsesPreserveLockedDecisionShapes() throws {
        let amendment = CodexServerRequestResponse.command(
            .acceptWithExecpolicyAmendment(["git status"])
        )
        XCTAssertEqual(
            amendment.result(for: "item/commandExecution/requestApproval")?["decision"]?["acceptWithExecpolicyAmendment"]?["execpolicy_amendment"]?.arrayValue,
            [.string("git status")]
        )
        XCTAssertEqual(
            CodexServerRequestResponse.fileChange(.acceptForSession)
                .result(for: "item/fileChange/requestApproval")?["decision"]?.stringValue,
            "acceptForSession"
        )
        XCTAssertEqual(
            CodexServerRequestResponse.permissions(
                permissions: .object(["network": .object(["enabled": .bool(true)])]),
                scope: .session,
                strictAutoReview: true
            ).result(for: "item/permissions/requestApproval")?["scope"]?.stringValue,
            "session"
        )
        XCTAssertEqual(
            CodexServerRequestResponse.toolUserInput(answers: ["q1": ["A", "B"]])
                .result(for: "item/tool/requestUserInput")?["answers"]?["q1"]?["answers"]?.arrayValue,
            [.string("A"), .string("B")]
        )
        XCTAssertEqual(
            CodexServerRequestResponse.mcpElicitation(
                action: .accept,
                content: .object(["email": .string("user@example.test")])
            ).result(for: "mcpServer/elicitation/request")?["action"]?.stringValue,
            "accept"
        )
        XCTAssertEqual(
            CodexServerRequestResponse.dynamicToolCall(
                contentItems: [.object(["type": .string("text")])],
                success: true
            ).result(for: "item/tool/call")?["success"]?.boolValue,
            true
        )
        XCTAssertEqual(
            CodexServerRequestResponse.legacyReview(.denied(rejection: "no"))
                .result(for: "execCommandApproval")?["decision"]?["denied"]?["rejection"]?.stringValue,
            "no"
        )
        XCTAssertNil(
            CodexServerRequestResponse.command(.accept)
                .result(for: "item/tool/requestUserInput")
        )
    }

    func testDeclinedCommandApprovalTerminatesTheRetainedCommandCard() throws {
        // "Deny" and "Deny and stop".
        for decision in ["decline", "cancel"] {
            let reducer = steps.recording
            var state = CodexTaskState.empty
            XCTAssertTrue(reducer.applySnapshot(makeThreadSnapshot(items: [[
                "id": .string("command-pending"),
                "type": .string("commandExecution"),
                "command": .string("touch /tmp/probe"),
                "cwd": .string("/tmp"),
                "status": .string("inProgress")
            ]]), to: &state))
            XCTAssertTrue(reducer.applyServerRequest(
                id: .string("approval-pending"),
                method: "item/commandExecution/requestApproval",
                params: .object([
                    "threadId": .string("thread-1"),
                    "turnId": .string("turn-1"),
                    "itemId": .string("command-pending")
                ]),
                sequence: 1,
                to: &state
            ))

            let answer: JSONValue = .object(["decision": .string(decision)])
            XCTAssertTrue(reducer.resolveServerRequest(id: "s:approval-pending", response: answer, in: &state))
            // Codex then says only that the request closed, without the answer: the card keeps the
            // person's, live and as saved for the next launch.
            reducer.applyNotification(method: "serverRequest/resolved", params: .object([
                "threadId": .string("thread-1"), "requestId": .string("approval-pending")
            ]), sequence: 2, to: &state)
            let request = try XCTUnwrap(state.serverRequestsByID["s:approval-pending"])
            XCTAssertEqual(request.resolution, .resolved(answer), decision)
            XCTAssertEqual(CodexRequestResponseProjection.request(request).state, .denied, decision)
            let saved = try JSONDecoder().decode(
                CodexPendingServerRequest.self, from: JSONEncoder().encode(CodexPendingServerRequest(request)))
            XCTAssertEqual(CodexRequestResponseProjection.request(saved.state).state, .denied, decision)

            guard decision == "decline" else { continue }
            let commandItem = try XCTUnwrap(state.thread?.turns.first?.items.first)
            XCTAssertEqual(commandItem.lifecycle, .completed)
            guard case let .commandExecution(command) = commandItem.content else {
                return XCTFail("declined command should remain a command card")
            }
            XCTAssertEqual(command.status, "declined")
            XCTAssertEqual(commandItem.raw["status"]?.stringValue, "declined")
        }
    }

    func testTerminalResumeInterruptsOnlyActivityWithoutAPendingApproval() throws {
        let reducer = steps.recording
        var state = CodexTaskState.empty
        XCTAssertTrue(reducer.applySnapshot(makeThreadSnapshot(items: [
            [
                "id": .string("orphaned-command"),
                "type": .string("commandExecution"),
                "command": .string("touch /tmp/orphaned"),
                "cwd": .string("/tmp"),
                "status": .string("inProgress")
            ],
            [
                "id": .string("pending-command"),
                "type": .string("commandExecution"),
                "command": .string("touch /tmp/pending"),
                "cwd": .string("/tmp"),
                "status": .string("inProgress")
            ]
        ]), to: &state))
        state.thread?.turns[0].items[0].lifecycle = .inProgress
        state.thread?.turns[0].items[1].lifecycle = .inProgress
        XCTAssertTrue(reducer.applyServerRequest(
            id: .string("approval-still-pending"),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("pending-command")
            ]),
            sequence: 1,
            to: &state
        ))

        reducer.reconcileTerminalActivityItems(in: &state)

        let items = try XCTUnwrap(state.thread?.turns.first?.items)
        let orphaned = try XCTUnwrap(items.first { $0.id == "orphaned-command" })
        XCTAssertEqual(orphaned.lifecycle, .completed)
        guard case let .commandExecution(orphanedCommand) = orphaned.content else {
            return XCTFail("orphaned activity should remain a command card")
        }
        XCTAssertEqual(orphanedCommand.status, "interrupted")

        let pending = try XCTUnwrap(items.first { $0.id == "pending-command" })
        XCTAssertEqual(pending.lifecycle, .inProgress)
        guard case let .commandExecution(pendingCommand) = pending.content else {
            return XCTFail("pending activity should remain a command card")
        }
        XCTAssertEqual(pendingCommand.status, "inProgress")
    }

    func testPersistedDeclineWinsAfterActivityHistoryMergesLater() throws {
        let reducer = steps.recording
        var state = CodexTaskState.empty
        XCTAssertTrue(reducer.applySnapshot(makeThreadSnapshot(items: [[
            "id": .string("late-command"),
            "type": .string("commandExecution"),
            "command": .string("touch /tmp/late"),
            "cwd": .string("/tmp"),
            "status": .string("inProgress")
        ]]), to: &state))
        state.thread?.turns[0].items[0].lifecycle = .inProgress
        state.serverRequestsByID["approval-resolved"] = CodexServerRequestState(
            id: "approval-resolved",
            method: "item/commandExecution/requestApproval",
            kind: .commandExecutionApproval,
            threadID: "thread-1",
            turnID: "turn-1",
            itemID: "late-command",
            params: nil,
            resolution: .resolved(.object(["decision": .string("decline")]))
        )

        reducer.reconcileResolvedServerRequestItems(in: &state)
        reducer.reconcileTerminalActivityItems(in: &state)

        let item = try XCTUnwrap(state.thread?.turns.first?.items.first)
        XCTAssertEqual(item.lifecycle, .completed)
        guard case let .commandExecution(command) = item.content else {
            return XCTFail("reconciled item should remain a command card")
        }
        XCTAssertEqual(command.status, "declined")
    }

    private func makeThreadSnapshot(items: [[String: JSONValue]]) -> JSONValue {
        object([
            "id": .string("thread-1"), "sessionId": .string("session-1"),
            "preview": .string("Restore Codex"), "cwd": .string("/tmp/workspace"),
            "cliVersion": .string("0.148.0-alpha.9"), "modelProvider": .string("openai"),
            "createdAt": .integer(1_700_000_000), "updatedAt": .integer(1_700_000_010),
            "ephemeral": .bool(false), "status": object(["type": .string("idle")]),
            "turns": .array([object([
                "id": .string("turn-1"), "status": .string("completed"),
                "itemsView": .string("full"), "items": .array(items.map(JSONValue.object))
            ])])
        ])
    }

    private func usageValue() -> JSONValue {
        let breakdown: JSONValue = object([
            "inputTokens": .integer(4), "cachedInputTokens": .integer(1),
            "outputTokens": .integer(5), "reasoningOutputTokens": .integer(2),
            "totalTokens": .integer(12)
        ])
        return object(["total": breakdown, "last": breakdown, "modelContextWindow": .integer(100)])
    }

    private func object(_ values: [String: JSONValue]) -> JSONValue {
        .object(values)
    }
}
