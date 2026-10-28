import AppKit
import Observation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Following measured on the native scroll view SwiftUI lays out, with the transcript mounted in
/// a test window that is never shown on screen.
@MainActor
final class TranscriptAutoFollowTests: XCTestCase {
    @Observable
    final class Feed {
        var entries: [TranscriptEntry]
        init(_ entries: [TranscriptEntry]) { self.entries = entries }
    }

    @Observable
    final class CodexFeed {
        var state: CodexTaskState
        init(_ state: CodexTaskState) { self.state = state }
    }

    fileprivate static let size = NSSize(width: 620, height: 420)
    fileprivate static let pinned: CGFloat = 48

    // MARK: - The Codex timeline

    func checkTheCodexTimelineCountsOnlyItsShownPendingRequests() {
        var state = codexState(paragraphs: 1)
        state.approvalsByID["waiting"] = approval("waiting", turnID: "turn-1")
        state.approvalsByID["answered"] = CodexApprovalState(
            id: "answered", method: "item/commandExecution/requestApproval", threadID: "thread-1",
            turnID: "turn-1", itemID: nil, resolution: .resolved(nil), raw: nil
        )
        state.approvalsByID["unscoped"] = approval("unscoped", turnID: nil)
        state.serverRequestsByID["question"] = CodexServerRequestState(
            id: "question", method: "item/tool/requestUserInput", kind: .unknown("item/tool/requestUserInput"),
            threadID: "thread-1", turnID: "turn-1", itemID: nil, params: nil, resolution: .pending
        )
        // What the conversation hands following.
        let pending = CodexConversationProjection.presentation(
            state, workspaceURL: URL(filePath: "/tmp/qa"), historySelection: nil
        ).pendingRequestIDs
        XCTAssertEqual(pending, ["waiting", "question"])
    }

    func checkTheCodexTimelineBringsANewPendingApprovalIntoView() throws {
        try requireAwakeDisplay()
        let feed = CodexFeed(codexState(paragraphs: 10))
        let (hosting, window) = mount(CodexHost(feed: feed))
        defer { window.close() }
        let scroll = try XCTUnwrap(scrollView(in: hosting))
        XCTAssertLessThanOrEqual(distance(scroll), Self.pinned)

        userScroll(scroll, up: 600, in: hosting)
        XCTAssertGreaterThan(distance(scroll), Self.pinned)
        feed.state.approvalsByID["approval-1"] = approval("approval-1", turnID: "turn-1")
        pump(hosting)
        XCTAssertLessThanOrEqual(distance(scroll), Self.pinned)
    }

    /// A turn shorter than the window that grows past it, whether the whole state is replaced (a
    /// presentation snapshot) or its items arrive one by one, keeps the bottom in view.
    func checkACodexTurnGrowingPastTheWindowKeepsTheBottomFollowed() throws {
        let feed = CodexFeed(codexState(paragraphs: 1))
        let (hosting, window) = mount(CodexHost(feed: feed))
        defer { window.close() }
        let scroll = try XCTUnwrap(scrollView(in: hosting))
        XCTAssertLessThanOrEqual(distance(scroll), Self.pinned)

        feed.state = codexState(paragraphs: 12)
        pump(hosting)
        XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, Self.size.height * 2, "the turn did not grow")
        XCTAssertLessThanOrEqual(distance(scroll), Self.pinned, "replacing the state left the bottom")

