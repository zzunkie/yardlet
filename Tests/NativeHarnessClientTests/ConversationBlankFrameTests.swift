import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The conversation never draws blank — neither the empty canvas nor the window's gray behind it —
/// while the person switches tasks, sends and reads a response as it streams, or opens a long
/// conversation and reads back through it. The whole window (`MainWindow` over an `AppModel`) is
/// mounted, at the size the person's window has (900 × 600), in a window that is never shown, and
/// every frame Core Animation commits is read (`BlankFrameProbe`). The tasks are long working
/// conversations (`LongConversationFixture`); fake adapters stand in for the providers, and nothing the
/// person owns is read or written.
///
/// Each measurement prints `[blank-frames] <name>: <frames>, <blank> blank in <runs> run(s), longest
/// <ms>`; `NHC_BLANK_FRAMES_DUMP=1` also prints every frame, the scroll geometry and an image of the
/// first blank frame of each run under `.build/blank-frames`.
@MainActor
final class ConversationBlankFrameTests: XCTestCase {
    static let size = NSSize(width: 900, height: 600)

    // MARK: - Switching tasks

    /// Loaded tasks of every length and harness, opened one after another and back and forth quickly.
    func testSwitchingTasksNeverDrawsABlankConversation() throws {
        let window = try makeWindow([.claude("Short", turns: 2), .claude("Long", turns: 90), .codex("Codex", turns: 60)])
        defer { window.close() }
        window.show(0)
        window.measure("switch to a long task") { window.select(1) }
        window.measure("switch to a short task") { window.select(0) }
        window.measure("switch to a long Codex task") { window.select(2) }
        window.measure("switch back and forth quickly", seconds: 0) {
            for step in 0..<9 { window.probe.run("open \(step % 3)", for: 0.06) { window.select(step % 3) } }
            window.probe.run("settle", for: 1.2)
        }
        window.report()
    }

    /// What opening a long conversation again costs: from choosing it to the first frame that draws
    /// it, the window's layout passes until it settles, and the main thread's time for both, beside a
    /// short and a middling one. Run with `NHC_PERF_BENCH=1`; it prints the numbers and checks nothing
    /// else.
    func testBenchmarkSwitchingToALongConversation() throws {
        guard ProcessInfo.processInfo.environment["NHC_PERF_BENCH"] == "1" else {
            throw XCTSkip("Set NHC_PERF_BENCH=1 to run the task switch benchmark")
        }
        let window = try makeWindow([.claude("Short", turns: 2), .claude("Middling", turns: 20),
                                     .claude("Long", turns: 300)])
        defer { window.close() }
        window.show(0)
        var costs: [String: [Window.SwitchCost]] = [:]
        for round in 0..<4 {
            for (index, name) in [(1, "20 turns"), (2, "300 turns")] {
                window.show(0)
                let cost = window.switchCost(to: index)
                if round > 0 { costs[name, default: []].append(cost) }
            }
        }
        for name in ["20 turns", "300 turns"] {
            for cost in costs[name] ?? [] { print("[switch-cost] \(name): \(cost)") }
        }
    }

    /// What a published fragment costs the whole window while a task answers under 1, 9 and 300
    /// finished turns (the turn window draws 10). The same answer streams twice into the task, once
    /// while the window shows it and once while it shows another task; the difference in the main
    /// thread's time, per publication of the shown task, is what drawing it costs. Run with
    /// `NHC_PERF_BENCH=1`; it prints the numbers and checks nothing else.
    func testBenchmarkStreamingInTheWholeWindow() throws {
        guard ProcessInfo.processInfo.environment["NHC_PERF_BENCH"] == "1" else {
            throw XCTSkip("Set NHC_PERF_BENCH=1 to run the window streaming benchmark")
        }
        let window = try makeWindow([.claude("Idle", turns: 1), .claude("One", turns: 1), .claude("Nine", turns: 9),
                                     .claude("Long", turns: 300)])
        defer { window.close() }
        func stream(_ index: Int, shown: Bool) -> (cpu: TimeInterval, publications: Int) {
            window.show(shown ? index : 0)
            window.send(index, "Write it up.")
            window.emit(index, .assistantDelta("Working on it. "), wait: 0.2)
            let published = window.model.publicationCounts.transcripts
            let start = Window.mainThreadCPU()
            for fragment in 0..<90 {
                window.emit(index, .assistantDelta(fragment.isMultiple(of: 20) ? "\n\n- point \(fragment) " : "word\(fragment) "),
                            wait: 0.02)
            }
            window.probe.run("settle", for: 0.3)
            let cost = (Window.mainThreadCPU() - start, window.model.publicationCounts.transcripts - published)
            window.emit(index, .assistantMessageCompleted("Done."))
            window.emit(index, .turnCompleted)
            window.emit(index, .sessionStatusChanged(.ready), wait: 0.1)
            return cost
        }
        var lines: [String] = []
        for round in 0..<3 {
            for (index, name) in [(1, "1 turn"), (2, "9 turns"), (3, "300 turns")] {
                let shown = stream(index, shown: true)
                let hidden = stream(index, shown: false)
                if round > 0 {
                    lines.append(String(
                        format: "%@: drawing %.2f ms a publication (%d publications; main thread %.0f ms shown, %.0f ms hidden)",
                        name, (shown.cpu - hidden.cpu) * 1000 / Double(max(shown.publications, 1)), shown.publications,
                        shown.cpu * 1000, hidden.cpu * 1000))
                }
            }
        }
        for line in lines { print("[window-streaming] \(line)") }
    }

    /// The task opened was being read at an earlier turn: it opens there.
    func testSwitchingToATaskReadAtAnEarlierTurnNeverDrawsABlankConversation() throws {
        let window = try makeWindow([.claude("Short", turns: 3), .claude("Long", turns: 80), .codex("Codex", turns: 60)])
        defer { window.close() }
        window.show(0)
        window.model.taskWorkspaces.state(for: window.tasks[1].id).transcript.bookmark = .init(
            anchorID: LongConversationFixture.claudeTurnID(seed: "1", turn: 62), fraction: 0.2, followsLatest: false)
        window.model.taskWorkspaces.state(for: window.tasks[2].id).codex.bookmark = .init(
            anchorID: "turn-41", fraction: 0.3, followsLatest: false)
        window.measure("switch to a place in a Claude task") { window.select(1) }
        window.measure("switch to a place in a Codex task") { window.select(2) }
        window.measure("switch back to the place in the Claude task") { window.select(1) }
        window.report()
    }

