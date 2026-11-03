import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The Files panel's reader on TextKit 2: it stays on TextKit 2, finds lines from what it laid out,
/// restores a far reading position, and keeps the line break it adds after a long last line out of
/// the text, the selection and every edit.
@MainActor
final class WorkspaceFileReaderTests: XCTestCase {
    private final class Switches: @unchecked Sendable { var count = 0 }
    private let switches = Switches()
    private var observer: NSObjectProtocol?

    override func setUp() async throws {
        let switches = switches
        observer = NotificationCenter.default.addObserver(
            forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: nil, queue: nil
        ) { notification in
            if notification.object is WorkspaceFileTextView { switches.count += 1 }
        }
    }

    override func tearDown() async throws {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertEqual(switches.count, 0, "Something asked the reader for TextKit 1")
    }

    private func reader(_ document: WorkspaceFileDocument, bookmark: FileReadingBookmark = .init(),
                        location: WorkspaceFileLocation? = nil, onBookmark: @escaping (FileReadingBookmark) -> Void = { _ in },
                        onEdit: ((String) -> Void)? = nil) -> WindowlessRender.Host<WorkspaceFileReader> {
        let host = WindowlessRender.Host(WorkspaceFileReader(
            document: document, bookmark: bookmark, location: location, navigationID: UUID(), fontSize: 12, focus: nil,
            onBookmark: onBookmark, onNavigated: { _ in }, onEdit: onEdit), size: NSSize(width: 640, height: 420))
        host.settle(passes: 4)
        return host
    }

    private func textView(in host: WindowlessRender.Host<WorkspaceFileReader>) throws -> WorkspaceFileTextView {
        func find(_ view: NSView) -> WorkspaceFileTextView? {
            if let text = view as? WorkspaceFileTextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(host.hosting))
    }

    func testAFarReadingPositionOpensOnItsLine() throws {
        let text = (1...60_000).map { "line \($0) " + String(repeating: "x", count: $0 % 90) }.joined(separator: "\n") + "\n"
        let document = WorkspaceFileDocument(path: "notes.txt", text: text)
        let host = reader(document, bookmark: .init(line: 41_234, lineOffset: 0, horizontalOffset: 0))
        defer { host.close() }
        let view = try textView(in: host)
        XCTAssertNotNil(view.textLayoutManager)
        let top = try XCTUnwrap(view.enclosingScrollView?.contentView.bounds.minY)
        let shown = try XCTUnwrap(view.line(atY: top))
        XCTAssertEqual(document.line(atUTF16Offset: shown.offset), 41_234)
        var numbered: [Int] = []
        view.enumerateLines(in: try XCTUnwrap(view.enclosingScrollView?.contentView.bounds)) { offset, _ in
            numbered.append(document.line(atUTF16Offset: offset))
        }
        XCTAssertEqual(numbered.first, 41_234)
        XCTAssertEqual(numbered, Array(41_234..<(41_234 + numbered.count)))

        // A link to the last, empty line lands there.
        let end = reader(document, location: .init(relativePath: "notes.txt", line: 60_001))
        defer { end.close() }
        let last = try textView(in: end)
        var lines: [Int] = []
        last.enumerateLines(in: try XCTUnwrap(last.enclosingScrollView?.contentView.bounds)) { offset, _ in
            lines.append(document.line(atUTF16Offset: offset))
        }
        XCTAssertEqual(lines.last, 60_001)
        XCTAssertEqual(last.selectedRange(), NSRange(location: document.utf16Length, length: 0))
    }

