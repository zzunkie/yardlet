import AppKit
import Observation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Scrolling up to the top of a conversation with earlier turns brings them in, as an upward
/// infinite scroll does: the local window's next step, a Codex thread's earlier page, or more of a
/// Claude transcript read from its end. Only the reader's own scrolling asks, once per load, and
/// what the reader sees stays where it is as the earlier turns arrive above it, a few each display
/// cycle the reader holds still (`ConversationTurnReveal`). The rail's "Load more history" stays and
/// keeps the place the same way.
@MainActor
final class ConversationTopLoadingTests: XCTestCase {
    // MARK: - When to load

    func testOnlyTheReadersOwnScrollingToTheTopLoads() {
        var loading = TranscriptTopLoading()
        XCTAssertFalse(loading.shouldLoad(offset: 0, userDriven: false, key: "local:50|t51"),
                       "opening, restoring a place, a jump to a find match or growth is not the reader scrolling")
        XCTAssertFalse(loading.shouldLoad(offset: 900, userDriven: true, key: "local:50|t51"), "not near the top")
        XCTAssertFalse(loading.shouldLoad(offset: 40, userDriven: true, key: nil), "nothing earlier")
        XCTAssertTrue(loading.shouldLoad(offset: 120, userDriven: true, key: "local:50|t51"))
        XCTAssertEqual(loading.inFlight, "local:50|t51")
    }

    /// One load at a time: not again while it is in flight, and not again in the same gesture once it
    /// arrived, before the arrived turns pushed the reader away from the top; then again at the top.
    func testOneLoadAtATime() {
        var loading = TranscriptTopLoading()
        XCTAssertTrue(loading.shouldLoad(offset: 100, userDriven: true, key: "provider:c2|t20"))
        XCTAssertFalse(loading.shouldLoad(offset: 20, userDriven: true, key: "provider:c2|t20"), "in flight")
        loading.readerBeganScrolling()
        XCTAssertFalse(loading.shouldLoad(offset: 0, userDriven: true, key: "provider:c2|t20"),
                       "a new scroll does not ask again while the page is on its way")

        XCTAssertFalse(loading.shouldLoad(offset: 0, userDriven: true, key: "provider:c1|t10"),
                       "arrived, but the reader is still at the top the arrival is about to push down")
        XCTAssertNil(loading.inFlight)
        XCTAssertFalse(loading.shouldLoad(offset: 2_550, userDriven: false, key: "provider:c1|t10"))
        XCTAssertTrue(loading.shouldLoad(offset: 90, userDriven: true, key: "provider:c1|t10"),
                      "scrolled up to the top again")

        // Turns too short to push the reader down: the next scroll at the top asks again.
        XCTAssertFalse(loading.shouldLoad(offset: 40, userDriven: true, key: "provider:-|t1"))
        XCTAssertFalse(loading.shouldLoad(offset: 40, userDriven: true, key: "provider:-|t1"))
        loading.readerBeganScrolling()
        XCTAssertTrue(loading.shouldLoad(offset: 30, userDriven: true, key: "provider:-|t1"))
    }

    /// A load that brought nothing (the provider failed) is asked for again once the reader scrolls
    /// well away from the top and comes back, or after the earlier turns change.
    func testALoadThatBroughtNothingIsAskedForAgainAfterMovingAway() {
        var loading = TranscriptTopLoading()
        XCTAssertTrue(loading.shouldLoad(offset: 10, userDriven: true, key: "providerFile|t1"))
        XCTAssertFalse(loading.shouldLoad(offset: 300, userDriven: true, key: "providerFile|t1"))
        XCTAssertFalse(loading.shouldLoad(offset: 10, userDriven: true, key: "providerFile|t1"))
        XCTAssertFalse(loading.shouldLoad(offset: 700, userDriven: true, key: "providerFile|t1"))
        XCTAssertTrue(loading.shouldLoad(offset: 10, userDriven: true, key: "providerFile|t1"))
    }