    /// The task opened is streaming a long answer, and keeps streaming after it opens.
    func testSwitchingToARunningTaskNeverDrawsABlankConversation() throws {
        let window = try makeWindow([.claude("Running", turns: 40), .claude("Other", turns: 20)])
        defer { window.close() }
        window.show(0)
        window.send(0, "Keep going with the parser.")
        window.streamWork(0, calls: 10)
        window.show(1)
        window.measure("switch to a task that streams", seconds: 0.4) {
            window.select(0)
            window.streamText(0, paragraphs: 12)
        }
        window.measure("switch away while it streams", seconds: 0.4) {
            window.select(1)
            window.streamText(0, paragraphs: 3)
        }
        window.measure("switch back while it streams", seconds: 0.4) {
            window.select(0)
            window.streamText(0, paragraphs: 3)
        }
        window.report()
    }

    /// A Claude Code task opened for the first time this launch, with nothing in Yardlet's reading
    /// cache: its conversation is read from Claude Code's file. Until it arrives the conversation
    /// says it is loading — never "Start a conversation", which reads as an empty task — and the read
    /// starts as the task is chosen, not once its surface has been built.
    func testOpeningATaskWhoseHistoryIsNotReadYetShowsItLoading() throws {
        let window = try makeWindow([.claude("Short", turns: 3), .savedClaude("Saved", turns: 80)])
        defer { window.close() }
        window.show(0)
        var sawEmptyState = false, sawLoading = false
        window.measure("open a task whose history is not read yet", seconds: 0, loads: true) {
            window.select(1)
            window.probe.run("opened", for: 0.016)
            // What the conversation says while its history is on its way.
            let shown = window.host.accessibilityElements(visibleOnly: true).map(\.description)
            sawEmptyState = shown.contains { $0.contains(L10n.string("Start a conversation")) }
            sawLoading = shown.contains { $0.contains(L10n.string("Loading conversation")) }
            window.probe.run("reading", for: 1.5)
        }
        let firstDrawn = window.probe.frames.first { $0.ink >= BlankFrameProbe.blankInk }
        print("[blank-frames] conversation drew after \(Int((firstDrawn?.time ?? -1) * 1000)) ms")
        XCTAssertFalse(sawEmptyState, "A task with history read as empty while it loaded")
        XCTAssertTrue(sawLoading, "The conversation said it was loading")
        XCTAssertNotNil(firstDrawn, "The conversation drew once its history arrived")
        XCTAssertGreaterThanOrEqual(window.conversationInk, BlankFrameProbe.blankInk)
        // Once it drew, it never went blank again.
        let drawn = window.probe.frames.drop { $0.ink < BlankFrameProbe.blankInk }
        XCTAssertFalse(drawn.contains { $0.ink < BlankFrameProbe.blankInk }, window.probe.summary)
    }

    /// The pointer rested on the task's row before it was clicked: its saved conversation was read
    /// then, and the task opens on it, with no frame of anything else.
    func testOpeningATaskAfterRestingThePointerOnItDrawsItsConversationAtOnce() throws {
        let window = try makeWindow([.claude("Short", turns: 3), .savedClaude("Saved", turns: 80)])
        defer { window.close() }
        window.show(0)
        let saved = window.tasks[1].id
        window.model.prefetchSavedConversation(of: saved)
        for _ in 0..<150 where (window.model.transcriptBySessionID[saved] ?? []).isEmpty {
            window.probe.run("reading on hover", for: 0.02)
        }
        XCTAssertFalse((window.model.transcriptBySessionID[saved] ?? []).isEmpty, "The hover read the conversation")
        window.measure("open after resting the pointer on it", seconds: 1.0) { window.select(1) }
        XCTAssertGreaterThanOrEqual(window.probe.frames.first?.ink ?? 0, BlankFrameProbe.blankInk,
                                    "The first frame drew the conversation")
        window.report()
    }

    /// The same task, when the reading cache still holds what Yardlet streamed earlier under other
    /// IDs: the cache shows at once and the provider's read replaces it in place.
    func testOpeningASavedTaskOverItsReadingCacheNeverDrawsABlankConversation() throws {
        let window = try makeWindow([.claude("Short", turns: 3), .savedClaude("Saved", turns: 80, snapshot: 80)])
        defer { window.close() }
        window.show(0)
        window.measure("open a saved task over its reading cache", seconds: 2) { window.select(1) }
        window.report()
    }

    /// A Codex task opened for the first time this launch shows what the reading cache kept of its
    /// thread, and the thread read through the App Server (its newest turns) takes its place.
    func testOpeningASavedCodexTaskOverItsReadingCacheNeverDrawsABlankConversation() throws {
        let window = try makeWindow([.claude("Short", turns: 3), .savedCodex("Saved", turns: 60, cached: true)])
        defer { window.close() }
        window.show(0)
        window.measure("open a saved Codex task over its reading cache", seconds: 1.5) { window.select(1) }
        XCTAssertEqual(window.model.codexPresentationBySessionID[window.tasks[1].id]?.thread?.turns.count, 5,
                       "The thread's newest page took the cache's place")
        window.report()
    }

    /// The same with nothing in the reading cache: the conversation says it is loading until the
    /// thread's newest turns arrive, then draws them, and earlier pages arrive above the reader.
    func testOpeningASavedCodexTaskWithNoReadingCacheShowsItLoading() throws {
        let window = try makeWindow([.claude("Short", turns: 3), .savedCodex("Saved", turns: 60, cached: false)])
        defer { window.close() }
        window.show(0)
        var sawEmptyState = false
        window.measure("open a saved Codex task with no reading cache", seconds: 0, loads: true) {
            window.select(1)
            window.probe.run("opened", for: 0.016)
            let shown = window.host.accessibilityElements(visibleOnly: true).map(\.description)
            sawEmptyState = shown.contains { $0.contains(L10n.string("Start a conversation")) }
            window.probe.run("reading", for: 1.5)
        }
        XCTAssertFalse(sawEmptyState, "A task with history read as empty while it loaded")
        let drawn = window.probe.frames.drop { $0.ink < BlankFrameProbe.blankInk }
        XCTAssertFalse(drawn.isEmpty, "The thread drew once it arrived")
        XCTAssertFalse(drawn.contains { $0.ink < BlankFrameProbe.blankInk }, window.probe.summary)
        try readBack(window, loads: 3)
    }

