import Foundation
import XCTest
@testable import NativeHarnessClient

/// A long Codex thread projected through `ConversationProjectionCache`, as the renderer projects
/// each update: an update projects again only the turns whose input it changed
/// (plan A3.4). The counts are exact and every kept projection equals a fresh one, so these run with
/// the quick tests; the time bound is generous so a loaded machine passes. The streaming benchmark is
/// `LongCodexThreadPerformanceTests` (route `projection`).
final class ConversationProjectionCacheTests: XCTestCase {
    private let decoder = CodexTaskDecoder()
    private let workspace = URL(filePath: "/tmp/yardlet-projection-performance", directoryHint: .isDirectory)

    func testAnUpdateToOneOfThreeHundredTurnsProjectsOnlyThatTurn() {
        var state = longThread(turns: 300)
        let cache = ConversationProjectionCache()
        let clock = ContinuousClock()

        var presentation = ConversationPresentation(harness: .codex, turns: [])
        let first = clock.measure { presentation = project(state, with: cache) }
        XCTAssertEqual(cache.counts, .init(reused: 0, projected: 300))
        XCTAssertEqual(presentation.turns.count, 300)

        _ = project(state, with: cache)
        XCTAssertEqual(cache.counts, .init(reused: 300, projected: 300), "An unchanged update projects nothing")

        // An answer in the middle of the thread grows.
        state.thread?.turns[150].items[9] = decoder.item(
            from: message("history-150-item-9", "A longer answer.", phase: "final_answer"),
            fallbackID: "history-150-item-9", lifecycle: .completed
        )
        let update = clock.measure { presentation = project(state, with: cache) }
        XCTAssertEqual(cache.counts, .init(reused: 599, projected: 301), "Only the changed turn is projected")
        XCTAssertEqual(presentation, fresh(state), "Kept turns are the turns a fresh projection makes")
        guard case let .answer(text, _)? = presentation.turns[150].answers.last?.kind else {
            return XCTFail("the grown answer should stay the turn's answer")
        }
        XCTAssertEqual(text, "A longer answer.")

        print(String(format: "[perf] conversation projection: 300 turns %.2f ms, one changed turn %.2f ms",
                     first.milliseconds, update.milliseconds))
        XCTAssertLessThan(update, .seconds(1), "An update to one turn of a long thread stays cheap")
    }

    func testATurnStreamingAndAnsweredProjectsOnlyTheTurnsItTouches() {
        var state = longThread(turns: 300)
        let cache = ConversationProjectionCache()
        _ = project(state, with: cache)
        var counts = cache.counts

        func expectProjected(_ expected: Int, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
            let presentation = project(state, with: cache)
            XCTAssertEqual(cache.counts.projected - counts.projected, expected, step, file: file, line: line)
            XCTAssertEqual(presentation, fresh(state), step, file: file, line: line)
            counts = cache.counts
        }

        // A new turn starts: it, and the turn that stops being the one to edit.
        state.thread?.turns.append(decoder.turn(from: .object([
            "id": .string("live"), "status": .string("inProgress"),
            "items": .array([user("live-user", "Keep going")])
        ]), fallbackID: "live")!)
        expectProjected(2, "turn starts")

        // Its command streams.
        state.thread?.turns[300].items.append(decoder.item(from: command("live-command", output: "Compiling\n"),
                                                           fallbackID: "live-command", lifecycle: .inProgress))
        expectProjected(1, "command starts")
        for line in 0..<5 {
            guard case var .commandExecution(running) = state.thread?.turns[300].items[1].content else {
                return XCTFail("the command should stay a command")
            }
            running.aggregatedOutput = (running.aggregatedOutput ?? "") + "Line \(line)\n"
            state.thread?.turns[300].items[1].content = .commandExecution(running)
            let items = cache.codexItems.projected
            expectProjected(1, "output \(line)")
            // In that turn, only the command is projected again; the request is kept.
            XCTAssertEqual(cache.codexItems.projected - items, 1, "output \(line)")
        }

        // An approval arrives for an earlier turn, then is answered.
        state.approvalsByID["late"] = CodexApprovalState(
            id: "late", method: "item/commandExecution/requestApproval", threadID: "long",
            turnID: "history-100", itemID: nil, resolution: .pending, raw: nil
        )
        expectProjected(1, "approval for an earlier turn")
        state.approvalsByID["late"]?.resolution = .resolved(nil)
        expectProjected(1, "approval answered")

        // The turn finishes and becomes the one to edit.
        state.thread?.turns[300].status = .completed
        expectProjected(1, "turn finishes")

        // Opening a history result marks items in any turn, so every turn is read again.
        let presentation = cache.codex(
            state, workspaceURL: workspace, historySelection: CodexHistorySearchSelection(query: "history-42", snippet: nil)
        )
        XCTAssertEqual(cache.counts.projected - counts.projected, 301)
        XCTAssertEqual(presentation.turns[42].prompt.first?.isHistoryMatch, true)
    }

