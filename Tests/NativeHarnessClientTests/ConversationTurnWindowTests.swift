import Foundation
import XCTest
@testable import NativeHarnessClient

/// The renderer's engine (plan M9): a turn's parts in its record's order, and the local window over a
/// long conversation's turns (A5.3, D11).
final class ConversationTurnWindowTests: XCTestCase {
    func testATranscriptTurnKeepsItsEntriesOrderWhateverPartEachBecame() throws {
        let user = TranscriptEntry(content: .user(text: "Fix it"))
        let note = TranscriptEntry(content: .assistant(text: "Looking.", isStreaming: false))
        let waiting = TranscriptEntry(content: .permission(
            PermissionRequest(id: "p", title: "Run", detail: nil, command: "ls"), state: .pending
        ))
        let plan = TranscriptEntry(content: .plan("☐ Step"))
        let tool = TranscriptEntry(content: .activity(HarnessActivity(id: "t", kind: "Bash", title: "Bash"), state: .completed))
        let allowed = TranscriptEntry(content: .permission(
            PermissionRequest(id: "a", title: "Bash", detail: nil, command: nil, toolCallID: "t"), state: .allowed
        ))
        let failure = TranscriptEntry(content: .error(message: "Broke", recoverable: true))
        let entries = [user, note, waiting, plan, tool, allowed, failure]
        let presentation = TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: false
        )
        let turn = try XCTUnwrap(presentation.turns.first)
        // The allowed request reads on its tool's card, so the order leaves it out.
        XCTAssertEqual(turn.recordOrder, [user, note, waiting, plan, tool, failure].map(\.id.uuidString))
        XCTAssertEqual(turn.partsInRecordOrder.map(\.id), turn.recordOrder)
        guard case .request = turn.partsInRecordOrder[2], case .plan = turn.partsInRecordOrder[3],
              case .outcome = turn.partsInRecordOrder[5] else {
            return XCTFail("\(turn.partsInRecordOrder)")
        }
        // A Codex turn has no record order of its own.
        XCTAssertTrue(ConversationTurn(id: "turn-1", status: .completed, timing: .init())
            .partsInRecordOrder.isEmpty)
    }

    func testTheWindowKeepsTheLatestTurnsAndCountsTheRest() {
        let presentation = transcript(turns: 10)
        XCTAssertEqual(ConversationTurnWindow().apply(to: presentation), presentation, "ten turns fit the window")
        // D11: the latest 10 turns, and 10 more at a time (40 until the eager stack, 2026-10-18).
        XCTAssertEqual(ConversationTurnWindow.initialTurnCount, 10)
        XCTAssertEqual(ConversationTurnWindow.step, 10)
        let long = transcript(turns: 90)
        XCTAssertEqual(ConversationTurnWindow().apply(to: long).turns.map(\.id), Array(long.turns.suffix(10)).map(\.id))
        XCTAssertEqual(ConversationTurnWindow().apply(to: long).earlier, .local(hiddenCount: 80))
        XCTAssertEqual(ConversationTurnWindow().widened().apply(to: long).earlier, .local(hiddenCount: 70))

        let window = ConversationTurnWindow(turnCount: 4)
        let windowed = window.apply(to: presentation)
        XCTAssertEqual(windowed.turns.map(\.id), Array(presentation.turns.suffix(4)).map(\.id))
        XCTAssertEqual(windowed.earlier, .local(hiddenCount: 6))
        XCTAssertTrue(window.hides(presentation.turns[2].id, in: presentation))
        XCTAssertFalse(window.hides(presentation.turns[8].id, in: presentation))
        XCTAssertFalse(window.hides("elsewhere", in: presentation))

        XCTAssertEqual(window.widened().turnCount, 4 + ConversationTurnWindow.step)
        // A turn the reader went to stays in, with every turn after it.
        var reached = window
        reached.earliestTurnID = presentation.turns[2].id
        XCTAssertEqual(reached.apply(to: presentation).turns.map(\.id), Array(presentation.turns[2...]).map(\.id))
        XCTAssertEqual(reached.apply(to: presentation).earlier, .local(hiddenCount: 2))
    }

    /// A Codex thread pages its own turns; the window applies to the loaded ones, and the provider's
    /// cursor stands once every loaded turn is in the window (D11).
    func testTheWindowAppliesToTheTurnsAProviderLoaded() {
        var paged = transcript(turns: 10)
        paged.earlier = .provider(cursor: "earlier")
        let windowed = ConversationTurnWindow(turnCount: 2).apply(to: paged)
        XCTAssertEqual(windowed.turns.map(\.id), Array(paged.turns.suffix(2)).map(\.id))
        XCTAssertEqual(windowed.earlier, .local(hiddenCount: 8))
        XCTAssertEqual(ConversationTurnWindow(turnCount: 10).apply(to: paged), paged)
    }

    /// A long turn whose work shows is drawn in rows of a few runs of its work, which the window
    /// counts, so a conversation shown again builds only the rows it draws. The rows read as the turn:
    /// every item once, grouped as the whole turn grouped it, the head named after the turn and the
    /// tail closing it, and the parts before the tail stay as they were while the turn streams on.
    func testALongTurnWhoseWorkShowsIsDrawnInRowsOfItsRuns() throws {
        func presentation(_ turn: JSONValue) -> ConversationPresentation {
            CodexConversationProjection.presentation(LongConversationFixture.codex(threadID: "thread-rows", turns: [turn]),
                                                     workspaceURL: URL(filePath: "/tmp/yardlet-rows"), historySelection: nil)
        }
        func rows(_ presentation: ConversationPresentation) -> ConversationTurnRows {
            ConversationTurnRows(turns: presentation, split: ConversationTurnRows.split)
        }
        func calls(_ items: [ConversationItem]) -> Int { items.count { ConversationWorkSummary.category(of: $0) != nil } }
        let whole = presentation(LongConversationFixture.streamedCodexTurn(id: "turn-long", commands: 4, seconds: 100))
        let turn = try XCTUnwrap(whole.turns.first)
        XCTAssertFalse(turn.foldsWork)
        let split = rows(whole)
        let drawn = split.presentation.turns
        XCTAssertGreaterThan(drawn.count, 3)
        XCTAssertEqual(drawn.first?.id, turn.id)
        XCTAssertEqual(drawn.first?.prompt, turn.prompt)
        XCTAssertEqual(drawn.dropFirst().map(\.id),
                       (1..<drawn.count).map { ConversationTurnRows.partID(turnID: turn.id, index: $0) })
        XCTAssertEqual(Set(drawn.map { split.turnID(of: $0.id) }), [turn.id])
        XCTAssertEqual(split.part(of: turn.id), .head)
        XCTAssertEqual(split.part(of: drawn[1].id), .middle)
        XCTAssertEqual(drawn.flatMap(\.work), turn.work)
        XCTAssertEqual(drawn.flatMap { ConversationWorkGrouping.runs($0.work).map(\.id) },
                       ConversationWorkGrouping.runs(turn.work).map(\.id))
        XCTAssertTrue(drawn.dropLast().allSatisfy { ConversationWorkGrouping.runs($0.work).count == ConversationTurnRows.runsPerPart })
        let tail = try XCTUnwrap(drawn.last)
        XCTAssertEqual(tail.answers, turn.answers)
        XCTAssertTrue(drawn.dropLast().allSatisfy { $0.answers.isEmpty && $0.outcome == nil })
        XCTAssertEqual(split.part(of: tail.id), .tail(stepsBefore: calls(turn.work) - calls(tail.work)))
        XCTAssertEqual(split.turns(drawnIn: Array(drawn.suffix(2))).map(\.id), [turn.id])
        XCTAssertEqual(ConversationTurnWindow().apply(to: split.presentation).turns.count,
                       ConversationTurnWindow.initialTurnCount)

        // The longer stream's request names its length; its work is the same so far.
        let grown = rows(presentation(LongConversationFixture.streamedCodexTurn(id: "turn-long", commands: 4, seconds: 130)))
            .presentation.turns
        XCTAssertGreaterThan(grown.count, drawn.count)
        XCTAssertEqual(grown.first?.work, drawn.first?.work)
        XCTAssertEqual(Array(grown[1..<(drawn.count - 1)]), Array(drawn[1..<(drawn.count - 1)]))

        // A part saved as a place reads as its turn once the turn is drawn whole.
        XCTAssertEqual(ConversationAnchorResolver(presentation: whole, threadID: "thread-rows").anchor(for: drawn[2].id)?.turnID,
                       turn.id)
        XCTAssertNil(ConversationTurnRows.turnID(ofPart: turn.id))

        // A turn that folds its work, and a short one, are drawn whole.
        guard case var .object(fields) = LongConversationFixture.streamedCodexTurn(id: "turn-folds", commands: 4, seconds: 98),
              case var .array(items) = fields["items"],
              let last = items.lastIndex(where: { $0["type"]?.stringValue == "agentMessage" }),
              case var .object(answer) = items[last] else { return XCTFail("no answer to mark") }
        answer["phase"] = .string("final_answer")
        items[last] = .object(answer)
        fields["items"] = .array(items)
        let folding = presentation(.object(fields))
        XCTAssertTrue(try XCTUnwrap(folding.turns.first).foldsWork)
        XCTAssertEqual(rows(folding).presentation, folding)
        let short = presentation(LongConversationFixture.codexTurn(0))
        XCTAssertEqual(rows(short).presentation, short)
    }

    private func transcript(turns: Int) -> ConversationPresentation {
        let entries = (1...turns).flatMap { index in
            [TranscriptEntry(content: .user(text: "Request \(index)")),
             TranscriptEntry(content: .assistant(text: "Answer \(index)", isStreaming: false))]
        }
        return TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        )
    }
}
