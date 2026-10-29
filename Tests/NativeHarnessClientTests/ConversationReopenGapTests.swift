import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// A task opened again after a while shows no empty band between the turn before the person's latest
/// message and that message (2026-10-23: a user reported a wide gap there when coming back to a
/// session after a while).
///
/// A turn built anew (its hosting let go after four other tasks, or never made) is measured outside
/// the window: SwiftUI asks each text in it for its size at the turn's width and at the narrowest and
/// widest it could take (291, 0 and 2397 in a recorded open), and the text measured with the layout it
/// draws, so it was left laid out at the last width asked. Shown at its own width, its container came
/// back to that width and TextKit 2 laid out again only the lines in view, placed after lines still laid
/// out for the other width: the lines drew higher than the frame, whose height was the text's at its
/// own width, and the bottom of the frame, above the next request, stayed empty. A window resized while
/// the task was hidden did the same. Now the text is laid out whole at its own width before it draws.
@MainActor
final class ConversationReopenGapTests: XCTestCase {
    static let answer = (0..<5).map { _ in
        "The parser returned early on an empty input, so the lexer never saw the end token. "
            + String(repeating: "Some words that wrap across the line as an answer does. ", count: 5)
    }.joined(separator: "\n\n") + "\n\n- Fixed the early return\n- Added a test\n- Ran the suite"

    private func text(_ source: String = answer) -> TranscriptProseContainerView {
        let view = TranscriptProseContainerView()
        let blocks = TranscriptMarkdownDocument(source).blocks.enumerated().map {
            TranscriptProseBlock(block: $1, path: [$0])
        }
        view.update(blocks: blocks, style: TranscriptProseStyle())
        return view
    }

