import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// What a scroll costs each frame beyond moving what is already laid out: the conversation's turns
/// telling the reading tracker where they are, and the sidebar's rows taking the pointer as they pass
/// under it. Each step of a trackpad gesture lays out and draws the unshown window and turns the run
/// loop for 16 ms, as a display cycle would. Run with `NHC_PERF_BENCH=1`; the benchmarks print their
/// numbers and check nothing else.
@MainActor
final class ScrollFrameCostTests: XCTestCase {
    private typealias TaskSpec = ConversationBlankFrameTests.TaskSpec

    /// A reader's scroll through a conversation of 200 short turns with 60 of them drawn, 16 points a
    /// step, 150 steps up and 150 back, three times. A step counts the turns that told the reading
    /// tracker their place, the turns drawn again and the rows laid out anew, beside the main
    /// thread's time.
    func testBenchmarkScrollingALongConversation() throws {
        guard ProcessInfo.processInfo.environment["NHC_PERF_BENCH"] == "1" else {
            throw XCTSkip("Set NHC_PERF_BENCH=1 to run the conversation scroll benchmark")
        }
        try requireAwakeDisplay()
        let host = WindowlessRender.Host(
            ConversationTimeline(source: .transcript(entries: Self.transcript(turns: 200), harness: .claudeCode,
                                                     status: .ready, latestTurnIsComplete: true))
                .frame(width: 900, height: 800).background(ParityTheme.canvas),
            size: NSSize(width: 900, height: 800))
        defer { host.close() }
        host.settle(passes: 12)
        let scroll = try XCTUnwrap(Self.scrollViews(in: host.hosting).max { $0.frame.height < $1.frame.height })
        // The reader's scroll reaches the top five times: 10 more turns arrive each time.
        for _ in 0..<5 {
            let height = scroll.documentView?.frame.height ?? 0
            gesture(scroll, in: host, steps: 8, delta: Int32(scroll.contentView.bounds.minY / 8) + 40)
            for _ in 0..<60 where (scroll.documentView?.frame.height ?? 0) == height { host.settle(passes: 1) }
            host.settle(passes: 6)
        }
        let steps = 300, delta: Int32 = 16
        let room = CGFloat(steps / 2) * CGFloat(delta)
        let height = scroll.documentView?.frame.height ?? 0
        try XCTSkipIf(height < room + 1_600, "The conversation drew too few turns to scroll through: \(height) pt")
        // Read from well below the top, where the scroll up brings nothing in.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: room + 600))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.settle(passes: 8)

        var rounds: [Round] = []
        for _ in 0..<3 {
            rounds.append(measure(scroll, in: host, steps: steps, delta: delta))
            host.settle(passes: 6)
        }
        let round = rounds.sorted { $0.total < $1.total }[rounds.count / 2]
        PerfBenchRecord.write("scroll-conversation", [
            "turnPlacesAStepCount": round.perStep(.conversationTurnPlaced),
            "turnsDrawnAgainCount": Double(round.counts[.conversationTurn] ?? 0),
            "rowsLaidOutCount": Double(round.counts[.conversationRowLaidOut] ?? 0),
            "stepMedianMs": round.median, "stepP95Ms": round.p95, "totalMs": round.total
        ])
        for round in rounds {
            print(String(format: "[scroll-cost] conversation, %.0f pt of %.0f: %.2f turn places a step, %d timeline bodies, "
                          + "%d turns drawn again, %d rows laid out; %@", round.moved, height,
                          round.perStep(.conversationTurnPlaced), round.counts[.conversationTimeline] ?? 0,
                          round.counts[.conversationTurn] ?? 0, round.counts[.conversationRowLaidOut] ?? 0, round.time))
        }
    }

