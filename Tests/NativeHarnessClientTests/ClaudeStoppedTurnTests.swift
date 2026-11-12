import AppKit
import Foundation
import XCTest
@testable import NativeHarnessClient

/// A turn Yardlet asked Claude Code to stop still ends with a `result`, as an error. Stop and a
/// Send now the CLI answered by stopping the turn end it as stopped: no error card, the text it
/// streamed stays, and the task is ready. A failure Yardlet did not cause shows as before.
final class ClaudeStoppedTurnTests: XCTestCase {
    // MARK: - The CLI's result

    func testOnlyAnAbortedTurnsResultReadsAsAStop() throws {
        XCTAssertTrue(ClaudeProtocol.endsAbortedTurn(try json(StoppedTurnFrames.abortedWhileAnswering),
                                                     allowingUnstatedReason: false))
        XCTAssertTrue(ClaudeProtocol.endsAbortedTurn(try json(StoppedTurnFrames.abortedWhileToolsRan),
                                                     allowingUnstatedReason: false))
        // A CLI from before `terminal_reason` says only the subtype.
        let unstated = try json(StoppedTurnFrames.abortedWithoutReason)
        XCTAssertTrue(ClaudeProtocol.endsAbortedTurn(unstated, allowingUnstatedReason: true))
        XCTAssertFalse(ClaudeProtocol.endsAbortedTurn(unstated, allowingUnstatedReason: false))
        for failure in [StoppedTurnFrames.apiError, StoppedTurnFrames.setupFailed, StoppedTurnFrames.notLoggedIn,
                        StoppedTurnFrames.completed] {
            XCTAssertFalse(ClaudeProtocol.endsAbortedTurn(try json(failure), allowingUnstatedReason: true), failure)
        }
        var nested = try XCTUnwrap(try json(StoppedTurnFrames.abortedWhileAnswering).objectValue)
        nested["parent_tool_use_id"] = .string("toolu_01")
        XCTAssertFalse(ClaudeProtocol.endsAbortedTurn(.object(nested), allowingUnstatedReason: true),
                       "A subagent's result is not the conversation's turn")
    }

    // MARK: - Stop

    /// Stop on both routes: the aborted result ends the turn as stopped. What streamed stays and
    /// no error card is drawn.
    func testStopEndsTheTurnAsStoppedAndKeepsWhatStreamed() async throws {
        for routed in [false, true] {
            let session = try await StoppedTurnSession(routed: routed)
            try await session.adapter.send("Write the release notes", to: session.handle)
            await session.emit(StoppedTurnFrames.delta("The release adds "))
            try await session.waitFor { $0.contains(.assistantDelta("The release adds ")) }

            try await session.adapter.interrupt(session.handle)
            await session.emit(StoppedTurnFrames.interruptionMarker)
            await session.emit(StoppedTurnFrames.abortedWhileAnswering)
            try await session.waitForTurnEnd()

            let payloads = await session.log.payloads
            XCTAssertFalse(payloads.contains { if case .error = $0 { true } else { false } }, "routed: \(routed)")
            XCTAssertFalse(payloads.contains(.sessionStatusChanged(.failed)))
            XCTAssertTrue(payloads.contains(.turnCompleted))
            XCTAssertEqual(payloads.last, .sessionStatusChanged(.ready))
            var transcript = TranscriptBuilder()
            payloads.forEach { transcript.apply($0) }
            XCTAssertEqual(transcript.entries.map(\.content), [.assistant(text: "The release adds ", isStreaming: false)])
            XCTAssertNotNil(transcript.entries.last?.turnStoppedAt, "the turn reads as the person's stop")
            await session.close()
        }
    }

