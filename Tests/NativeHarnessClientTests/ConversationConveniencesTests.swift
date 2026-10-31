import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The conveniences the Claude and Codex apps both offer inside a conversation: a message's menu
/// with what is under the pointer (a code block, a web link, a file link) and the whole message, a
/// table's "Expand table" and "Copy table", and a command's "Copy command" and "Copy output".
@MainActor
final class ConversationConveniencesTests: XCTestCase {
    static let message = """
    See [the docs](https://example.com/docs) and [the parser](Sources/Parser.swift).

    ```swift
    let answer = 42
    print(answer)
    ```

    | Case | Before | After |
    |:---|:---:|---:|
    | Empty | crash | `[.end]` |
    | Pipe a\\|b | 1 | 2 |
    """

    private struct Message: View {
        var scheme: ColorScheme = .light
        var opened: (URL) -> Void = { _ in }
        var opensLocalFiles = true
        var body: some View {
            ConversationAgentMessage(itemID: "answer", harness: .claudeCode, text: ConversationConveniencesTests.message,
                                     isCommentary: false, isStreaming: false)
                .environment(\.transcriptWorkspaceURL, URL(filePath: "/tmp/yardlet-conveniences"))
                .environment(\.transcriptOpensLocalFiles, opensLocalFiles)
                .environment(\.openURL, OpenURLAction { url in
                    opened(url)
                    return .handled
                })
                .environment(\.revealsSentMessageActions, true)
                .environment(\.colorScheme, scheme)
                .padding(24)
                .frame(width: 720, alignment: .topLeading)
                .background(ParityTheme.canvas)
        }
    }

    private func makeHost(_ message: Message = Message()) -> WindowlessRender.Host<Message> {
        let host = WindowlessRender.Host(message, size: NSSize(width: 720, height: 700),
                                         appearance: message.scheme == .dark ? .dark : .light)
        host.settle()
        return host
    }

    private func menu(at word: String, in text: TranscriptProseTextView, atEnd: Bool = false) throws -> [String] {
        try menuItems(at: word, in: text, atEnd: atEnd).map(\.title)
    }