    func testEarlierItemsArrivedOnlyBeforeTheFirstOne() {
        XCTAssertTrue(TranscriptTopLoading.earlierItemsArrived(from: ["b", "c"], to: ["a", "b", "c"]))
        XCTAssertFalse(TranscriptTopLoading.earlierItemsArrived(from: ["b", "c"], to: ["b", "c", "d"]), "appended")
        XCTAssertFalse(TranscriptTopLoading.earlierItemsArrived(from: ["b", "c"], to: ["x", "y"]), "renamed")
        XCTAssertFalse(TranscriptTopLoading.earlierItemsArrived(from: [], to: ["a"]))
    }

    /// The first item in view goes back to where it was: a scroll anchor lines up the same point of
    /// the item and of the viewport, so the anchor puts its top `y` points into the viewport again.
    func testThePlaceToKeepPutsTheFirstItemInViewBackWhereItWas() async {
        let tracker = TranscriptReadingTracker()
        tracker.start(record: nil, itemIDs: ["t1", "t2", "t3"])
        tracker.observe(offset: 1_000, height: 4_000, viewport: CGSize(width: 600, height: 600),
                        followsLatest: false, userDriven: true)
        tracker.measure(id: "t1", frame: CGRect(x: 0, y: -50, width: 560, height: 300))
        tracker.measure(id: "t2", frame: CGRect(x: 0, y: 274, width: 560, height: 500))
        let place = tracker.placeToKeep()
        XCTAssertEqual(place?.id, "t1")
        XCTAssertEqual(Double(place?.anchor.y ?? 0) * (600 - 300), -50, accuracy: 0.001)

        // An item exactly as tall as the viewport cannot say where it was; the next one does.
        tracker.measure(id: "t1", frame: CGRect(x: 0, y: -50, width: 560, height: 600))
        let next = tracker.placeToKeep()
        XCTAssertEqual(next?.id, "t2")
        XCTAssertEqual(Double(next?.anchor.y ?? 0) * (600 - 500), 274, accuracy: 0.001)
    }

    /// Keeping the reader's place as earlier turns arrive ends SwiftUI's scroll phase: the view moving
    /// on with its content and viewport unchanged is still the reader's scroll, until it stands still.
    func testTheReadersScrollGoesOnAcrossAKeptPlaceUntilTheViewStandsStill() {
        func metrics(_ offset: CGFloat, height: CGFloat = 3_000) -> TranscriptScrollMetrics {
            TranscriptScrollMetrics(height: height, viewport: CGSize(width: 600, height: 600), offset: offset,
                                    distance: height - offset - 600)
        }
        let start = Date(timeIntervalSince1970: 1_000)
        var scroll = TranscriptContinuedScroll()
        XCTAssertFalse(scroll.continues(from: metrics(500), to: metrics(470), at: start), "no place kept")

        scroll.keptPlace(at: start)
        XCTAssertTrue(scroll.continues(from: metrics(680), to: metrics(650), at: start + 0.1))
        XCTAssertFalse(scroll.continues(from: metrics(650), to: metrics(650, height: 3_500), at: start + 0.2),
                       "the content changed: layout, not the reader")
        XCTAssertTrue(scroll.continues(from: metrics(650), to: metrics(620), at: start + 0.5),
                      "each move of the reader's keeps it going")
        XCTAssertFalse(scroll.continues(from: metrics(620), to: metrics(590), at: start + 1.2), "stood still")
        XCTAssertFalse(scroll.goesOn(at: start + 1.2))
        XCTAssertFalse(scroll.continues(from: metrics(590), to: metrics(560), at: start + 1.3), "over")

        scroll.keptPlace(at: start + 2)
        scroll.end()
        XCTAssertFalse(scroll.continues(from: metrics(560), to: metrics(530), at: start + 2.1),
                       "SwiftUI tracks the reader's scrolling again")
    }

    // MARK: - Rendered, with a reader's scrolling

