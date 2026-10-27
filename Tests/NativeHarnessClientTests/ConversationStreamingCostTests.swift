import AppKit
import Darwin
import Observation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// What one published fragment of a streaming answer costs the conversation as the conversation
/// grows: the same answer streams under 1, 4 and 9 finished turns (the turn window draws 10), each
/// fragment laid out as a shown window's display cycle lays it out. The layers under the hosting view
/// stand in for SwiftUI's display list, which every update walks.
///
/// Run with `NHC_PERF_BENCH=1`; it prints the numbers and checks nothing else.
@MainActor
final class ConversationStreamingCostTests: XCTestCase {
    @Observable
    final class Feed {
        var entries: [TranscriptEntry]
        init(_ entries: [TranscriptEntry]) { self.entries = entries }
    }

    private struct Host: View {
        let feed: Feed
        var body: some View {
            TaskConversationView(harness: .claudeCode, workspaceURL: LongConversationFixture.workspace,
                                 entries: feed.entries, sessionStatus: .running)
                .frame(width: 900, height: 700)
        }
    }

    struct Cost {
        let finishedTurns: Int
        let perFragment: Double
        let layoutPerFragment: Double
        let layers: Int
        /// Turns drawn again in their own hosting views while the fragments streamed.
        let turnsDrawn: Int
    }

    func testBenchmarkAFragmentAgainstTheConversationsLength() throws {
        guard ProcessInfo.processInfo.environment["NHC_PERF_BENCH"] == "1" else {
            throw XCTSkip("Set NHC_PERF_BENCH=1 to run the streaming cost benchmark")
        }
        var costs: [Cost] = []
        for round in 0..<2 {
            for turns in [1, 4, 9] {
                let cost = try measure(finishedTurns: turns)
                if round > 0 { costs.append(cost) }
            }
        }
        for cost in costs {
            print(String(format: "[streaming-cost] %d finished turns: %.2f ms a fragment (layout %.2f ms), %d layers, %d turns drawn",
                         cost.finishedTurns, cost.perFragment * 1000, cost.layoutPerFragment * 1000, cost.layers,
                         cost.turnsDrawn))
        }
    }