    /// Stop while calls run: the CLI answers each call it cut with a failed result, one the call's own
    /// (a command cut short), one a refusal addressed to the model. Each reads as stopped without that
    /// text, the turn as the person's stop, on both routes. A call that finished before keeps its result.
    func testStopEndsTheCallsItCutAsStopped() async throws {
        for routed in [false, true] {
            let payloads = try await StoppedTurnSession.stoppedWhileCallsRan(
                request: "Run the sleep, then tell me how many tests passed", routed: routed)
            let stop = try XCTUnwrap(payloads.firstIndex(of: .turnStopped), "routed: \(routed)")
            XCTAssertLessThan(stop, try XCTUnwrap(payloads.firstIndex(of: .turnCompleted)))
            var transcript = TranscriptBuilder()
            transcript.appendUser("Run the sleep, then tell me how many tests passed")
            payloads.forEach { transcript.apply($0) }
            let calls = transcript.entries.compactMap { entry -> (String, TranscriptActivityState, String?)? in
                guard case let .activity(activity, state) = entry.content else { return nil }
                return (activity.id, state, activity.output)
            }
            XCTAssertEqual(calls.map(\.0), ["toolu_version", "toolu_sleep", "toolu_tests"])
            XCTAssertEqual(calls.map(\.1), [.completed, .stopped, .stopped], "routed: \(routed)")
            XCTAssertEqual(calls.map(\.2), ["0.4.2", nil, nil], "routed: \(routed)")
            let turn = try XCTUnwrap(TranscriptConversationProjection.presentation(
                from: transcript.entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true
            ).turns.last)
            XCTAssertEqual(turn.status, .interrupted)
        }
    }

    /// A Stop with no turn running asks the CLI all the same, but marks nothing: the next turn's
    /// failure is still one.
    func testStopWithNoTurnRunningLeavesTheNextTurnsFailureAsItIs() async throws {
        let session = try await StoppedTurnSession(routed: false)
        try await session.adapter.interrupt(session.handle)
        try await session.adapter.send("Run the tests", to: session.handle)
        await session.emit(StoppedTurnFrames.abortedWhileAnswering)
        try await session.waitForTurnEnd(failed: true)
        let payloads = await session.log.payloads
        XCTAssertTrue(payloads.contains(.error(message: "Claude reported an error", recoverable: true)))
        XCTAssertEqual(payloads.last, .sessionStatusChanged(.failed))
        await session.close()
    }

    /// Stop asks for the turn to end, not for a failure to be hidden: an API error, or a result
    /// that says the turn failed for another reason, shows as before.
    func testAFailureAfterStopStillShows() async throws {
        for failure in [StoppedTurnFrames.apiError, StoppedTurnFrames.setupFailed] {
            let session = try await StoppedTurnSession(routed: false)
            try await session.adapter.send("Run the tests", to: session.handle)
            try await session.adapter.interrupt(session.handle)
            await session.emit(failure)
            try await session.waitForTurnEnd(failed: true)
            let payloads = await session.log.payloads
            XCTAssertTrue(payloads.contains { if case .error = $0 { true } else { false } }, failure)
            XCTAssertFalse(payloads.contains(.turnStopped), failure)
            XCTAssertEqual(payloads.last, .sessionStatusChanged(.failed))
            await session.close()
        }
    }

    /// The stop settles at the turn's own result: a turn that finished before the Stop reached
    /// the CLI leaves nothing that would hide the next turn's failure.
    func testAStopSettlesAtTheNextResult() async throws {
        let session = try await StoppedTurnSession(routed: false)
        try await session.adapter.send("Run the tests", to: session.handle)
        try await session.adapter.interrupt(session.handle)
        await session.emit(StoppedTurnFrames.completed)
        try await session.waitForTurnEnd()
        try await session.adapter.send("Run them again", to: session.handle)
        await session.emit(StoppedTurnFrames.abortedWhileAnswering)
        try await session.waitFor { $0.filter { $0 == .sessionStatusChanged(.ready) }.count == 2 && $0.last == .sessionStatusChanged(.failed) }
        let payloads = await session.log.payloads
        XCTAssertEqual(payloads.filter { if case .error = $0 { true } else { false } }.count, 1)
        await session.close()
    }

