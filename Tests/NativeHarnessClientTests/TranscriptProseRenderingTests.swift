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
    /// scroll target `Text` placed did.
    func testGoingToAMatchInATextBringsItToTheMiddle() async throws {
        var entries: [TranscriptEntry] = []
        for index in 0..<8 {
            entries.append(TranscriptEntry(content: .user(text: "Request \(index)")))
            let words = String(repeating: "Words that wrap across the line as an answer does. ", count: 8)
            let needle = index == 2 ? " The needle sits here." : ""
            entries.append(TranscriptEntry(content: .assistant(
                text: "Answer \(index).\n\n\(words)\n\n- \(words)\(needle)\n- \(words)", isStreaming: false)))
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
