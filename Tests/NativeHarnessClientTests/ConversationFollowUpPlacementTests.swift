import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// D13: where a message sent while a turn runs appears, as the Codex app shows it: the running turn
/// takes it (`turn/steer`), so it is part of that turn, drawn in the turn's work where the provider
/// took it rather than at the turn's top. When the turn ends on its answer and its work folds, a
/// message the person wrote stays in view where it was sent, as the Claude app leaves it (2026-10-31;
/// ChatGPT.app 26.1023 folds it with the work, `Tj`), while a message another task sent folds with the
/// work the answer followed. Every harness follows it by the one rule (`ConversationTurnLayout`): a
/// Codex steered message, and a Claude Code follow-up the CLI read at the running turn's next step
/// (`TranscriptEntry.joinsRunningTurn`).
@MainActor
final class ConversationFollowUpPlacementTests: XCTestCase {
    private let decoder = CodexTaskDecoder()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private static let workspace = URL(filePath: "/tmp/yardlet-follow-up", directoryHint: .isDirectory)

    // MARK: - Engine

    func testACodexMessageSteeredAfterTheWorkBeganIsInTheWork() throws {
        let presentation = CodexConversationProjection.presentation(
            codexThread(finished: true), workspaceURL: Self.workspace, historySelection: nil
        )
        let turn = try XCTUnwrap(presentation.turns.first)
        XCTAssertEqual(turn.prompt.map(\.id), ["u1"])
        XCTAssertEqual(turn.work.map(\.id), ["m1", "c1", "u2"])
        XCTAssertEqual(turn.answers.map(\.id), ["a1"])
        XCTAssertEqual(turn.workKeptWhenFolded.map(\.id), ["u2"], "the person's message stays in view after the answer")

        // A message another task sent into the turn folds under the answer that followed it.
        let fromTask = TaskMessage(senderID: UUID().uuidString, senderName: "Coordinator", body: "Use Python instead")
        let sentByTask = try XCTUnwrap(CodexConversationProjection.presentation(
            codexThread(finished: true, followUp: fromTask.text(in: .yardlet)),
            workspaceURL: Self.workspace, historySelection: nil
        ).turns.first)
        XCTAssertNotNil(sentByTask.work.last?.taskMessage)
        XCTAssertEqual(sentByTask.workKeptWhenFolded.map(\.id), [], "the answer followed the task's message, so it folds")

        // Messages sent before any work are the turn's request, however many.
        var opening = codexThread(finished: true)
        opening.thread?.turns[0].items.swapAt(1, 3)
        let request = try XCTUnwrap(CodexConversationProjection.presentation(
            opening, workspaceURL: Self.workspace, historySelection: nil
        ).turns.first)
        XCTAssertEqual(request.prompt.map(\.id), ["u1", "u2"])
        XCTAssertFalse(request.work.contains { $0.id == "u2" })
    }

    func testAClaudeFollowUpReadIntoTheRunningTurnStaysInThatTurn() throws {
        let entries = claudeEntries(finished: false)
        let presentation = TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .running, latestTurnIsComplete: false
        )
        XCTAssertEqual(presentation.turns.count, 1)
        let turn = try XCTUnwrap(presentation.turns.first)
        XCTAssertEqual(turn.prompt.map(\.id), [entries[0].id.uuidString])
        XCTAssertEqual(turn.work.map(\.id), entries[1...].map(\.id.uuidString))
        XCTAssertEqual(turn.workKeptWhenFolded.map(\.id), [entries[3].id.uuidString], "no answer followed it yet")

        // Once the turn is over, its menu works on the latest message, the one read into it.
        let finished = claudeEntries(finished: true)
        let idle = try XCTUnwrap(TranscriptConversationProjection.presentation(
            from: finished, harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        ).turns.first)
        XCTAssertEqual(idle.actions.editLatest?.entryID, finished[3].id)
        XCTAssertEqual(idle.actions.restoreFiles?.entryID, finished[3].id)
        XCTAssertEqual(idle.answers.map(\.id), [finished[5].id.uuidString])
        XCTAssertEqual(idle.workKeptWhenFolded.map(\.id), [finished[3].id.uuidString], "the person's message stays in view")

