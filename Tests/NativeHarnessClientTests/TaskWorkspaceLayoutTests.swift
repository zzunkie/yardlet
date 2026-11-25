import AppKit
import SwiftUI
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

    /// In an area too narrow to keep the conversation in view, the panel floats as a sheet inset from the
    /// area's edges, the conversation's leading edge showing behind it.
    func testCompactPanelFloatsAsASheetAndFitsTerminalWithinBounds() {
        let layout = TaskWorkspaceMetrics.resolve(size: CGSize(width: 519, height: 510), trailing: true, terminal: true, preferredWidth: 900, preferredHeight: 900)
        XCTAssertEqual(layout.panelPlacement, .sheet)
        XCTAssertTrue(layout.showsChat)
        XCTAssertEqual(layout.chatWidth, 519)
        XCTAssertEqual(layout.panelInset, 8)
        XCTAssertEqual(layout.trailingWidth, 519 - 48 - 8)
        XCTAssertEqual(layout.conversationCover, 0)
        XCTAssertEqual(layout.railWidth, 0)
        XCTAssertEqual(layout.upperHeight + layout.terminalHeight + 6, 510)
        XCTAssertGreaterThanOrEqual(layout.upperHeight, 180)
    }

    /// Beside the panel the conversation keeps 560 and the panel the Codex app's 320. Where both do not
    /// fit, the panel floats 8 in from the area's edge at 320 and the conversation runs up to it, keeping
    /// 560 under its edge; below the Codex app's 320 + 352 the panel floats as a sheet over it, and only
    /// the expand button puts the panel in the conversation's place.
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
        XCTAssertEqual(floating.panelInset, 8)
        XCTAssertEqual(floating.chatWidth, 560, "the conversation runs up to the floating panel")
        XCTAssertEqual(floating.conversationCover, 3)
        let under = layout(760)
        XCTAssertEqual(under.chatWidth, 560, "and keeps its minimum under the panel's edge")
        XCTAssertEqual(under.conversationCover, 128)
        // The Codex app's 320 + 352 and the divider.
        XCTAssertEqual(layout(678).panelPlacement, .over)
        XCTAssertEqual(layout(677).panelPlacement, .sheet)
        XCTAssertTrue(layout(677).showsChat)
        let expanded = TaskWorkspaceMetrics.resolve(size: CGSize(width: 677, height: 700), trailing: true, terminal: false,
                                                    preferredWidth: 420, preferredHeight: 240, expanded: true)
        XCTAssertEqual(expanded.panelPlacement, .inPlace)
        XCTAssertFalse(expanded.showsChat)
        XCTAssertEqual(expanded.panelInset, 0)
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

    /// The panel in the conversation's place (expanded) or as a sheet over a narrow area leaves the conversation the
    /// width it showed at: no message is laid out at another width as it hides and shows, and a turn is measured again
    /// only when it is drawn again (as it is disabled and enabled), however long the conversation.
    /// `NHC_HIDDEN_CONVERSATION_TURNS` sets its length; the main thread's time for each step is printed.
    @MainActor
    func testTheHiddenConversationKeepsTheWidthItShowedAt() async throws {
        let turns = Int(ProcessInfo.processInfo.environment["NHC_HIDDEN_CONVERSATION_TURNS"] ?? "") ?? 40
        // Scrollers over the content, as with a trackpad. A scroller that takes room (a mouse, or a Mac without
        // a display, as on CI) leaves a disabled scroll view, and its messages are laid out at the width it gives up.
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(arguments.merging(["AppleShowScrollBars": "WhenScrolling"]) { $1 },
                                                forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        defer {
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        }
        let area = HiddenConversationArea()
        let conversation = ConversationTimeline(
            source: .transcript(entries: LongConversationFixture.claude(turns: turns, seed: "hidden-conversation"),
                                harness: .claudeCode, status: .ready, latestTurnIsComplete: true),
            readingPosition: TranscriptReadingPosition(), actions: ConversationActions(),
            renderState: ConversationRenderState())
        let host = WindowlessRender.Host(HiddenConversationWorkspace(area: area, conversation: conversation),
                                         size: NSSize(width: 1200, height: 800))
        defer { host.close(); ViewBodyCensus.isEnabled = false; ViewBodyCensus.reset() }
        await host.settle(until: {
            (BlankFrameProbe.conversationScrollView(in: host.hosting)?.documentView?.bounds.height ?? 0) > 800
        })
        func proseLayouts() -> Int {
            TranscriptProseRenderingTests.containers(in: host.hosting).reduce(0) { $0 + $1.newWidthLayouts }
        }
        // Laid out once several passes in a row lay nothing out: on a slow Mac the conversation still draws turns
        // into its window after it first fills the view.
        ViewBodyCensus.isEnabled = true
        func settled() async {
            var quiet = 0, last = (-1, -1)
            await host.settle(until: {
                let now = (ViewBodyCensus[.conversationRowLaidOut], proseLayouts())
                quiet = now == last ? quiet + 1 : 0
                last = now
                return quiet >= 5
            })
        }
        await settled()
        let proseBefore = proseLayouts()
        ViewBodyCensus.reset()
        var milliseconds: [Int] = []
        func step(_ change: () -> Void) {
            var start = timespec(), end = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &start)
            change()
            host.settle(passes: 4, interval: 0.01)
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &end)
            milliseconds.append((end.tv_sec - start.tv_sec) * 1_000 + (end.tv_nsec - start.tv_nsec) / 1_000_000)
        }
        for _ in 0..<3 {
            step { area.preferences.isExpanded = true }
            step { area.preferences.isExpanded = false }
        }
        // Narrower than the conversation and the panel side by side.
        step { host.window.setContentSize(NSSize(width: 600, height: 800)) }
        step { host.window.setContentSize(NSSize(width: 1200, height: 800)) }
        await settled()
        let prose = proseLayouts() - proseBefore
        let measured = ViewBodyCensus[.conversationRowLaidOut], drawn = ViewBodyCensus[.conversationTurn]
        print("[hidden-conversation] turns=\(turns) proseLayouts=\(prose) turnsMeasured=\(measured) turnsDrawn=\(drawn) "
              + "mainCPUMilliseconds=\(milliseconds)")
        XCTAssertEqual(prose, 0)
        XCTAssertLessThanOrEqual(measured, drawn)
    }

    /// The turns and what the conversation is worked from share one column: at most 768 pt wide and centered,
    /// with the 32 pt gutter inside each side (docs/DESIGN_SYSTEM.md). Drawn, the turns' outer edges and the
    /// composer's are the same at every width, and under a floating side panel, which the composer keeps clear
    /// of, their leading edges are.
    @MainActor
    func testTheConversationAndItsComposerShareOneColumn() throws {
        XCTAssertEqual(ParityTheme.conversationColumnWidth(in: 1_100), 704)
        XCTAssertEqual(ParityTheme.conversationColumnWidth(in: 816), 704)
        XCTAssertEqual(ParityTheme.conversationColumnWidth(in: 790), 704)
        XCTAssertEqual(ParityTheme.conversationColumnWidth(in: 600), 536)
        XCTAssertEqual(ParityTheme.conversationColumnWidth(in: 50), 0)

        // A sent message stands at the column's trailing edge and a code block spans the column.
        let entries = [
            TranscriptEntry(content: .user(text: "Make the parser accept trailing commas.")),
            TranscriptEntry(content: .assistant(text: "Done.\n\n```swift\nlet values = [1, 2, 3,]\n```", isStreaming: false)),
            TranscriptEntry(content: .user(text: "Thanks.")),
            TranscriptEntry(content: .assistant(text: "You're welcome.", isStreaming: false))
        ]
        let conversationHeight: CGFloat = 520
        for (width, cover) in [(1_100.0, 0.0), (790.0, 0.0), (600.0, 0.0), (620.0, 180.0)] {
            let draft = TaskComposerDraft()
            draft.text = "Also cover nested arrays"
            let size = NSSize(width: width, height: conversationHeight + 160)
            let capture = try WindowlessRender.hosted(
                VStack(spacing: 0) {
                    ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .ready,
                                                             latestTurnIsComplete: true))
                        .frame(height: conversationHeight)
                    PromptComposer(harness: .claudeCode, composerDraft: draft, isRunning: false).clearOfFloatingPanel()
                    Spacer(minLength: 0)
                }
                .environment(\.conversationTrailingCover, cover)
                .environment(\.colorScheme, .dark)
                .background(ParityTheme.canvas)
                .frame(width: size.width, height: size.height),
                size: size, appearance: .dark, passes: 10
            )
            let bitmap = capture.bitmap
            let scale = capture.backingScaleFactor
            let canvas = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide - 2, y: 2))
            func drawn(_ x: Int, _ y: Int) -> Bool {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let base = canvas.usingColorSpace(.deviceRGB) else { return false }
                return abs(color.redComponent - base.redComponent) + abs(color.greenComponent - base.greenComponent)
                    + abs(color.blueComponent - base.blueComponent) > 0.12
            }
            /// The outermost drawn points across `rows` (in points from the top), right of the turn rail.
            func edges(_ rows: StrideThrough<CGFloat>) -> (CGFloat, CGFloat)? {
                var left = Int.max, right = Int.min
                for row in rows {
                    let y = Int(row * scale)
                    for x in Int(26 * scale)..<bitmap.pixelsWide where drawn(x, y) {
                        left = min(left, x)
                        right = max(right, x)
                    }
                }
                return left <= right ? (CGFloat(left) / scale, CGFloat(right + 1) / scale) : nil
            }
            let turns = try XCTUnwrap(edges(stride(from: 12, through: conversationHeight - 12, by: 1)), "\(width)")
            let composer = try XCTUnwrap(edges(stride(from: conversationHeight + 40, through: conversationHeight + 40, by: 1)),
                                         "\(width)")
            let column = ParityTheme.conversationColumnWidth(in: width)
            let leading = ((width - column) / 2).rounded(.down)
            let clear = ParityTheme.conversationColumnWidth(in: width - cover)
            XCTAssertEqual(turns.0, leading, accuracy: 0.5, "turns' leading edge at \(width)")
            XCTAssertEqual(composer.0, leading, accuracy: 0.5, "composer's leading edge at \(width)")
            if cover == 0 {
                XCTAssertEqual(turns.1, leading + column, accuracy: 0.5, "turns' trailing edge at \(width)")
                XCTAssertEqual(composer.1, leading + column, accuracy: 0.5, "composer's trailing edge at \(width)")
            } else {
                XCTAssertEqual(composer.1, leading + clear, accuracy: 0.5, "the composer stops at the panel")
            }
        }
    }
}

@MainActor @Observable
private final class HiddenConversationArea {
    var preferences = TaskWorkspacePreferences()
}

private struct HiddenConversationWorkspace: View {
    @Bindable var area: HiddenConversationArea
    let conversation: ConversationTimeline

    var body: some View {
        TaskWorkspaceLayout(showsTrailing: true, showsTerminal: false, preferences: $area.preferences,
                            onReturnToChat: {}, chat: { conversation }, rail: { EmptyView() },
                            trailing: { Color.gray }, bottom: { EmptyView() })
    }
}