    /// The sidebar of 400 tasks in 40 projects under a reader's scroll, 14 points a step, 120 steps down
    /// and 120 back, three times with no pointer over the window and three times with the pointer resting
    /// over the list. A step counts the rows drawn again and the rows that reported their place, beside
    /// the main thread's time.
    ///
    /// The window is never shown, so the pointer is a stand-in: SwiftUI works out hover again after each
    /// layout of a window on screen, and here it is handed a pointer event at the same place after each
    /// step instead. SwiftUI takes no hover while the system hides the pointer, as it does while someone
    /// types, and the benchmark then skips: move the pointer and run it again.
    func testBenchmarkScrollingTheSidebarUnderARestingPointer() throws {
        guard ProcessInfo.processInfo.environment["NHC_PERF_BENCH"] == "1" else {
            throw XCTSkip("Set NHC_PERF_BENCH=1 to run the sidebar scroll benchmark")
        }
        try requireAwakeDisplay()
        var specs = (0..<400).map { TaskSpec(title: "Task \($0)", content: .empty, folder: "project-\($0 % 40)") }
        specs.append(.claude("Shown", turns: 3))
        let window = try ConversationBlankFrameTests.makeWindow(specs, for: self)
        defer { window.close() }
        window.show(specs.count - 1)
        let host = window.host
        let scroll = try XCTUnwrap(Self.scrollViews(in: host.hosting).first { scroll in
            let frame = scroll.convert(scroll.bounds, to: nil)
            return frame.maxX <= SidebarWidth.maximum && (scroll.documentView?.frame.height ?? 0) > frame.height
        }, "the sidebar's list")
        let steps = 240, delta: Int32 = -14
        let listHeight = scroll.documentView?.frame.height ?? 0

        var rounds: [(name: String, round: Round)] = []
        for _ in 0..<3 {
            rounds.append(("no pointer", measure(scroll, in: host, steps: steps, delta: delta)))
            host.settle(passes: 4)
        }

        // The pointer comes to rest on a task's row, which draws its hover.
        let list = scroll.convert(scroll.bounds, to: nil)
        var pointer: NSPoint?
        ViewBodyCensus.isEnabled = true
        defer { ViewBodyCensus.isEnabled = false; ViewBodyCensus.reset() }
        for attempt in 0..<8 where pointer == nil {
            let place = NSPoint(x: list.midX, y: list.midY + CGFloat(attempt % 4) * 9)
            ViewBodyCensus.reset()
            point(at: place, entering: true, in: host)
            host.settle(passes: 4)
            if ViewBodyCensus[.sidebarRow] > 0 { pointer = place }
        }
        ViewBodyCensus.isEnabled = false
        guard let pointer else {
            throw XCTSkip("No row took the pointer: SwiftUI takes no hover while the system hides the pointer")
        }
        var afterRest: [Int] = []
        for _ in 0..<3 {
            rounds.append(("the pointer resting on the list", measure(scroll, in: host, steps: steps, delta: delta) {
                self.point(at: pointer, entering: false, in: host)
            }))
            // Once the list rests, the row under the pointer has it.
            ViewBodyCensus.isEnabled = true
            ViewBodyCensus.reset()
            point(at: pointer, entering: false, in: host)
            host.settle(passes: 6)
            afterRest.append(ViewBodyCensus[.sidebarRow])
            ViewBodyCensus.isEnabled = false
        }
        for (index, name) in ["no pointer", "the pointer resting on the list"].enumerated() {
            let sorted = rounds.filter { $0.name == name }.map(\.round).sorted { $0.total < $1.total }
            let round = sorted[sorted.count / 2]
            PerfBenchRecord.write(index == 0 ? "scroll-sidebar-no-pointer" : "scroll-sidebar-resting-pointer", [
                "rowsDrawnAStepCount": round.perStep(.sidebarRow), "rowPlacesAStepCount": round.perStep(.sidebarRowPlaced),
                "stepMedianMs": round.median, "stepP95Ms": round.p95, "totalMs": round.total
            ])
        }
        for (name, round) in rounds {
            print(String(format: "[scroll-cost] sidebar, %@, %.0f pt of %.0f: %.2f rows drawn a step, %.2f row places a step, "
                          + "%d window bodies; %@", name, round.moved, listHeight, round.perStep(.sidebarRow),
                          round.perStep(.sidebarRowPlaced), round.counts[.mainWindow] ?? 0, round.time))
        }
        print("[scroll-cost] sidebar, rows drawn once the list rested under the pointer: \(afterRest)")
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let sinceMove = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        if sinceKey < sinceMove {
            print("[scroll-cost] sidebar: someone typed during the run; the rounds with the pointer may have had no hover")
        }
    }

    // MARK: - A gesture, measured

    private struct Round {
        let counts: [ViewBodyCensus.Body: Int]
        let steps: [Double]
        /// How far the view was from where it started at the gesture's turn.
        let moved: CGFloat

        var total: Double { steps.reduce(0, +) }
        var median: Double { steps.sorted()[steps.count / 2] }
        var p95: Double { steps.sorted()[steps.count * 95 / 100] }
        var time: String {
            String(format: "main thread %.0f ms in all, a step %.2f ms median, %.2f ms p95, %.2f ms max",
                   total, median, p95, steps.max() ?? 0)
        }

