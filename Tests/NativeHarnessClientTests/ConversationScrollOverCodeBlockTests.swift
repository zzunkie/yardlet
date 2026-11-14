import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// A trackpad's vertical scroll with the pointer over a table too wide for the conversation (or a code
/// block outside a message's text), which scrolls sideways in a scroll view of its own, scrolls the
/// conversation: the inner scroll view takes only the sideways part. Both conversation renderers (the stack and the row list, `ConversationRowListSwitch`)
/// are checked by whichever this run draws. The window is clear, takes no clicks and stands below and
/// left of every display, as the performance bench's do (`QABackground.moveOffScreen`), and is never
/// made active; the events go through it as the application hands them on.
@MainActor
final class ConversationScrollOverCodeBlockTests: XCTestCase {
    private var outerScroll: NSScrollView?

    func testScrollingOverACodeBlockScrollsTheConversation() throws {
        // A table too wide for the conversation, in the middle of it: a message's code blocks wrap in its
        // text, and a table that fits draws without a scroll view.
        var entries = LongConversationFixture.claude(turns: 8, seed: "scroll-over-code", links: true)
        let columns = 1...10
        let table = "| " + columns.map { "Column \($0)" }.joined(separator: " | ") + " |\n|"
            + String(repeating: "---|", count: columns.count) + "\n"
            + (1...3).map { row in "| " + columns.map { "a value wide enough to scroll, \(row).\($0)" }.joined(separator: " | ") + " |" }
                .joined(separator: "\n")
        let middle = try XCTUnwrap(entries.indices.filter {
            if case .user = entries[$0].content { return true } else { return false }
        }.dropFirst(4).first)
        entries.insert(contentsOf: [
            TranscriptEntry(content: .user(text: "Compare the cases in one table")),
            TranscriptEntry(content: .assistant(text: "Here they are.\n\n" + table, isStreaming: false))
        ], at: middle)
        let host = WindowlessRender.Host(
            ConversationTimeline(
                source: .transcript(entries: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true)
            )
            .frame(width: 900, height: 700),
            size: NSSize(width: 900, height: 700), titled: true)
        defer { host.window.close() }
        // A scroll view applies a trackpad's scroll at its display's next frame, which a window gets
        // only with a part of it on a display: AppKit keeps a corner of a titled window on one. The
        // window is clear before it is ordered in.
        host.window.alphaValue = 0
        host.window.ignoresMouseEvents = true
        host.window.collectionBehavior.formUnion([.transient, .ignoresCycle])
        let screens = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        host.window.setFrameOrigin(NSPoint(x: screens.minX - 5_000, y: screens.minY - 5_000))
        host.window.orderFrontRegardless()
        QABackground.moveOffScreen(host.window)
        var outer: NSScrollView?
        host.settle {
            outer = Self.scrollViews(in: host.hosting).max {
                ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
            }
            return (outer?.documentView?.frame.height ?? 0) > 2 * 700
        }
        let conversation = try XCTUnwrap(outer)
        outerScroll = conversation
        // With the display asleep there are no display frames, and the window takes no scroll,
        // wherever the pointer is.
        let start = conversation.contentView.bounds.minY
        for phase: CGScrollPhase in [.began, .changed, .ended] {
            send(phase: phase, delta: phase == .changed ? 20 : 0, to: conversation)
            host.settle(passes: 1, interval: 0.016)
        }
        host.settle(passes: 6, interval: 0.02)
        if conversation.contentView.bounds.minY == start {
            throw XCTSkip("the window takes no scroll here (no display frames)")
        }

        // Go up until an inner scroll view (a code block's or a table's) is in the middle of the view. A
        // row that comes into view is laid out over the next passes, slower on CI, so each step waits a few.
        // The steps are not the reader's scroll, which has ended: they stand for a move made for the
        // reader (find's match, an accessibility scroll), which stops following the latest output as the
        // reader's own does, so the rows laid out on the way do not take the view back to the end.
        host.settle(passes: 10, interval: 0.05)
        var inner: NSScrollView?
        for _ in 0..<160 {
            let visible = conversation.convert(conversation.bounds, to: nil)
            inner = Self.scrollViews(in: conversation.documentView ?? conversation).first { candidate in
                guard candidate !== conversation, candidate.window != nil else { return false }
                let frame = candidate.convert(candidate.bounds, to: nil)
                return frame.height >= 40 && frame.midY > visible.minY + 120 && frame.midY < visible.maxY - 120
            }
            if inner != nil { break }
            let clip = conversation.contentView
            guard clip.bounds.minY > 0 else { break }
            clip.scroll(to: NSPoint(x: 0, y: max(0, clip.bounds.minY - 100)))
            conversation.reflectScrolledClipView(clip)
            host.settle(passes: 3, interval: 0.03)
        }
        let target = try XCTUnwrap(inner, "a code block or table is in view")
        let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        XCTAssertTrue(host.hosting.hitTest(point)?.isDescendant(of: target) ?? false, "the pointer is over the code block")

        let before = conversation.contentView.bounds.minY
        send(phase: .began, delta: 0, at: point, in: host.window)
        for _ in 0..<10 {
            send(phase: .changed, delta: 20, at: point, in: host.window)
            host.settle(passes: 1, interval: 0.016)
        }
        send(phase: .ended, delta: 0, at: point, in: host.window)
        host.settle(until: { before - conversation.contentView.bounds.minY > 100 })
        XCTAssertGreaterThan(before - conversation.contentView.bounds.minY, 100,
                             "the conversation scrolled up under the pointer over a code block")
    }

    /// A trackpad's scroll at `point` in `window`, as the application hands it on: the row list's
    /// event monitor sees it before the window does.
    private func send(phase: CGScrollPhase, delta: Int32, at point: NSPoint, in window: NSWindow) {
        guard let wheel = Self.wheel(phase: phase, delta: delta, at: point) else { return }
        if let list = outerScroll as? ConversationRowListScrollView, !list.handsOn(wheel) { return }
        window.sendEvent(wheel)
    }

    /// A trackpad's scroll handed to `scroll` itself.
    private func send(phase: CGScrollPhase, delta: Int32, to scroll: NSScrollView) {
        let center = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        guard scroll.window != nil,
              let wheel = Self.wheel(phase: phase, delta: delta, at: center) else { return }
        scroll.scrollWheel(with: wheel)
    }

    /// A continuous scroll wheel event of `delta` points (positive moves toward the top) at `point` in the
    /// window. An event made here belongs to no window, and reads its location in screen coordinates as
    /// the window it is handed to reads it in its own, so it is made at the window's point.
    private static func wheel(phase: CGScrollPhase, delta: Int32, at point: NSPoint) -> NSEvent? {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: delta, wheel2: 0, wheel3: 0) else { return nil }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(delta))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(delta))
        // CGEvent locations count down from the top of the main display.
        let height = NSScreen.screens.first?.frame.height ?? 0
        event.location = CGPoint(x: point.x, y: height - point.y)
        return NSEvent(cgEvent: event)
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }
}