    /// A read-only file is drawn through a window of its lines: far places, the end, a link's line and
    /// what is copied are the file's.
    func testAReadOnlyFileMovesItsWindowWithTheReader() throws {
        let text = (1...300_000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let document = WorkspaceFileDocument(path: "big.log", text: text, isEditable: false)
        var kept: FileReadingBookmark?
        let host = reader(document, bookmark: .init(line: 250_000, lineOffset: 0, horizontalOffset: 0), onBookmark: { kept = $0 })
        defer { host.close() }
        let view = try textView(in: host)
        let clip = try XCTUnwrap(view.enclosingScrollView?.contentView)
        XCTAssertLessThan(try XCTUnwrap(view.textStorage?.length), text.utf16.count / 20, "Only a window is in the text storage")
        XCTAssertEqual(view.documentLength, document.utf16Length)
        func shownLines() -> [Int] {
            var lines: [Int] = []
            view.enumerateLines(in: clip.bounds) { offset, top in
                if top >= clip.bounds.minY { lines.append(document.line(atUTF16Offset: offset)) }
            }
            return lines
        }
        XCTAssertEqual(shownLines().first, 250_000)
        let top = try XCTUnwrap(view.line(atY: clip.bounds.minY))
        XCTAssertEqual(document.line(atUTF16Offset: top.offset), 250_000)

        // The text drawn there is that line's.
        let laid = try XCTUnwrap(view.textLayoutManager?.textLayoutFragment(for: CGPoint(x: 0, y: clip.bounds.minY - view.textContainerOrigin.y + 2)))
        let content = try XCTUnwrap(view.textLayoutManager?.textContentManager)
        let offset = content.offset(from: content.documentRange.location, to: laid.rangeInElement.location)
        XCTAssertEqual((view.string as NSString).substring(with: NSRange(location: offset, length: 11)), "line 250000")

        view.scrollToEndOfDocument(nil)
        host.settle(passes: 2)
        XCTAssertEqual(shownLines().last, 300_001)
        XCTAssertEqual(kept?.line, document.line(atUTF16Offset: try XCTUnwrap(view.line(atY: clip.bounds.minY)).offset))
        view.scrollToBeginningOfDocument(nil)
        host.settle(passes: 2)
        XCTAssertEqual(shownLines().first, 1)

        // A link far away selects its line in the file, and copying gives the file's text.
        let link = reader(document, location: .init(relativePath: "big.log", line: 123_456))
        defer { link.close() }
        let linked = try textView(in: link)
        let pasteboard = NSPasteboard(name: .init("WorkspaceFileReaderTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(linked.writeSelection(to: pasteboard, types: linked.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), "line 123456\n")
        pasteboard.releaseGlobally()
    }

    func testScrollingKeepsTheLineAtTheTop() throws {
        let text = (1...5_000).map { "line \($0)" }.joined(separator: "\n")
        let document = WorkspaceFileDocument(path: "notes.txt", text: text)
        var kept: FileReadingBookmark?
        let host = reader(document, onBookmark: { kept = $0 })
        defer { host.close() }
        let view = try textView(in: host)
        let clip = try XCTUnwrap(view.enclosingScrollView?.contentView)
        let target = try XCTUnwrap(view.lineTop(atUTF16Offset: document.lineStarts[2_999]))
        clip.scroll(to: NSPoint(x: 0, y: target + 5))
        view.enclosingScrollView?.reflectScrolledClipView(clip)
        host.settle(passes: 2)
        XCTAssertEqual(kept?.line, 3_000)
        XCTAssertEqual(try XCTUnwrap(kept?.lineOffset), 5, accuracy: 0.5)
    }

    func testALongLastLineWithoutALineBreakGetsOneThatIsNeverSelectedOrEdited() throws {
        let text = String(repeating: "x", count: 5_000)
        let document = WorkspaceFileDocument(path: "bundle.min.js", text: text)
        var edits: [String] = []
        let host = reader(document, onEdit: { edits.append($0) })
        defer { host.close() }
        let view = try textView(in: host)
        XCTAssertEqual(view.textStorage?.length, 5_001)
        XCTAssertEqual(view.documentLength, 5_000)
        XCTAssertEqual(view.documentText, text)
        view.selectAll(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 5_000))

        view.setSelectedRange(NSRange(location: 5_001, length: 0))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 5_000, length: 0))
        view.insertText("y", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(edits.last, text + "y")
        view.deleteForward(nil)
        XCTAssertEqual(view.documentText, text + "y", "The added line break stays")
        XCTAssertEqual(view.textStorage?.length, 5_002)

        // A short last line, or one that ends with a line break, is shown as it is.
        for short in ["let a = 1", String(repeating: "x", count: 5_000) + "\n"] {
            let plain = reader(WorkspaceFileDocument(path: "a.swift", text: short))
            defer { plain.close() }
            XCTAssertEqual(try textView(in: plain).textStorage?.string, short)
        }
    }

    private func color(at offset: Int, in view: WorkspaceFileTextView) -> NSColor? {
        view.textStorage?.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor
    }

    func testColorsFollowAnEditUntilNewOnesArrive() throws {
        let document = WorkspaceFileDocument(path: "a.swift", text: "let a = \"b\"\n")
        let host = reader(document, onEdit: { _ in })
        defer { host.close() }
        let view = try textView(in: host)
        XCTAssertEqual(color(at: 0, in: view), .systemPurple)
        XCTAssertEqual(color(at: 9, in: view), .systemGreen)
        XCTAssertEqual(color(at: 4, in: view), .labelColor)

        // Typing before the string moves its color along with it.
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.insertText("bb", replacementRange: NSRange(location: NSNotFound, length: 0))
        host.settle(passes: 2)
        XCTAssertEqual(color(at: 11, in: view), .systemGreen)
        XCTAssertEqual(color(at: 0, in: view), .systemPurple)

        // New colors replace them without touching the text or the selection.
        let selection = NSRange(location: 2, length: 3)
        view.setSelectedRange(selection)
        let recolored = WorkspaceFileDocument(id: document.id, path: "a.swift", text: view.documentText)
            .highlighted([.init(range: NSRange(location: 0, length: 3), kind: .comment)])
        host.hosting.rootView = WorkspaceFileReader(
            document: recolored, bookmark: .init(), location: nil, navigationID: UUID(), fontSize: 12, focus: nil,
            onBookmark: { _ in }, onNavigated: { _ in })
        host.settle(passes: 2)
        XCTAssertEqual(color(at: 0, in: view), .secondaryLabelColor)
        XCTAssertEqual(color(at: 11, in: view), .labelColor)
        XCTAssertEqual(view.documentText, "let bba = \"b\"\n")
        XCTAssertEqual(view.selectedRange(), selection)
    }

    func testOnlyTheLinesInViewAreColoredUntilTheyComeIntoView() throws {
        let text = String(repeating: "let value = \"text\" // note\n", count: 40_000)
        // Small read-only source files use the same viewport colors as editable ones.
        for editable in [true, false] {
            let document = WorkspaceFileDocument(path: "a.swift", text: text, isEditable: editable)
            XCTAssertFalse(document.tokens.isEmpty)
            let host = reader(document)
            defer { host.close() }
            let view = try textView(in: host)
            let lastLine = document.lineStarts[document.lineStarts.count - 2]
            XCTAssertEqual(color(at: 0, in: view), .systemPurple)
            XCTAssertEqual(color(at: lastLine, in: view), .labelColor, "A line far below is not colored yet")

            let clip = try XCTUnwrap(view.enclosingScrollView?.contentView)
            clip.scroll(to: NSPoint(x: 0, y: try XCTUnwrap(view.lineTop(atUTF16Offset: lastLine)) - 100))
            view.enclosingScrollView?.reflectScrolledClipView(clip)
            host.settle(passes: 2)
            XCTAssertEqual(color(at: lastLine, in: view), .systemPurple)
            XCTAssertEqual(color(at: lastLine + 13, in: view), .systemGreen)
        }
    }
}
