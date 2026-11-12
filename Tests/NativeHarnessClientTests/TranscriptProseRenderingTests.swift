import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// A message's prose is one text a drag selects across — paragraphs, headings, lists, quotes and
/// code blocks — and copying it gives the words as they read. Tables and the Codex cards stay views
/// of their own between such texts. Review images go to `.build/conversation-text/`.
@MainActor
final class TranscriptProseRenderingTests: XCTestCase {
    static let message = """
    ## What changed

    The parser returned early on an **empty input**, so the lexer never saw the *end token*. See \
    [the parser](Sources/Parser.swift) and `parse(_:)`.

    - The lexer now always ends with `.end`.
    - The tests cover the empty input:
      1. no characters
      2. only spaces

    > A quoted note that wraps across the line as a longer note does when the message is narrow.

    ```swift
    func parse(_ input: String) -> [Token] {
        guard !input.isEmpty else { return [.end] }
        return Lexer(input).tokens + [.end]
    }
    ```

    ---

    Nothing else changed: a parse ~~still~~ took 240~400ms before and takes 110~150ms now.

    | Case | Before | After |
    |---|---|---|
    | Empty | crash | `[.end]` |

    That is all.
    """

    private struct Message: View {
        let scheme: ColorScheme
        var text = TranscriptProseRenderingTests.message
        var body: some View {
            ConversationAgentMessage(itemID: "answer", harness: .claudeCode, text: text, isCommentary: false,
                                     isStreaming: false)
                .environment(\.transcriptWorkspaceURL, URL(filePath: "/tmp/yardlet-prose"))
                .environment(\.colorScheme, scheme)
                .padding(24)
                .frame(width: 720, alignment: .topLeading)
                .background(ParityTheme.canvas)
        }
    }

    func testAMessagesProseIsOneTextBetweenItsTables() throws {
        let host = WindowlessRender.Host(Message(scheme: .light), size: NSSize(width: 720, height: 1_000), appearance: .light)
        defer { host.close() }
        host.settle()
        let texts = Self.proseTextViews(in: host.hosting)
        // The prose before the table, and the line after it.
        XCTAssertEqual(texts.count, 2)
        let first = try XCTUnwrap(texts.first)
        XCTAssertTrue(first.string.hasPrefix("What changed\n"))
        XCTAssertTrue(first.string.contains("Nothing else changed: a parse still took 240~400ms before and takes 110~150ms now."))
        // Two tildes strike; one stays a tilde, as a range writes it.
        let storage = try XCTUnwrap(first.textStorage)
        var struck: [String] = []
        storage.enumerateAttribute(.strikethroughStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { struck.append(storage.attributedSubstring(from: range).string) }
        }
        XCTAssertEqual(struck, ["still"])
        XCTAssertEqual(texts.last?.string, "That is all.")
        XCTAssertGreaterThan(first.frame.height, 300, "The text is laid out whole")
    }

    func testCopyingAcrossBlocksGivesTheTextAsItReads() throws {
        let host = WindowlessRender.Host(Message(scheme: .light), size: NSSize(width: 720, height: 1_000), appearance: .light)
        defer { host.close() }
        host.settle()
        let text = try XCTUnwrap(Self.proseTextViews(in: host.hosting).first)
        text.selectAll(nil)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TranscriptProseRenderingTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(text.writeSelection(to: pasteboard, types: text.writablePasteboardTypes))
        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertEqual(copied, """
        What changed

        The parser returned early on an empty input, so the lexer never saw the end token. See the parser and parse(_:).

        • The lexer now always ends with .end.
        • The tests cover the empty input:
          1. no characters
          2. only spaces

        A quoted note that wraps across the line as a longer note does when the message is narrow.

        func parse(_ input: String) -> [Token] {
            guard !input.isEmpty else { return [.end] }
            return Lexer(input).tokens + [.end]
        }



        Nothing else changed: a parse still took 240~400ms before and takes 110~150ms now.
        """)
    }

