import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// A trackpad's vertical scroll with the pointer over a code block or a table, which scroll sideways
/// in a scroll view of their own, scrolls the conversation: the inner scroll view takes only the
/// sideways part. Both conversation renderers (the stack and the table,
/// `ConversationTableTimelineSetting`) are checked by whichever this run draws.
@MainActor
final class ConversationScrollOverCodeBlockTests: XCTestCase {
    private var outerScroll: NSScrollView?

    func testScrollingOverACodeBlockScrollsTheConversation() throws {
        let entries = LongConversationFixture.claude(turns: 8, seed: "scroll-over-code", links: true)
        let timeline = ConversationTimeline(
            source: .transcript(entries: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true)
        )
        let host = NSHostingView(rootView: timeline.frame(width: 900, height: 700))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        spin(0.6)

        let scrolls = allScrollViews(in: host)
        let outer = try XCTUnwrap(scrolls.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        // A scroll view applies a scroll at the display's next frame: with the display asleep it takes
        // none, wherever the pointer is.
        let start = outer.contentView.bounds.minY
        for phase: CGScrollPhase in [.began, .changed, .ended] { send(phase: phase, delta: phase == .changed ? 20 : 0, to: outer) }
        spin(0.2)
        if outer.contentView.bounds.minY == start { throw XCTSkip("the window takes no scroll here (no display frames)") }
        // Go up until an inner scroll view (a code block's or a table's) is in the middle of the view.
        var inner: NSScrollView?
        for _ in 0..<80 {
            let visible = outer.convert(outer.bounds, to: nil)
            inner = allScrollViews(in: outer.documentView ?? outer).first { candidate in
                guard candidate !== outer, candidate.window != nil else { return false }
                let frame = candidate.convert(candidate.bounds, to: nil)
                return frame.height >= 40 && frame.midY > visible.minY + 120 && frame.midY < visible.maxY - 120
            }
            if inner != nil { break }
            let clip = outer.contentView
            clip.scroll(to: NSPoint(x: 0, y: max(0, clip.bounds.minY - 150)))
            outer.reflectScrolledClipView(clip)
            spin(0.05)
        }
        let target = try XCTUnwrap(inner, "a code block or table is in view")
        outerScroll = outer
        let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        XCTAssertTrue(window.contentView?.hitTest(point)?.isDescendant(of: target) ?? false, "the pointer is over the code block")

        let before = outer.contentView.bounds.minY
        send(phase: .began, delta: 0, at: point, in: window)
        for _ in 0..<10 {
            send(phase: .changed, delta: 20, at: point, in: window)
            spin(0.016)
        }
        send(phase: .ended, delta: 0, at: point, in: window)
        spin(0.3)
        let moved = before - outer.contentView.bounds.minY
        XCTAssertGreaterThan(moved, 100, "the conversation scrolled up under the pointer over a code block")
    }

    private func send(phase: CGScrollPhase, delta: Int32, at point: NSPoint, in window: NSWindow) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: delta, wheel2: 0, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(delta))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(delta))
        let screen = window.convertPoint(toScreen: point)
        // CGEvent locations count from the top of the main display.
        let height = NSScreen.screens.first?.frame.height ?? 0
        event.location = CGPoint(x: screen.x, y: height - screen.y)
        guard let wheel = NSEvent(cgEvent: event) else { return }
        // As the application hands it in: the table's event monitor sees it before the window does.
        if let table = outerScroll as? ConversationTableScrollView, !table.handsOn(wheel) { return }
        window.sendEvent(wheel)
    }

    /// A trackpad's scroll handed to `scroll` itself.
    private func send(phase: CGScrollPhase, delta: Int32, to scroll: NSScrollView) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: delta, wheel2: 0, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        if let wheel = NSEvent(cgEvent: event) { scroll.scrollWheel(with: wheel) }
        spin(0.016)
    }

    private func allScrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(allScrollViews)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