    /// A long shared transcript (300 Claude turns, 1,500 entries) through the same cache (M5): a
    /// turn is projected again only when its own entries, the approvals its cards name, or what only
    /// the last turn reads (its status, whether it is complete) change.
    func testATranscriptUpdateProjectsOnlyTheTurnsItTouches() {
        var entries = (0..<300).flatMap { index -> [TranscriptEntry] in
            [
                TranscriptEntry(content: .user(text: "Request \(index)")),
                TranscriptEntry(content: .assistant(text: "Looking at \(index).", isStreaming: false)),
                TranscriptEntry(content: .activity(HarnessActivity(id: "call-\(index)", kind: "Bash", title: "Run \(index)",
                                                                   input: "swift test", output: "ok"), state: .completed)),
                TranscriptEntry(content: .permission(PermissionRequest(id: "request-\(index)", title: "Run", detail: nil,
                                                                       command: "swift test", toolCallID: "call-\(index)"),
                                                     state: .allowed)),
                TranscriptEntry(content: .assistant(text: "Done \(index).", isStreaming: false))
            ]
        }
        let cache = ConversationProjectionCache()
        let clock = ContinuousClock()
        var status = SessionStatus.ready
        var counts = cache.counts
        var presentation = ConversationPresentation(harness: .claudeCode, turns: [])

        @discardableResult
        func expectProjected(_ expected: Int, _ step: String, file: StaticString = #filePath, line: UInt = #line) -> Duration {
            let time = clock.measure {
                presentation = cache.transcript(entries, harness: .claudeCode, status: status, latestTurnIsComplete: true)
            }
            XCTAssertEqual(cache.counts.projected - counts.projected, expected, step, file: file, line: line)
            XCTAssertEqual(presentation, TranscriptConversationProjection.presentation(
                from: entries, harness: .claudeCode, status: status, latestTurnIsComplete: true
            ), step, file: file, line: line)
            counts = cache.counts
            return time
        }

        let first = expectProjected(300, "first projection")
        XCTAssertEqual(presentation.turns.count, 300)
        XCTAssertTrue(presentation.turns.allSatisfy(\.foldsWork))
        expectProjected(0, "unchanged")

        // An answer in the middle grows.
        entries[754].content = .assistant(text: "Done 150, with more.", isStreaming: false)
        let update = expectProjected(1, "answer grows")

        // The task starts a new turn: it, and the turn that stops being the last.
        status = .running
        entries.append(TranscriptEntry(content: .user(text: "Keep going")))
        expectProjected(2, "turn starts")
        entries.append(TranscriptEntry(content: .activity(HarnessActivity(id: "live", kind: "Bash", title: "Build"),
                                                          state: .running)))
        expectProjected(1, "its tool starts")
        // Its request is allowed: only the turn whose card it names is read again.
        entries.append(TranscriptEntry(content: .permission(PermissionRequest(id: "live-request", title: "Build",
            detail: nil, command: nil, toolCallID: "live"), state: .allowed)))
        expectProjected(1, "its request is allowed")
        XCTAssertEqual(presentation.turns.last?.work.count, 1, "The allowed request folds into the tool")
        status = .ready
        expectProjected(1, "the task stops")

        print(String(format: "[perf] transcript projection: 300 turns %.2f ms, one changed turn %.2f ms",
                     first.milliseconds, update.milliseconds))
        XCTAssertLessThan(update, .seconds(1), "An update to one turn of a long transcript stays cheap")
    }