    func testAMessageDrawsInBothAppearances() throws {
        let directory = try WindowlessRender.directory("conversation-text")
        let captures = try WindowlessRender.hostedInBothAppearances("prose-message", in: directory,
                                                                    size: NSSize(width: 720, height: 1_000)) {
            Message(scheme: $0.colorScheme)
        }
        for capture in captures {
            XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 9))
        }
    }

    /// A message that starts with a code block draws the block's header row, and its Copy, inside the
    /// message, as one that starts with words does: TextKit 2 leaves no room above a text's first
    /// paragraph, where the header is drawn.
    func testAMessageThatStartsWithCodeDrawsItsHeaderInside() throws {
        let text = "```swift\nfunc parse() -> [Token] { [.end] }\n```\n\nThat is the parser."
        try WindowlessRender.hostedInBothAppearances("prose-code-first", in: WindowlessRender.directory("conversation-text"),
                                                     size: NSSize(width: 720, height: 400)) {
            Message(scheme: $0.colorScheme, text: text)
        }
        let host = WindowlessRender.Host(Message(scheme: .light, text: text), size: NSSize(width: 720, height: 400),
                                         appearance: .light)
        defer { host.close() }
        host.settle()
        let container = try XCTUnwrap(Self.proseTextViews(in: host.hosting).first?.superview)
        let copy = try XCTUnwrap(container.subviews.first { $0 is NSHostingView<AnyView> })
        XCTAssertTrue(container.bounds.contains(copy.frame), "\(copy.frame) in \(container.bounds)")
    }

    /// A message's text view, and what TextKit 2 builds inside it (the views that draw its lines and
    /// its selection, and its layout manager with every line it laid out), are let go with the message.
    /// A conversation opened again builds its messages anew; on macOS 27 each one let go otherwise left
    /// its laid-out text behind.
    func testAMessageLeavesNothingBehindOnceItIsGone() async throws {
        var host: WindowlessRender.Host<Message>? = WindowlessRender.Host(
            Message(scheme: .light), size: NSSize(width: 720, height: 1_000), appearance: .light)
        host?.settle()
        var released: [() -> AnyObject?] = []
        for text in Self.proseTextViews(in: try XCTUnwrap(host?.hosting)) {
            for object in [text, text.textLayoutManager as AnyObject?] + text.subviews {
                weak var weakObject = object
                released.append { weakObject }
            }
        }
        XCTAssertGreaterThan(released.count, 4)
        host?.close()
        host = nil
        try await waitUntil { released.allSatisfy { $0() == nil } }
    }

    static func proseTextViews(in root: NSView) -> [TranscriptProseTextView] {
        func all(_ view: NSView) -> [TranscriptProseTextView] {
            ((view as? TranscriptProseTextView).map { [$0] } ?? []) + view.subviews.flatMap(all)
        }
        return all(root).sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
    }
}

extension TranscriptProseRenderingTests {
    /// Going to a match inside a message's text brings it to the middle of the conversation, as the
    /// scroll target `Text` placed did; so does going to one in a table's cell, which the table's own
    /// point brings there (`conversationFindAnchor`), when find first goes to it, on Return and on ⌘G.
    func testGoingToAMatchInATextOrATableBringsItToTheMiddle() async throws {
        var entries: [TranscriptEntry] = []
        for index in 0..<8 {
            entries.append(TranscriptEntry(content: .user(text: "Request \(index)")))
            let words = String(repeating: "Words that wrap across the line as an answer does. ", count: 8)
            let needle = index == 2 ? " The needle sits here." : ""
            let table = index == 5 ? "\n\n| Function | What it does |\n| --- | --- |\n| `Store.load()` | Reads the notes. |\n"
                + "| `Store.done(note_id)` | Marks the note as done. |" : ""
            entries.append(TranscriptEntry(content: .assistant(
                text: "Answer \(index).\n\n\(words)\n\n- \(words)\(needle)\n- \(words)\(table)", isStreaming: false)))
        }
        let find = ConversationFindModel()
        find.debounce = .zero
        let view = TaskConversationView(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/yardlet-prose"),
                                        entries: entries, latestTurnIsComplete: true)
            .environment(\.conversationFind, find)
            .frame(width: 760, height: 560)
            .background(ParityTheme.canvas)
        let host = WindowlessRender.Host(view, size: NSSize(width: 760, height: 560), appearance: .light)
        defer { host.close() }
        func settle(_ passes: Int) async throws {
            for _ in 0..<passes {
                host.hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
            }
        }
        try await settle(6)
        find.open()
        find.updateSource(.conversation(TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true)))
        find.query = "needle"
        await find.waitForSearch()
        try await settle(12)
        XCTAssertEqual(find.currentResult?.matches.count, 1)
        let scroll = try XCTUnwrap(BlankFrameProbe.conversationScrollView(in: host.hosting))
        let containers = Self.containers(in: host.hosting)
        let holder = try XCTUnwrap(containers.first { $0.textView.string.contains("needle") })
        let range = (holder.textView.string as NSString).range(of: "needle")
        let rect = try XCTUnwrap(holder.rect(of: range))
        let match = holder.convert(rect, to: scroll.contentView)
        let visible = scroll.contentView.bounds
        print("[prose-find] match \(NSStringFromRect(match)) visible \(NSStringFromRect(visible))")
        XCTAssertTrue(visible.intersects(match), "The match is in view")
        try WindowlessRender.writePNG(host.capture().bitmap,
                                      to: WindowlessRender.directory("conversation-text").appending(path: "find-in-text.png"))
        XCTAssertEqual(match.midY, visible.midY, accuracy: visible.height * 0.15, "The match is in the middle")

