import Foundation
import XCTest
@testable import NativeHarnessClient

/// The saved-card window and the supplement of saved cards must stay what walking the whole
/// presentation gave, while costing only the newest window.
final class CodexPersistedTimelineTests: XCTestCase {
    func testTheSavedWindowMatchesWalkingTheWholeThreadAsItStreams() {
        var timeline = CodexPersistedTimeline()
        var state = Self.thread(turns: 200, itemsPerTurn: 9)
        XCTAssertEqual(timeline.items(from: state), Self.referenceItems(state))
        XCTAssertEqual(Self.referenceItems(state).count, 500, "The fixture must overflow the window")

        // A running command streams, an answer of an interrupted turn grows, a card settles,
        // turns arrive and leave, and the walk reuses what did not change.
        let last = state.thread!.turns.count - 1
        state.thread!.turns[last].status = .inProgress
        state.thread!.turns[last].items.append(Self.command("live", output: nil, done: false))
        XCTAssertEqual(timeline.items(from: state), Self.referenceItems(state))
        for line in ["Compiling\n", "Linking\n"] {
            let index = state.thread!.turns[last].items.count - 1
            guard case var .commandExecution(command) = state.thread!.turns[last].items[index].content else {
                return XCTFail("command")
            }
            command.aggregatedOutput = (command.aggregatedOutput ?? "") + line
            state.thread!.turns[last].items[index].content = .commandExecution(command)
            XCTAssertEqual(timeline.items(from: state), Self.referenceItems(state))
        }
        state.thread!.turns[last].status = .interrupted
        state.thread!.turns[last].items.append(Self.answer("partial", "Half an answer"))
        state.thread!.turns[last].items.append(Self.answer("empty", ""))
        XCTAssertEqual(timeline.items(from: state), Self.referenceItems(state))
        state.thread!.turns[last].items[state.thread!.turns[last].items.count - 3] =
            Self.command("live", output: "Compiling\nLinking\n", done: true)
        XCTAssertEqual(timeline.items(from: state), Self.referenceItems(state))
        state.thread!.turns.removeFirst(3)
        state.thread!.turns.append(contentsOf: Self.thread(turns: 2, itemsPerTurn: 4, prefix: "new").thread!.turns)
        XCTAssertEqual(timeline.items(from: state), Self.referenceItems(state))
        state.thread!.turns[0].items.removeAll()
        XCTAssertEqual(timeline.items(from: state), Self.referenceItems(state))
        state.thread = nil
        XCTAssertEqual(timeline.items(from: state), [])
    }