        // A message the provider did not read into a running turn still starts a turn of its own.
        var sequential = finished
        sequential[3].joinsRunningTurn = nil
        XCTAssertEqual(TranscriptConversationProjection.presentation(
            from: sequential, harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        ).turns.count, 2)
    }

    /// Last turn spans the whole turn, from its request, a message read into it included.
    func testLastTurnStartsAtTheTurnsRequest() throws {
        let edit = { (id: String, path: String) in
            TranscriptEntry(content: .activity(HarnessActivity(
                id: id, kind: "Write", title: "Write", input: path,
                diff: HarnessActivityDiff(path: path, oldText: nil, newText: "print(1)\n")
            ), state: .completed))
        }
        let request = TranscriptEntry(content: .user(text: "Port the script"))
        let entries = [
            request, edit("w1", "/tmp/yardlet-follow-up/a.py"),
            TranscriptEntry(content: .user(text: "Also b"), joinsRunningTurn: true), edit("w2", "/tmp/yardlet-follow-up/b.py")
        ]
        let diff = try XCTUnwrap(ConversationFileChangeProjection.lastTurnDiff(
            entries: entries, harness: .claudeCode, isRunning: false, workspaceURL: Self.workspace
        ))
        XCTAssertEqual(diff.turnID, request.id.uuidString)
        XCTAssertTrue(diff.text.contains("a.py") && diff.text.contains("b.py"), diff.text)
    }

    /// The saved transcript keeps its shape: the fact is written only for a message read into a
    /// running turn, and entries saved before it read as before.
    func testTheReadingCacheKeepsItsShape() throws {
        let plain = TranscriptEntry(content: .user(text: "Hi"))
        let plainJSON = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(plainJSON.contains("joinsRunningTurn"), plainJSON)
        let joined = TranscriptEntry(content: .user(text: "Also"), joinsRunningTurn: true)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptEntry.self, from: JSONEncoder().encode(joined)), joined)
        let older = try JSONDecoder().decode(TranscriptEntry.self, from: Data(plainJSON.utf8))
        XCTAssertNil(older.joinsRunningTurn)
        var builder = TranscriptBuilder()
        builder.appendUser("Run it")
        builder.appendUser("Also this", joinsRunningTurn: true)
        XCTAssertEqual(builder.entries.map(\.joinsRunningTurn), [nil, true])
    }

    // MARK: - Drawn

    /// While the turn runs, the steered message is in the work after what came before it; once the
    /// turn ends on its answer and folds, the work folds and the message stays where it was, between
    /// the fold and the answer. Codex and Claude Code draw the folded turn in the same pixels.
    func testTheMessageIsDrawnWhereItWasTakenAndStaysWhenTheWorkFolds() throws {
        let directory = try WindowlessRender.directory("conversation-m12f-qa")
        let size = NSSize(width: 760, height: 900)
        for (stage, finished) in [("running", false), ("folded", true)] {
            for appearance in WindowlessRender.Appearance.allCases {
                let codex = try ConversationDrawing.draw(
                    ConversationTimeline(source: .codex(codexThread(finished: finished), workspaceURL: Self.workspace,
                                                        historySelection: nil),
                                         actions: ConversationActions(forkCodexTurn: { _ in })),
                    size: size, appearance: appearance
                )
                let claude = try ConversationDrawing.draw(
                    ConversationTimeline(source: .transcript(
                        entries: claudeEntries(finished: finished), harness: .claudeCode,
                        status: finished ? .ready : .running, latestTurnIsComplete: finished
                    ), actions: claudeActions()),
                    size: size, appearance: appearance
                )
                for (name, drawing) in [("codex", codex), ("claude-code", claude)] {
                    try WindowlessRender.writePNG(
                        drawing.capture.bitmap,
                        to: directory.appending(path: "follow-up-\(stage)-\(name)-\(appearance.rawValue).png")
                    )
                    let texts = drawing.elements.map(\.description)
                    let joined = texts.joined(separator: "\n")
                    let request = try XCTUnwrap(texts.firstIndex { $0.contains("Port the script to Swift") }, joined)
                    XCTAssertFalse(drawing.elements.contains { ConversationDrawing.isRailTurn($0.label) },
                                   "one turn, not two:\n\(joined)")
                    XCTAssertEqual(texts.filter { $0.contains("Use Python instead") }.count, 1, joined)
                    let followUp = try XCTUnwrap(texts.firstIndex { $0.contains("Use Python instead") }, joined)
                    if finished {
                        let header = try XCTUnwrap(drawing.elements.firstIndex {
                            ConversationDrawing.isWorkTime($0.label) || ConversationDrawing.isWorkTime($0.value)
                        }, joined)
                        let answer = try XCTUnwrap(texts.firstIndex { $0.contains("Ported to Python.") }, joined)
                        XCTAssertLessThan(request, header, joined)
                        XCTAssertLessThan(header, followUp, "the person's message stays in view:\n\(joined)")
                        XCTAssertLessThan(followUp, answer, joined)
                        XCTAssertFalse(joined.contains("Reading the script first."), "the work folds:\n\(joined)")
                        XCTAssertFalse(joined.contains("Switching to Python."), "the work folds:\n\(joined)")
                    } else {
                        let work = try XCTUnwrap(texts.firstIndex { $0.contains("Reading the script first.") }, joined)
                        let reply = try XCTUnwrap(texts.firstIndex { $0.contains("Switching to Python.") }, joined)
                        XCTAssertLessThan(request, work, joined)
                        XCTAssertLessThan(work, followUp, joined)
                        XCTAssertLessThan(followUp, reply, joined)
                    }
                }
                if finished {
                    XCTAssertEqual(ConversationDrawing.differingBytes(codex.capture.bitmap, claude.capture.bitmap), 0,
                                   "Codex and Claude Code draw the folded turn differently")
                }
            }
        }
    }

    // MARK: - Fixtures

    /// A request, working notes, a command, a message steered in, and (once finished) the answer.
    private func codexThread(finished: Bool, followUp: String = "Use Python instead") -> CodexTaskState {
        var items: [JSONValue] = [
            user("u1", "Port the script to Swift"),
            .object(["id": .string("m1"), "type": .string("agentMessage"), "text": .string("Reading the script first."),
                     "phase": .string("commentary")]),
            .object(["id": .string("c1"), "type": .string("commandExecution"), "command": .string("cat script.sh"),
                     "cwd": .string(Self.workspace.path), "status": .string("completed"), "commandActions": .array([]),
                     "aggregatedOutput": .string("echo hi\n"), "exitCode": .integer(0)]),
            user("u2", followUp)
        ]
        items.append(finished
            ? .object(["id": .string("a1"), "type": .string("agentMessage"), "text": .string("Ported to Python."),
                       "phase": .string("final_answer")])
            : .object(["id": .string("m2"), "type": .string("agentMessage"), "text": .string("Switching to Python."),
                       "phase": .string("commentary")]))
        var turn: [String: JSONValue] = [
            "id": .string("turn-1"), "status": .string(finished ? "completed" : "inProgress"), "items": .array(items)
        ]
        if finished { turn["durationMs"] = .integer(5_000) }
        var thread = decoder.thread(from: .object(["id": .string("thread-follow-up")]))!
        thread.turns = [decoder.turn(from: .object(turn), fallbackID: "turn-1")!]
        return CodexTaskState(thread: thread)
    }

    private func user(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("userMessage"),
                 "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    /// The same turn as Claude Code records it: the follow-up the CLI read at the turn's next step
    /// joins the running turn.
    private func claudeEntries(finished: Bool) -> [TranscriptEntry] {
        func at(_ seconds: Double, _ content: TranscriptEntryContent, joins: Bool? = nil) -> TranscriptEntry {
            TranscriptEntry(createdAt: start.addingTimeInterval(seconds), content: content, joinsRunningTurn: joins)
        }
        var entries = [
            at(0, .user(text: "Port the script to Swift")),
            at(1, .assistant(text: "Reading the script first.", isStreaming: false)),
            at(2, .activity(HarnessActivity(id: "toolu_bash", kind: "Bash", title: "Bash", input: "cat script.sh",
                                            output: "echo hi\n"), state: .completed)),
            at(3, .user(text: "Use Python instead"), joins: true)
        ]
        entries += finished
            ? [at(4, .assistant(text: "Switching to Python.", isStreaming: false)),
               at(5, .assistant(text: "Ported to Python.", isStreaming: false))]
            : [at(4, .assistant(text: "Switching to Python.", isStreaming: true))]
        return entries
    }

    private func claudeActions() -> ConversationActions {
        var actions = ConversationActions(rewind: ConversationRewindActions(
            beginCodexEdit: { _ in }, beginClaudeEdit: { _ in }, cancelEdit: {}, loadFilePoints: { [] },
            previewFiles: { _ in throw CancellationError() }, restoreFiles: { _ in throw CancellationError() }
        ))
        actions.branch = { _ in }
        return actions
    }
}
