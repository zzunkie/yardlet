import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

@MainActor
final class ConversationRowListTests: XCTestCase {
    @MainActor
    private final class History {
        let turns = TranscriptConversationProjection.presentation(
            from: LongConversationFixture.claude(turns: 240), harness: .claudeCode,
            status: .completed, latestTurnIsComplete: true).turns
        let renderState = ConversationRenderState()
        let tracker = TranscriptReadingTracker()
        var requested = Set<Int>()

        func list(count: Int = 240, following: Bool = true, target: ConversationRowTarget? = nil) -> ConversationRowList {
            let context = ConversationItemContext(harness: .claudeCode, workspaceURL: LongConversationFixture.workspace,
                                                  actions: ConversationActions())
            return ConversationRowList(
                rowIDs: turns.prefix(count).map(\.id), part: { _ in .whole }, row: { [self] index in
                    requested.insert(index)
                    return ConversationTurnHost(turn: turns[index], context: context, handlers: .init(), renderState: renderState)
                }, renderState: renderState, scrollState: .constant(.init(isFollowing: following)), latestRequestID: nil,
                pendingRequestIDs: [], readingTracker: tracker, loadEarlier: nil, earlierKey: nil, onReturnToLatest: {},
                target: target, scroller: ConversationRowListScroller())
        }
    }