        // The scroll to the match's turn and the table's point centering itself both move the
        // conversation; the conversation stays on the match.
        find.query = "Store.done"
        await find.waitForSearch()
        for move in ["typing", "Return", "⌘G"] {
            if move == "Return" { find.submit() } else if move == "⌘G" { find.next() }
            try await settle(12)
            XCTAssertEqual(find.currentResult?.matches.count, 1)
            let point = try XCTUnwrap(Self.findPoints(in: host.hosting).first, "The table places the match's point")
            let cell = point.convert(point.bounds, to: scroll.contentView)
            let shown = scroll.contentView.bounds
            XCTAssertEqual(cell.midY, shown.midY, accuracy: shown.height * 0.15,
                           "After \(move), the table's match is in the middle: \(cell) in \(shown)")
        }
        try WindowlessRender.writePNG(host.capture().bitmap,
                                      to: WindowlessRender.directory("conversation-text").appending(path: "find-in-table.png"))
    }

    /// The points tables and other drawn views place for find's current match.
    static func findPoints(in root: NSView) -> [NSView] {
        (type(of: root) == ConversationFindCenteringView.self ? [root] : []) + root.subviews.flatMap(findPoints)
    }

    static func containers(in root: NSView) -> [TranscriptProseContainerView] {
        ((root as? TranscriptProseContainerView).map { [$0] } ?? []) + root.subviews.flatMap(containers)
    }
}

extension TranscriptProseRenderingTests {
    /// A link opens through SwiftUI's `openURL`, as a `Text`'s does; a relative one is a file in the
    /// task's folder, which the window opens in its file panel.
    func testALinkOpensThroughOpenURLRelativeToTheTasksFolder() throws {
        var opened: [URL] = []
        let view = Message(scheme: .light)
            .environment(\.openURL, OpenURLAction { url in
                opened.append(url)
                return .handled
            })
        let host = WindowlessRender.Host(view, size: NSSize(width: 720, height: 1_000), appearance: .light)
        defer { host.close() }
        host.settle()
        let text = try XCTUnwrap(Self.proseTextViews(in: host.hosting).first)
        let index = (text.string as NSString).range(of: "the parser").location
        let link = try XCTUnwrap(text.textStorage?.attribute(.link, at: index, effectiveRange: nil))
        text.clicked(onLink: link, at: index)
        XCTAssertEqual(opened.map { $0.path(percentEncoded: false) }, ["/tmp/yardlet-prose/Sources/Parser.swift"])
    }

    /// The interface size setting scales the text, headings and code with it.
    func testTheInterfaceSizeScalesTheText() throws {
        func height(_ scale: CGFloat) throws -> CGFloat {
            let host = WindowlessRender.Host(Message(scheme: .light).environment(\.yardletInterfaceScale, scale),
                                             size: NSSize(width: 720, height: 1_400), appearance: .light)
            defer { host.close() }
            host.settle()
            return try XCTUnwrap(Self.proseTextViews(in: host.hosting).first).frame.height
        }
        let standard = try height(1), larger = try height(1.25)
        XCTAssertGreaterThan(larger, standard * 1.15)
    }
}