    /// An answer streaming at the end of a long transcript, as a task publishes it: the builder at its
    /// limit drops its oldest entries as new ones come, and says what changed (`TranscriptChange`). The
    /// turns it left as they were are kept without being compared, so only the turn that changed (and
    /// the oldest one, which lost entries) is split again and projected again; a change in an earlier
    /// turn splits the turns from there and keeps those that came out the same.
    func testATranscriptPublishedFromItsBuilderSplitsAndProjectsOnlyTheTurnsItChanged() throws {
        var builder = TranscriptBuilder(entries: (0..<150).flatMap { index -> [TranscriptEntry] in
            [
                TranscriptEntry(content: .user(text: "Request \(index)")),
                TranscriptEntry(content: .reasoning(text: "Thinking \(index).", isStreaming: false)),
                TranscriptEntry(content: .activity(HarnessActivity(id: "call-\(index)", kind: "Bash", title: "Run \(index)",
                                                                   input: "swift test", output: "ok"), state: .completed)),
                TranscriptEntry(content: .assistant(text: "Done \(index).", isStreaming: false))
            ]
        }, limit: 400)
        let cache = ConversationProjectionCache()
        var transcript = TranscriptTurns(builder.entries)
        _ = builder.takeChange()
        _ = cache.transcript(transcript, harness: .claudeCode, status: .running, latestTurnIsComplete: false)
        var counts = cache.counts

        /// Publishes what the builder holds, and checks that the turns are the turns of a fresh split,
        /// that `kept` of the earlier turns were kept as they were, and that `projected` were projected.
        func publish(keeping kept: Int, projecting projected: Int, _ step: String,
                     file: StaticString = #filePath, line: UInt = #line) {
            let earlier = transcript.turns
            transcript = transcript.updated(to: builder.entries, change: builder.takeChange())
            XCTAssertEqual(transcript.turns.map(\.entries), TranscriptTurns(builder.entries).turns.map(\.entries), step,
                           file: file, line: line)
            let keptTurns = transcript.turns.filter { turn in earlier.contains { $0 === turn } }
            XCTAssertEqual(keptTurns.count, kept, "\(step): turns kept", file: file, line: line)
            let presentation = cache.transcript(transcript, harness: .claudeCode, status: .running,
                                                latestTurnIsComplete: false)
            XCTAssertEqual(cache.counts.projected - counts.projected, projected, "\(step): turns projected",
                           file: file, line: line)
            XCTAssertEqual(presentation, TranscriptConversationProjection.presentation(
                from: builder.entries, harness: .claudeCode, status: .running, latestTurnIsComplete: false
            ), step, file: file, line: line)
            counts = cache.counts
        }

        // 100 turns of 4 entries. A request opens a turn and pushes out the oldest entry: the oldest
        // turn is the rest of it, and the turn before the new one stops being the last.
        builder.appendUser("Write it up.")
        publish(keeping: 99, projecting: 3, "request")
        // The answer's entry pushes out another.
        builder.apply(.assistantDelta("Working "))
        publish(keeping: 99, projecting: 2, "the answer starts")
        // Fragments into the entry that streams change only its turn.
        for fragment in 0..<5 {
            builder.apply(.assistantDelta("word\(fragment) "))
            publish(keeping: 100, projecting: 1, "fragment \(fragment)")
        }
        // A call between fragments ends the answer's entry; the next fragment starts another, and the
        // oldest turn goes whole.
        builder.apply(.activityStarted(HarnessActivity(id: "live", kind: "Bash", title: "Build")))
        publish(keeping: 99, projecting: 2, "a call")
        builder.apply(.assistantDelta("more "))
        publish(keeping: 99, projecting: 1, "the answer goes on")
        // The completed message takes the first entry and the other goes.
        builder.apply(.assistantMessageCompleted("Working word0 word1 word2 word3 word4 more "))
        publish(keeping: 99, projecting: 1, "the answer completes")
        // A call in an earlier turn reports again, as a background task does: its turn is split and
        // projected again, and the turns after it are split again and come out the same.
        builder.apply(.activityCompleted(HarnessActivity(id: "call-120", kind: "Bash", title: "Run 120",
                                                         input: "swift test", output: "ok, again")))
        publish(keeping: 99, projecting: 1, "an earlier call")
    }

    // MARK: - Fixtures

    private func project(_ state: CodexTaskState, with cache: ConversationProjectionCache) -> ConversationPresentation {
        cache.codex(state, workspaceURL: workspace, historySelection: nil)
    }

    private func fresh(_ state: CodexTaskState) -> ConversationPresentation {
        CodexConversationProjection.presentation(state, workspaceURL: workspace, historySelection: nil)
    }

    /// Finished turns as `LongCodexThreadPerformanceTests` streams them: a request, reasoning,
    /// commands with output, commentary, a file change and an answer.
    private func longThread(turns: Int) -> CodexTaskState {
        var thread = decoder.thread(from: .object(["id": .string("long")]))!
        thread.turns = (0..<turns).map { index in
            let turnID = "history-\(index)"
            let items: [JSONValue] = (0..<10).map { slot in
                let id = "\(turnID)-item-\(slot)"
                switch slot {
                case 0: return user(id, "Request \(turnID): read the module and fix the failing case.")
                case 1, 7: return .object(["id": .string(id), "type": .string("reasoning"),
                                           "summary": .array([.string("Reading \(id)")]), "content": .array([])])
                case 3: return message(id, "Checking \(id).", phase: "commentary")
                case 5: return .object(["id": .string(id), "type": .string("fileChange"), "status": .string("completed"),
                                        "changes": .array([.object([
                                            "path": .string("/tmp/yardlet-projection-performance/Sources/Module.swift"),
                                            "kind": .object(["type": .string("update")]),
                                            "diff": .string("@@ -1,3 +1,3 @@\n-old \(id)\n+new \(id)\n context\n")
                                        ])])])
                case 9: return message(id, "Fixed \(id).", phase: "final_answer")
                default: return command(id, output: String(repeating: "Test Case passed (0.01 seconds).\n", count: 40))
                }
            }
            return decoder.turn(from: .object([
                "id": .string(turnID), "status": .string("completed"), "durationMs": .integer(1_234), "items": .array(items)
            ]), fallbackID: turnID)!
        }
        return CodexTaskState(thread: thread)
    }

    private func user(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("userMessage"),
                 "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    private func message(_ id: String, _ text: String, phase: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("agentMessage"), "text": .string(text), "phase": .string(phase)])
    }

    private func command(_ id: String, output: String) -> JSONValue {
        .object([
            "id": .string(id), "type": .string("commandExecution"), "command": .string("swift test"),
            "cwd": .string("/tmp/yardlet-projection-performance"), "status": .string("completed"),
            "commandActions": .array([]), "aggregatedOutput": .string(output), "exitCode": .integer(0)
        ])
    }
}

private extension Duration {
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