    private func mount(height: CGFloat = 700, scroll: ConversationRowListScrollView = .init(),
                       animation: ConversationRowListController.ScrollAnimation? = nil)
        -> ConversationRowListController {
        let assistiveReading = ConversationAssistiveReading.isOn
        ConversationAssistiveReading.isOn = { false }
        defer { ConversationAssistiveReading.isOn = assistiveReading }
        let controller = animation.map { ConversationRowListController(scrollView: scroll, animateScroll: $0) }
            ?? ConversationRowListController(scrollView: scroll)
        controller.scrollView.frame = CGRect(x: 0, y: 0, width: 900, height: height)
        controller.scrollView.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in controller.dismantle() }
        return controller
    }

    func testLongHistoryMeasuresOnlyTheViewportAndKeepsHeightsAcrossControlChanges() throws {
        let history = History()
        let turns = history.turns
        let tracker = history.tracker
        let list = history.list()
        XCTAssertEqual(turns.count, 240)
        let controller = mount()
        var environment = EnvironmentValues()
        environment.controlActiveState = .key
        environment.claudeShellCommands = ClaudeShellCommandActions(isRunning: false, run: { _ in }, stop: {}, runForEntry: { _ in nil })
        ViewBodyCensus.isEnabled = true
        defer {
            ViewBodyCensus.isEnabled = false
            ViewBodyCensus.reset()
        }
        ViewBodyCensus.reset()
        controller.update(list, environment: environment)
        for counter in [ViewBodyCensus.Body.conversationTurnShow, .conversationTurn, .conversationRowLaidOut] {
            let count = ViewBodyCensus[counter]
            XCTAssertGreaterThan(count, 0)
            XCTAssertLessThan(count, 24)
        }
        let before = controller.scrollView.contentView.bounds
        let document = try XCTUnwrap(controller.scrollView.documentView)
        XCTAssertEqual(before.maxY, document.frame.maxY, accuracy: 1)
        for toggle in 0..<3 {
            ViewBodyCensus.reset()
            switch toggle {
            case 0: environment.controlActiveState = .inactive
            case 1: environment.claudeShellCommands?.isRunning = true
            default: environment.revealsSentMessageActions = true
            }
            controller.update(list, environment: environment)
            XCTAssertLessThan(ViewBodyCensus[.conversationTurnShow], 24)
            XCTAssertEqual(ViewBodyCensus[.conversationHeightInvalidation], 0)
            XCTAssertEqual(ViewBodyCensus[.conversationTurn], 0)
            XCTAssertEqual(ViewBodyCensus[.conversationRowLaidOut], 0)
            XCTAssertEqual(controller.scrollView.contentView.bounds, before)
        }

        controller.pauseFollowing()
        controller.restore(.anchor(turns[40].id))
        let row = try XCTUnwrap(tracker.rowFrame?(turns[40].id))
        XCTAssertEqual(row.minY, controller.scrollView.contentView.bounds.minY, accuracy: 1)
        XCTAssertTrue(controller.scrollView.documentView?.subviews.contains { ($0 as? ConversationRowCell)?.rowID == turns[40].id } == true)
    }

    func testQuarterPointAtOverscanBoundaryShowsTheRowBeforeMountingIt() throws {
        let history = History()
        let controller = mount(height: 80)
        let list = history.list()
        controller.update(list, environment: .init())
        let last = try XCTUnwrap(history.tracker.rowFrame?(history.turns[239].id))
        let clip = controller.scrollView.contentView
        let document = try XCTUnwrap(controller.scrollView.documentView)
        // At the ideal bottom the overscan starts exactly at the last row. The actual clip
        // starts a quarter point earlier and reaches into the unvisited penultimate row.
        let height = (last.height + ConversationLayout.turnSpacing + ConversationLayout.bottomPadding) / 2
        clip.postsBoundsChangedNotifications = false
        clip.bounds = CGRect(x: 0, y: document.frame.height - height - 0.25, width: clip.bounds.width, height: height)
        XCTAssertEqual(clip.bounds.maxY, document.frame.height - 0.25, accuracy: 0.001)
        XCTAssertFalse(history.requested.contains(238))
        controller.update(list, environment: .init())
        XCTAssertTrue(history.requested.contains(238))
        // Refining the estimate can move the pinned end. Cross the same seam at its measured position.
        clip.setBoundsOrigin(NSPoint(x: 0, y: document.frame.height - height - 0.25))
        controller.update(list, environment: .init())
        let cells = document.subviews.compactMap { $0 as? ConversationRowCell }
        XCTAssertNotNil(cells.first { $0.rowID == history.turns[238].id }?.content)
    }

    func testAnimatedJumpLeavesIntermediateRowsUnmeasured() throws {
        let history = History()
        var frames = 0
        let controller = mount { clip, destination, complete in
            let start = clip.bounds.minY
            for step in 1...24 {
                clip.setBoundsOrigin(NSPoint(x: 0, y: start + (destination.y - start) * CGFloat(step) / 24))
                NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
                frames += 1
            }
            complete()
            return true
        }
        controller.update(history.list(), environment: .init())
        history.requested.removeAll()
        let id = history.turns[4].id
        let target = ConversationRowTarget(rowID: id, placement: .top, animated: true, token: 1)
        controller.update(history.list(following: false, target: target), environment: .init())
        XCTAssertEqual(frames, 24)
        XCTAssertLessThan(history.requested.count, 24)
        XCTAssertTrue(history.requested.isDisjoint(with: 20..<220))
        let frame = try XCTUnwrap(history.tracker.rowFrame?(id))
        XCTAssertEqual(controller.scrollView.contentView.bounds.minY, frame.minY, accuracy: 1)
    }

    func testElasticScrollKeepsTheClipOutsideMeasuredBounds() throws {
        final class ElasticClip: NSClipView {
            var stretching = false
            override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
                stretching ? proposed : super.constrainBoundsRect(proposed)
            }
        }
        let history = History()
        let scroll = ConversationRowListScrollView()
        let clip = ElasticClip()
        scroll.contentView = clip
        let controller = mount(scroll: scroll)
        controller.update(history.list(), environment: .init())
        let document = try XCTUnwrap(scroll.documentView)
        let beyondEnd = document.frame.height - clip.bounds.height + 12
        // AppKit allows these origins during a trackpad gesture, but constrains synthetic scrolls.
        clip.stretching = true
        clip.scroll(to: NSPoint(x: 0, y: beyondEnd))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
        XCTAssertEqual(clip.bounds.minY, beyondEnd, accuracy: 0.01)
    }

    func testEndKeyPinsTheMeasuredTailWhileReadingEarlierRows() throws {
        let history = History()
        let controller = mount()
        controller.update(history.list(count: 1, following: false), environment: .init())
        controller.update(history.list(following: false), environment: .init())
        XCTAssertFalse(history.requested.contains(239))
        let document = try XCTUnwrap(controller.scrollView.documentView)
        let estimatedEnd = document.frame.height
        controller.scrollView.scrollToEndOfDocument(nil)
        XCTAssertTrue(history.requested.contains(239))
        XCTAssertGreaterThan(document.frame.height, estimatedEnd)
        XCTAssertEqual(controller.scrollView.contentView.bounds.maxY, document.frame.height, accuracy: 1)
    }

    func testTaskSurfaceHostAndTurnCacheDeferEvictedHostings() async throws {
        let tasks = TaskSurfaceHostings()
        let render = ConversationRenderState()
        let holder = NSObject()
        weak var task: NSHostingView<AnyView>?
        weak var turn: ConversationTurnHosting?
        autoreleasepool {
            task = tasks.hosting(for: UUID()).0
            turn = render.hosting(for: "first", holder: holder)
            turn?.holder = nil
            for _ in 0..<ConversationRenderState.recentLimit {
                _ = tasks.hosting(for: UUID())
                _ = ConversationRenderState().hosting(for: "other", holder: holder)
            }
        }
        XCTAssertNotNil(task)
        XCTAssertNotNil(turn)
        try await waitUntil { task == nil && turn == nil }
    }
}