    /// A long transcript opens at its bottom without loading. Scrolling up to the top brings in the
    /// window's next 10 turns once, and the turn at the top stays there; scrolling up to the new top
    /// again and again brings in the rest.
    func testScrollingToTheTopOfATranscriptBringsEarlierTurnsInOnceAndKeepsThePlace() throws {
        try requireAwakeDisplay()
        let mounted = mount(ConversationTimeline(source: .transcript(
            entries: Self.transcript(turns: 90), harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        )))
        defer { mounted.window.close() }
        let scroll = try XCTUnwrap(scrollView(in: mounted.hosting))
        pump(mounted.hosting, passes: 12)
        XCTAssertEqual(drawnTurnCount(mounted.hosting), 10, "opening at the bottom loads nothing")

        scrollToNearTheTop(scroll, in: mounted.hosting)
        XCTAssertEqual(drawnTurnCount(mounted.hosting), 10)
        userScroll(scroll, up: Int32(scroll.contentView.bounds.minY + 200), in: mounted.hosting)
        pumpUntil(mounted.hosting) { drawnTurnCount(mounted.hosting) == 20 }
        XCTAssertEqual(drawnTurnCount(mounted.hosting), 20, "one load for one arrival at the top")
        let after = try XCTUnwrap(topRequest(in: mounted))
        XCTAssertTrue((80...81).contains(after.number), "the turn read stays in view, not the new top: \(after)")
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 1_500, "the earlier turns arrived above the reader")