    private func measure(finishedTurns: Int) throws -> Cost {
        var entries = LongConversationFixture.claude(turns: finishedTurns)
        entries.append(TranscriptEntry(content: .user(text: "Write up what changed")))
        let answer = TranscriptEntry(content: .assistant(text: "Working", isStreaming: true))
        entries.append(answer)
        let feed = Feed(entries)
        let host = WindowlessRender.Host(Host(feed: feed), size: NSSize(width: 900, height: 700), appearance: .light)
        defer { host.close() }
        host.settle(passes: 20)

        var text = "## Summary\n\nWorking"
        func publish(_ fragment: Int) {
            text += fragment.isMultiple(of: 25) ? "\n\n- point \(fragment) " : " word\(fragment)"
            feed.entries[feed.entries.count - 1] = TranscriptEntry(
                id: answer.id, createdAt: answer.createdAt, content: .assistant(text: text, isStreaming: true))
        }
        for fragment in 0..<20 {
            publish(fragment)
            host.hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date())
        }
        let fragments = 80
        ViewBodyCensus.isEnabled = true
        ViewBodyCensus.reset()
        defer { ViewBodyCensus.isEnabled = false }
        var layout = 0.0
        let start = Self.mainThreadCPU()
        for fragment in 20..<(20 + fragments) {
            publish(fragment)
            let layoutStart = Self.mainThreadCPU()
            host.hosting.layoutSubtreeIfNeeded()
            layout += Self.mainThreadCPU() - layoutStart
            RunLoop.main.run(until: Date())
        }
        let perFragment = (Self.mainThreadCPU() - start) / Double(fragments)
        let turnsDrawn = ViewBodyCensus[.conversationTurn]
        return Cost(finishedTurns: finishedTurns, perFragment: perFragment, layoutPerFragment: layout / Double(fragments),
                    layers: Self.layerCount(host.hosting.layer), turnsDrawn: turnsDrawn)
    }

    @Observable
    final class CodexFeed {
        var state: CodexTaskState
        init(_ state: CodexTaskState) { self.state = state }
    }

    private struct CodexHost: View {
        let feed: CodexFeed
        var body: some View {
            TaskConversationView(harness: .codex, workspaceURL: LongConversationFixture.workspace, entries: [],
                                 sessionStatus: .running, codexTaskState: feed.state)
                .frame(width: 900, height: 700)
        }
    }

    /// A Codex answer streaming at the end of a turn of 3 and of 72 calls, under four finished turns
    /// (129 items in all with 72): what a fragment costs the main thread, and how many turns it drew
    /// whole.
    func testBenchmarkACodexFragmentInATurnOfManyCalls() throws {
        guard ProcessInfo.processInfo.environment["NHC_PERF_BENCH"] == "1" else {
            throw XCTSkip("Set NHC_PERF_BENCH=1 to run the streaming cost benchmark")
        }
        var costs: [(calls: Int, cost: Cost)] = []
        for round in 0..<3 {
            for calls in [3, 72] {
                let cost = measureCodex(calls: calls)
                if round > 0 { costs.append((calls, cost)) }
            }
        }
        for (calls, cost) in costs {
            print(String(format: "[codex-streaming-cost] %d calls: %.2f ms a fragment (layout %.2f ms), %d layers, %d turns drawn",
                         calls, cost.perFragment * 1000, cost.layoutPerFragment * 1000, cost.layers, cost.turnsDrawn))
        }
    }

    private func measureCodex(calls: Int) -> Cost {
        let finished = (0..<4).map { LongConversationFixture.codexTurn($0) }
        let running = LongConversationFixture.runningCodexTurn(4, request: "Write up what changed", calls: calls, paragraphs: 1)
        var state = LongConversationFixture.codex(threadID: "thread-cost", turns: finished + [running])
        let turn = state.thread!.turns.count - 1, item = state.thread!.turns[turn].items.count - 1
        // The answer is being written, as the App Server's first delta leaves it.
        state.thread!.turns[turn].items[item].lifecycle = .inProgress
        let feed = CodexFeed(state)
        let host = WindowlessRender.Host(CodexHost(feed: feed), size: NSSize(width: 900, height: 700), appearance: .light)
        defer { host.close() }
        host.settle(passes: 20)

        var text = "## Summary\n\nWorking"
        func publish(_ fragment: Int) {
            text += fragment.isMultiple(of: 25) ? "\n\n- point \(fragment) " : " word\(fragment)"
            guard case var .agentMessage(message) = feed.state.thread!.turns[turn].items[item].content else { return }
            message.text = text
            feed.state.thread!.turns[turn].items[item].content = .agentMessage(message)
        }
        for fragment in 0..<20 {
            publish(fragment)
            host.hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date())
        }
        let fragments = 80
        ViewBodyCensus.isEnabled = true
        ViewBodyCensus.reset()
        defer { ViewBodyCensus.isEnabled = false }
        var layout = 0.0
        let start = Self.mainThreadCPU()
        for fragment in 20..<(20 + fragments) {
            publish(fragment)
            let layoutStart = Self.mainThreadCPU()
            host.hosting.layoutSubtreeIfNeeded()
            layout += Self.mainThreadCPU() - layoutStart
            RunLoop.main.run(until: Date())
        }
        let perFragment = (Self.mainThreadCPU() - start) / Double(fragments)
        return Cost(finishedTurns: 4, perFragment: perFragment, layoutPerFragment: layout / Double(fragments),
                    layers: Self.layerCount(host.hosting.layer), turnsDrawn: ViewBodyCensus[.conversationTurn])
    }

    @Observable
    final class Shown {
        var isShown = true
    }

    private struct Toggle: View {
        let shown: Shown
        let entries: [TranscriptEntry]
        let renderState: ConversationRenderState
        var body: some View {
            Group {
                if shown.isShown {
                    TaskConversationView(harness: .claudeCode, workspaceURL: LongConversationFixture.workspace,
                                         entries: entries, sessionStatus: .ready, latestTurnIsComplete: true,
                                         renderState: renderState)
                } else {
                    Color.clear
                }
            }
            .frame(width: 900, height: 700)
        }
    }

    /// A conversation shown again, as a task is opened again: the main thread's time from showing it
    /// to its having drawn, under 20 and 300 finished turns (the turn window draws 10).
    func testBenchmarkShowingAConversationAgain() throws {
        guard ProcessInfo.processInfo.environment["NHC_PERF_BENCH"] == "1" else {
            throw XCTSkip("Set NHC_PERF_BENCH=1 to run the streaming cost benchmark")
        }
        var lines: [String] = []
        for turns in [20, 300] {
            let shown = Shown()
            let host = WindowlessRender.Host(
                Toggle(shown: shown, entries: LongConversationFixture.claude(turns: turns), renderState: ConversationRenderState()),
                size: NSSize(width: 900, height: 700), appearance: .light)
            defer { host.close() }
            host.settle(passes: 20)
            var costs: [Double] = []
            for round in 0..<6 {
                shown.isShown = false
                host.settle(passes: 4)
                let start = Self.mainThreadCPU()
                shown.isShown = true
                // Until it has drawn: the run loop's waits cost the main thread nothing.
                host.settle(passes: 3, interval: 0.01)
                let cost = Self.mainThreadCPU() - start
                host.settle(passes: 2)
                if round > 0 { costs.append(cost) }
            }
            lines.append(String(format: "%d turns: shown again in %@ ms of the main thread", turns,
                                costs.map { String(format: "%.1f", $0 * 1000) }.joined(separator: ", ")))
        }
        for line in lines { print("[show-again] \(line)") }
    }

    private static func layerCount(_ layer: CALayer?) -> Int {
        guard let layer else { return 0 }
        return 1 + (layer.sublayers ?? []).reduce(0) { $0 + layerCount($1) }
    }

    private static func mainThreadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let port = pthread_mach_thread_np(pthread_self())
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
    }
}