    /// A message in a hosting view of its own, measured outside the window and then shown, as a turn
    /// built anew is (`ConversationTurnHosting`): SwiftUI asks each text for its size at the turn's
    /// width and at the narrowest and widest it could take, then places it. Every text draws laid out
    /// at the width it shows at, to the bottom of its frame.
    func testAMessageMeasuredOutsideTheWindowDrawsItsTextsAtTheirOwnWidth() throws {
        let controller = NSHostingController(rootView: AnyView(
            ConversationAgentMessage(itemID: "answer", harness: .claudeCode, text: Self.answer, isCommentary: false,
                                     isStreaming: false)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        ))
        controller.sizingOptions = []
        let height = ceil(controller.sizeThatFits(in: CGSize(width: 291, height: CGFloat.greatestFiniteMagnitude)).height)
        // In a conversation scrolled to its end, the message's last lines in view.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 291, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 291, height: 300))
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 291, height: height))
        scroll.documentView = content
        window.contentView = scroll
        content.addSubview(controller.view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 291, height: height)
        content.scroll(NSPoint(x: 0, y: height - 300))
        for _ in 0..<4 {
            scroll.layoutSubtreeIfNeeded()
            scroll.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let texts = TranscriptProseRenderingTests.proseTextViews(in: content).compactMap {
            $0.superview as? TranscriptProseContainerView
        }
        XCTAssertFalse(texts.isEmpty)
        for text in texts {
            XCTAssertEqual(text.laidOutHeight, ceil(text.bounds.height), "The text draws laid out at the width it shows at")
        }
        // Drawn: the message's last line sits at the bottom of the view, not above an empty band.
        let bitmap = try WindowlessRender.capture(scroll)
        let scale = CGFloat(bitmap.pixelsHigh) / scroll.bounds.height
        let lowest = (0..<bitmap.pixelsHigh).reversed().first { y in
            stride(from: 0, to: bitmap.pixelsWide, by: 2).contains { x in
                (bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) < 0.5
            }
        } ?? 0
        // From the last drawn line to the bottom of the message's text, where its frame ends.
        let last = try XCTUnwrap(texts.max { $0.convert($0.bounds, to: scroll).maxY < $1.convert($1.bounds, to: scroll).maxY })
        let textBottom = last.convert(last.bounds, to: scroll).maxY
        let band = textBottom - CGFloat(lowest) / scale
        print(String(format: "[reopen-gap] unit: %.0f pt between the last drawn line and the bottom of its text", band))
        XCTAssertLessThanOrEqual(band, 12, "The last line is drawn at the bottom of its text")
        try WindowlessRender.writePNG(bitmap, to: WindowlessRender.directory("reopen-gap").appending(path: "unit-message-end.png"))
    }

    /// A text shown at its end in a scroll view, then measured at a wider window's width while it
    /// still shows at its own (a task's turns kept while the window was resized), then moved there: it
    /// is laid out at the width it shows at each time.
    func testATextMeasuredAtTheNextWidthIsLaidOutAtTheWidthItShowsAt() {
        let text = text()
        let narrow = text.size(forWidth: 291).height
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 700, height: narrow))
        scroll.documentView = content
        window.contentView = scroll
        content.addSubview(text)
        text.frame = NSRect(x: 0, y: 0, width: 291, height: narrow)
        func settle() {
            for _ in 0..<3 {
                scroll.layoutSubtreeIfNeeded()
                scroll.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
        content.scroll(NSPoint(x: 0, y: narrow - 300))
        settle()
        let wide = text.size(forWidth: 671).height
        XCTAssertEqual(text.size(forWidth: 291).height, narrow)
        settle()
        XCTAssertEqual(text.laidOutHeight, narrow, "Measured at the next width, still laid out at its own")
        content.frame.size.height = wide
        text.frame.size = NSSize(width: 671, height: wide)
        content.scroll(NSPoint(x: 0, y: wide - 300))
        settle()
        XCTAssertEqual(text.laidOutHeight, wide, "Moved to the next width, laid out there")
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}

/// The same in the whole window, as the person opens tasks: a Claude Code task, a saved one whose first
/// read begins inside a turn, a Codex thread and a saved one read through the App Server, each opened
/// the first time, again after four other tasks let its turns go, again with its turns kept, and after
/// the window was resized, light and dark. Each check reads two things: every text in the
/// conversation is laid out at the height its frame takes, and in the drawn window the space between
/// the previous turn's last line and the latest request is the turn spacing, not an empty band.
///
/// Images go to `.build/reopen-gap/`.
@MainActor
final class ConversationReopenGapWindowTests: XCTestCase {
    typealias Window = ConversationBlankFrameTests.Window

    /// The most the drawn space above the latest request may be: the turns' spacing (15) and the
    /// space a turn leaves under its last line, with room for a line's descent.
    static let largestSpaceAboveTheRequest: CGFloat = 64
    /// The most the drawn space under the last line may be at the conversation's end: the space a
    /// turn leaves under its last line and the conversation's bottom padding (28).
    static let largestSpaceBelowTheLastLine: CGFloat = 80

    struct Check: CustomStringConvertible {
        let name: String
        /// Texts laid out at a height other than their frame's: "laid out / frame".
        let misplacedTexts: [String]
        let textCount: Int
        /// The drawn space between the previous turn's last line and the latest request, in points;
        /// nil when the latest request is above the view (a long latest turn).
        let spaceAboveRequest: CGFloat?
        /// The drawn space under the conversation's last line, at its end.
        let spaceBelowLastLine: CGFloat

        var description: String {
            String(format: "%@: space above the latest request %@ pt, under the last line %.0f pt, %d of %d texts laid out at another height %@",
                   name, spaceAboveRequest.map { String(format: "%.0f", $0) } ?? "-", spaceBelowLastLine,
                   misplacedTexts.count, textCount, misplacedTexts.prefix(4).joined(separator: ", "))
        }
    }

    func testOpeningTasksAgainLeavesNoGapAboveTheLatestRequestInLight() throws {
        try run(.light, everyWay: true)
    }

    func testOpeningTasksAgainLeavesNoGapAboveTheLatestRequestInDark() throws {
        try run(.dark, everyWay: false)
    }

    private func run(_ appearance: WindowlessRender.Appearance, everyWay: Bool) throws {
        // Each task's latest turn is short, so the turn before it shows above the latest request.
        let window = try ConversationBlankFrameTests.makeWindow([
            .claude("Claude", turns: 18), .savedClaude("Saved", turns: 214), .codex("Codex", turns: 60),
            .savedCodex("SavedCodex", turns: 60, cached: false),
            .claude("B", turns: 2), .claude("C", turns: 2), .claude("D", turns: 2), .claude("E", turns: 2)
        ], for: self)
        defer { window.close() }
        window.host.window.appearance = NSAppearance(named: appearance.appKitName)
        let subjects = [(0, "claude"), (1, "saved-claude"), (2, "codex"), (3, "saved-codex")]
        let others = [4, 5, 6, 7]
        var checks: [Check] = []
        func check(_ index: Int, _ name: String) throws {
            window.show(index)
            window.host.settle(passes: 20)
            checks.append(try self.check(window, name: "\(name)-\(appearance.suffix)"))
        }
        window.show(others[0])
        for (index, name) in subjects { try check(index, "\(name)-first") }
        for index in others { window.show(index) }
        for (index, name) in subjects {
            try check(index, "\(name)-after-four-others")
            for other in others { window.show(other) }
        }
        guard everyWay else { return try report(checks) }
        // Again while its turns are kept (one other task between).
        for (index, name) in subjects {
            window.show(others[0])
            try check(index, "\(name)-kept")
        }
        // A wider window, its turns let go.
        resize(window, to: NSSize(width: 1280, height: 800))
        for (index, name) in subjects {
            for other in others { window.show(other) }
            try check(index, "\(name)-wider")
        }
        // Shown wide, hidden, the window made narrower, shown again with its turns kept.
        for (index, name) in subjects {
            resize(window, to: NSSize(width: 1280, height: 800))
            window.show(index)
            window.show(others[0])
            resize(window, to: ConversationBlankFrameTests.size)
            try check(index, "\(name)-narrower-kept")
        }
        try report(checks)
    }

    /// A Claude Code task whose first read began inside the turn before its latest one: that turn's
    /// end (its last calls and answer, no request) shows right above the latest request, built anew.
    func testATurnTheFirstReadBeganInsideEndsRightAboveTheLatestRequest() throws {
        // Turns 2 and 3 of a conversation; the read began after turn 2's request and thinking.
        let entries = Array(LongConversationFixture.claude(turns: 4).dropFirst(34 + 7 + 2))
        guard case .user = entries[5].content else { return XCTFail("Turn 3 begins with its request") }
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(
                TaskConversationView(harness: .claudeCode, workspaceURL: LongConversationFixture.workspace,
                                     entries: entries, sessionStatus: .ready, latestTurnIsComplete: true,
                                     renderState: ConversationRenderState())
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: 640, height: 600)
                    .background(ParityTheme.canvas),
                size: NSSize(width: 640, height: 600), appearance: appearance)
            defer { host.close() }
            host.settle(passes: 20)
            // The conversation: the largest scroll view.
            let scroll = try XCTUnwrap(Self.all(host.hosting).compactMap { $0 as? NSScrollView }
                .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
            let check = try Self.check(scroll, in: host.hosting, capture: host.capture(),
                                       name: "head-turn-\(appearance.suffix)")
            print("[reopen-gap] \(check)")
            XCTAssertEqual(check.misplacedTexts, [], check.name)
            let space = try XCTUnwrap(check.spaceAboveRequest, "\(check.name): the latest request is in view")
            XCTAssertLessThanOrEqual(space, Self.largestSpaceAboveTheRequest, "\(check)")
        }
    }

    /// What opening a task whose turns were let go costs (four other tasks opened since): every turn
    /// the window draws is built and measured anew. Run with `NHC_PERF_BENCH=1`; it prints the numbers
    /// and checks nothing else.
    func testBenchmarkOpeningATaskWhoseTurnsWereLetGo() throws {
        guard ProcessInfo.processInfo.environment["NHC_PERF_BENCH"] == "1" else {
            throw XCTSkip("Set NHC_PERF_BENCH=1 to run the benchmark")
        }
        let window = try ConversationBlankFrameTests.makeWindow([
            .claude("Middling", turns: 20), .claude("Long", turns: 300),
            .claude("B", turns: 2), .claude("C", turns: 2), .claude("D", turns: 2), .claude("E", turns: 2)
        ], for: self)
        defer { window.close() }
        var lines: [String] = []
        for round in 0..<4 {
            for (index, name) in [(0, "20 turns"), (1, "300 turns")] {
                for other in 2...5 { window.show(other) }
                let cost = window.switchCost(to: index)
                if round > 0 {
                    lines.append("\(name): \(cost)")
                    cost.record("reopen-\(name.replacingOccurrences(of: " ", with: "-"))-let-go")
                }
            }
        }
        for line in lines { print("[reopen-cost] \(line)") }
    }

    private func resize(_ window: Window, to size: NSSize) {
        guard window.host.window.contentView?.frame.size != size else { return }
        window.host.window.setContentSize(size)
        window.host.settle(passes: 10)
    }

    private func report(_ checks: [Check]) throws {
        for check in checks { print("[reopen-gap] \(check)") }
        for check in checks {
            XCTAssertEqual(check.misplacedTexts, [], "\(check.name): every text is laid out at the height it takes")
            if let space = check.spaceAboveRequest {
                XCTAssertLessThanOrEqual(space, Self.largestSpaceAboveTheRequest, "\(check.name): \(check)")
            }
            XCTAssertLessThanOrEqual(check.spaceBelowLastLine, Self.largestSpaceBelowTheLastLine, "\(check.name): \(check)")
        }
        // The fixtures' latest turns are short: the latest request shows in most opens (a saved Codex
        // thread reopened reads the fake App Server's next page, whose latest turn is long).
        XCTAssertGreaterThan(checks.filter { $0.spaceAboveRequest != nil }.count, checks.count / 2)
    }

    // MARK: - Reading the window

    private func check(_ window: Window, name: String) throws -> Check {
        let scroll = try XCTUnwrap(BlankFrameProbe.conversationScrollView(in: window.host.hosting, minX: SidebarWidth.minimum))
        return try Self.check(scroll, in: window.host.hosting, capture: window.host.capture(), name: name)
    }

    static func check(_ scroll: NSScrollView, in root: NSView, capture: WindowlessRender.Capture, name: String) throws -> Check {
        let document = try XCTUnwrap(scroll.documentView)
        let texts = all(document).compactMap { $0 as? TranscriptProseContainerView }
            .filter { $0.window != nil && $0.bounds.height > 0 }
        let misplaced = texts.filter { abs($0.laidOutHeight - ceil($0.bounds.height)) > 1 }.map {
            String(format: "%.0f/%.0f", $0.laidOutHeight, $0.bounds.height)
        }
        if let directory = try? WindowlessRender.directory("reopen-gap") {
            try WindowlessRender.writePNG(capture.bitmap, to: directory.appending(path: "\(name).png"))
        }
        return Check(name: name, misplacedTexts: misplaced, textCount: texts.count,
                     spaceAboveRequest: spaceAboveLatestRequest(scroll: scroll, document: document, in: root,
                                                                capture: capture),
                     spaceBelowLastLine: spaceBelowLastLine(scroll: scroll, in: root, capture: capture))
    }

    /// From the conversation's last drawn line down to the bottom of its view.
    private static func spaceBelowLastLine(scroll: NSScrollView, in root: NSView, capture: WindowlessRender.Capture) -> CGFloat {
        let column = scroll.convert(scroll.bounds, to: root)
        let scale = capture.backingScaleFactor
        let drawn = drawnRows(in: capture.bitmap, column: column, scale: scale)
        var row = Int(column.maxY * scale) - 1
        while row > Int(column.minY * scale), !drawn(row) { row -= 1 }
        return (column.maxY * scale - CGFloat(row)) / scale
    }

    /// Whether a row of the drawn window has anything but the canvas across the conversation's column.
    private static func drawnRows(in bitmap: NSBitmapImageRep, column: CGRect, scale: CGFloat) -> (Int) -> Bool {
        // The canvas, at the column's left edge, which the content's inset keeps clear.
        let canvas = luminance(bitmap.colorAt(x: Int((column.minX + 4) * scale), y: Int(column.midY * scale)))
        return { row in
            stride(from: Int((column.minX + 40) * scale), to: Int((column.maxX - 40) * scale), by: 2).contains { x in
                abs(luminance(bitmap.colorAt(x: x, y: row)) - canvas) > 0.3
            }
        }
    }

    /// From the top of the latest turn (its request) up to the first drawn line above it, in the
    /// drawn window, across the conversation's column.
    private static func spaceAboveLatestRequest(scroll: NSScrollView, document: NSView, in root: NSView,
                                                capture: WindowlessRender.Capture) -> CGFloat? {
        // The turns: the outermost hosting views in the conversation.
        func turns(_ view: NSView) -> [NSView] {
            view is NSHostingView<AnyView> ? [view] : view.subviews.flatMap(turns)
        }
        guard let latest = turns(document).max(by: {
            $0.convert($0.bounds, to: document).minY < $1.convert($1.bounds, to: document).minY
        }) else { return nil }
        let column = scroll.convert(scroll.bounds, to: root)
        let top = latest.convert(latest.bounds, to: root).minY
        guard top > column.minY + 1, top < column.maxY else { return nil }
        let scale = capture.backingScaleFactor
        let drawn = drawnRows(in: capture.bitmap, column: column, scale: scale)
        // Nothing drawn up to the column's top: the space is at least that far.
        var row = Int(top * scale) - 1
        while row > Int(column.minY * scale), !drawn(row) { row -= 1 }
        return (top * scale - CGFloat(row)) / scale
    }

    private static func luminance(_ color: NSColor?) -> CGFloat {
        guard let color = color?.usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }

    private static func all(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(all)
    }
}