    func testSupplementingSavedCardsMatchesTheWholeThreadFilter() {
        var state = Self.thread(turns: 6, itemsPerTurn: 6)
        let saved = CodexPersistedTimeline().itemsForTest(from: state)
        // The provider's history: one turn interrupted without its answer and with a card it
        // left as started, a card it dropped, a turn it has not loaded, and a repeated turn ID.
        state.thread!.turns[2].status = .interrupted
        state.thread!.turns[2].items.removeAll { $0.id == "turn-2-item-5" }
        state.thread!.turns[2].items[2].lifecycle = .inProgress
        state.thread!.turns[3].items.removeAll { $0.id == "turn-3-item-2" }
        state.thread!.turns[4].items[2].lifecycle = .historical
        state.thread!.turns.remove(at: 5)
        state.thread!.turns.append(Self.thread(turns: 1, itemsPerTurn: 3, prefix: "turn-4").thread!.turns[0].renamed("turn-4"))
        let extra = [
            CodexPersistedTimelineItem(turnID: "turn-2", item: Self.answer("turn-2-item-5", "Saved answer")),
            CodexPersistedTimelineItem(turnID: "turn-1", item: Self.answer("turn-1-extra", "Not interrupted")),
            CodexPersistedTimelineItem(turnID: "turn-2", item: Self.answer("turn-2-item-0", "Provider has it"))
        ]
        let cards = saved + extra
        var timeline = CodexPersistedTimeline()
        let entries = timeline.supplementEntries(for: state, saved: cards)
        XCTAssertEqual(entries, Self.referenceEntries(state, cards))
        XCTAssertFalse(entries.isEmpty, "The fixture must supplement something")
        XCTAssertEqual(entries.filter { $0.item.id == "turn-2-item-5" }.count, 2)
        XCTAssertFalse(entries.contains { $0.item.id == "turn-1-extra" })

        // Merged as one page, the cards land as merged one at a time: a card whose ID came earlier
        // in the page, turns interleaved, and turns the page adds in the order it names them.
        let page = Array(entries.prefix(2)) + [
            CodexItemPageEntry(turnID: "unloaded-b", item: Self.answer("b", "B")),
            CodexItemPageEntry(turnID: "unloaded-a", item: Self.answer("a", "A"))
        ] + entries.dropFirst(2) + [CodexItemPageEntry(turnID: "unloaded-b", item: Self.reasoning("b"))]
        var merged = state, oneByOne = state
        CodexTaskReducer().mergeItemPage(CodexItemPage(entries: page, nextCursor: "next", backwardsCursor: nil), into: &merged)
        for entry in page {
            CodexTaskReducer().mergeItemPage(
                CodexItemPage(entries: [entry], nextCursor: "next", backwardsCursor: nil), into: &oneByOne
            )
        }
        XCTAssertEqual(merged, oneByOne)
        XCTAssertEqual(merged.thread!.turns.suffix(2).map(\.id), ["unloaded-b", "unloaded-a"])

        // Remembered turns answer the same as long as they are the same, and change with them.
        XCTAssertEqual(timeline.supplementEntries(for: state, saved: cards), entries)
        state.thread!.turns[2].items.append(Self.answer("turn-2-item-5", "The provider's own"))
        XCTAssertEqual(timeline.supplementEntries(for: state, saved: cards), Self.referenceEntries(state, cards))
        state.thread!.turns[2].status = .completed
        state.thread!.turns[3].items.append(Self.command("turn-3-item-2", output: "back\n", done: true))
        XCTAssertEqual(timeline.supplementEntries(for: state, saved: cards), Self.referenceEntries(state, cards))
        state.thread!.turns.swapAt(0, 5)
        XCTAssertEqual(timeline.supplementEntries(for: state, saved: cards), Self.referenceEntries(state, cards))
        let fewer = Array(cards.dropFirst(4))
        XCTAssertEqual(timeline.supplementEntries(for: state, saved: fewer), Self.referenceEntries(state, fewer))
        XCTAssertEqual(timeline.supplementEntries(for: .empty, saved: cards), [])
        XCTAssertEqual(timeline.supplementEntries(for: state, saved: []), [])
        XCTAssertEqual(timeline.supplementEntries(for: state, saved: cards), Self.referenceEntries(state, cards))
    }