        for count in 13...16 {
            feed.state = codexState(paragraphs: count)
            pump(hosting)
            XCTAssertLessThanOrEqual(distance(scroll), Self.pinned, "growth to \(count) paragraphs left the bottom")
        }
        try snapshot(hosting, to: "codex-short-turn-grown.png")
    }

    // MARK: - A Claude task's transcript

    func checkAFailedToolCardOpeningItselfKeepsTheTurnFollowed() throws {
        let feed = Feed([
            TranscriptEntry(content: .user(text: "Fix the calc tests")),
            TranscriptEntry(content: .assistant(text: "I'll run the tests first.", isStreaming: false))
        ])
        let (hosting, window) = mount(Host(feed: feed))
        defer { window.close() }
        let scroll = try XCTUnwrap(scrollView(in: hosting))

        let bash = HarnessActivity(id: "toolu_1", kind: "Bash", title: "Bash", input: "python3 test_calc.py")
        feed.entries.append(TranscriptEntry(content: .activity(bash, state: .running)))
        pump(hosting)
        var failed = bash
        failed.output = (1...40).map { "line \($0) of failing output" }.joined(separator: "\n")
        failed.outcome = .failed
        feed.entries[2].content = .activity(failed, state: .failed)
        pump(hosting)
        XCTAssertLessThanOrEqual(distance(scroll), Self.pinned)
        for index in 0..<5 {
            feed.entries.append(TranscriptEntry(content: .assistant(
                text: String(repeating: "More about the failure \(index). ", count: 12), isStreaming: false)))
            pump(hosting)
            XCTAssertLessThanOrEqual(distance(scroll), Self.pinned, "growth \(index) left the bottom")
        }
    }

    func checkOpeningAToolCardByHandAtTheBottomKeepsItPinned() throws {
        var entries = [TranscriptEntry(content: .user(text: "Fix the calc tests"))]
        for index in 0..<6 {
            entries.append(TranscriptEntry(content: .assistant(
                text: String(repeating: "Earlier reasoning \(index). ", count: 20), isStreaming: false)))
        }
        // A call whose card folds its details (a Claude Bash call is the command card, which shows its
        // command whole).
        let read = HarnessActivity(id: "toolu_1", kind: "Read", title: "Read",
                                   input: (1...30).map { "line \($0)" }.joined(separator: "\n"))
        entries.append(TranscriptEntry(content: .activity(read, state: .completed)))
        let feed = Feed(entries)
        let (hosting, window) = mount(Host(feed: feed))
        defer { window.close() }
        let scroll = try XCTUnwrap(scrollView(in: hosting))
        let collapsed = scroll.documentView?.frame.height ?? 0
        XCTAssertLessThanOrEqual(distance(scroll), Self.pinned)

        // Clicks reach SwiftUI only in an ordered window; this one is transparent and off screen.
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        hosting.display()
        pump(hosting)
        // The last card's disclosure chevron: inset 24 + card padding, 50pt above the bottom, above
        // the running turn's live line (24pt, and the turn's item spacing; `ConversationLiveWorkLine`).
        click(window, at: NSPoint(x: 38, y: 50 + 24 + ConversationLayout.itemSpacing))
        pump(hosting)
        XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, collapsed + 100, "the card did not open")
        XCTAssertLessThanOrEqual(distance(scroll), Self.pinned)

        feed.entries.append(TranscriptEntry(content: .assistant(
            text: String(repeating: "The output shows the failure. ", count: 20), isStreaming: false)))
        pump(hosting)
        XCTAssertLessThanOrEqual(distance(scroll), Self.pinned)
        try snapshot(hosting, to: "opened-card-then-growth.png")
    }

    func checkANewPendingApprovalIsBroughtIntoViewAfterScrollingAway() throws {
        try requireAwakeDisplay()
        var entries = [TranscriptEntry(content: .user(text: "Fix the calc tests"))]
        for index in 0..<8 {
            entries.append(TranscriptEntry(content: .assistant(
                text: String(repeating: "Earlier reasoning \(index). ", count: 20), isStreaming: false)))
        }
        let feed = Feed(entries)
        let (hosting, window) = mount(Host(feed: feed))
        defer { window.close() }
        let scroll = try XCTUnwrap(scrollView(in: hosting))

        userScroll(scroll, up: 600, in: hosting)
        XCTAssertGreaterThan(distance(scroll), Self.pinned)
        // Ordinary growth leaves a reader who scrolled away where they are.
        let edit = HarnessActivity(id: "toolu_edit", kind: "Edit", title: "Edit")
        feed.entries.append(TranscriptEntry(content: .activity(edit, state: .running)))
        pump(hosting)
        XCTAssertGreaterThan(distance(scroll), Self.pinned)

        feed.entries.append(TranscriptEntry(content: .permission(PermissionRequest(
            id: "permission-1", title: "Edit", detail: "calc.py", command: nil, toolCallID: "toolu_edit",
            preview: .edits(path: "/tmp/qa/calc.py", edits: [PermissionEditPreview(
                oldText: .init(bounding: "    return a - b"), newText: .init(bounding: "    return a + b"),
                replacesAll: false
            )], omittedEditCount: 0)
        ), state: .pending)))
        pump(hosting)
        XCTAssertLessThanOrEqual(distance(scroll), Self.pinned)
        try snapshot(hosting, to: "pending-approval-in-view.png")
    }

    // MARK: - Fixtures

    fileprivate struct Host: View {
        let feed: Feed
        var body: some View {
            // A Claude task's conversation, as a task draws it.
            TaskConversationView(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/qa"), entries: feed.entries,
                                 sessionStatus: .running)
                .frame(width: TranscriptAutoFollowTests.size.width, height: TranscriptAutoFollowTests.size.height)
        }
    }

    fileprivate struct CodexHost: View {
        let feed: CodexFeed
        var body: some View {
            TaskConversationView(
                harness: .codex, workspaceURL: URL(filePath: "/tmp/qa"), entries: [], codexTaskState: feed.state,
                actions: ConversationActions(retryTurn: { _ in })
            )
            .frame(width: TranscriptAutoFollowTests.size.width, height: TranscriptAutoFollowTests.size.height)
        }
    }

    fileprivate func codexState(paragraphs: Int) -> CodexTaskState {
        let decoder = CodexTaskDecoder()
        var thread = decoder.thread(from: .object(["id": .string("thread-1")]))!
        thread.turns = [decoder.turn(from: .object([
            "id": .string("turn-1"), "status": .string("inProgress"),
            "items": .array((0..<paragraphs).map { index in
                .object(["id": .string("answer-\(index)"), "type": .string("agentMessage"),
                         "text": .string(String(repeating: "Codex paragraph \(index). ", count: 20))])
            })
        ]), fallbackID: "turn-1")!]
        return CodexTaskState(thread: thread)
    }

    fileprivate func approval(_ id: String, turnID: String?) -> CodexApprovalState {
        CodexApprovalState(
            id: id, method: "item/commandExecution/requestApproval", threadID: "thread-1", turnID: turnID,
            itemID: nil, resolution: .pending, raw: .object(["command": .string("python3 test_calc.py")])
        )
    }

    fileprivate func mount<Content: View>(_ view: Content) -> (NSHostingView<Content>, NSWindow) {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        pump(hosting)
        return (hosting, window)
    }

    fileprivate func pump(_ hosting: NSView) {
        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    /// A trackpad scroll with its phases, which is how SwiftUI tells a reader's scroll from layout.
    /// A phased trackpad scroll only moves while the display is awake (a locked or sleeping Mac
    /// stops the scroll animation), so those checks are skipped rather than reported as failures.
    fileprivate func requireAwakeDisplay() throws {
        try XCTSkipIf(CGDisplayIsAsleep(CGMainDisplayID()) != 0, "Scrolling needs an awake display")
        // The display can wake for a moment while the screen stays locked; scrolling stops then too.
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        try XCTSkipIf((session?["CGSSessionScreenIsLocked"] as? Bool) == true, "Scrolling needs an unlocked screen")
    }

    fileprivate func userScroll(_ scroll: NSScrollView, up points: Int32, in hosting: NSView) {
        let steps: [(phase: Int64, delta: Int32)] = [(1, 0)] + Array(repeating: (2, points / 6), count: 6) + [(4, 0)]
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

    fileprivate func click(_ window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                              clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
    }

    fileprivate func snapshot(_ hosting: NSView, to name: String) throws {
        let bitmap = try WindowlessRender.capture(hosting)
        try WindowlessRender.writePNG(bitmap, to: WindowlessRender.directory("follow-qa").appending(path: name))
    }

    /// The conversation's scroll view: the composer has small scroll views of its own, so take
    /// the tallest one rather than whichever comes first in the view tree.
    fileprivate func scrollView(in view: NSView) -> NSScrollView? {
        func all(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(all)
        }
        return all(view).max { $0.frame.height < $1.frame.height }
    }

    fileprivate func distance(_ scroll: NSScrollView) -> CGFloat {
        (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.maxY
    }
}

extension TranscriptAutoFollowTests {
    // MARK: - State

    func testOnlyANewPendingRequestResumesFollowing() {
        var state = TranscriptScrollFollowState()
        state.observe(distance: 600, userDriven: true)
        XCTAssertFalse(state.isFollowing)
        XCTAssertFalse(state.pendingRequestsChanged(from: [], to: []))
        XCTAssertTrue(state.pendingRequestsChanged(from: [], to: ["permission-1"]))
        XCTAssertTrue(state.isFollowing)

        state.observe(distance: 600, userDriven: true)
        // Answering a request, or the same request redrawn, is not a new one.
        XCTAssertFalse(state.pendingRequestsChanged(from: ["permission-1"], to: []))
        XCTAssertFalse(state.pendingRequestsChanged(from: ["permission-1"], to: ["permission-1"]))
        XCTAssertFalse(state.isFollowing)
        XCTAssertTrue(state.pendingRequestsChanged(from: ["permission-1"], to: ["permission-1", "permission-2"]))
    }

    func testTheCodexTimelineCountsOnlyItsShownPendingRequests() {
        checkTheCodexTimelineCountsOnlyItsShownPendingRequests()
    }

    // MARK: - The common transcript

    func testAFailedToolCardOpeningItselfKeepsTheTurnFollowed() throws {
        try checkAFailedToolCardOpeningItselfKeepsTheTurnFollowed()
    }

    func testOpeningAToolCardByHandAtTheBottomKeepsItPinned() throws {
        try checkOpeningAToolCardByHandAtTheBottomKeepsItPinned()
    }

    func testANewPendingApprovalIsBroughtIntoViewAfterScrollingAway() throws {
        try checkANewPendingApprovalIsBroughtIntoViewAfterScrollingAway()
    }

    // MARK: - The Codex timeline

    func testTheCodexTimelineBringsANewPendingApprovalIntoView() throws {
        try checkTheCodexTimelineBringsANewPendingApprovalIntoView()
    }

    /// A Codex turn growing past the window keeps the bottom followed (M12e).
    func testACodexTurnGrowingPastTheWindowKeepsTheBottomFollowed() throws {
        try checkACodexTurnGrowingPastTheWindowKeepsTheBottomFollowed()
    }
}
