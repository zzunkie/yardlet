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

    private struct CodexBesideListHost: View {
        let feed: CodexFeed
        let renderState: ConversationRenderState
        var body: some View {
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<400, id: \.self) { row in
                            Text(verbatim: "Task \(row): look at the parser module")
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        }
                    }
                }
                .frame(width: 280)
                TaskConversationView(harness: .codex, workspaceURL: LongConversationFixture.workspace, entries: [],
                                     sessionStatus: .running, codexTaskState: feed.state, renderState: renderState)
            }
            .frame(width: 1338, height: 900)
        }
    }

    /// The condition of the report this benchmark answers: a Codex answer, a list, streams at the
    /// end of a turn of 72 calls under four finished turns (125 items in all) while the list beside
    /// the conversation scrolls. Each step streams one fragment, scrolls the list, lays the window out
    /// and draws it, and turns the run loop for 2 ms. `NHC_PERF_STEPS` sets the steps (120), and
    /// `NHC_PERF_ANSWERS` which answers stream (`short,long`).
    func testBenchmarkACodexFragmentBesideAScrollingList() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NHC_PERF_BENCH"] == "1" else {
            throw XCTSkip("Set NHC_PERF_BENCH=1 to run the streaming cost benchmark")
        }
        let steps = environment["NHC_PERF_STEPS"].flatMap(Int.init) ?? 120
        let answers = (environment["NHC_PERF_ANSWERS"] ?? "none,short,long").split(separator: ",").map(String.init)
        var lines: [String] = []
        for answer in answers {
            for round in 0..<2 {
                lines.append("\(answer) list, round \(round + 1): " + measureBesideList(answer: answer, steps: steps))
            }
        }
        for line in lines { print("[issue-183] \(line)") }
    }

    private func measureBesideList(answer: String, steps: Int) -> String {
        let finished = (0..<4).map { LongConversationFixture.codexTurn($0) }
        let running = LongConversationFixture.runningCodexTurn(4, request: "Write up what changed", calls: 72, paragraphs: 1)
        var state = LongConversationFixture.codex(threadID: "thread-183", turns: finished + [running])
        let turn = state.thread!.turns.count - 1, item = state.thread!.turns[turn].items.count - 1
        state.thread!.turns[turn].items[item].lifecycle = .inProgress
        // A short list grows from nothing to about 1,000 characters, a long one from about 2,000 to 3,000.
        let earlier = answer == "long"
            ? (0..<24).map { "- Item \($0): the parser returned early on an empty input, so the lexer never saw it." }
                .joined(separator: "\n") + "\n"
            : ""
        let opening = "## Summary\n\n" + earlier + "- Working"
        var text = opening
        guard case var .agentMessage(message) = state.thread!.turns[turn].items[item].content else { return "" }
        message.text = text
        state.thread!.turns[turn].items[item].content = .agentMessage(message)
        let feed = CodexFeed(state)
        func publish(_ fragment: Int) {
            // A run longer than the default starts the answer again every 130 fragments, so it stays
            // as long as the default's.
            if fragment.isMultiple(of: 130) { text = opening }
            text += fragment.isMultiple(of: 12) ? "\n- Item \(fragment / 12) " : " word\(fragment)"
            guard case var .agentMessage(message) = feed.state.thread!.turns[turn].items[item].content else { return }
            message.text = text
            feed.state.thread!.turns[turn].items[item].content = .agentMessage(message)
        }
        let renderState = ConversationRenderState()
        let host = WindowlessRender.Host(CodexBesideListHost(feed: feed, renderState: renderState),
                                         size: NSSize(width: 1338, height: 900), appearance: .light)
        defer { host.close() }
        host.settle(passes: 20)
        let list = Self.scrollViews(in: host.hosting).min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        func step(_ index: Int) {
            if answer != "none" { publish(index) }
            if let list {
                list.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(index % 60) * 24))
                list.reflectScrolledClipView(list.contentView)
            }
            host.hosting.layoutSubtreeIfNeeded()
            host.window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
        for index in 0..<10 { step(index) }
        ViewBodyCensus.isEnabled = true
        ViewBodyCensus.reset()
        defer { ViewBodyCensus.isEnabled = false }
        let projected = renderState.projection.counts.projected
        if let file = ProcessInfo.processInfo.environment["NHC_PERF_MARK"] {
            FileManager.default.createFile(atPath: file, contents: Data("\(getpid())".utf8))
        }
        var durations: [Double] = []
        let start = Self.mainThreadCPU()
        for index in 10..<(10 + steps) {
            let stepStart = CACurrentMediaTime()
            step(index)
            durations.append(CACurrentMediaTime() - stepStart)
        }
        let cpu = Self.mainThreadCPU() - start
        durations.sort()
        return String(format: "median step %.1f ms, p95 %.1f ms, main thread %.2f s over %d steps (%.2f ms a step), "
                      + "%d turns drawn whole, %d turns projected, answer %d characters",
                      durations[durations.count / 2] * 1000, durations[durations.count * 95 / 100] * 1000, cpu, steps,
                      cpu / Double(steps) * 1000, ViewBodyCensus[.conversationTurn],
                      renderState.projection.counts.projected - projected, text.count)
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
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
