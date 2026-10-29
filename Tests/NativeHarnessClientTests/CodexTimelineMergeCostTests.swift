import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import NativeHarnessClient

/// What one streamed Codex presentation costs the main actor in a task with many saved cards: the
/// app merges the saved cards into every state the provider streams (`supplementEntries`, then
/// `mergeItemPage`), settles running cards and works out which cards to save, as
/// `AppModel.startCodexPresentationCollection` does. The provider's resumed history leaves each
/// card historical, so every saved card replaces the provider's copy on every state.
///
/// Run with `NHC_PERF_BENCH=1`; `NHC_CODEX_CARDS=<file>` reads a saved card file instead of the
/// built-in one. It prints the numbers and a digest of the last merged state, and checks nothing else.
@MainActor
final class CodexTimelineMergeCostTests: XCTestCase {
    func testBenchmarkAStreamedStateAgainstTheSavedCards() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NHC_PERF_BENCH"] == "1" else {
            throw XCTSkip("Set NHC_PERF_BENCH=1 to run the Codex timeline merge benchmark")
        }
        let saved: [CodexPersistedTimelineItem]
        if let path = environment["NHC_CODEX_CARDS"], !path.isEmpty {
            saved = try JSONDecoder().decode([CodexPersistedTimelineItem].self, from: Data(contentsOf: URL(filePath: path)))
        } else {
            saved = Self.syntheticCards(turns: [263, 237], outputLength: 5_000)
        }
        var provider = Self.providerState(resuming: saved)
        let reducer = CodexTaskReducer()
        var timeline = CodexPersistedTimeline()
        var persisted = CodexPersistedTimeline()
        var settledTurns = CodexSettledTurns()
        var mergeTimes: [Double] = []
        var stepTimes: [Double] = []
        var mergeCPU = 0.0, stepCPU = 0.0
        var entryCount = 0
        var last = provider
        let states = 200
        for step in 0..<states {
            // The provider streams a fragment into the running answer and sends the state.
            let liveTurn = provider.thread!.turns.count - 1
            guard case var .agentMessage(message) = provider.thread!.turns[liveTurn].items[1].content else {
                return XCTFail("live answer")
            }
            message.text += "word \(step) "
            provider.thread!.turns[liveTurn].items[1].content = .agentMessage(message)

            let stepStart = (ContinuousClock.now, Self.threadCPU())
            var merged = provider
            let entries = timeline.supplementEntries(for: merged, saved: saved)
            if !entries.isEmpty {
                reducer.mergeItemPage(CodexItemPage(entries: entries, nextCursor: nil, backwardsCursor: nil), into: &merged)
            }
            let mergeEnd = (ContinuousClock.now, Self.threadCPU())
            reducer.reconcileResolvedServerRequestItems(in: &merged)
            reducer.reconcileTerminalActivityItems(in: &merged, settledTurns: &settledTurns)
            _ = persisted.items(from: merged)
            let stepEnd = (ContinuousClock.now, Self.threadCPU())

            entryCount = entries.count
            last = merged
            guard step >= 10 else { continue }
            mergeTimes.append(Self.seconds(mergeEnd.0 - stepStart.0))
            stepTimes.append(Self.seconds(stepEnd.0 - stepStart.0))
            mergeCPU += mergeEnd.1 - stepStart.1
            stepCPU += stepEnd.1 - stepStart.1
        }
        let measured = Double(mergeTimes.count)
        let items = last.thread!.turns.reduce(0) { $0 + $1.items.count }
        print(String(format: "[codex-merge-cost] %d saved cards, %d supplemented a state, %d items in %d turns",
                     saved.count, entryCount, items, last.thread!.turns.count))
        print(String(format: "[codex-merge-cost] merge: median %.2f ms, p95 %.2f ms, CPU %.2f ms a state",
                     Self.percentile(mergeTimes, 0.5) * 1000, Self.percentile(mergeTimes, 0.95) * 1000,
                     mergeCPU / measured * 1000))
        print(String(format: "[codex-merge-cost] whole state: median %.2f ms, p95 %.2f ms, CPU %.2f ms a state",
                     Self.percentile(stepTimes, 0.5) * 1000, Self.percentile(stepTimes, 0.95) * 1000,
                     stepCPU / measured * 1000))
        print("[codex-merge-cost] merged state digest \(Self.digest(last))")
    }

    // MARK: - Fixture

    /// The provider's state after a resume: the saved cards' turns, each with the person's request
    /// and the cards as the provider's history gives them (historical), then a running turn.
    private static func providerState(resuming saved: [CodexPersistedTimelineItem]) -> CodexTaskState {
        var turnIDs: [String] = []
        var itemsByTurn: [String: [CodexItemState]] = [:]
        for card in saved {
            if itemsByTurn[card.turnID] == nil {
                turnIDs.append(card.turnID)
                itemsByTurn[card.turnID] = [user("\(card.turnID)-request")]
            }
            var item = card.pageEntry.item
            item.lifecycle = .historical
            itemsByTurn[card.turnID]!.append(item)
        }
        func turn(_ id: String, _ status: CodexTurnStatus, _ items: [CodexItemState]) -> CodexTurnState {
            CodexTurnState(
                id: id, status: status, startedAt: nil, completedAt: nil, durationMilliseconds: nil,
                itemsView: .full, items: items, itemsNextCursor: nil, plan: nil, tokenUsage: nil,
                error: nil, raw: .object(["id": .string(id)])
            )
        }
        var turns = turnIDs.map { turn($0, .completed, itemsByTurn[$0]!) }
        turns.append(turn("live", .inProgress, [
            user("live-request"),
            CodexTaskDecoder().item(from: .object([
                "id": .string("live-answer"), "type": .string("agentMessage"), "text": .string(""),
                "phase": .string("final_answer")
            ]), fallbackID: "live-answer", lifecycle: .inProgress)
        ]))
        var state = CodexTaskState.empty
        state.thread = CodexThreadState(
            id: "thread", sessionID: nil, name: nil, preview: "", workspacePath: "/tmp/workspace",
            cliVersion: nil, modelProvider: nil, parentThreadID: nil, forkedFromID: nil, status: .active(flags: []),
            canAcceptDirectInput: nil, createdAt: nil, updatedAt: nil, turns: turns,
            turnsNextCursor: nil, turnsBackwardsCursor: nil, itemsBackwardsCursor: nil, raw: .object([:])
        )
        return state
    }

    private static func syntheticCards(turns: [Int], outputLength: Int) -> [CodexPersistedTimelineItem] {
        let output = String(repeating: "Compiling module\n", count: outputLength / 17)
        return turns.enumerated().flatMap { turnIndex, count in
            (0..<count).map { slot in
                let id = "call_\(turnIndex)_\(slot)_0123456789abcdef"
                let item = CodexTaskDecoder().item(from: .object([
                    "id": .string(id), "type": .string("commandExecution"), "command": .string("swift build \(slot)"),
                    "cwd": .string("/tmp/workspace"), "status": .string("completed"),
                    "aggregatedOutput": .string(output), "exitCode": .number(0)
                ]), fallbackID: id, lifecycle: .completed)
                return CodexPersistedTimelineItem(turnID: "turn-\(turnIndex)", item: item)
            }
        }
    }

    private static func user(_ id: String) -> CodexItemState {
        CodexTaskDecoder().item(from: .object([
            "id": .string(id), "type": .string("userMessage"),
            "content": .array([.object(["type": .string("text"), "text": .string("Keep going")])])
        ]), fallbackID: id, lifecycle: .completed)
    }

    // MARK: - Measuring

    private static func threadCPU() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    /// Every item of every turn, in order, with what the merge decides about it.
    private static func digest(_ state: CodexTaskState) -> String {
        var hash = SHA256()
        for turn in state.thread?.turns ?? [] {
            hash.update(data: Data("turn \(turn.id) \(turn.status) \(turn.itemsNextCursor ?? "-")\n".utf8))
            for item in turn.items {
                let card = CodexPersistedTimelineItem(turnID: turn.id, item: item)
                let raw = (try? JSONEncoder.sorted.encode(card.raw)) ?? Data()
                hash.update(data: Data("\(item.id) \(item.lifecycle) \(String(describing: item.startedAt)) \(String(describing: item.completedAt))\n".utf8))
                hash.update(data: raw)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

private extension JSONEncoder {
    static let sorted: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()
}
