import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The conveniences the Claude and Codex apps both offer inside a conversation: a message's menu
/// with what is under the pointer (a code block, a web link, a file link, a link to another task) and
/// the whole message, a table's "Expand table" and "Copy table", and a command's "Copy command" and
/// "Copy output".
@MainActor
final class ConversationConveniencesTests: XCTestCase {
    static let otherTask = UUID(uuidString: "4EBD4D44-7698-409A-A317-9F7AAD442C2E")!

    static let message = """
    See [the docs](https://example.com/docs) and [the parser](Sources/Parser.swift), as [the other task](#\(otherTask.uuidString)) did.

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
        var places = ConversationLinkPlaces()
        var body: some View {
            ConversationAgentMessage(itemID: "answer", harness: .claudeCode, text: ConversationConveniencesTests.message,
                                     isCommentary: false, isStreaming: false)
                .environment(\.transcriptWorkspaceURL, URL(filePath: "/tmp/yardlet-conveniences"))
                .environment(\.transcriptOpensLocalFiles, opensLocalFiles)
                .environment(\.conversationLinkPlaces, places)
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

    /// The menu's titles, a separator as "—".
    private func menu(at word: String, in text: TranscriptProseTextView, atEnd: Bool = false) throws -> [String] {
        try menuItems(at: word, in: text, atEnd: atEnd).map { $0.isSeparatorItem ? "—" : $0.title }
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
        var placed: [(TaskLink, TaskLinkPlace)] = []
        var inBrowserPanel: [URL] = []
        let places = ConversationLinkPlaces(task: { link, _, place in placed.append((link, place)) },
                                            browserPanel: { inBrowserPanel.append($0) })
        let host = makeHost(Message(opened: { opened.append($0) }, places: places))
        defer { host.close() }
        let text = try text(in: host)

        // A web link opens in the task's browser panel, or in the default browser. The menu over a link is
        // the link's alone: the text system's own link, writing and font items give way.
        let link = try menu(at: "the docs", in: text)
        XCTAssertEqual(link, [L10n.string("Open in the browser panel"), L10n.string("Open in default browser"),
                              "—", L10n.string("Copy link"), L10n.string("Copy message")], "\(link)")
        try menuItems(at: "the docs", in: text).first { $0.title == L10n.string("Open in the browser panel") }.map(perform)
        XCTAssertEqual(inBrowserPanel, [URL(string: "https://example.com/docs")!])

        let file = try menu(at: "the parser", in: text)
        XCTAssertEqual(file, [L10n.string("Open file"), L10n.string("Open in its app"), L10n.string("Reveal in Finder"),
                              "—", L10n.string("Copy path"), L10n.string("Copy message")], "\(file)")
        try menuItems(at: "the parser", in: text).first { $0.title == L10n.string("Open file") }.map(perform)
        XCTAssertEqual(opened.map { $0.path(percentEncoded: false) }, ["/tmp/yardlet-conveniences/Sources/Parser.swift"])

        // A link to another task opens it as its sidebar row's menu does, and copies as it was written.
        let task = try menu(at: "the other task", in: text)
        XCTAssertEqual(task, [L10n.string("Open task"), L10n.string("Open in New Tab"), L10n.string("Open in Split View"),
                              L10n.string("Open in Side Panel"), "—", L10n.string("Copy link"), L10n.string("Copy message")],
                       "\(task)")
        try menuItems(at: "the other task", in: text).first { $0.title == L10n.string("Open in Split View") }.map(perform)
        try menuItems(at: "the other task", in: text).first { $0.title == L10n.string("Open in Side Panel") }.map(perform)
        XCTAssertEqual(placed.map(\.0), [.task(Self.otherTask), .task(Self.otherTask)])
        XCTAssertEqual(placed.map(\.1), [.splitView, .sidePanel])
        try menuItems(at: "the other task", in: text).first { $0.title == L10n.string("Open task") }.map(perform)
        XCTAssertEqual(opened.last, TaskLink.url(Self.otherTask))
        try menuItems(at: "the other task", in: text).first { $0.title == L10n.string("Copy link") }.map(perform)
        XCTAssertEqual(TranscriptClipboard.pasteboard.string(forType: .string), "[the other task](#\(Self.otherTask.uuidString))")
        // With words selected, their Copy heads the copies.
        text.setSelectedRange((text.string as NSString).range(of: "See"))
        let selected = try menuItems(at: "the other task", in: text)
        XCTAssertEqual(selected.firstIndex { $0.action == #selector(NSText.copy(_:)) }, 5, "\(selected.map(\.title))")
        text.setSelectedRange(NSRange(location: 0, length: 0))

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
        // Without the window's places, a web link and a task link offer what needs none.
        let link = try menu(at: "the docs", in: text)
        XCTAssertEqual(Array(link.prefix(3)), [L10n.string("Open in default browser"), "—", L10n.string("Copy link")], "\(link)")
        let task = try menu(at: "the other task", in: text)
        XCTAssertEqual(Array(task.prefix(3)), [L10n.string("Open task"), "—", L10n.string("Copy link")], "\(task)")
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

    func testALinkIsReadForWhatItNames() {
        XCTAssertEqual(ConversationLinkKind(URL(string: "https://example.com/docs")!), .web)
        XCTAssertEqual(ConversationLinkKind(URL(string: "HTTP://example.com")!), .web)
        XCTAssertEqual(ConversationLinkKind(URL(filePath: "/tmp/yardlet/Sources/Parser.swift")), .file)
        XCTAssertEqual(ConversationLinkKind(URL(string: "Sources/Parser.swift")!), .file)
        XCTAssertEqual(ConversationLinkKind(URL(string: "mailto:someone@example.com")!), .other)
        XCTAssertEqual(ConversationLinkKind(TaskLink.url(Self.otherTask)), .task(.task(Self.otherTask)))
        XCTAssertEqual(ConversationLinkKind(URL(string: "codex://threads/thread_1")!), .task(.codexThread("thread_1")))
        // A heading's anchor names nothing outside the message, so its menu offers nothing of its own.
        let heading = URL(string: "#usage")!
        XCTAssertEqual(ConversationLinkKind(heading), .place)
        XCTAssertEqual(ConversationLinkMenu.items(for: heading, opensLocalFiles: true, places: ConversationLinkPlaces()), [])
        // Another computer's file is named, never opened or shown at its path here; where that computer's files can
        // be read (another Mac's task), it opens once read from there.
        let elsewhere = URL(string: "reports/crash-notes.txt")!
        XCTAssertEqual(ConversationLinkMenu.items(for: elsewhere, opensLocalFiles: false, places: ConversationLinkPlaces()),
                       [[.copyPath]])
        var readable = ConversationLinkPlaces()
        readable.fileElsewhere = { _ in }
        XCTAssertEqual(ConversationLinkMenu.items(for: elsewhere, opensLocalFiles: false, places: readable), [[.open], [.copyPath]])
        // A Codex thread copies as the address the Codex app opens.
        XCTAssertEqual(ConversationLinkMenu.copiedLink(URL(string: "codex://threads/thread_1")!, text: "the thread"),
                       "codex://threads/thread_1")
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

    /// The links' menus, each as the items the message's text gives for it, drawn as a menu lists them
    /// beside the message, in both appearances. AppKit draws a real menu only on the screen, so the items
    /// are drawn in a view of their own.
    func testTheLinkMenusDrawInBothAppearances() throws {
        let directory = try WindowlessRender.directory("conversation-text")
        let places = ConversationLinkPlaces(task: { _, _, _ in }, browserPanel: { _ in })
        for appearance in WindowlessRender.Appearance.allCases {
            let host = makeHost(Message(scheme: appearance.colorScheme, places: places))
            defer { host.close() }
            let text = try text(in: host)
            let menus = try ["the other task", "the docs", "the parser"].map { word in
                (word, try menuItems(at: word, in: text).filter { !$0.isHidden }.map { $0.isSeparatorItem ? "—" : $0.title })
            }
            let sheet = WindowlessRender.Host(
                LinkMenusSheet(menus: menus).environment(\.colorScheme, appearance.colorScheme),
                size: NSSize(width: 760, height: 260), appearance: appearance)
            defer { sheet.close() }
            sheet.settle()
            try WindowlessRender.writePNG(sheet.capture().bitmap, to: directory.appending(path: "link-menus-\(appearance.suffix).png"))
        }
    }

    private struct LinkMenusSheet: View {
        let menus: [(String, [String])]

        var body: some View {
            HStack(alignment: .top, spacing: 20) {
                ForEach(menus, id: \.0) { link, items in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(link).foregroundStyle(ParityTheme.accent).font(.system(size: 13))
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                if item == "—" {
                                    Divider().padding(.vertical, 5).padding(.horizontal, 10)
                                } else {
                                    Text(item).font(.system(size: 13)).padding(.horizontal, 12).frame(height: 22)
                                }
                            }
                        }
                        .padding(.vertical, 5)
                        .frame(width: 220, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).stroke(ParityTheme.separator) }
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ParityTheme.canvas)
        }
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
