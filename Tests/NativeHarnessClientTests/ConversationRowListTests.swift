import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

@MainActor
final class ConversationRowListTests: XCTestCase {
    func testLongHistoryMeasuresOnlyTheViewportAndKeepsHeightsAcrossControlChanges() throws {
        let renderState = ConversationRenderState()
        let turns = TranscriptConversationProjection.presentation(
            from: LongConversationFixture.claude(turns: 240), harness: .claudeCode,
            status: .completed, latestTurnIsComplete: true).turns
        XCTAssertEqual(turns.count, 240)
        let context = ConversationItemContext(harness: .claudeCode, workspaceURL: LongConversationFixture.workspace,
                                              actions: ConversationActions())
        let tracker = TranscriptReadingTracker()
        let list = ConversationRowList(
            rowIDs: turns.map(\.id), part: { _ in .whole }, row: {
                ConversationTurnHost(turn: turns[$0], context: context, handlers: .init(), renderState: renderState)
            }, renderState: renderState, scrollState: .constant(.init()), latestRequestID: nil, pendingRequestIDs: [],
            readingTracker: tracker, loadEarlier: nil, earlierKey: nil, onReturnToLatest: {},
            target: nil, scroller: ConversationRowListScroller())
        let assistiveReading = ConversationAssistiveReading.isOn
        ConversationAssistiveReading.isOn = { false }
        defer { ConversationAssistiveReading.isOn = assistiveReading }
        let controller = ConversationRowListController()
        defer { controller.dismantle() }
        controller.scrollView.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        controller.scrollView.layoutSubtreeIfNeeded()
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
            print("Initial 240-row viewport \(counter): \(count)")
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