    /// Without any stop from Yardlet, the same aborted-turn result is still an error, as before, and a
    /// call that failed reads as failed with what it returned.
    func testAnAbortedResultYardletDidNotCauseStillShows() async throws {
        let session = try await StoppedTurnSession(routed: true)
        try await session.adapter.send("Run the tests", to: session.handle)
        await session.emit(StoppedTurnFrames.twoCommands)
        await session.emit(StoppedTurnFrames.testsFailed)
        await session.emit(StoppedTurnFrames.abortedWhileAnswering)
        try await session.waitForTurnEnd(failed: true)
        let payloads = await session.log.payloads
        XCTAssertTrue(payloads.contains(.error(message: "Claude reported an error", recoverable: true)))
        XCTAssertFalse(payloads.contains(.turnStopped))
        XCTAssertEqual(payloads.last, .sessionStatusChanged(.failed))
        let failed = payloads.compactMap { payload -> HarnessActivity? in
            guard case let .activityCompleted(activity) = payload else { return nil }
            return activity
        }
        XCTAssertEqual(failed.map(\.outcome), [.failed])
        XCTAssertEqual(failed.first?.output, "Exit code 1\nFAILED (failures=1)")
        await session.close()
    }

    // MARK: - Send now

    /// Send now that the CLI answered `stopped`: its aborted turn ends as stopped on both routes,
    /// and the message then starts its own turn.
    func testSendNowThatStopsTheTurnEndsItAsStopped() async throws {
        for routed in [false, true] {
            let session = try await StoppedTurnSession(routed: routed)
            let id = try await session.runningTurnWithQueuedFollowUp()
            await session.transport.setInterruptResponse(.object([
                "send_now": .string("stopped"), "still_queued": .array([.string(id)])
            ]))
            let answer = try await session.followUps.sendFollowUpNow(messageID: id, in: session.handle)
            XCTAssertEqual(answer, .stopped)
            await session.emit(StoppedTurnFrames.interruptionMarker)
            await session.emit(StoppedTurnFrames.abortedWhileAnswering)
            try await session.waitForTurnEnd()
            await session.emit(SendNowFrames.lifecycle(id, "started"))
            try await session.waitFor { $0.last == .sessionStatusChanged(.running) }

            let payloads = await session.log.payloads
            XCTAssertFalse(payloads.contains { if case .error = $0 { true } else { false } }, "routed: \(routed)")
            XCTAssertFalse(payloads.contains(.sessionStatusChanged(.failed)))
            XCTAssertTrue(payloads.contains(.followUpDelivery(.init(messageID: id, state: .read, joinsRunningTurn: false))))
            await session.close()
        }
    }

    /// The CLI writes the stopped turn's result after its answer, but the result can be read
    /// first. It still ends the turn as stopped, and the answer read after it marks nothing more.
    func testSendNowWhoseResultIsReadBeforeItsAnswerStillEndsTheTurnAsStopped() async throws {
        let session = try await StoppedTurnSession(routed: false)
        let id = try await session.runningTurnWithQueuedFollowUp()
        await session.transport.setInterruptResponse(.object([
            "send_now": .string("stopped"), "still_queued": .array([.string(id)])
        ]))
        await session.transport.holdInterrupt()
        let press = Task { try await session.followUps.sendFollowUpNow(messageID: id, in: session.handle) }
        try await session.waitUntil { await session.transport.hasHeldInterrupt }
        await session.emit(StoppedTurnFrames.abortedWhileAnswering)
        try await session.waitForTurnEnd()
        await session.transport.answerHeldInterrupt()
        let answer = try await press.value
        XCTAssertEqual(answer, .stopped)
        var payloads = await session.log.payloads
        XCTAssertFalse(payloads.contains { if case .error = $0 { true } else { false } })

        // The message's own turn then fails on its own, without a `terminal_reason`: that shows.
        await session.emit(SendNowFrames.lifecycle(id, "started"))
        await session.emit(StoppedTurnFrames.abortedWithoutReason)
        try await session.waitFor { $0.last == .sessionStatusChanged(.failed) }
        payloads = await session.log.payloads
        XCTAssertEqual(payloads.filter { if case .error = $0 { true } else { false } }.count, 1)
        await session.close()
    }