    /// A streamed state merges its saved cards as their page would merge, and the turns it did not
    /// change come back in the storage of the last state's merge: what compares them next (settling
    /// cards, choosing the cards to save, the views) then finds them equal at once.
    func testMergingSavedCardsMatchesMergingTheirPageAndKeepsTheTurnsThatDidNotChange() {
        var state = Self.thread(turns: 6, itemsPerTurn: 6)
        var cards = CodexPersistedTimeline().itemsForTest(from: state)
        // The provider's history leaves every card it resumed historical, so every saved card replaces its copy.
        for turn in state.thread!.turns.indices {
            for item in state.thread!.turns[turn].items.indices { state.thread!.turns[turn].items[item].lifecycle = .historical }
        }
        var timeline = CodexPersistedTimeline()
        func merged(_ state: CodexTaskState) -> CodexTaskState {
            var merged = state
            timeline.merge(cards, into: &merged)
            var page = state
            CodexTaskReducer().mergeItemPage(
                CodexItemPage(entries: Self.referenceEntries(state, cards), nextCursor: nil, backwardsCursor: nil), into: &page)
            XCTAssertEqual(merged, page)
            return merged
        }
        func sameStorage(_ first: CodexTaskState, _ second: CodexTaskState, turn: Int) -> Bool {
            first.thread!.turns[turn].items.withUnsafeBufferPointer { first in
                second.thread!.turns[turn].items.withUnsafeBufferPointer { $0.baseAddress == first.baseAddress }
            }
        }
        let first = merged(state)

        // The latest turn runs and streams; then a card of it is saved, which changes the saved cards.
        let last = state.thread!.turns.count - 1
        state.thread!.turns[last].status = .inProgress
        state.thread!.turns[last].items.append(Self.command("live", output: "Compiling\n", done: false))
        let streaming = merged(state)
        XCTAssertTrue(sameStorage(first, streaming, turn: 0), "An unchanged turn was merged again")
        cards.append(CodexPersistedTimelineItem(turnID: state.thread!.turns[last].id,
                                                item: Self.command("live", output: "Compiling\n", done: false)))
        let saved = merged(state)
        XCTAssertTrue(sameStorage(streaming, saved, turn: 0), "A card saved in another turn merged this one again")

        // A turn the provider changed, and cards of that turn the app saved again, are merged anew.
        state.thread!.turns[1].items.removeLast()
        XCTAssertFalse(sameStorage(saved, merged(state), turn: 1))
        let removed = cards.remove(at: cards.firstIndex { $0.turnID == state.thread!.turns[2].id }!)
        XCTAssertFalse(merged(state).thread!.turns[2].items.contains { $0.id == removed.pageEntry.item.id
            && $0.lifecycle == .completed }, "A card no longer saved still replaced its copy")
        state.thread = nil
        var none = state
        timeline.merge(cards, into: &none)
        XCTAssertNil(none.thread)
    }

    func testRememberedSettledTurnsCloseTheSameCardsAsAFreshWalk() {
        var settledTurns = CodexSettledTurns()
        var state = Self.thread(turns: 5, itemsPerTurn: 3)
        func check(_ phase: String) {
            var fresh = state
            CodexTaskReducer().reconcileTerminalActivityItems(in: &fresh)
            var remembered = state
            CodexTaskReducer().reconcileTerminalActivityItems(in: &remembered, settledTurns: &settledTurns)
            XCTAssertEqual(remembered, fresh, phase)
            state = remembered
        }
        check("settled history")
        state.thread!.turns[4].status = .inProgress
        state.thread!.turns[4].items.append(Self.command("live", output: nil, done: false))
        check("a running turn is left alone")
        state.serverRequestsByID["s1"] = CodexServerRequestState(
            id: "s1", method: "item/commandExecution/requestApproval", kind: .commandExecutionApproval,
            threadID: "thread", turnID: "turn-4", itemID: "live", params: nil, resolution: .pending
        )
        state.thread!.turns[4].status = .completed
        check("a pending approval keeps its card running in a finished turn")
        check("and again")
        state.serverRequestsByID["s1"]?.resolution = .resolved(.object(["decision": .string("accept")]))
        check("an answered approval lets the card close")
        XCTAssertEqual(state.thread!.turns[4].items.last?.lifecycle, .completed)
        state.thread!.turns[1].items[1].lifecycle = .inProgress
        check("a settled turn whose items changed is walked again")
        XCTAssertEqual(state.thread!.turns[1].items[1].lifecycle, .completed)
        state.thread = nil
        check("no thread")
    }

    func testTerminalTurnsCloseOnlyTheirRunningCards() {
        var state = Self.thread(turns: 3, itemsPerTurn: 3)
        state.thread!.turns[1].items[2] = Self.command("running", output: "half\n", done: false)
        state.thread!.turns[2].status = .inProgress
        state.thread!.turns[2].items[2] = Self.command("live", output: nil, done: false)
        let untouched = state
        var settled = state
        CodexTaskReducer().reconcileTerminalActivityItems(in: &settled)
        XCTAssertEqual(settled.thread!.turns[1].items[2].lifecycle, .completed)
        XCTAssertEqual(settled.thread!.turns[1].items[2].raw["status"], .string("interrupted"))
        XCTAssertEqual(settled.thread!.turns[2], untouched.thread!.turns[2])
        XCTAssertEqual(settled.thread!.turns[0], untouched.thread!.turns[0])
        var again = settled
        CodexTaskReducer().reconcileTerminalActivityItems(in: &again)
        XCTAssertEqual(again, settled)
    }

