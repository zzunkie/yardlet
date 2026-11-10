import Foundation
import XCTest
@testable import NativeHarnessClient

final class ClaudeSessionProjectionTests: XCTestCase {
    func testProductYHPRoutePreservesPlansAndBackgroundTermination() async throws {
        let transport = FakeClaudeTransport()
        let adapter = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport }),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/claude-parity"), initialPrompt: nil
        ))
        let recorder = ParityRecorder()
        let finished = expectation(description: "background terminal event through the product route")
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
                if case let .activityCompleted(activity) = event.payload,
                   activity.id == "agent", activity.outcome == .stopped {
                    finished.fulfill()
                    break
                }
            }
        }
        try await adapter.send("Review", to: handle)
        for json in [
            agentStart, backgroundStart, agentAcknowledgement,
            #"{"type":"assistant","parent_tool_use_id":"agent","message":{"content":[{"type":"text","text":"Hidden child answer"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"list","name":"TaskList","input":{}}]}}"#,
            #"{"type":"user","tool_use_result":{"tasks":[{"id":"1","subject":"Read the code","status":"in_progress","blockedBy":[]}]},"message":{"content":[{"type":"tool_result","tool_use_id":"list","content":"Task list"}]}}"#,
            successfulTurn,
            #"{"type":"system","subtype":"task_updated","task_id":"bg","patch":{"status":"killed"}}"#
        ] { await transport.emit(try decode(json)) }
        await fulfillment(of: [finished], timeout: 3)
        collector.cancel()
        let payloads = await recorder.payloads
        XCTAssertTrue(payloads.contains(.planUpdated("◉ Read the code")))
        let turnEnd = try XCTUnwrap(payloads.firstIndex(of: .turnCompleted))
        var builder = TranscriptBuilder()
        for payload in payloads.prefix(through: turnEnd) { builder.apply(payload) }
        XCTAssertEqual(activity("agent", in: builder)?.state, .running)
        XCTAssertEqual(activity("agent", in: builder)?.value.isBackground, true)
        for payload in payloads.dropFirst(turnEnd + 1) { builder.apply(payload) }
        XCTAssertEqual(activity("agent", in: builder)?.state, .stopped)
        XCTAssertFalse(payloads.contains(.assistantMessageCompleted("Hidden child answer")))
        await adapter.close(handle)
    }

    func testNestedMessagesDoNotOverwriteTheMainAnswerThinkingOrTools() throws {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        builder.appendUser("Review the code")
        let frames = [
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Main "}}}"#,
            #"{"type":"stream_event","parent_tool_use_id":"agent","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Child answer"}}}"#,
            #"{"type":"stream_event","parent_tool_use_id":"agent","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"Child thinking"}}}"#,
            #"{"type":"assistant","parent_tool_use_id":"agent","message":{"content":[{"type":"text","text":"Child answer"},{"type":"tool_use","id":"child-tool","name":"Bash","input":{"command":"pwd"}}]}}"#,
            #"{"type":"user","parent_tool_use_id":"agent","message":{"content":[{"type":"tool_result","tool_use_id":"child-tool","content":"/tmp"}]}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"answer"}}}"#
        ]
        for json in frames {
            let frame = try decode(json)
            if frame["parent_tool_use_id"]?.stringValue != nil {
                XCTAssertTrue(ClaudeEventProjector().payloads(from: frame).isEmpty)
            }
            for payload in projection.payloads(from: frame) { builder.apply(payload) }
        }
        XCTAssertEqual(builder.entries.count, 2)
        XCTAssertEqual(builder.entries.last?.content, .assistant(text: "Main answer", isStreaming: true))
    }

    func testBackgroundAgentSurvivesItsAcknowledgementAndForegroundTurn() throws {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        builder.appendUser("Review in the background")
        try apply(agentStart, to: &projection, builder: &builder)
        try apply(backgroundStart, to: &projection, builder: &builder)
        try apply(agentAcknowledgement, to: &projection, builder: &builder)
        try apply(successfulTurn, to: &projection, builder: &builder)
        XCTAssertEqual(activity("agent", in: builder)?.state, .running)
        XCTAssertEqual(activity("agent", in: builder)?.value.isBackground, true)

        try apply(#"{"type":"system","subtype":"task_progress","task_id":"bg","tool_use_id":"agent","description":"Review","last_tool_name":"Read","usage":{"tool_uses":4,"total_tokens":900,"duration_ms":1250}}"#,
                  to: &projection, builder: &builder)
        XCTAssertEqual(activity("agent", in: builder)?.state, .running)
        XCTAssertTrue(activity("agent", in: builder)?.value.output?.contains("900") == true)
        XCTAssertTrue(activity("agent", in: builder)?.value.input?.contains("Review the code") == true)

        try apply(#"{"type":"system","subtype":"task_notification","task_id":"bg","status":"failed","summary":"The check failed"}"#,
                  to: &projection, builder: &builder)
        XCTAssertEqual(activity("agent", in: builder)?.state, .failed)
        XCTAssertEqual(activity("agent", in: builder)?.value.output, "The check failed")
        XCTAssertEqual(builder.entries.filter { if case .activity = $0.content { true } else { false } }.count, 1)
        let late = try decode(#"{"type":"system","subtype":"task_progress","task_id":"bg","usage":{"tool_uses":5,"total_tokens":1000,"duration_ms":1500}}"#)
        XCTAssertTrue(projection.payloads(from: late).isEmpty)
    }

    func testTaskUpdatedKilledTerminatesWithoutANotification() throws {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        try apply(agentStart, to: &projection, builder: &builder)
        try apply(backgroundStart, to: &projection, builder: &builder)
        try apply(successfulTurn, to: &projection, builder: &builder)
        try apply(#"{"type":"system","subtype":"task_updated","task_id":"bg","patch":{"status":"killed"}}"#,
                  to: &projection, builder: &builder)
        XCTAssertEqual(activity("agent", in: builder)?.state, .stopped)
    }

    /// Claude Code runs its background work on after a turn that ends on a usage limit or an error, as
    /// after one that completes (2.1.308 reported a background shell finished minutes after the limit
    /// stopped its turn), so its card keeps running and an account move keeps waiting for it. When the
    /// CLI's process ends, the work ends with it, which the CLI cannot report: the adapter stops the card.
    func testBackgroundWorkOutlivesTurnsEndedByALimitOrAnErrorButNotItsProcess() async throws {
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport })
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/claude-parity"), initialPrompt: nil
        ))
        let recorder = ParityRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) { await recorder.append(event.payload) }
        }
        defer { collector.cancel() }
        func backgroundCard() async -> TranscriptActivityState? {
            var builder = TranscriptBuilder()
            for payload in await recorder.payloads { builder.apply(payload) }
            return activity("agent", in: builder)?.state
        }
        func turnsEnded() async -> Int { await recorder.payloads.filter { $0 == .turnCompleted }.count }

        try await adapter.send("Review", to: handle)
        for json in [
            agentStart, backgroundStart, agentAcknowledgement,
            #"{"type":"assistant","error":"rate_limit","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"You've hit your limit"}]}}"#,
            #"{"type":"result","subtype":"success","is_error":true,"result":"You've hit your limit"}"#
        ] { await transport.emit(try decode(json)) }
        try await waitUntil { await turnsEnded() == 1 }
        let limitTurn = await recorder.payloads
        XCTAssertTrue(limitTurn.contains { if case .usageLimitReached = $0 { true } else { false } })
        let afterLimit = await backgroundCard()
        XCTAssertEqual(afterLimit, .running)

        await transport.emit(try decode(#"{"type":"result","subtype":"success","is_error":true,"result":"API Error: 500"}"#))
        try await waitUntil { await turnsEnded() == 2 }
        let afterError = await backgroundCard()
        XCTAssertEqual(afterError, .running)

        await transport.crash()
        try await waitUntil { await backgroundCard() == .stopped }
        await adapter.close(handle)
    }

    /// Claude Code 2.1.318 refuses a turn with no login as a synthetic assistant message and an error
    /// `result` in the same words: the card that offers the sign-in, not an answer as well.
    func testATurnRefusedForItsSignInIsTheErrorCardAlone() throws {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        try apply(#"{"type":"assistant","error":"authentication_failed","isApiErrorMessage":true,"message":{"id":"m","role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"Not logged in · Please run /login"}]}}"#,
                  to: &projection, builder: &builder)
        try apply(#"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#,
                  to: &projection, builder: &builder)
        XCTAssertEqual(builder.entries.count, 1)
        guard case let .error(message, _, _)? = builder.entries.first?.content else {
            return XCTFail("\(builder.entries)")
        }
        XCTAssertEqual(TranscriptRecoveryProjection.errorSummary(message), ProviderSignIn.prompt)
        XCTAssertEqual(message, "Not logged in · Please run /login", "Details keep the CLI's words")
    }

    func testLateLaunchAcknowledgementDoesNotEraseFailure() throws {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        try apply(agentStart, to: &projection, builder: &builder)
        try apply(backgroundStart, to: &projection, builder: &builder)
        try apply(#"{"type":"system","subtype":"task_notification","task_id":"bg","status":"failed","summary":"Timed out"}"#,
                  to: &projection, builder: &builder)
        try apply(agentAcknowledgement, to: &projection, builder: &builder)
        XCTAssertEqual(activity("agent", in: builder)?.state, .failed)
        XCTAssertEqual(activity("agent", in: builder)?.value.output, "Timed out")
    }

    func testMovingAnAgentToTheBackgroundUsesTheProviderPatch() throws {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        try apply(agentStart, to: &projection, builder: &builder)
        try apply(#"{"type":"system","subtype":"task_started","task_id":"bg","tool_use_id":"agent","description":"Review","is_backgrounded":false,"task_type":"local_agent"}"#,
                  to: &projection, builder: &builder)
        try apply(#"{"type":"system","subtype":"task_updated","task_id":"bg","patch":{"is_backgrounded":true}}"#,
                  to: &projection, builder: &builder)
        try apply(successfulTurn, to: &projection, builder: &builder)
        XCTAssertEqual(activity("agent", in: builder)?.state, .running)
        builder.endRuntime()
        XCTAssertEqual(activity("agent", in: builder)?.state, .stopped)
    }

    func testLateBackgroundPatchIsAuthoritativeButLateForegroundProgressIsNot() throws {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        try apply(agentStart, to: &projection, builder: &builder)
        try apply(#"{"type":"system","subtype":"task_started","task_id":"bg","tool_use_id":"agent","description":"Review","is_backgrounded":false}"#,
                  to: &projection, builder: &builder)
        try apply(successfulTurn, to: &projection, builder: &builder)
        XCTAssertEqual(activity("agent", in: builder)?.state, .stopped)
        let progress = try decode(#"{"type":"system","subtype":"task_progress","task_id":"bg","summary":"Read"}"#)
        XCTAssertTrue(projection.payloads(from: progress).isEmpty)
        try apply(#"{"type":"system","subtype":"task_updated","task_id":"bg","patch":{"is_backgrounded":true}}"#,
                  to: &projection, builder: &builder)
        XCTAssertEqual(activity("agent", in: builder)?.state, .running)
        XCTAssertNil(activity("agent", in: builder)?.value.outcome)
    }

    func testForegroundAgentResultAfterItsTaskEndsKeepsTheSubagentCard() throws {
        // The CLI can finish a foreground agent's task before the Agent call's own result.
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        builder.appendUser("Summarize the README with an agent")
        var payloads: [HarnessEventPayload] = []
        for json in [
            agentStart,
            #"{"type":"system","subtype":"task_started","task_id":"fg","tool_use_id":"agent","description":"Review","task_type":"local_agent","prompt":"Review the code"}"#,
            #"{"type":"assistant","parent_tool_use_id":"agent","message":{"content":[{"type":"tool_use","id":"child-read","name":"Read","input":{"file_path":"README.md"}}]}}"#,
            #"{"type":"system","subtype":"task_progress","task_id":"fg","tool_use_id":"agent","description":"Review","last_tool_name":"Read","usage":{"tool_uses":1,"total_tokens":900,"duration_ms":1200}}"#,
            #"{"type":"system","subtype":"task_notification","task_id":"fg","tool_use_id":"agent","status":"completed","summary":"The code is fine.","usage":{"tool_uses":1,"total_tokens":1000,"duration_ms":3200}}"#,
            #"{"type":"user","tool_use_result":{"status":"completed","agentId":"child-agent","content":[{"type":"text","text":"The code is fine."}],"totalToolUseCount":1,"totalTokens":990,"totalDurationMs":3190},"message":{"content":[{"type":"tool_result","tool_use_id":"agent","content":[{"type":"text","text":"[Subagent hand-back] Framing for the model. The report follows:\n  The code is fine."}]}]}}"#,
            successfulTurn
        ] {
            let frame = projection.payloads(from: try decode(json))
            payloads += frame
            frame.forEach { builder.apply($0) }
        }
        XCTAssertFalse(payloads.contains { payload in
            if case let .activityCompleted(activity) = payload { return activity.kind == "tool_result" }
            return false
        })
        let cards = builder.entries.filter { if case .activity = $0.content { true } else { false } }
        XCTAssertEqual(cards.count, 1)
        let card = try XCTUnwrap(activity("agent", in: builder))
        XCTAssertEqual(card.state, .completed)
        XCTAssertEqual(card.value.kind, "Agent")
        XCTAssertEqual(card.value.title, "Review")
        XCTAssertEqual(card.value.output, "The code is fine.\n" + L10n.format("%@ tool uses · %@ tokens · %@ s", "1", "1000", "3.2"))
        XCTAssertEqual(card.value.subtask, HarnessSubtaskReference(
            taskID: "fg", agentID: "child-agent", toolUseID: "agent", taskType: "local_agent"
        ))
    }

    func testNestedAgentTaskLifecycleDoesNotCreateAnotherMainCard() throws {
        var projection = ClaudeSessionProjection()
        for json in [
            #"{"type":"system","subtype":"task_started","task_id":"nested","tool_use_id":"nested-tool","description":"Nested","task_type":"local_agent","spawn_depth":2}"#,
            #"{"type":"system","subtype":"task_progress","task_id":"nested","summary":"Read"}"#,
            #"{"type":"system","subtype":"task_notification","task_id":"nested","status":"completed","summary":"Done"}"#
        ] { XCTAssertTrue(projection.payloads(from: try decode(json)).isEmpty) }
    }

    func testForegroundWorkStillStopsWhenItsTurnEndsAndDetachedBackgroundIsOmitted() throws {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        try apply(agentStart, to: &projection, builder: &builder)
        try apply(successfulTurn, to: &projection, builder: &builder)
        XCTAssertEqual(activity("agent", in: builder)?.state, .stopped)
        builder.apply(.activityStarted(HarnessActivity(
            id: "background", kind: "Agent", title: "Review", isBackground: true
        )))
        let restored = TranscriptBuilder(entries: builder.entries)
        XCTAssertNil(activity("background", in: restored))
        let cached = try JSONDecoder().decode(HarnessActivity.self, from: Data(
            #"{"id":"old","kind":"Bash","title":"Bash","detail":null}"#.utf8
        ))
        XCTAssertNil(cached.isBackground)
    }

    func testAmbientTasksDoNotAppearInTheTranscript() throws {
        var projection = ClaudeSessionProjection()
        for json in [
            #"{"type":"system","subtype":"task_started","task_id":"hidden","description":"Watcher","ambient":true}"#,
            #"{"type":"system","subtype":"task_progress","task_id":"hidden","summary":"Still watching"}"#,
            #"{"type":"system","subtype":"task_updated","task_id":"hidden","patch":{"status":"completed"}}"#,
            #"{"type":"system","subtype":"task_notification","task_id":"hidden","status":"completed","summary":"Done"}"#
        ] {
            XCTAssertTrue(projection.payloads(from: try decode(json)).isEmpty)
        }
    }

    func testTodoListChangesOnlyAfterItsSuccessfulToolResult() throws {
        var projection = ClaudeSessionProjection()
        let start = try decode(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"todo","name":"TodoWrite","input":{"todos":[{"content":"Read the code","status":"completed","activeForm":"Reading"},{"content":"Run checks","status":"in_progress","activeForm":"Checking"}]}}]}}"#)
        XCTAssertFalse(projection.payloads(from: start).contains { if case .planUpdated = $0 { true } else { false } })
        let finish = try decode(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"todo","content":"Updated"}]}}"#)
        XCTAssertTrue(projection.payloads(from: finish).contains(.planUpdated("☑ Read the code\n◉ Run checks")))

        _ = projection.payloads(from: start)
        let failure = try decode(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"todo","content":"Denied","is_error":true}]}}"#)
        XCTAssertFalse(projection.payloads(from: failure).contains { if case .planUpdated = $0 { true } else { false } })
    }

    func testTaskListAndSuccessfulUpdatesRebuildProviderStateWithoutGuessing() throws {
        var tasks = ClaudeTaskListProjection()
        XCTAssertNil(tasks.completedTool(name: "TaskUpdate", input: try decode(#"{"taskId":"unknown","status":"completed"}"#), result: try decode(#"{"success":true,"taskId":"unknown","updatedFields":["status"]}"#)))
        XCTAssertEqual(tasks.completedTool(name: "TaskCreate", input: .object([:]), result: try decode(#"{"task":{"id":"1","subject":"Read the code"}}"#)), "☐ Read the code")
        XCTAssertNil(tasks.completedTool(name: "TaskUpdate", input: try decode(#"{"taskId":"1","status":"completed"}"#), result: try decode(#"{"success":false,"taskId":"1","error":"not found"}"#)))
        XCTAssertEqual(tasks.completedTool(name: "TaskUpdate", input: try decode(#"{"taskId":"1","status":"in_progress"}"#), result: try decode(#"{"success":true,"taskId":"1","updatedFields":["status"],"statusChange":{"from":"pending","to":"completed"}}"#)), "☑ Read the code")
        XCTAssertEqual(tasks.completedTool(name: "TaskList", input: .object([:]), result: try decode(#"{"tasks":[{"id":"2","subject":"Run checks","status":"in_progress","blockedBy":[]}]}"#)), "◉ Run checks")
        XCTAssertNil(tasks.completedTool(name: "TaskList", input: .object([:]), result: try decode(#"{"tasks":[{"id":"bad","subject":"Bad","status":"unknown"}]}"#)))
        XCTAssertEqual(tasks.completedTool(name: "TaskGet", input: .object([:]), result: try decode(#"{"task":{"id":"2","subject":"Run checks","status":"completed"}}"#)), "☑ Run checks")
        XCTAssertEqual(tasks.completedTool(name: "TaskUpdate", input: try decode(#"{"taskId":"2","status":"deleted"}"#), result: try decode(#"{"success":true,"taskId":"2","updatedFields":["status"]}"#)), L10n.string("No tasks"))
    }

    func testTypedTaskResultIsCorrelatedWithTheToolCall() throws {
        var projection = ClaudeSessionProjection()
        _ = projection.payloads(from: try decode(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"create","name":"TaskCreate","input":{"subject":"Proposed title"}}]}}"#))
        let payloads = projection.payloads(from: try decode(#"{"type":"user","tool_use_result":{"task":{"id":"1","subject":"Actual title"}},"message":{"content":[{"type":"tool_result","tool_use_id":"create","content":"Created"}]}}"#))
        XCTAssertTrue(payloads.contains(.planUpdated("☐ Actual title")))
    }

    private let agentStart = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"agent","name":"Agent","input":{"description":"Review","prompt":"Review the code"}}]}}"#
    private let backgroundStart = #"{"type":"system","subtype":"task_started","task_id":"bg","tool_use_id":"agent","description":"Review","task_type":"local_agent","is_backgrounded":true}"#
    private let agentAcknowledgement = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"agent","content":"Agent launched in the background"}]}}"#
    private let successfulTurn = #"{"type":"result","is_error":false,"subtype":"success"}"#

    private func decode(_ json: String) throws -> JSONValue {
        try ClaudeWireCodec().decodeLine(Data(json.utf8))
    }

    /// A tool result's images go with its call, live and read back from the history alike: the image
    /// file `Read` returned and an MCP screenshot beside its text, each inline, for the call's line to
    /// preview. The reading cache keeps none of their bytes.
    func testAToolResultsImagesStayWithTheCallButOutOfTheReadingCache() throws {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        builder.appendUser("Look at the settings window")
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        for json in [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"read","name":"Read","input":{"file_path":"/tmp/settings.png"}},{"type":"tool_use","id":"shot","name":"mcp__computer-use__app_screenshot","input":{"app":"com.example"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"read","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(png)"}}]}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"shot","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(png)"}},{"type":"text","text":"Captured the window"}]}]}}"#
        ] { try apply(json, to: &projection, builder: &builder) }

        for id in ["read", "shot"] {
            let call = try XCTUnwrap(activity(id, in: builder))
            XCTAssertEqual(call.state, .completed)
            XCTAssertEqual(call.value.images?.compactMap(\.url?.scheme), ["data"], id)
            guard case let .tool(tool) = ConversationActivityProjection.kind(
                call.value, harness: .claudeCode, phase: .completed, isApproved: false
            ) else { return XCTFail("\(id) is a call's line") }
            XCTAssertEqual(tool.previewImages.count, 1, id)
            let saved = try JSONDecoder().decode(HarnessActivity.self, from: JSONEncoder().encode(call.value))
            XCTAssertEqual(saved.images?.count, 1)
            XCTAssertNil(saved.images?.first?.url, "the reading cache keeps no inline bytes")
        }
        XCTAssertEqual(activity("shot", in: builder)?.value.output, "Captured the window")
    }

    private func apply(_ json: String, to projection: inout ClaudeSessionProjection, builder: inout TranscriptBuilder) throws {
        for payload in projection.payloads(from: try decode(json)) { builder.apply(payload) }
    }

    private func activity(_ id: String, in builder: TranscriptBuilder) -> (value: HarnessActivity, state: TranscriptActivityState)? {
        for entry in builder.entries {
            if case let .activity(value, state) = entry.content, value.id == id { return (value, state) }
        }
        return nil
    }
}

private actor ParityRecorder {
    private(set) var payloads: [HarnessEventPayload] = []
    func append(_ payload: HarnessEventPayload) { payloads.append(payload) }
}