        func perStep(_ body: ViewBodyCensus.Body) -> Double { Double(counts[body] ?? 0) / Double(steps.count) }
    }

    /// One trackpad gesture of `steps` steps, `delta` points each, the first half one way and the second
    /// half back. `afterStep` runs once the step's scroll is laid out and drawn.
    private func measure(_ scroll: NSScrollView, in host: WindowlessRender.Host<some View>, steps: Int, delta: Int32,
                         afterStep: () -> Void = {}) -> Round {
        func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000 }
        let start = scroll.contentView.bounds.minY
        var moved: CGFloat = 0
        var times: [Double] = []
        ViewBodyCensus.isEnabled = true
        ViewBodyCensus.reset()
        wheel(scroll, phase: 1, delta: 0)
        for step in 0..<steps {
            let began = cpu()
            wheel(scroll, phase: 2, delta: step < steps / 2 ? delta : -delta)
            host.hosting.layoutSubtreeIfNeeded()
            host.window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.016))
            afterStep()
            times.append(cpu() - began)
            moved = max(moved, abs(scroll.contentView.bounds.minY - start))
        }
        let counts = ViewBodyCensus.counts
        ViewBodyCensus.isEnabled = false
        ViewBodyCensus.reset()
        wheel(scroll, phase: 4, delta: 0)
        return Round(counts: counts, steps: times, moved: moved)
    }

    /// A trackpad gesture with its phases, which is how SwiftUI tells a reader's scroll from layout.
    private func gesture(_ scroll: NSScrollView, in host: WindowlessRender.Host<some View>, steps: Int, delta: Int32) {
        wheel(scroll, phase: 1, delta: 0)
        for _ in 0..<steps {
            wheel(scroll, phase: 2, delta: delta)
            host.settle(passes: 1, interval: 0.02)
        }
        wheel(scroll, phase: 4, delta: 0)
        host.settle(passes: 4)
    }

    private func wheel(_ scroll: NSScrollView, phase: Int64, delta: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: delta, wheel2: 0, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        if let wheel = NSEvent(cgEvent: event) { scroll.scrollWheel(with: wheel) }
    }

    /// Hands the window's hosting view a pointer event at `place`, in the window's coordinates. The real
    /// pointer stays where it is.
    private func point(at place: NSPoint, entering: Bool, in host: WindowlessRender.Host<some View>) {
        let hosting = host.hosting, number = host.window.windowNumber, now = ProcessInfo.processInfo.systemUptime
        if entering, let area = hosting.trackingAreas.first(where: { $0.options.contains(.mouseEnteredAndExited) }),
           let entered = NSEvent.enterExitEvent(
               with: .mouseEntered, location: place, modifierFlags: [], timestamp: now, windowNumber: number, context: nil,
               eventNumber: 0, trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()), userData: nil) {
            hosting.mouseEntered(with: entered)
        }
        if let moved = NSEvent.mouseEvent(with: .mouseMoved, location: place, modifierFlags: [], timestamp: now,
                                          windowNumber: number, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            hosting.mouseMoved(with: moved)
        }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    // MARK: - Fixture

    private static let namespace = UUID(uuidString: "3C7A2E10-5B64-4F0D-9A1E-7D2C4B6A8F03")!

    /// `turns` short turns: a request and an answer of a few lines with a link and code in it, every
    /// fourth with a code block.
    private static func transcript(turns: Int) -> [TranscriptEntry] {
        (1...turns).flatMap { index in
            var answer = "Answer \(index). See [the notes](https://example.com/notes/\(index)) and `Sources/File\(index).swift`: "
                + "the change keeps what the reader sees where it is."
            if index % 4 == 0 {
                answer += "\n\n```swift\nlet turn = \(index)\nprint(turn)\n```"
            }
            return [
                TranscriptEntry(id: NameBasedUUID.make(namespace: namespace, name: "u\(index)"),
                                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60),
                                content: .user(text: "Request \(index)")),
                TranscriptEntry(id: NameBasedUUID.make(namespace: namespace, name: "a\(index)"),
                                createdAt: Date(timeIntervalSince1970: 1_700_000_030 + Double(index) * 60),
                                content: .assistant(text: answer, isStreaming: false))
            ]
        }
    }
}