    func testTheReadingSnapshotKeepsTheNewestEntriesOfTheWholeThread() {
        for (turns, errorEvery) in [(0, 1), (3, 2), (90, 7), (400, 5)] {
            var state = Self.thread(turns: turns, itemsPerTurn: 4)
            state.thread!.createdAt = Date(timeIntervalSince1970: 1_650_000_000)
            for index in 0..<turns {
                state.thread!.turns[index].items.insert(CodexTaskDecoder().item(from: .object([
                    "id": .string("user-\(index)"), "type": .string("userMessage"),
                    "content": .array([.object(["type": .string("text"), "text": .string("Request \(index)")])])
                ]), fallbackID: "user-\(index)", lifecycle: .completed), at: 0)
            }
            for index in 0..<turns where index % errorEvery == 0 {
                state.thread!.turns[index].error = .string(index % 2 == 0 ? "Stopped \(index)" : "  ")
                state.thread!.turns[index].completedAt = Date(timeIntervalSince1970: Double(1_700_000_000 + index))
            }
            if turns > 0 {
                state.thread!.turns[turns - 1].items.append(Self.answer("blank", "   "))
                state.thread!.turns[turns - 1].items.append(
                    CodexTaskDecoder().item(from: .object([
                        "id": .string("plan"), "type": .string("plan"), "text": .string("1. Build")
                    ]), fallbackID: "plan", lifecycle: .completed)
                )
            }
            let entries = CodexTranscriptSnapshotProjection.entries(from: state)
            let reference = Self.referenceTranscript(state)
            XCTAssertEqual(entries.map(\.content), reference.map(\.content), "\(turns) turns")
            XCTAssertEqual(entries.map(\.createdAt), reference.map(\.createdAt), "\(turns) turns")
        }
    }

    // MARK: - The whole-thread walks these replace