    /// What reading saved conversations costs the window once the reads arrive, with no answer being
    /// written: 828 tasks in 10 projects, the shown one a finished Codex conversation, and 8 saved
    /// Codex tasks nothing has read yet this launch at the top of their projects. The sidebar scrolls
    /// 240 steps, each laying out and drawing the window and turning the run loop for 16 ms; in the
    /// second run the pointer rests on one of the 8 every 30 steps, which reads its newest turns
    /// (`prefetchSavedConversation`), and in the third on the same 8 again. Run with
    /// `NHC_PERF_BENCH=1`; it prints the numbers and checks nothing else.
    func testBenchmarkHoverReadsArrivingWhileTheSidebarScrolls() throws {
        guard ProcessInfo.processInfo.environment["NHC_PERF_BENCH"] == "1" else {
            throw XCTSkip("Set NHC_PERF_BENCH=1 to run the hover read benchmark")
        }
        var specs = (0..<819).map { TaskSpec(title: "Task \($0)", content: .empty, folder: "project-\($0 % 10)") }
        specs += (0..<8).map { TaskSpec(title: "Saved \($0)", content: .savedCodex(30, cached: false), folder: "project-\($0)") }
        specs.append(TaskSpec(title: "Shown", content: .codex(5), folder: "project-9"))
        let window = try makeWindow(specs)
        defer { window.close() }
        window.show(specs.count - 1)
        let saved = window.tasks.filter { $0.title.hasPrefix("Saved") }.map(\.id)
        let host = window.host
        let scroll = try XCTUnwrap(Self.scrollViews(in: host.hosting).first { scroll in
            let frame = scroll.convert(scroll.bounds, to: nil)
            return frame.maxX <= SidebarWidth.maximum && (scroll.documentView?.frame.height ?? 0) > frame.height
        }, "the sidebar's list")
        func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000 }
        func run(_ name: String, reads: Bool) -> String {
            let height = scroll.documentView?.frame.height ?? 0
            let read = saved.filter { window.model.codexPresentationBySessionID[$0] != nil }.count
            var steps: [Double] = []
            ViewBodyCensus.isEnabled = true
            ViewBodyCensus.reset()
            defer { ViewBodyCensus.isEnabled = false; ViewBodyCensus.reset() }
            for step in 0..<240 {
                let start = cpu()
                if reads, step % 30 == 20 { window.model.prefetchSavedConversation(of: saved[step / 30]) }
                scroll.contentView.scroll(to: NSPoint(x: 0, y: 120 + CGFloat(step % 40) * 8))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.hosting.layoutSubtreeIfNeeded()
                host.window.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.016))
                steps.append(cpu() - start)
            }
            let sorted = steps.sorted()
            return String(format: "%@: max %.2f ms, p95 %.2f ms, %.0f ms in all; %d read; window bodies %d, "
                          + "conversation bodies %d, sidebar rows %d; list %.0f to %.0f pt", name, sorted.last ?? 0,
                          sorted[sorted.count * 95 / 100], steps.reduce(0, +),
                          saved.filter { window.model.codexPresentationBySessionID[$0] != nil }.count - read,
                          ViewBodyCensus[.mainWindow], ViewBodyCensus[.conversationTimeline], ViewBodyCensus[.sidebarRow],
                          height, scroll.documentView?.frame.height ?? 0)
        }
        let lines = [run("no reads", reads: false), run("8 first reads", reads: true), run("the same 8 again", reads: true)]
        for line in lines { print("[hover-reads] \(line)") }
    }

    /// What an earlier page costs the window as it arrives: a saved Codex task of 60 turns opened on
    /// its newest 5 and read up near their top, 120 steps, each laying out and drawing the window and
    /// turning the run loop for 16 ms. The reader moves the view a little each of the first 30 steps;
    /// at step 30 their mouse wheel reaches the top, which brings in the 10 turns before them. Then
    /// they read where they are, holding the view still, or keep turning the wheel up a notch a step,
    /// which brings in more at each top. Each round opens the task anew. Run with `NHC_PERF_BENCH=1`;
    /// it prints the numbers and checks nothing else.
    func testBenchmarkAnEarlierPageArriving() throws {
        guard ProcessInfo.processInfo.environment["NHC_PERF_BENCH"] == "1" else {
            throw XCTSkip("Set NHC_PERF_BENCH=1 to run the earlier page benchmark")
        }
        func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000 }
        enum Reader: String, CaseIterable { case reads = "reads where it arrived", wheels = "keeps wheeling up" }
        var lines: [String] = []
        for reader in Reader.allCases {
            for round in 0..<2 {
                let window = try makeWindow([.claude("Short", turns: 3), .savedCodex("Saved", turns: 60, cached: false)])
                defer { window.close() }
                window.show(1)
                let task = window.tasks[1].id
                for _ in 0..<150 where window.model.codexPresentationBySessionID[task]?.thread?.turns.count != 5 {
                    window.probe.run("reading", for: 0.02)
                }
                let host = window.host
                let scroll = try XCTUnwrap(BlankFrameProbe.conversationScrollView(in: host.hosting,
                                                                                  minX: SidebarWidth.minimum))
                func move(to y: CGFloat) {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                // One notch of a classic mouse wheel toward the top, which SwiftUI reports as the reader's.
                func wheelUp() {
                    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3,
                                              wheel2: 0, wheel3: 0), let wheel = NSEvent(cgEvent: event) else { return }
                    scroll.scrollWheel(with: wheel)
                }
                move(to: 400)
                host.settle(passes: 10, interval: 0.03)
                let height = scroll.documentView?.frame.height ?? 0
                var steps: [Double] = []
                ViewBodyCensus.isEnabled = true
                ViewBodyCensus.reset()
                defer { ViewBodyCensus.isEnabled = false; ViewBodyCensus.reset() }
                for step in 0..<120 {
                    let start = cpu()
                    if step < 30 {
                        move(to: max(0, scroll.contentView.bounds.minY + (step.isMultiple(of: 2) ? 12 : -12)))
                    } else if step == 30 {
                        move(to: 150)
                        wheelUp()
                    } else if reader == .wheels {
                        wheelUp()
                    }
                    host.hosting.layoutSubtreeIfNeeded()
                    host.window.displayIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.016))
                    steps.append(cpu() - start)
                }
                let sorted = steps.sorted()
                lines.append(String(
                    format: "%@, round %d: max %.2f ms, p95 %.2f ms, %.0f ms in all, %d steps over 50 ms; %d turns; "
                    + "%d turn views made, %d conversation bodies; content %.0f to %.0f pt", reader.rawValue, round + 1,
                    sorted.last ?? 0, sorted[sorted.count * 95 / 100], steps.reduce(0, +), steps.filter { $0 > 50 }.count,
                    window.model.codexPresentationBySessionID[task]?.thread?.turns.count ?? 0,
                    ViewBodyCensus[.conversationTurnHosting], ViewBodyCensus[.conversationTimeline], height,
                    scroll.documentView?.frame.height ?? 0))
            }
        }
        for line in lines { print("[earlier-page] \(line)") }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    // MARK: - Sending and responding

    /// A message sent in a Codex task that was only read: the task connects, the App Server's resumed
    /// thread (its newest turns and the new one) takes the place of the turns read before, and the
    /// answer streams in and finishes.
    func testSendingInACodexTaskThatWasOnlyReadNeverDrawsABlankConversation() throws {
        let window = try makeWindow([.claude("Short", turns: 3), .codex("Codex", turns: 60)])
        defer { window.close() }
        window.show(1)
        let task = window.tasks[1]
        let request = "Please fix the next parser case."
        func resumed(calls: Int, paragraphs: Int, running: Bool = true) -> CodexTaskState {
            var turns = (57..<60).map { LongConversationFixture.codexTurn($0, tag: "Codex ") }
            var latest = LongConversationFixture.runningCodexTurn(60, request: request, calls: calls, paragraphs: paragraphs)
            if !running, case var .object(fields) = latest {
                fields["status"] = .string("completed")
                fields["completedAt"] = .integer(1_800_003_700)
                fields["durationMs"] = .integer(40_000)
                latest = .object(fields)
            }
            turns.append(latest)
            return LongConversationFixture.codex(threadID: "thread-1", turns: turns)
        }
        window.emitCodex(1, resumed(calls: 0, paragraphs: 0))
        window.measure("send in a Codex task that was only read", seconds: 0.6) { window.send(1, request) }
        window.measure("the Codex answer streams", seconds: 0.3) {
            for step in 1...12 { window.emitCodex(1, resumed(calls: min(step, 8), paragraphs: max(0, step - 4))) }
        }
        window.measure("the Codex turn finishes", seconds: 0.8) {
            window.emitCodex(1, resumed(calls: 8, paragraphs: 8, running: false))
        }
        XCTAssertEqual(window.model.codexPresentationBySessionID[task.id]?.thread?.turns.last?.id, "turn-60")
        window.report()
    }

    /// Sent at the end, then a turn that works through ten calls and streams a long answer, in the
    /// person's narrow window: the conversation follows it to the end and keeps drawing.
    func testStreamingALongAnswerNeverDrawsABlankConversation() throws {
        let window = try makeWindow([.claude("Long", turns: 40)])
        defer { window.close() }
        window.show(0)
        window.measure("send at the end", seconds: 0.2) { window.send(0, "Please fix the next parser case.") }
        window.measure("stream the work", seconds: 0.2) { window.streamWork(0, calls: 10) }
        window.measure("stream a long answer", seconds: 0.2) { window.streamText(0, paragraphs: 12) }
        window.measure("wait for the next update", seconds: 0.4) {}
        XCTAssertLessThanOrEqual(window.distanceFromEnd, 48, "Following kept the end in view")
        window.report()
    }

    /// A trackpad swipe toward the end while the answer streams, its momentum included: what arrives
    /// under the reader's gesture is not the reader leaving the end, so following goes on and the
    /// conversation ends at the end. (Following stopped a fragment short of the end, under the
    /// gesture, and fell further behind with every word after it.)
    func testSwipingTowardTheEndWhileItStreamsKeepsFollowing() throws {
        let window = try makeWindow([.claude("Long", turns: 12)])
        defer { window.close() }
        window.show(0)
        window.send(0, "Please fix the next parser case.")
        window.streamWork(0, calls: 3)
        window.streamText(0, paragraphs: 3)
        for round in 0..<3 {
            window.measure("swipe toward the end as it streams \(round)", seconds: 0.05) { window.swipeTowardTheEnd(0) }
            window.measure("stream on after the swipe \(round)", seconds: 0.3) { window.streamText(0, paragraphs: 2) }
            XCTAssertLessThanOrEqual(window.distanceFromEnd, 1, "Following went on through swipe \(round)")
        }
        window.report()
    }

    /// The turn finishes and its work folds: the conversation gets much shorter under the reader.
    func testFinishingAndFoldingNeverDrawsABlankConversation() throws {
        let window = try makeWindow([.claude("Long", turns: 40)])
        defer { window.close() }
        window.show(0)
        window.send(0, "Please fix the next parser case.")
        window.streamWork(0, calls: 30)
        window.streamText(0, paragraphs: 12)
        window.measure("finish and fold", seconds: 1.0) { window.finishTurn(0) }
        XCTAssertLessThanOrEqual(window.distanceFromEnd, 48, "Following kept the end in view")
        window.report()
    }

    /// The reader is partway up the running turn, which pauses following — they went back to it from
    /// another task while it ran — as the answer streams on below them and the turn finishes and
    /// folds under them.
    func testStreamingAndFoldingWhileReadingTheRunningTurnNeverDrawsABlankConversation() throws {
        let window = try makeWindow([.claude("Long", turns: 40), .claude("Other", turns: 5)])
        defer { window.close() }
        window.show(0)
        window.send(0, "Please fix the next parser case.")
        window.streamWork(0, calls: 10)
        window.streamText(0, paragraphs: 6)
        window.show(1)
        let running = try XCTUnwrap(window.model.transcriptBySessionID[window.tasks[0].id]?.last { entry in
            if case .user = entry.content { return true }
            return false
        })
        window.model.taskWorkspaces.state(for: window.tasks[0].id).transcript.bookmark = .init(
            anchorID: running.id.uuidString, fraction: 0.4, followsLatest: false)
        window.measure("go back to the running turn partway up", seconds: 0.4) { window.select(0) }
        XCTAssertGreaterThan(window.distanceFromEnd, 48, "The reader is above the end")
        window.measure("stream while reading the running turn", seconds: 0.3) { window.streamText(0, paragraphs: 6) }
        window.measure("finish and fold while reading the running turn", seconds: 1.0) { window.finishTurn(0) }
        window.report()
    }

    /// The same, with the reader's own scroll up a little from the end while the answer streams.
    /// Scroll gestures do not move while the screen is locked; the test is skipped then.
    func testStreamingAndFoldingAfterScrollingUpNeverDrawsABlankConversation() throws {
        let window = try makeWindow([.claude("Long", turns: 40)])
        defer { window.close() }
        window.show(0)
        window.send(0, "Please fix the next parser case.")
        window.streamWork(0, calls: 10)
        window.streamText(0, paragraphs: 6)
        window.measure("scroll up while it streams", seconds: 0.2) { window.userScroll(up: 260) }
        try XCTSkipIf(window.distanceFromEnd <= 48, "The scroll gesture did not move (the screen is locked)")
        window.measure("stream while reading above the end", seconds: 0.3) { window.streamText(0, paragraphs: 6) }
        window.measure("finish and fold while reading above the end", seconds: 1.0) { window.finishTurn(0) }
        window.report()
    }

    /// A request to approve arrives while the answer streams, then is answered; then messages are
    /// queued behind the running turn, which raises the composer.
    func testApprovalsAndQueuedMessagesNeverDrawABlankConversation() throws {
        let window = try makeWindow([.claude("Long", turns: 40)])
        defer { window.close() }
        window.show(0)
        window.send(0, "Run the parser tests.")
        window.streamWork(0, calls: 10)
        window.streamText(0, paragraphs: 8)
        window.measure("approval appears", seconds: 0.6) {
            window.emit(0, .permissionRequested(PermissionRequest(
                id: "approve-1", title: "Bash", detail: "Run the parser tests", command: "swift test --filter ParserTests",
                toolCallID: nil, preview: nil)))
        }
        window.measure("approval answered", seconds: 0.6) { window.emit(0, .permissionExpired("approve-1")) }
        window.measure("messages queued", seconds: 0.6) {
            window.send(0, "Also check the lexer.")
            window.send(0, "And then the tokens.")
            window.streamText(0, paragraphs: 4)
        }
        window.report()
    }

    /// The composer grows line by line while the answer streams, and shrinks back when sent.
    func testTheComposerGrowingNeverDrawsABlankConversation() throws {
        let window = try makeWindow([.claude("Long", turns: 40)])
        defer { window.close() }
        window.show(0)
        window.send(0, "Run the parser tests.")
        window.streamWork(0, calls: 10)
        let draft = window.model.composerDrafts.tasks.draft(for: window.tasks[0].id)
        window.measure("composer grows while it streams", seconds: 0.4) {
            for line in 1...10 {
                window.probe.run("line \(line)") { draft.text += "A line of the next request \(line)\n" }
                window.streamText(0, paragraphs: 1)
            }
        }
        window.measure("composer shrinks", seconds: 0.6) { draft.text = "" }
        window.report()
    }

    /// The session rail goes away and comes back beside a long running turn, which reflows every line.
    /// The answer's text in view also lays out its lines there at each width: at the person's narrow
    /// width the "Show more" and working lines alone draw enough to pass for a conversation.
    func testTogglingTheRailNeverDrawsABlankConversation() throws {
        let window = try makeWindow([.claude("Long", turns: 40)])
        defer { window.close() }
        window.show(0)
        window.send(0, "Run the parser tests.")
        window.streamWork(0, calls: 10)
        window.streamText(0, paragraphs: 12)
        // The rail is pressed once the whole answer is in the conversation, not while it still arrives.
        window.waitForAnswer(0, containing: "Paragraph 11: ")
        XCTAssertEqual(window.proseInViewWithoutLines, [], "Streamed")
        window.measure("hide the rail", seconds: 0.6) { XCTAssertTrue(window.pressRailToggle()) }
        XCTAssertEqual(window.proseInViewWithoutLines, [], "The rail hidden")
        window.measure("show the rail", seconds: 0.6) { XCTAssertTrue(window.pressRailToggle()) }
        XCTAssertEqual(window.proseInViewWithoutLines, [], "The rail shown again")
        window.report()
    }

    // MARK: - Long conversations

    /// A long Claude Code conversation, more than its first read takes, opened for the first time;
    /// then read back from its first drawn turn, earlier turns arriving above the reader (the
    /// window's next turns, then more of Claude Code's file); then "Latest response".
    func testReadingALongSavedConversationBackNeverDrawsABlankConversation() throws {
        let window = try makeWindow([.claude("Short", turns: 3), .savedClaude("Saved", turns: 220, snapshot: 3)])
        defer { window.close() }
        window.show(0)
        window.measure("open a long saved conversation", seconds: 1.5) { window.select(1) }
        try readBack(window, loads: 8)
    }

    /// A Codex thread longer than the turns drawn at first, read back the same way.
    func testReadingALongCodexThreadBackNeverDrawsABlankConversation() throws {
        let window = try makeWindow([.claude("Short", turns: 3), .codex("Codex", turns: 120)])
        defer { window.close() }
        window.show(0)
        window.measure("open a long Codex thread", seconds: 1.0) { window.select(1) }
        try readBack(window, loads: 8)
    }

    /// Goes to the first turn drawn, as the turn rail does, then brings earlier turns in above it
    /// `loads` times, as scrolling up to the top or the rail's "Load more history" does, and returns
    /// with "Latest response".
    private func readBack(_ window: Window, loads: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        window.measure("go to the first turn drawn", seconds: 0.6) {
            // The rail's first mark, "Turn 1 of <drawn turns>".
            let isFirstTurn = { (label: String) in
                (1...400).contains { label == L10n.format("Turn %lld of %lld", Int64(1), Int64($0)) }
            }
            XCTAssertTrue(window.press(isFirstTurn), file: file, line: line)
        }
        XCTAssertGreaterThan(window.distanceFromEnd, 48, "The reader is at the first turn drawn", file: file, line: line)
        // Until every turn is drawn, when the rail no longer offers more.
        var loaded = 0
        for load in 1...loads {
            var pressed = false
            window.measure("earlier turns arrive above (\(load))", seconds: 0.5) {
                pressed = window.press { $0 == L10n.string("Load more history") }
            }
            guard pressed else { break }
            loaded += 1
        }
        XCTAssertGreaterThan(loaded, 0, "Earlier turns were brought in", file: file, line: line)
        window.measure("latest response", seconds: 1.0) {
            XCTAssertTrue(window.press { $0 == L10n.string("Latest response") }, file: file, line: line)
        }
        XCTAssertLessThanOrEqual(window.distanceFromEnd, 48, "Back at the latest output", file: file, line: line)
        window.report(file: file, line: line)
    }

    // MARK: - Fixture

    struct TaskSpec {
        enum Content {
            case claude(Int), codex(Int), empty
            /// A Claude Code task not connected this launch, whose conversation is read from Claude
            /// Code's saved file when it opens; `snapshot` is what Yardlet's reading cache still
            /// holds for it (nothing for an imported task, or the entries it streamed earlier).
            case savedClaude(Int, snapshot: Int?)
            /// A Codex task not connected this launch, whose thread is read through a fake App Server
            /// when it opens (the newest 5 turns, then 10 at a time); `cached` says whether Yardlet's
            /// reading cache still holds the thread as it was flattened when the task last closed.
            case savedCodex(Int, cached: Bool)
        }
        let title: String
        let content: Content
        var status: SessionStatus = .completed
        var unread = false
        /// The folder the task works in, which tasks of one project share; by default one of its own.
        var folder: String?

        static func claude(_ title: String, turns: Int) -> Self { .init(title: title, content: .claude(turns)) }
        static func codex(_ title: String, turns: Int) -> Self { .init(title: title, content: .codex(turns)) }
        static func savedClaude(_ title: String, turns: Int, snapshot: Int? = nil) -> Self {
            .init(title: title, content: .savedClaude(turns, snapshot: snapshot))
        }
        static func savedCodex(_ title: String, turns: Int, cached: Bool) -> Self {
            .init(title: title, content: .savedCodex(turns, cached: cached))
        }
    }

    @MainActor
    final class Window {
        let model: AppModel
        let tasks: [SessionRecord]
        let host: WindowlessRender.Host<AnyView>
        let probe: BlankFrameProbe
        private(set) var measurements: [(name: String, result: BlankFrameProbe.Summary, loads: Bool)] = []

        /// What the app's own blank-viewport log wrote (`ConversationBlankViewportLog`).
        private(set) var logLines: [String] = []
        private let wasLogging = ConversationBlankViewportLog.isEnabled
        private let logWrite = ConversationBlankViewportLog.write

        init(model: AppModel, tasks: [SessionRecord], adapters: [HarnessKind: FakeHarnessAdapter]) {
            self.model = model
            self.tasks = tasks
            self.adapters = adapters
            ConversationBlankViewportLog.isEnabled = true
            host = WindowlessRender.Host(AnyView(MainWindow(model: model)), size: ConversationBlankFrameTests.size,
                                         appearance: .light)
            let hosting = host.hosting
            probe = BlankFrameProbe(hosting: hosting) {
                BlankFrameProbe.conversationScrollView(in: hosting, minX: SidebarWidth.minimum)
            }
            if ProcessInfo.processInfo.environment["NHC_BLANK_FRAMES_DUMP"] != nil {
                probe.blankImageDirectory = try? WindowlessRender.directory("blank-frames")
            }
            ConversationBlankViewportLog.write = { [weak self] line in
                self?.logLines.append(line)
                print("[blank-frames] log: \(line)")
            }
            host.settle(passes: 20, interval: 0.03)
        }

        let adapters: [HarnessKind: FakeHarnessAdapter]
        private var sequence: UInt64 = 1

        /// Sends as the composer does.
        func send(_ index: Int, _ text: String) {
            let task = tasks[index]
            Task { await model.send(HarnessUserInput(text: text), to: task) }
            probe.run("send", for: 0.15)
        }

        func emit(_ index: Int, _ payload: HarnessEventPayload, wait: TimeInterval = 0.03) {
            let task = tasks[index]
            guard let adapter = adapters[task.harness] else { return }
            sequence += 1
            let sequence = sequence
            Task { await adapter.emit(payload, for: task.id, sequence: sequence) }
            probe.run(String("\(payload)".prefix(40)), for: wait)
        }

        /// The Codex thread's state, as an attached App Server publishes it; before the task attaches,
        /// the state its App Server answers with once it does.
        func emitCodex(_ index: Int, _ state: CodexTaskState, wait: TimeInterval = 0.04) {
            let task = tasks[index]
            guard let adapter = adapters[.codex] else { return }
            Task { await adapter.emitPresentation(state, for: task.id) }
            probe.run("codex state", for: wait)
        }

        /// A running turn's thinking, text and `calls` tool calls, as a provider streams them.
        func streamWork(_ index: Int, calls: Int) {
            emit(index, .reasoningDelta("Reading the parser before changing it. "))
            emit(index, .assistantDelta("I'll read the parser and run its tests."))
            emit(index, .assistantMessageCompleted("I'll read the parser and run its tests."))
            for call in 0..<calls {
                let activity = HarnessActivity(id: "live-\(sequence)-\(call)", kind: "Bash", title: "Bash",
                    input: #"{"command":"swift test --filter ParserTests","description":"Run the parser tests"}"#)
                emit(index, .activityStarted(activity), wait: 0.01)
                var finished = activity
                finished.output = "Test Suite 'ParserTests' passed\n\t Executed 14 tests, with 0 failures"
                emit(index, .activityCompleted(finished), wait: 0.01)
            }
            for word in 0..<20 { emit(index, .assistantDelta("word\(word) "), wait: 0.02) }
        }

        /// More of the running turn's text, `paragraphs` long.
        func streamText(_ index: Int, paragraphs: Int) {
            for paragraph in 0..<paragraphs {
                let words = String(repeating: "Words that wrap across the line. ", count: 12)
                emit(index, .assistantDelta("\n\nParagraph \(paragraph): " + words), wait: 0.02)
            }
        }

        /// Turns the run loop until the task's latest answer holds `text`, then lets the window lay it out.
        func waitForAnswer(_ index: Int, containing text: String, file: StaticString = #filePath, line: UInt = #line) {
            let deadline = Date().addingTimeInterval(5)
            while !(model.transcriptBySessionID[tasks[index].id]?.last { entry in
                if case let .assistant(answer, _) = entry.content { return answer.contains(text) }
                return false
            } != nil) {
                guard Date() < deadline else { return XCTFail("The answer did not arrive", file: file, line: line) }
                probe.run("wait for the answer", for: 0.01)
            }
            host.settle(passes: 10, interval: 0.03)
        }

        /// How far the conversation is from its end.
        var distanceFromEnd: CGFloat {
            conversation.map(BlankFrameProbe.distance) ?? -1
        }

        /// What the conversation draws now (`BlankFrameProbe.ink`).
        var conversationInk: Double {
            host.hosting.layoutSubtreeIfNeeded()
            return conversation.map(BlankFrameProbe.ink) ?? 0
        }

        /// The message texts in view (`TranscriptProseTextView`) whose viewport lays out no lines, by
        /// their length: a text the conversation shows that draws nothing.
        var proseInViewWithoutLines: [Int] {
            host.hosting.layoutSubtreeIfNeeded()
            guard let clip = conversation?.contentView else { return [] }
            var texts: [TranscriptProseTextView] = []
            func visit(_ view: NSView) {
                if let text = view as? TranscriptProseTextView { texts.append(text) }
                view.subviews.forEach(visit)
            }
            visit(clip)
            return texts.compactMap { text in
                // The text view's own visible rect is not clipped to it; what of it the conversation shows.
                let shown = clip.convert(text.bounds, from: text).intersection(clip.bounds)
                guard shown.height > 1, let length = text.textStorage?.length, length > 0 else { return nil }
                return text.textLayoutManager?.textViewportLayoutController.viewportRange == nil ? length : nil
            }
        }

        private var conversation: NSScrollView? {
            BlankFrameProbe.conversationScrollView(in: host.hosting, minX: SidebarWidth.minimum)
        }

        /// The reader's own scrolling toward earlier content, `points` far, with a classic mouse wheel,
        /// which SwiftUI reports as interacting. (A trackpad gesture's phased events wait for the
        /// gesture's end while the screen is locked.)
        func userScroll(up points: CGFloat) {
            guard let scroll = conversation else { return }
            let start = scroll.contentView.bounds.minY
            for _ in 0..<80 where start - scroll.contentView.bounds.minY < points && scroll.contentView.bounds.minY > 0 {
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3,
                                          wheel2: 0, wheel3: 0),
                      let wheel = NSEvent(cgEvent: event) else { break }
                scroll.scrollWheel(with: wheel)
                probe.run("scroll", for: 0.016)
            }
            probe.run("scrolled", for: 0.2)
        }

        /// The reader's trackpad swipe toward the end, and its momentum, while the running turn's answer
        /// streams on: phased events, which SwiftUI reports as the reader's scrolling until the
        /// momentum ends.
        func swipeTowardTheEnd(_ index: Int) {
            guard let scroll = conversation else { return }
            func swipe(_ delta: Int32, phase: Int64 = 0, momentum: Int64 = 0) {
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta,
                                          wheel2: 0, wheel3: 0) else { return }
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
                if let wheel = NSEvent(cgEvent: event) { scroll.scrollWheel(with: wheel) }
                probe.run("swipe", for: 0.016)
            }
            var fragment = 0
            func words() {
                fragment += 1
                emit(index, .assistantDelta(fragment.isMultiple(of: 4) ? "\n\nParagraph \(fragment): "
                    : "some more words that wrap along the line \(fragment) "), wait: 0)
            }
            // Fingers on the trackpad, then toward the end (began, changed, ended), then the momentum
            // (begin, continue, end).
            swipe(0, phase: 128)
            swipe(-4, phase: 1)
            for _ in 0..<6 { swipe(-8, phase: 2); words() }
            swipe(0, phase: 4)
            swipe(-8, momentum: 1)
            for step in 0..<30 {
                swipe(Int32(-max(1, 8 - step / 4)), momentum: 2)
                if step.isMultiple(of: 3) { words() }
            }
            swipe(0, momentum: 3)
        }

        /// The running turn's answer and its end, which folds its work.
        func finishTurn(_ index: Int) {
            emit(index, .assistantMessageCompleted(LongConversationFixture.answer(3)))
            emit(index, .turnCompleted)
            emit(index, .sessionStatusChanged(.ready))
        }

        /// The title bar's session rail button.
        func pressRailToggle() -> Bool {
            press { [L10n.string("Hide session rail"), L10n.string("Show session rail")].contains($0) }
        }

        /// Presses the first accessibility element whose label `matches`, as a click does.
        @discardableResult
        func press(_ matches: (String) -> Bool) -> Bool {
            host.hosting.layoutSubtreeIfNeeded()
            let attribute = "AXEnhancedUserInterface" as NSString
            let app = NSApplication.shared
            _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true),
                            with: attribute)
            defer {
                _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: false),
                                with: attribute)
            }
            var visited = Set<ObjectIdentifier>()
            func visit(_ node: AnyObject) -> Bool {
                for case let child as NSObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    guard visited.insert(ObjectIdentifier(child)).inserted else { continue }
                    let label = (child.responds(to: NSSelectorFromString("accessibilityLabel"))
                        ? child.value(forKey: "accessibilityLabel") as? String : nil) ?? ""
                    if !label.isEmpty, matches(label), child.responds(to: NSSelectorFromString("accessibilityPerformPress")) {
                        _ = child.perform(NSSelectorFromString("accessibilityPerformPress"))
                        return true
                    }
                    if visit(child) { return true }
                }
                return false
            }
            return visit(host.hosting)
        }

        /// Opens a task as a sidebar click does.
        func select(_ index: Int) {
            model.splits.activate(.session(tasks[index].id))
        }

        struct SwitchCost: CustomStringConvertible {
            /// From choosing the task to the end of the first layout pass that draws its conversation.
            let firstFrame: TimeInterval
            /// The main thread's time until then.
            let firstFrameCPU: TimeInterval
            /// Turns of the run loop that updated the window (over 1 ms of the main thread), in the 1.5 s
            /// after choosing it.
            let passes: Int
            let cpu: TimeInterval
            let layers: Int
            /// Turns drawn, and turn hosting views made rather than found kept with the task.
            var turnsDrawn = 0
            var hostingsMade = 0

            var description: String {
                String(format: "first frame %.1f ms (main thread %.1f ms), %d updates, main thread %.1f ms in 1.5 s, %d layers, %d turns drawn, %d turn views made",
                       firstFrame * 1000, firstFrameCPU * 1000, passes, cpu * 1000, layers, turnsDrawn, hostingsMade)
            }
        }

        /// Opens a task the way a sidebar click does, and times the turns of the run loop until the
        /// conversation drawn is the new task's.
        func switchCost(to index: Int) -> SwitchCost {
            let hosting = host.hosting
            let old = conversation
            let oldHeight = old?.documentView?.frame.height ?? 0
            var passes = 0
            var firstFrame: TimeInterval?
            var firstFrameCPU: TimeInterval?
            let start = Date()
            let startCPU = Self.mainThreadCPU()
            var lastCPU = startCPU
            // After Core Animation's commit (2,000,000) and the probe's display cycle: a turn of the run
            // loop that kept the main thread busy for over a millisecond updated the window.
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true,
                                                              2_200_000) { [weak self] _, _ in
                let now = Self.mainThreadCPU()
                if now - lastCPU > 0.001 { passes += 1 }
                defer { lastCPU = Self.mainThreadCPU() }
                guard firstFrame == nil else { return }
                let laidOut = Date().timeIntervalSince(start)
                MainActor.assumeIsolated {
                    guard let scroll = self?.conversation,
                          scroll !== old || scroll.documentView?.frame.height != oldHeight,
                          BlankFrameProbe.ink(scroll) >= BlankFrameProbe.blankInk else { return }
                    firstFrame = laidOut
                    firstFrameCPU = now - startCPU
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            ViewBodyCensus.isEnabled = true
            ViewBodyCensus.reset()
            select(index)
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            var cost = SwitchCost(firstFrame: firstFrame ?? .infinity, firstFrameCPU: firstFrameCPU ?? .infinity,
                                  passes: passes, cpu: Self.mainThreadCPU() - startCPU, layers: Self.layerCount(hosting.layer))
            cost.turnsDrawn = ViewBodyCensus[.conversationTurn]
            cost.hostingsMade = ViewBodyCensus[.conversationTurnHosting]
            ViewBodyCensus.isEnabled = false
            return cost
        }

        private static func layerCount(_ layer: CALayer?) -> Int {
            guard let layer else { return 0 }
            return 1 + (layer.sublayers ?? []).reduce(0) { $0 + layerCount($1) }
        }

        nonisolated static func mainThreadCPU() -> TimeInterval {
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

        /// Opens a task and lets it settle.
        func show(_ index: Int) {
            select(index)
            host.settle(passes: 30, interval: 0.03)
        }

        /// Reads every frame while `change` runs and for `seconds` after.
        /// - Parameter loads: the conversation is loading when the measurement starts: it may draw
        ///   nothing (a loading spinner) until its history arrives, and never again after.
        func measure(_ name: String, seconds: TimeInterval = 1.5, loads: Bool = false, _ change: () -> Void) {
            probe.record(name)
            change()
            if seconds > 0 { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
            probe.stop()
            measurements.append((name, probe.result, loads))
            print("[blank-frames] \(name): \(probe.summary)")
            if ProcessInfo.processInfo.environment["NHC_BLANK_FRAMES_DUMP"] != nil {
                let scroll = conversation
                print("[blank-frames]   scroll \(scroll.map { NSStringFromRect($0.convert($0.bounds, to: host.hosting)) } ?? "none")")
                for frame in probe.frames { print("[blank-frames]   \(frame)") }
                if let directory = try? WindowlessRender.directory("blank-frames"), let capture = try? host.capture() {
                    try? WindowlessRender.writePNG(capture.bitmap, to: directory.appending(path: "\(name).png"))
                }
            }
        }

        func report(file: StaticString = #filePath, line: UInt = #line) {
            for (name, result, loads) in measurements {
                XCTAssertGreaterThan(result.frames, 0, "\(name): frames were drawn", file: file, line: line)
                XCTAssertEqual(loads ? result.blankAfterDrawn : result.blank, 0, "\(name): \(result.text)",
                               file: file, line: line)
            }
        }

        func close() {
            probe.close()
            host.close()
            ConversationBlankViewportLog.isEnabled = wasLogging
            ConversationBlankViewportLog.write = logWrite
        }
    }

    private func makeWindow(_ specs: [TaskSpec]) throws -> Window {
        try Self.makeWindow(specs, for: self)
    }

    /// The whole window over tasks made from `specs`, cleaned up when `testCase` ends.
    static func makeWindow(_ specs: [TaskSpec], for testCase: XCTestCase) throws -> Window {
        let suite = testDefaultsSuite("ConversationBlankFrames")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        var sessions: [SessionRecord] = []
        var transcripts: [UUID: [TranscriptEntry]] = [:]
        var codex: [UUID: CodexTaskState] = [:]
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-blank-frames-\(UUID().uuidString)")
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Saved Codex tasks read their threads through the product route (YHP over the App Server
        // adapter) from a fake App Server, which a runtime of their own names.
        let savedCodexRuntime = root.appending(path: "codex")
        try Data("#!/bin/sh\nprintf 'codex-cli 0.163.0\\n'\n".utf8).write(to: savedCodexRuntime)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: savedCodexRuntime.path)
        var savedCodexThreads: [String: JSONValue] = [:]
        for (index, spec) in specs.enumerated() {
            let harness: HarnessKind = switch spec.content {
            case .codex, .savedCodex: .codex
            default: .claudeCode
            }
            var workspace = LongConversationFixture.workspace.appending(path: spec.folder ?? "p\(index)")
            var runtime = URL(filePath: "/tmp/yardlet-missing-\(harness.rawValue)")
            var providerSessionID: String?
            var connection: ProviderConnection?
            if case .codex = spec.content { providerSessionID = "thread-\(index)" }
            if case let .savedCodex(turns, _) = spec.content {
                runtime = savedCodexRuntime
                providerSessionID = "thread-\(index)"
                savedCodexThreads["thread-\(index)"] = LongConversationFixture.codexThread(
                    threadID: "thread-\(index)", turns: (0..<turns).map { LongConversationFixture.codexTurn($0, tag: "\(spec.title) ") })
            }
            if case let .savedClaude(turns, _) = spec.content {
                workspace = root.appending(path: "project-\(index)")
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                let config = root.appending(path: "config")
                let id = NameBasedUUID.make(namespace: UUID(uuidString: "0C0C0C0C-0000-4000-8000-000000000000")!,
                                            name: "\(suite)|\(index)").uuidString.lowercased()
                try LongConversationFixture.writeClaudeTranscript(
                    LongConversationFixture.claudeRecords(turns: turns, sessionID: id, workspace: workspace,
                                                          tag: "\(spec.title) "),
                    sessionID: id, config: config, workspace: workspace)
                providerSessionID = id
                connection = ProviderConnection(id: "blank-frames-\(index)", name: "qa@example.test", harness: .claudeCode,
                                                providerID: nil, homePath: config.path(percentEncoded: false),
                                                credentialSelector: nil)
            }
            let session = SessionRecord(
                harness: harness, workspaceURL: workspace,
                runtimeExecutableURL: runtime, title: spec.title,
                status: spec.status, createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
                providerSessionID: providerSessionID,
                hasUnreadUpdate: spec.unread, completionState: spec.status == .completed ? .completed : .none,
                connection: connection)
            sessions.append(session)
            switch spec.content {
            case let .savedClaude(_, snapshot):
                // Streamed earlier: the same kind of turns under the IDs Yardlet gave them then.
                if let snapshot {
                    transcripts[session.id] = LongConversationFixture.claude(turns: snapshot, seed: "streamed-\(index)",
                                                                             tag: "\(spec.title) ")
                }
            case let .claude(turns):
                transcripts[session.id] = LongConversationFixture.claude(turns: turns, seed: "\(index)",
                                                                         tag: "\(spec.title) ")
            case let .codex(turns):
                let state = LongConversationFixture.codex(turns: turns, threadID: "thread-\(index)", tag: "\(spec.title) ")
                codex[session.id] = state
                transcripts[session.id] = LongConversationFixture.claude(turns: 1, seed: "snapshot-\(index)")
            case let .savedCodex(turns, cached):
                // What the reading cache kept when the task last closed: the thread, flattened.
                if cached {
                    transcripts[session.id] = CodexTranscriptSnapshotProjection.entries(from: LongConversationFixture.codex(
                        turns: turns, threadID: "thread-\(index)", tag: "\(spec.title) "))
                }
            case .empty:
                break
            }
        }
        let adapters: [HarnessKind: FakeHarnessAdapter] = [
            .claudeCode: FakeHarnessAdapter(kind: .claudeCode), .codex: FakeHarnessAdapter(kind: .codex)
        ]
        let appServer = YHPCodexCompatibilityAdapter(
            adapter: CodexAdapter(executableURL: savedCodexRuntime,
                                  transport: CodexSavedThreadsTransport(threads: savedCodexThreads)),
            manifest: HarnessProtocolCompatibilityManifest.codex())
        let model = AppModel(
            store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { kind, url in
                if url == savedCodexRuntime.standardizedFileURL { return appServer }
                return adapters[kind] ?? FakeHarnessAdapter(kind: kind)
            },
            connections: ProviderConnectionStore(),
            modelCatalogs: HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
                claudeConfigDirectory: root.appending(path: "claude"), codexHome: root.appending(path: "codex-home"),
                codexYardletHome: root.appending(path: "codex-yardlet")), environment: [:]),
            initialTranscripts: transcripts,
            initialCodexPresentation: codex,
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            sessionTitleResolver: { _ in nil },
            sessionTitleRetryCount: 0,
            restoresIndexOnLaunch: false
        )
        testCase.addTeardownBlock { await model.shutdown() }
        return Window(model: model, tasks: sessions, adapters: adapters)
    }
}