        for _ in 0..<60 where (drawnTurnCount(mounted.hosting) ?? 0) < 90 {
            userScroll(scroll, up: 3_000, in: mounted.hosting)
        }
        XCTAssertEqual(drawnTurnCount(mounted.hosting), 90)
    }

    /// A classic mouse wheel, without a trackpad's phases, is the reader's scrolling too (SwiftUI
    /// reports it as interacting): wheeling up to the top brings the earlier turns in.
    func testAMouseWheelToTheTopBringsEarlierTurnsIn() throws {
        try requireAwakeDisplay()
        let mounted = mount(ConversationTimeline(source: .transcript(
            entries: Self.transcript(turns: 90), harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        )))
        defer { mounted.window.close() }
        let scroll = try XCTUnwrap(scrollView(in: mounted.hosting))
        pump(mounted.hosting, passes: 12)
        scrollToNearTheTop(scroll, in: mounted.hosting)
        for _ in 0..<80 where drawnTurnCount(mounted.hosting) == 10 {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 5,
                                      wheel2: 0, wheel3: 0),
                  let wheel = NSEvent(cgEvent: event) else { continue }
            scroll.scrollWheel(with: wheel)
            pump(mounted.hosting, passes: 2)
        }
        pumpUntil(mounted.hosting) { drawnTurnCount(mounted.hosting) == 20 }
        XCTAssertEqual(drawnTurnCount(mounted.hosting), 20)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 1_500, "the earlier turns arrived above the reader")
    }

    /// A Codex thread with loaded turns the window leaves out brings those in first and then asks for
    /// its earlier page, in one scroll up: the loaded turns arrive at the top, the reader goes on up
    /// past them, and the page is asked for once, not again while it is on its way; when it arrives,
    /// the turn the reader was at stays in view.
    func testACodexPageAskedForAtTheTopArrivesWithoutMovingTheReader() throws {
        try requireAwakeDisplay()
        // 12 loaded turns: the window draws the latest 10 and holds back 13 and 14.
        let feed = Feed(Self.codexThread(turns: 13...24, cursor: "before-12"))
        let asked = Counter()
        var actions = ConversationActions()
        actions.loadMoreCodexTurns = { asked.count += 1 }
        let mounted = mount(CodexFeedView(feed: feed, actions: actions))
        defer { mounted.window.close() }
        let scroll = try XCTUnwrap(scrollView(in: mounted.hosting))
        pump(mounted.hosting, passes: 12)
        XCTAssertEqual(asked.count, 0)
        XCTAssertEqual(drawnTurnCount(mounted.hosting), 10)

        scrollToNearTheTop(scroll, in: mounted.hosting)
        XCTAssertEqual(drawnTurnCount(mounted.hosting), 10)
        // One long scroll up: to the top, where 13 and 14 arrive above the reader, and on up to the
        // new top, where the provider's page is asked for.
        userScroll(scroll, up: 2_400, steps: 16, in: mounted.hosting)
        XCTAssertEqual(drawnTurnCount(mounted.hosting), 12, "the loaded turns come first")
        XCTAssertEqual(asked.count, 1, "then the provider's page, in the same scroll")
        userScroll(scroll, up: 300, in: mounted.hosting)
        XCTAssertEqual(asked.count, 1, "not again while the page is on its way")
        let before = try XCTUnwrap(topRequest(in: mounted), listed(mounted.hosting))
        XCTAssertEqual(before.number, 13)

        feed.state = Self.codexThread(turns: 3...24, cursor: "before-2")
        pumpUntil(mounted.hosting) { drawnTurnCount(mounted.hosting) == 22 }
        XCTAssertEqual(drawnTurnCount(mounted.hosting), 22, "the page is drawn whole")
        let after = try XCTUnwrap(topRequest(in: mounted))
        XCTAssertEqual(after.number, 13, "the turn read stays where it was")
        XCTAssertEqual(after.y, before.y, accuracy: 2)
        XCTAssertEqual(asked.count, 1)
    }

    /// A Claude transcript read from its end offers the rest of its file. The rail's "Load more
    /// history" asks for it, and the longer read's earlier turns arrive above the reader, who stays.
    func testTheRailReadsMoreOfAClaudeFileAndKeepsThePlace() throws {
        try requireAwakeDisplay()
        // The read so far: the latest 10 turns, a request and an answer each.
        let feed = TranscriptFeed(Array(Self.transcript(turns: 60).suffix(20)))
        let asked = Counter()
        var actions = ConversationActions()
        actions.readEarlierHistory = { asked.count += 1 }
        feed.actions = actions
        let mounted = mount(TranscriptFeedView(feed: feed))
        defer { mounted.window.close() }
        let scroll = try XCTUnwrap(scrollView(in: mounted.hosting))
        pump(mounted.hosting, passes: 12)
        XCTAssertTrue(listed(mounted.hosting).contains(L10n.string("Load more history")),
                      "the file's earlier turns are offered")
        userScroll(scroll, up: 1_500, in: mounted.hosting)
        pump(mounted.hosting, passes: 8)
        XCTAssertEqual(asked.count, 0, "scrolled back, not up to the top")
        let before = try XCTUnwrap(topRequest(in: mounted))

        XCTAssertTrue(press(L10n.string("Load more history"), in: mounted.hosting))
        pump(mounted.hosting, passes: 4)
        XCTAssertEqual(asked.count, 1)
        feed.entries = Self.transcript(turns: 60)
        feed.actions = ConversationActions()
        pumpUntil(mounted.hosting) { drawnTurnCount(mounted.hosting) == 20 }
        let after = try XCTUnwrap(topRequest(in: mounted))
        XCTAssertEqual(after.number, before.number, "the turn read stays where it was")
        XCTAssertEqual(after.y, before.y, accuracy: 2)
        // The window's next step draws: the 10 read before and 10 of the ones the read brought in.
        XCTAssertEqual(drawnTurnCount(mounted.hosting), 20)
    }

    /// A mouse wheel turned on past the turns that arrived at the top is still the reader scrolling.
    /// Keeping the reader's place as the window's turns arrive ends SwiftUI's scroll phase, though not
    /// the wheel; the new top still asks for the provider's page, once.
    func testAWheelGoingOnPastArrivedTurnsAsksForTheCodexPageOnce() throws {
        let feed = Feed(Self.codexThread(turns: 13...24, cursor: "before-12"))
        let asked = Counter()
        var actions = ConversationActions()
        actions.loadMoreCodexTurns = { asked.count += 1 }
        let mounted = mount(CodexFeedView(feed: feed, actions: actions))
        defer { mounted.window.close() }
        let scroll = try XCTUnwrap(scrollView(in: mounted.hosting))
        pump(mounted.hosting, passes: 12)
        XCTAssertEqual(drawnTurnCount(mounted.hosting), 10)
        let start = scroll.contentView.bounds.minY

        // Three lines a notch, 16 ms apart: past the top, the turns that arrive there, and on.
        for _ in 0..<120 {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3,
                                      wheel2: 0, wheel3: 0),
                  let wheel = NSEvent(cgEvent: event) else { continue }
            scroll.scrollWheel(with: wheel)
            RunLoop.main.run(until: Date().addingTimeInterval(0.016))
        }
        pump(mounted.hosting, passes: 8)
        try XCTSkipIf(scroll.contentView.bounds.minY == start, "The wheel did not move the conversation")
        XCTAssertEqual(drawnTurnCount(mounted.hosting), 12, "the loaded turns came first")
        XCTAssertEqual(asked.count, 1, "then the provider's page, once, with the wheel still turning at the top")
    }

    // MARK: - Fixtures

    @Observable
    final class Feed {
        var state: CodexTaskState
        init(_ state: CodexTaskState) { self.state = state }
    }

    @MainActor @Observable
    final class TranscriptFeed {
        var entries: [TranscriptEntry]
        var actions = ConversationActions()
        init(_ entries: [TranscriptEntry]) { self.entries = entries }
    }

    private struct CodexFeedView: View {
        let feed: Feed
        let actions: ConversationActions
        var body: some View {
            ConversationTimeline(
                source: .codex(feed.state, workspaceURL: URL(filePath: "/tmp/yardlet"), historySelection: nil),
                actions: actions
            )
            .frame(width: 620, height: 600)
        }
    }

    private struct TranscriptFeedView: View {
        let feed: TranscriptFeed
        var body: some View {
            ConversationTimeline(
                source: .transcript(entries: feed.entries, harness: .claudeCode, status: .ready,
                                    latestTurnIsComplete: true),
                actions: feed.actions
            )
            .frame(width: 620, height: 600)
        }
    }

    private final class Counter { var count = 0 }

    private struct Mounted {
        let hosting: NSView
        let window: NSWindow
    }

    private static let answer = String(repeating: "Words in the answer, enough to wrap a few lines. ", count: 9)

    /// `turns` turns, `Request 1` first, each a request and a few lines of answer.
    private static func transcript(turns: Int) -> [TranscriptEntry] {
        (1...turns).flatMap { index in
            [TranscriptEntry(id: NameBasedUUID.make(namespace: namespace, name: "u\(index)"),
                             createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60),
                             content: .user(text: "Request \(index)")),
             TranscriptEntry(id: NameBasedUUID.make(namespace: namespace, name: "a\(index)"),
                             createdAt: Date(timeIntervalSince1970: 1_700_000_030 + Double(index) * 60),
                             content: .assistant(text: "Answer \(index). " + answer, isStreaming: false))]
        }
    }

    private static let namespace = UUID(uuidString: "6B1B8C52-1D5E-4C1A-9E44-3D2F1A0B7C11")!

    /// Finished Codex turns `turns`, each a request and its answer, with the cursor before them.
    private static func codexThread(turns: ClosedRange<Int>, cursor: String?) -> CodexTaskState {
        let decoder = CodexTaskDecoder()
        var thread = decoder.thread(from: .object(["id": .string("thread-top")]))!
        thread.turns = turns.map { index in
            decoder.turn(from: .object([
                "id": .string("turn-\(index)"), "status": .string("completed"), "durationMs": .integer(1_000),
                "items": .array([
                    .object(["id": .string("u\(index)"), "type": .string("userMessage"),
                             "content": .array([.object(["type": .string("text"), "text": .string("Request \(index)")])])]),
                    .object(["id": .string("a\(index)"), "type": .string("agentMessage"),
                             "text": .string("Answer \(index). " + answer), "phase": .string("final_answer")])
                ])
            ]), fallbackID: "turn-\(index)")!
        }
        thread.turnsNextCursor = cursor
        return CodexTaskState(thread: thread)
    }

    private func mount<Content: View>(_ view: Content) -> Mounted {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view.frame(width: 620, height: 600).background(ParityTheme.canvas))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        pump(hosting)
        return Mounted(hosting: hosting, window: window)
    }

    private func pump(_ hosting: NSView, passes: Int = 6) {
        for _ in 0..<passes {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    /// Pumps until `isDone`, as turns that arrived are drawn in their own time, for `testWaitLimitSeconds`
    /// at most.
    private func pumpUntil(_ hosting: NSView, _ isDone: () -> Bool) {
        let deadline = Date().addingTimeInterval(testWaitLimitSeconds)
        while !isDone(), Date() < deadline { pump(hosting, passes: 1) }
    }

    /// A trackpad scroll with its phases, which is how SwiftUI tells a reader's scroll from layout.
    /// It only moves while the display is awake and unlocked (`TranscriptAutoFollowTests`).
    private func requireAwakeDisplay() throws {
        try XCTSkipIf(CGDisplayIsAsleep(CGMainDisplayID()) != 0, "Scrolling needs an awake display")
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        try XCTSkipIf((session?["CGSSessionScreenIsLocked"] as? Bool) == true, "Scrolling needs an unlocked screen")
    }

    private func userScroll(_ scroll: NSScrollView, up points: Int32, steps count: Int32 = 6, in hosting: NSView) {
        let steps: [(phase: Int64, delta: Int32)] = [(1, 0)]
            + Array(repeating: (2, points / count), count: Int(count)) + [(4, 0)]
        for step in steps {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: step.delta, wheel2: 0, wheel3: 0) else { continue }
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: step.phase)
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            if let wheel = NSEvent(cgEvent: event) { scroll.scrollWheel(with: wheel) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        pump(hosting)
    }

    /// Scrolls up until the top is within one more short scroll, without reaching it.
    private func scrollToNearTheTop(_ scroll: NSScrollView, in hosting: NSView) {
        for _ in 0..<20 where scroll.contentView.bounds.minY > 900 {
            let remaining = scroll.contentView.bounds.minY - 500
            userScroll(scroll, up: Int32(min(2_400, max(60, remaining))), in: hosting)
        }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        func all(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(all)
        }
        return all(view).max { $0.frame.height < $1.frame.height }
    }

    /// The topmost request in view, by number, with its top in screen points.
    private func topRequest(in mounted: Mounted) -> (number: Int, y: CGFloat)? {
        mounted.hosting.layoutSubtreeIfNeeded()
        let attribute = "AXEnhancedUserInterface" as NSString
        let app = NSApplication.shared
        _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true),
                        with: attribute)
        defer {
            _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: false),
                            with: attribute)
        }
        var found: [(Int, NSRect)] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ node: AnyObject) {
            for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                guard visited.insert(ObjectIdentifier(child)).inserted else { continue }
                let label = (child.accessibilityLabel?() ?? nil) ?? ""
                let value = ((child.accessibilityValue?() as Any??) ?? nil).map { "\($0)" } ?? ""
                let text = value.hasPrefix("Request ") ? value : label
                if text.hasPrefix("Request "), let number = Int(text.dropFirst("Request ".count)),
                   let frame = child.accessibilityFrame?(), frame.intersects(mounted.window.frame) {
                    found.append((number, frame))
                }
                visit(child)
            }
        }
        visit(mounted.hosting)
        return found.max { $0.1.maxY < $1.1.maxY }.map { ($0.0, $0.1.maxY) }
    }

    private func listed(_ hosting: NSView) -> String {
        WindowlessRender.accessibilityElements(in: hosting).map(\.description).joined(separator: "\n")
    }

    /// How many turns the conversation draws, as its rail names them ("Turn 40 of 40").
    private func drawnTurnCount(_ hosting: NSView) -> Int? {
        WindowlessRender.accessibilityElements(in: hosting).compactMap { element -> Int? in
            guard ConversationDrawing.isRailTurn(element.label) else { return nil }
            return element.label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.max()
        }.max()
    }

    private func press(_ label: String, in view: NSView) -> Bool {
        let attribute = "AXEnhancedUserInterface" as NSString
        let app = NSApplication.shared
        _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true),
                        with: attribute)
        defer {
            _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: false),
                            with: attribute)
        }
        func visit(_ node: AnyObject) -> AnyObject? {
            for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                if (child.accessibilityLabel?() ?? nil) == label { return child }
                if let found = visit(child) { return found }
            }
            return nil
        }
        return visit(view)?.accessibilityPerformPress?() ?? false
    }
}