extension TranscriptProseRenderingTests {
    /// A table wider than its message wraps its cells to fit, as the Codex and Claude apps' tables do,
    /// at the conversation's narrowest beside the side panel (560 pt, 496 inside its gutters), at the
    /// 616 pt a 1200 pt window gave and at the widest message, and measures at the height it is drawn
    /// at, as a turn measures its messages before placing them (`ConversationTurnHosting`). Only a
    /// table whose words cannot fit side by side scrolls sideways, and then its scroller shows. Review
    /// images: `.build/conversation-text/table-*.png`.
    func testAWideTableWrapsItsCellsToFitTheMessage() throws {
        let functions = """
        | File | Function | What it does |
        | --- | --- | --- |
        | `src/notes/__main__.py` | `main()` | Parses `sys.argv`: `add <text>`, `list` or `done <id>`, and calls `Store`. No arguments lists the notes. |
        | `src/notes/store.py` | `Store.load()` | Returns the list of notes from the file, or an empty list if the file doesn't exist. |
        | `src/notes/store.py` | `Store.done(note_id)` | Marks the note with that id as done and saves. |
        | `tests/test_store.py` | `StoreTests.test_add_then_done` | Adds a note, marks it done, and checks that done is true after reloading. |
        """
        let identifiers = """
        | Before | After | Caller | Callee | Test |
        | --- | --- | --- | --- | --- |
        | `ConversationScrollRestorationController` | `ConversationReadingPositionKeeper` | `TranscriptScrollFollowing.restore` | `ConversationTurnHosting.size(forWidth:)` | `ConversationReadingPositionTests` |
        """
        let directory = try WindowlessRender.directory("conversation-text")
        for (name, table, widths, scrolls) in [("table-fit", functions, [CGFloat(496), 616, 704], false),
                                               ("table-scroll", identifiers, [CGFloat(496)], true)] {
            for width in widths {
                for appearance in WindowlessRender.Appearance.allCases {
                    let message = TranscriptMarkdownText(text: table).environment(\.colorScheme, appearance.colorScheme)
                    let placed = PlacedHeight()
                    let host = WindowlessRender.Host(
                        message.frame(width: width)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { placed.height = $0 }
                            .padding(24)
                            .frame(width: width + 48, height: 520, alignment: .topLeading).background(ParityTheme.canvas),
                        size: NSSize(width: width + 48, height: 520), appearance: appearance)
                    defer { host.close() }
                    host.settle()
                    try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(
                        path: "\(name)-\(Int(width))-\(appearance.suffix).png"))
                    let measured = NSHostingController(rootView: message).sizeThatFits(
                        in: CGSize(width: width, height: .greatestFiniteMagnitude))
                    XCTAssertEqual(measured.height, placed.height, accuracy: 1, "\(name) at \(width): measured as it is drawn")
                    let shown = Self.scrollViews(in: host.hosting).filter { !$0.isHiddenOrHasHiddenAncestor && !$0.frame.isEmpty }
                    for scroll in Self.scrollViews(in: host.hosting) {
                        print("[table \(name) \(Int(width))] scroll hidden \(scroll.isHiddenOrHasHiddenAncestor) frame \(NSStringFromRect(scroll.frame)) document \(NSStringFromRect(scroll.documentView?.frame ?? .zero)) style \(scroll.scrollerStyle.rawValue) scroller \(String(describing: scroll.horizontalScroller.map { ($0.isHidden, $0.alphaValue, NSStringFromRect($0.frame)) })) placed \(placed.height)")
                    }
                    if scrolls {
                        let scroll = try XCTUnwrap(shown.first, "\(name) at \(width): the table scrolls")
                        let document = try XCTUnwrap(scroll.documentView).frame.width
                        let scroller = try XCTUnwrap(scroll.horizontalScroller)
                        XCTAssertGreaterThan(document, scroll.contentView.bounds.width + 50, "\(name) at \(width)")
                        XCTAssertTrue(scroll.hasHorizontalScroller && !scroller.isHidden && scroller.alphaValue > 0,
                                      "\(name) at \(width): the scroller shows")
                    } else {
                        XCTAssertTrue(shown.isEmpty, "\(name) at \(width): the table fits without scrolling")
                    }
                }
            }
        }
    }

    private final class PlacedHeight {
        var height: CGFloat = 0
    }

    static func scrollViews(in root: NSView) -> [NSScrollView] {
        ((root as? NSScrollView).map { [$0] } ?? []) + root.subviews.flatMap(scrollViews)
    }
}