    private static func referenceTranscript(_ state: CodexTaskState) -> [TranscriptEntry] {
        guard let thread = state.thread else { return [] }
        var entries: [TranscriptEntry] = []
        let fixed = Date(timeIntervalSince1970: 1_600_000_000)
        for turn in thread.turns {
            for item in turn.items {
                let createdAt = item.startedAt ?? item.completedAt ?? turn.startedAt ?? turn.completedAt
                    ?? thread.updatedAt ?? thread.createdAt ?? fixed
                switch item.content {
                case let .userMessage(message):
                    let sent = message.sentContent
                    let text = sent.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty || !sent.images.isEmpty else { continue }
                    entries.append(TranscriptEntry(createdAt: createdAt, content: .user(
                        text: text, images: sent.images.isEmpty ? nil : sent.images
                    )))
                case let .agentMessage(message):
                    let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    entries.append(TranscriptEntry(createdAt: createdAt, content: .assistant(text: text, isStreaming: false)))
                case let .plan(text):
                    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    entries.append(TranscriptEntry(createdAt: createdAt, content: .plan(text)))
                default:
                    continue
                }
            }
            if let error = turn.error?.stringValue,
               !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries.append(TranscriptEntry(
                    createdAt: turn.completedAt ?? turn.startedAt ?? fixed,
                    content: .error(message: error, recoverable: false)
                ))
            }
        }
        return Array(entries.suffix(500))
    }

    private static func referenceItems(_ state: CodexTaskState) -> [CodexPersistedTimelineItem] {
        let items = (state.thread?.turns ?? []).flatMap { turn in
            turn.items.compactMap { item -> CodexPersistedTimelineItem? in
                if item.content.shouldPersistAcrossResume {
                    return CodexPersistedTimelineItem(turnID: turn.id, item: item)
                }
                if turn.status == .interrupted, case let .agentMessage(message) = item.content,
                   !message.text.isEmpty {
                    return CodexPersistedTimelineItem(turnID: turn.id, item: item)
                }
                return nil
            }
        }
        return Array(items.suffix(500))
    }

    private static func referenceEntries(
        _ state: CodexTaskState,
        _ saved: [CodexPersistedTimelineItem]
    ) -> [CodexItemPageEntry] {
        let loadedTurnIDs = Set(state.thread?.turns.map(\.id) ?? [])
        let lifecycles = Dictionary(
            (state.thread?.turns ?? []).flatMap { turn in turn.items.map { ("\(turn.id)\n\($0.id)", $0.lifecycle) } },
            uniquingKeysWith: max
        )
        return saved.map(\.pageEntry).filter { entry in
            guard loadedTurnIDs.contains(entry.turnID) else { return false }
            if let live = lifecycles["\(entry.turnID)\n\(entry.item.id)"],
               live >= entry.item.lifecycle { return false }
            if case .agentMessage = entry.item.content {
                guard let turn = state.thread?.turns.first(where: { $0.id == entry.turnID }),
                      turn.status == .interrupted else { return false }
                return !turn.items.contains { $0.id == entry.item.id }
            }
            return true
        }
    }

    // MARK: - Fixture

    private static func thread(turns: Int, itemsPerTurn: Int, prefix: String = "turn") -> CodexTaskState {
        var state = CodexTaskState.empty
        state.thread = CodexThreadState(
            id: "thread", sessionID: nil, name: nil, preview: "", workspacePath: "/tmp/workspace",
            cliVersion: nil, modelProvider: nil, parentThreadID: nil, forkedFromID: nil, status: .idle,
            canAcceptDirectInput: nil, createdAt: nil, updatedAt: nil,
            turns: (0..<turns).map { index in
                let id = "\(prefix)-\(index)"
                return CodexTurnState(
                    id: id, status: .completed, startedAt: nil, completedAt: nil, durationMilliseconds: nil,
                    itemsView: .full,
                    items: (0..<itemsPerTurn).map { slot in
                        let itemID = "\(id)-item-\(slot)"
                        switch slot % 3 {
                        case 0: return answer(itemID, "Answer \(itemID)")
                        case 1: return reasoning(itemID)
                        default: return command(itemID, output: "Output \(itemID)\n", done: true)
                        }
                    },
                    itemsNextCursor: nil, plan: nil, tokenUsage: nil, error: nil, raw: .object(["id": .string(id)])
                )
            },
            turnsNextCursor: nil, turnsBackwardsCursor: nil, itemsBackwardsCursor: nil, raw: .object([:])
        )
        return state
    }

    private static func answer(_ id: String, _ text: String) -> CodexItemState {
        CodexTaskDecoder().item(from: .object([
            "id": .string(id), "type": .string("agentMessage"), "text": .string(text), "phase": .string("final_answer")
        ]), fallbackID: id, lifecycle: .completed)
    }

    private static func reasoning(_ id: String) -> CodexItemState {
        CodexTaskDecoder().item(from: .object([
            "id": .string(id), "type": .string("reasoning"), "summary": .array([.string("Thinking")]), "content": .array([])
        ]), fallbackID: id, lifecycle: .completed)
    }

    private static func command(_ id: String, output: String?, done: Bool) -> CodexItemState {
        CodexTaskDecoder().item(from: .object([
            "id": .string(id), "type": .string("commandExecution"), "command": .string("swift build"),
            "cwd": .string("/tmp/workspace"), "status": .string(done ? "completed" : "inProgress"),
            "aggregatedOutput": output.map(JSONValue.string) ?? .null
        ]), fallbackID: id, lifecycle: done ? .completed : .inProgress)
    }
}

private extension CodexPersistedTimeline {
    func itemsForTest(from state: CodexTaskState) -> [CodexPersistedTimelineItem] {
        var timeline = self
        return timeline.items(from: state)
    }
}

private extension CodexTurnState {
    func renamed(_ id: String) -> CodexTurnState {
        CodexTurnState(
            id: id, status: status, startedAt: startedAt, completedAt: completedAt,
            durationMilliseconds: durationMilliseconds, itemsView: itemsView, items: items,
            itemsNextCursor: itemsNextCursor, plan: plan, tokenUsage: tokenUsage, error: error, raw: raw
        )
    }
}