    /// Send now that the CLI is delivering stopped nothing, so a failure of that turn is still one.
    /// Only a result that says the turn was aborted (the CLI stopping it after all) ends it as stopped.
    func testSendNowThatDeliversWithoutAStopLeavesTheTurnsFailureAsItIs() async throws {
        for (frame, isStop) in [(StoppedTurnFrames.abortedWithoutReason, false), (StoppedTurnFrames.apiError, false),
                                (StoppedTurnFrames.abortedWhileToolsRan, true)] {
            let session = try await StoppedTurnSession(routed: false)
            let id = try await session.runningTurnWithQueuedFollowUp()
            await session.transport.setInterruptResponse(try json(SendNowFrames.receipt(id)))
            let answer = try await session.followUps.sendFollowUpNow(messageID: id, in: session.handle)
            XCTAssertEqual(answer, .delivering)
            await session.emit(frame)
            try await session.waitForTurnEnd(failed: !isStop)
            let payloads = await session.log.payloads
            XCTAssertEqual(payloads.contains { if case .error = $0 { true } else { false } }, !isStop, frame)
            await session.close()
        }
    }

    /// Send now on a message the CLI already took stops nothing either.
    func testSendNowWithNothingWaitingMarksNothing() async throws {
        let session = try await StoppedTurnSession(routed: false)
        let id = try await session.runningTurnWithQueuedFollowUp()
        await session.transport.setInterruptResponse(.object(["send_now": .string("nothing_waiting"), "still_queued": .array([])]))
        let answer = try await session.followUps.sendFollowUpNow(messageID: id, in: session.handle)
        XCTAssertEqual(answer, .nothingWaiting)
        await session.emit(StoppedTurnFrames.abortedWhileToolsRan)
        try await session.waitForTurnEnd(failed: true)
        await session.close()
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}

/// The `result` frames a turn ends with, in the shapes Claude Code 2.1.295 builds them (read from
/// the installed binary's own result builder with `strings`; no run was recorded): an aborted turn
/// is `error_during_execution` with `terminal_reason` `aborted_streaming` or `aborted_tools`, no
/// `result`, and the CLI's `[ede_diagnostic]` line in `errors`.
enum StoppedTurnFrames {
    static let sessionID = "5b9f1a52-6c1e-4f7a-9d0e-2a4c8e1f3b77"