    private func menuItems(at word: String, in text: TranscriptProseTextView, atEnd: Bool = false) throws -> [NSMenuItem] {
        let container = try XCTUnwrap(text.superview as? TranscriptProseContainerView)
        let range = (text.string as NSString).range(of: word)
        XCTAssertNotEqual(range.location, NSNotFound, word)
        let rect = try XCTUnwrap(container.rect(of: range))
        let point = container.convert(NSPoint(x: atEnd ? rect.maxX - 1 : rect.midX, y: rect.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: try XCTUnwrap(text.window).windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        return try XCTUnwrap(text.menu(for: event)).items
    }

    private func text(in host: WindowlessRender.Host<Message>) throws -> TranscriptProseTextView {
        try XCTUnwrap(TranscriptProseRenderingTests.proseTextViews(in: host.hosting).first { $0.string.hasPrefix("See the docs") })
    }

    func testAMessagesMenuOffersWhatIsUnderThePointer() throws {
        var opened: [URL] = []
        let host = makeHost(Message(opened: { opened.append($0) }))
        defer { host.close() }
        let text = try text(in: host)

        // A click opens a web link in the task's browser; the menu offers the default browser instead.
        let link = try menu(at: "the docs", in: text)
        XCTAssertEqual(Array(link.prefix(3)), [L10n.string("Open in default browser"), L10n.string("Copy link"),
                                               L10n.string("Copy message")], "\(link)")
        XCTAssertEqual(link.filter { $0 == L10n.string("Copy link") }.count, 1, "The text's own link items give way: \(link)")

        let file = try menu(at: "the parser", in: text)
        XCTAssertEqual(Array(file.prefix(4)), [L10n.string("Open file"), L10n.string("Reveal in Finder"),
                                               L10n.string("Copy path"), L10n.string("Copy message")], "\(file)")
        try menuItems(at: "the parser", in: text).first { $0.title == L10n.string("Open file") }.map(perform)
        XCTAssertEqual(opened.map { $0.path(percentEncoded: false) }, ["/tmp/yardlet-conveniences/Sources/Parser.swift"])

        let code = try menu(at: "print(answer)", in: text)
        XCTAssertEqual(Array(code.prefix(2)), [L10n.string("Copy code"), L10n.string("Copy message")], "\(code)")
        // The app's copies go to the test process's own pasteboard, never the person's.
        let pasteboard = TranscriptClipboard.pasteboard
        XCTAssertNotEqual(pasteboard.name, NSPasteboard.general.name)
        try menuItems(at: "print(answer)", in: text).first { $0.title == L10n.string("Copy code") }.map(perform)
        XCTAssertEqual(pasteboard.string(forType: .string), "let answer = 42\nprint(answer)")
        try menuItems(at: "and", in: text).first { $0.title == L10n.string("Copy message") }.map(perform)
        XCTAssertEqual(pasteboard.string(forType: .string), Self.message)
    }

    /// A record of work on another computer names that computer's files: a file link there offers only
    /// its path, and a click on it opens nothing on this Mac. Web links are as before. Only the menu is
    /// built; nothing is shown or opened in Finder.
    func testAFileOnAnotherComputerIsNamedNotOpened() throws {
        var opened: [URL] = []
        let host = makeHost(Message(opened: { opened.append($0) }, opensLocalFiles: false))
        defer { host.close() }
        let text = try text(in: host)
        let file = try menu(at: "the parser", in: text)
        XCTAssertEqual(Array(file.prefix(2)), [L10n.string("Copy path"), L10n.string("Copy message")], "\(file)")
        XCTAssertFalse(file.contains(L10n.string("Open file")) || file.contains(L10n.string("Reveal in Finder")), "\(file)")
        let link = try menu(at: "the docs", in: text)
        XCTAssertEqual(Array(link.prefix(2)), [L10n.string("Open in default browser"), L10n.string("Copy link")], "\(link)")
        let container = try XCTUnwrap(text.superview as? TranscriptProseContainerView)
        container.open(URL(filePath: "/mnt/data/report.pdf"))
        XCTAssertTrue(opened.isEmpty)
        container.open(URL(string: "https://example.com/docs")!)
        XCTAssertEqual(opened, [URL(string: "https://example.com/docs")!])
    }

    private func perform(_ item: NSMenuItem) {
        guard let action = item.action else { return XCTFail("\(item.title) does nothing") }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    func testAWebLinkOpensInTheTasksBrowserAndTheRestWhereTheyBelong() {
        XCTAssertEqual(ConversationLinkRoute(URL(string: "https://example.com/docs")!), .taskBrowser)
        XCTAssertEqual(ConversationLinkRoute(URL(string: "HTTP://example.com")!), .taskBrowser)
        XCTAssertEqual(ConversationLinkRoute(URL(filePath: "/tmp/yardlet/Sources/Parser.swift")), .outside)
        XCTAssertEqual(ConversationLinkRoute(URL(string: "mailto:someone@example.com")!), .outside)
        XCTAssertEqual(ConversationLinkRoute(URL(string: "Sources/Parser.swift")!), .outside)
    }

    func testATableCopiesAsMarkdownAndAsAnHTMLTable() throws {
        let document = TranscriptMarkdownDocument(Self.message)
        guard case let .table(headers, rows, alignments)? = document.blocks.last else { return XCTFail("No table") }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ConversationConveniencesTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        TranscriptTableCopy.copy(headers: headers, rows: rows, alignments: alignments, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), """
        | Case | Before | After |
        | --- | :---: | ---: |
        | Empty | crash | [.end] |
        | Pipe a\\|b | 1 | 2 |
        """)
        let html = try XCTUnwrap(pasteboard.string(forType: .html))
        XCTAssertTrue(html.hasPrefix("<table><thead><tr><th>Case</th>"), html)
        XCTAssertTrue(html.contains("<td>Pipe a|b</td>"), html)
    }

    func testATableAndACommandOfferTheirCopiesAndTheTableItsExpansion() throws {
        let host = makeHost()
        defer { host.close() }
        let labels = host.accessibilityElements().filter { $0.role == NSAccessibility.Role.button.rawValue }.map(\.label)
        XCTAssertTrue(labels.contains(L10n.string("Copy table")), "\(labels)")
        XCTAssertTrue(labels.contains(L10n.string("Expand table")), "\(labels)")

        // A failed command starts open, so its command and output show.
        var ran = ConversationCommand(command: "swift test --filter ParserTests", status: "failed")
        ran.output = "Test Suite 'ParserTests' failed"
        ran.exitCode = 1
        let command = ConversationItem(id: "bash-1", kind: .command(ran), phase: .failed,
                                       source: .transcript(TranscriptEntry(content: .user(text: "x"))))
        let card = WindowlessRender.Host(
            ConversationWorkLine(item: command, harness: .codex, workspaceURL: URL(filePath: "/tmp"))
                .environment(\.revealsSentMessageActions, true)
                .padding(16).frame(width: 640, alignment: .topLeading).background(ParityTheme.canvas),
            size: NSSize(width: 640, height: 260), appearance: .light)
        defer { card.close() }
        card.settle()
        let cardLabels = card.accessibilityElements().filter { $0.role == NSAccessibility.Role.button.rawValue }.map(\.label)
        XCTAssertTrue(cardLabels.contains(L10n.string("Copy command")), "\(cardLabels)")
        XCTAssertTrue(cardLabels.contains(L10n.string("Copy output")), "\(cardLabels)")
        try WindowlessRender.writePNG(card.capture().bitmap,
                                      to: WindowlessRender.directory("conversation-text").appending(path: "command-copy-light.png"))
    }

    func testTheConveniencesDrawInBothAppearances() throws {
        let directory = try WindowlessRender.directory("conversation-text")
        for appearance in WindowlessRender.Appearance.allCases {
            let host = makeHost(Message(scheme: appearance.colorScheme))
            defer { host.close() }
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "conveniences-\(appearance.suffix).png"))
        }
    }
}
