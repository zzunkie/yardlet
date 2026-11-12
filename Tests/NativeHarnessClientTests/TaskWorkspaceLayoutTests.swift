import XCTest
@testable import NativeHarnessClient

final class TaskWorkspaceLayoutTests: XCTestCase {
    func testExpandedSidePanelKeepsTheChatOffscreenWithoutChangingTerminalHeight() {
        let layout = TaskWorkspaceMetrics.resolve(size: CGSize(width: 1000, height: 700), trailing: true, terminal: true, preferredWidth: 420, preferredHeight: 240, expanded: true)
        XCTAssertFalse(layout.showsChat)
        XCTAssertEqual(layout.chatWidth, 0)
        XCTAssertEqual(layout.trailingWidth, 1000)
        XCTAssertEqual(layout.terminalHeight, 240)
    }

    func testCompactPanelKeepsChatOffscreenAndFitsTerminalWithinBounds() {
        let layout = TaskWorkspaceMetrics.resolve(size: CGSize(width: 519, height: 510), trailing: true, terminal: true, preferredWidth: 900, preferredHeight: 900)
        XCTAssertFalse(layout.showsChat)
        XCTAssertEqual(layout.chatWidth, 0)
        XCTAssertEqual(layout.trailingWidth, 519)
        XCTAssertEqual(layout.upperHeight + layout.terminalHeight + 6, 510)
        XCTAssertGreaterThanOrEqual(layout.upperHeight, 180)
    }

    /// Beside the panel the conversation keeps 560 and the panel the Codex app's 320. Where both do not
    /// fit, the panel floats over the area's edge at 320 and the conversation runs up to it, keeping
    /// 560 under its edge; below the Codex app's 320 + 352 the panel takes the conversation's place.
    func testThePanelLeavesTheConversationItsMinimumOrFloatsOverItsEdge() {
        func layout(_ width: CGFloat, preferred: CGFloat = 420) -> TaskWorkspaceMetrics {
            TaskWorkspaceMetrics.resolve(size: CGSize(width: width, height: 700), trailing: true, terminal: false,
                                         preferredWidth: preferred, preferredHeight: 240)
        }
        let wide = layout(1000, preferred: 900)
        XCTAssertEqual(wide.panelPlacement, .beside)
        XCTAssertEqual(wide.chatWidth, 560)
        XCTAssertEqual(wide.trailingWidth, 434)
        XCTAssertEqual(layout(1000, preferred: 100).trailingWidth, 320)
        // 320, the divider and 560.
        XCTAssertEqual(layout(886).panelPlacement, .beside)
        let floating = layout(885)
        XCTAssertEqual(floating.panelPlacement, .over)
        XCTAssertEqual(floating.trailingWidth, 320)
        XCTAssertEqual(floating.chatWidth, 565, "the conversation runs up to the floating panel")
        XCTAssertEqual(floating.conversationCover, 0)
        let under = layout(760)
        XCTAssertEqual(under.chatWidth, 560, "and keeps its minimum under the panel's edge")
        XCTAssertEqual(under.conversationCover, 120)
        // The Codex app's 320 + 352 and the divider.
        XCTAssertTrue(layout(678).showsChat)
        XCTAssertEqual(layout(677).panelPlacement, .inPlace)
        XCTAssertFalse(layout(677).showsChat)
        let closed = TaskWorkspaceMetrics.resolve(size: CGSize(width: 1000, height: 700), trailing: false, terminal: false, preferredWidth: 674, preferredHeight: 240)
        XCTAssertEqual(closed.chatWidth, 1000)
        XCTAssertEqual(closed.upperHeight, 700)
    }

    func testTallTerminalRetainsReadingRoomForReviewAndConversationAtEachInterfaceSize() {
        for scale in [0.94, 1.0, 1.08] {
            for trailing in [false, true] {
                let layout = TaskWorkspaceMetrics.resolve(
                    size: CGSize(width: 659, height: 650), trailing: trailing, terminal: true,
                    preferredWidth: 420, preferredHeight: 1000, interfaceScale: scale
                )
                XCTAssertEqual(layout.upperHeight, (trailing ? 320 : 280) * scale, accuracy: 0.001)
                XCTAssertGreaterThanOrEqual(layout.terminalHeight, 180)
                XCTAssertEqual(layout.upperHeight + layout.terminalHeight + 6, 650, accuracy: 0.001)
            }
        }
    }

    func testCompactExpandedPanelAndResizeUseTheSameHeightLimit() {
        let height: CGFloat = 538
        let resized = TaskWorkspaceMetrics.constrainedTerminalHeight(
            900, availableHeight: height, trailing: true, interfaceScale: 1.08
        )
        let layout = TaskWorkspaceMetrics.resolve(
            size: CGSize(width: 519, height: height), trailing: true, terminal: true,
            preferredWidth: 420, preferredHeight: resized, expanded: true, interfaceScale: 1.08
        )
        XCTAssertFalse(layout.showsChat)
        XCTAssertEqual(layout.terminalHeight, resized)
        XCTAssertEqual(layout.upperHeight, 345.6, accuracy: 0.001)
        let reduced = TaskWorkspaceMetrics.constrainedTerminalHeight(
            resized - 30, availableHeight: height, trailing: true, interfaceScale: 1.08
        )
        XCTAssertEqual(reduced, 160, "the Codex app's bottom panel keeps 160")
    }

    func testSmallHeightTransitionAndClosingTerminalStayWithinAvailableBounds() {
        for height: CGFloat in [100, 300, 400, 538] {
            let layout = TaskWorkspaceMetrics.resolve(
                size: CGSize(width: 519, height: height), trailing: true, terminal: true,
                preferredWidth: 420, preferredHeight: 1000, interfaceScale: 1.08
            )
            XCTAssertGreaterThanOrEqual(layout.upperHeight, 0)
            XCTAssertGreaterThanOrEqual(layout.terminalHeight, 0)
            XCTAssertEqual(layout.upperHeight + layout.terminalHeight + 6, height, accuracy: 0.001)
            let closed = TaskWorkspaceMetrics.resolve(
                size: CGSize(width: 519, height: height), trailing: true, terminal: false,
                preferredWidth: 420, preferredHeight: 1000, interfaceScale: 1.08
            )
            XCTAssertEqual(closed.upperHeight, height)
            XCTAssertEqual(closed.terminalHeight, 0)
        }
    }
}