    static let abortedWhileAnswering = #"""
    {"type":"result","subtype":"error_during_execution","duration_ms":4120,"duration_api_ms":3870,"is_error":true,"num_turns":1,"stop_reason":null,"session_id":"5b9f1a52-6c1e-4f7a-9d0e-2a4c8e1f3b77","total_cost_usd":0.0123,"usage":{"input_tokens":12,"cache_creation_input_tokens":0,"cache_read_input_tokens":18000,"output_tokens":40},"modelUsage":{},"permission_denials":[],"terminal_reason":"aborted_streaming","fast_mode_state":"off","errors":["[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=null"],"uuid":"0d6c1f2e-8a43-4b5e-9c71-3e2f4a5b6c7d"}
    """#

    static let abortedWhileToolsRan = #"""
    {"type":"result","subtype":"error_during_execution","duration_ms":9020,"duration_api_ms":2100,"is_error":true,"num_turns":2,"stop_reason":"tool_use","session_id":"5b9f1a52-6c1e-4f7a-9d0e-2a4c8e1f3b77","total_cost_usd":0.02,"usage":{"input_tokens":30,"output_tokens":60},"modelUsage":{},"permission_denials":[],"terminal_reason":"aborted_tools","errors":["[ede_diagnostic] result_type=assistant last_content_type=tool_use stop_reason=tool_use"],"uuid":"1e7d2a3f-9b54-4c6f-8d82-4f3a5b6c7d8e"}
    """#

    /// The same without `terminal_reason`, as a CLI that predates it sends, or as a turn that threw.
    static let abortedWithoutReason = #"""
    {"type":"result","subtype":"error_during_execution","duration_ms":3000,"duration_api_ms":2800,"is_error":true,"num_turns":1,"session_id":"5b9f1a52-6c1e-4f7a-9d0e-2a4c8e1f3b77","total_cost_usd":0.01,"usage":{"input_tokens":10,"output_tokens":20},"permission_denials":[],"errors":[],"uuid":"2f8e3b4a-0c65-4d7a-9e93-5a4b6c7d8e9f"}
    """#

    /// An API error ends a turn as `success` with `is_error` and the error's text.
    static let apiError = #"""
    {"type":"result","subtype":"success","is_error":true,"api_error_status":500,"result":"API Error: 500 Internal server error","duration_ms":2000,"duration_api_ms":1900,"num_turns":1,"stop_reason":"stop_sequence","session_id":"5b9f1a52-6c1e-4f7a-9d0e-2a4c8e1f3b77","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0},"terminal_reason":"api_error","uuid":"3a9f4c5b-1d76-4e8b-8fa4-6b5c7d8e9f0a"}
    """#

    static let setupFailed = #"""
    {"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":5,"duration_api_ms":0,"num_turns":0,"stop_reason":null,"session_id":"5b9f1a52-6c1e-4f7a-9d0e-2a4c8e1f3b77","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0},"terminal_reason":"turn_setup_failed","errors":["queryParams builder failed: settings unreadable"],"uuid":"4b0a5d6c-2e87-4f9c-9ab5-7c6d8e9f0a1b"}
    """#

    static let notLoggedIn = #"{"type":"result","is_error":true,"result":"Not logged in"}"#

    static let completed = #"""
    {"type":"result","subtype":"success","is_error":false,"result":"Done.","stop_reason":"end_turn","terminal_reason":"completed","num_turns":1,"session_id":"5b9f1a52-6c1e-4f7a-9d0e-2a4c8e1f3b77","uuid":"5c1b6e7d-3f98-4a0d-8bc6-8d7e9f0a1b2c"}
    """#

    /// The interruption marker the CLI keeps in its transcript. It is not the user's message.
    static let interruptionMarker = #"""
    {"type":"user","parent_tool_use_id":null,"session_id":"5b9f1a52-6c1e-4f7a-9d0e-2a4c8e1f3b77","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}
    """#

    /// The same where the stop cut tool calls.
    static let toolUseInterruptionMarker = #"""
    {"type":"user","parent_tool_use_id":null,"session_id":"5b9f1a52-6c1e-4f7a-9d0e-2a4c8e1f3b77","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}
    """#

    /// A call that finished before the stop, and its result.
    static let versionCall = #"""
    {"type":"assistant","parent_tool_use_id":null,"session_id":"5b9f1a52-6c1e-4f7a-9d0e-2a4c8e1f3b77","message":{"id":"msg_v","role":"assistant","content":[{"type":"tool_use","id":"toolu_version","name":"Bash","input":{"command":"python3 -m sample_app --version","description":"Print the app version"}}]}}
    """#

    static let versionResult = #"""
    {"type":"user","parent_tool_use_id":null,"session_id":"5b9f1a52-6c1e-4f7a-9d0e-2a4c8e1f3b77","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_version","is_error":false,"content":"0.4.2"}]},"tool_use_result":{"stdout":"0.4.2","stderr":"","interrupted":false}}
    """#

    /// A step of two Bash calls; the second waits for the first.
    static let twoCommands = #"""
    {"type":"assistant","parent_tool_use_id":null,"session_id":"5b9f1a52-6c1e-4f7a-9d0e-2a4c8e1f3b77","message":{"id":"msg_s","role":"assistant","content":[{"type":"tool_use","id":"toolu_sleep","name":"Bash","input":{"command":"python3 -c \"import time; time.sleep(30)\"; echo done","description":"Sleep 30 seconds in Python then print done"}},{"type":"tool_use","id":"toolu_tests","name":"Bash","input":{"command":"PYTHONPATH=src python3 -m unittest discover -s tests -v 2>&1","description":"Run the unit test suite"}}]}}
    """#

    /// The CLI tracks a foreground command as a task, as it reported one in a recorded run (`SendNowFrames`).
    static let sleepStarted = #"""
    {"type":"system","subtype":"task_started","session_id":"5b9f1a52-6c1e-4f7a-9d0e-2a4c8e1f3b77","task_id":"b7sleep01","task_type":"local_bash","tool_use_id":"toolu_sleep","description":"Sleep 30 seconds in Python then print done","is_backgrounded":false}
    """#

    // After a Stop, the results the CLI writes for the calls it cut, as 2.1.322 builds them (read from
    // the installed binary with `strings`; no run was recorded): the running command's own result cut
    // short, and for a call that had not run, a refusal addressed to the model with its typed result
    // "User rejected tool use".

    static let sleepCutShort = #"""
    {"type":"user","parent_tool_use_id":null,"session_id":"5b9f1a52-6c1e-4f7a-9d0e-2a4c8e1f3b77","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_sleep","is_error":true,"content":"<error>Command was aborted before completion</error>"}]},"tool_use_result":{"stdout":"","stderr":"","interrupted":true}}
    """#

    static let testsRefused = #"""
    {"type":"user","parent_tool_use_id":null,"session_id":"5b9f1a52-6c1e-4f7a-9d0e-2a4c8e1f3b77","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_tests","is_error":true,"content":"The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.\n\nNote: The user's next message may contain a correction or preference. Pay close attention \u2014 if they explain what went wrong or how they'd prefer you to work, consider saving that to memory for future sessions."}]},"tool_use_result":"User rejected tool use","tool_result_meta":[{"id":"toolu_tests","non_execution_kind":"user-rejected"}]}
    """#

    /// A call that failed on its own.
    static let testsFailed = #"""
    {"type":"user","parent_tool_use_id":null,"session_id":"5b9f1a52-6c1e-4f7a-9d0e-2a4c8e1f3b77","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_tests","is_error":true,"content":"Exit code 1\nFAILED (failures=1)"}]},"tool_use_result":"Error: Exit code 1\nFAILED (failures=1)"}
    """#

    static func delta(_ text: String) -> String {
        #"{"type":"stream_event","parent_tool_use_id":null,"session_id":"\#(sessionID)","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}}"#
    }
}

/// One Claude task on a fake CLI, directly or behind the product route, with its events logged.
private struct StoppedTurnSession {
    let transport = FakeClaudeTransport()
    let adapter: any HarnessAdapter
    let followUps: any HarnessFollowUpQueueing
    let handle: HarnessSessionHandle
    let log = StoppedTurnPayloadLog()
    private let collector: Task<Void, Never>

    init(routed: Bool) async throws {
        let direct = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { [transport] _ in transport })
        let wrapped = YHPProviderCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.claude())
        adapter = routed ? wrapped : direct
        followUps = routed ? wrapped : direct
        handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/claude-stop"),
                                                       initialPrompt: nil))
        let events = await adapter.events(for: handle)
        collector = Task { [log] in for await event in events { await log.append(event.payload) } }
    }

    func emit(_ frame: String) async {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8)) else {
            return XCTFail("Unreadable frame \(frame)")
        }
        await transport.emit(value)
    }

    /// The payloads of a turn Stop ended while its calls ran: one call finished, then the stop cut the
    /// command running and the one waiting behind it.
    static func stoppedWhileCallsRan(request: String, routed: Bool) async throws -> [HarnessEventPayload] {
        let session = try await StoppedTurnSession(routed: routed)
        try await session.adapter.send(request, to: session.handle)
        await session.emit(StoppedTurnFrames.versionCall)
        await session.emit(StoppedTurnFrames.versionResult)
        await session.emit(StoppedTurnFrames.twoCommands)
        await session.emit(StoppedTurnFrames.sleepStarted)
        try await session.waitFor { $0.filter { if case .activityStarted = $0 { true } else { false } }.count >= 3 }
        try await session.adapter.interrupt(session.handle)
        await session.emit(StoppedTurnFrames.sleepCutShort)
        await session.emit(StoppedTurnFrames.testsRefused)
        await session.emit(StoppedTurnFrames.toolUseInterruptionMarker)
        await session.emit(StoppedTurnFrames.abortedWhileToolsRan)
        try await session.waitForTurnEnd()
        let payloads = await session.log.payloads
        await session.close()
        return payloads
    }

    /// A turn running with a follow-up the CLI holds in its queue, where Send now can find it.
    func runningTurnWithQueuedFollowUp() async throws -> String {
        try await adapter.send("Run the tests", to: handle)
        let id = UUID().uuidString.lowercased()
        try await followUps.sendFollowUp(HarnessUserInput(text: "Use Python instead"), messageID: id,
                                         priority: .next, to: handle)
        await emit(SendNowFrames.initFrame)
        await emit(SendNowFrames.lifecycle(id, "queued"))
        try await waitUntil { await followUps.canSendFollowUpNow(in: handle) }
        return id
    }

    /// The turn's end: the ready status after the one attaching set, or its failure.
    func waitForTurnEnd(failed: Bool = false) async throws {
        try await waitFor {
            failed ? $0.last == .sessionStatusChanged(.failed)
                : $0.filter { $0 == .sessionStatusChanged(.ready) }.count == 2
        }
    }

    func waitFor(_ condition: @escaping ([HarnessEventPayload]) -> Bool) async throws {
        try await waitUntil { condition(await log.payloads) }
    }

    func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + testWaitLimit
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, "Timed out")
    }

    func close() async {
        collector.cancel()
        await adapter.close(handle)
    }
}

private actor StoppedTurnPayloadLog {
    private(set) var payloads: [HarnessEventPayload] = []
    func append(_ payload: HarnessEventPayload) { payloads.append(payload) }
}

/// The turn Stop ended while its calls ran, drawn from the frames the CLI sends, in both appearances,
/// into `.build/claude-stop-qa/`: as the conversation shows it (`stopped-turn-*.png`), and with its run
/// of calls and each call opened (`stopped-calls-*.png`).
@MainActor
final class ClaudeStoppedTurnRenderingTests: XCTestCase {
    func testTheStoppedTurnRenders() async throws {
        let request = "Run `python3 -c \"import time; time.sleep(30)\"; echo done` in the foreground, then tell me how many tests passed."
        let payloads = try await StoppedTurnSession.stoppedWhileCallsRan(request: request, routed: false)
        var transcript = TranscriptBuilder()
        transcript.appendUser(request)
        payloads.forEach { transcript.apply($0) }
        // At the times a person sees them: the calls 4 seconds after the request, the stop at 13.
        let start = Date(timeIntervalSince1970: 1_794_000_000)
        let entries = transcript.entries.enumerated().map { index, entry in
            TranscriptEntry(id: entry.id, createdAt: start.addingTimeInterval(index == 0 ? 0 : 4), content: entry.content,
                            turnStoppedAt: entry.turnStoppedAt.map { _ in start.addingTimeInterval(13) })
        }
        let turn = try XCTUnwrap(TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true).turns.last)
        let stopped = L10n.string("Stopped")
        let folder = try WindowlessRender.directory("claude-stop-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let drawing = try ConversationDrawing.draw(
                ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .ready,
                                                         latestTurnIsComplete: true)),
                size: NSSize(width: 760, height: 260), appearance: appearance)
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: folder.appending(path: "stopped-turn-\(appearance.suffix).png"))
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains(L10n.format("You stopped after %lld seconds", Int64(13))), texts)

            let choices = ConversationDisclosureChoices()
            turn.work.forEach { choices.record($0.id, isOpen: true) }
            let calls = try ConversationDrawing.draw(
                ConversationWorkGroup(items: turn.work, harness: .claudeCode, startsOpen: true) { item in
                    ConversationWorkLine(item: item, harness: .claudeCode, workspaceURL: nil, runInTerminal: { _ in })
                }
                .environment(\.conversationDisclosureChoices, choices)
                .padding(24),
                size: NSSize(width: 760, height: 420), appearance: appearance)
            try WindowlessRender.writePNG(calls.capture.bitmap,
                                          to: folder.appending(path: "stopped-calls-\(appearance.suffix).png"))
            let lines = calls.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(lines.contains("Sleep 30 seconds in Python then print done \(stopped)"), lines)
            XCTAssertTrue(lines.contains("Run the unit test suite \(stopped)"), lines)
            XCTAssertFalse(lines.contains("want to proceed"), lines)
            XCTAssertFalse(lines.contains("Command was aborted"), lines)
        }
    }
}
