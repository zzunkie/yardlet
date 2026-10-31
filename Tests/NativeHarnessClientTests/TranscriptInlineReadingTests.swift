import Foundation
import XCTest
@testable import NativeHarnessClient

final class TranscriptInlineReadingTests: XCTestCase {
    private func content(_ source: String) throws -> TranscriptInlineContent {
        guard case let .paragraph(text) = try XCTUnwrap(TranscriptMarkdownDocument(source).blocks.first) else {
            throw NSError(domain: "Expected paragraph", code: 1)
        }
        return text
    }

    func testEscapedLiteralAndEmbeddedBackticksKeepVisibleCharacters() throws {
        let value = try content(#"Literal \*plain\* and ``let `key` = 1``."#)
        XCTAssertEqual(value.plainText, "Literal *plain* and let `key` = 1.")
        let code = value.attributed.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
        XCTAssertEqual(code.map { String(value.attributed[$0.range].characters) }, ["let `key` = 1"])
        XCTAssertFalse(value.attributed.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
    }

    func testFileLinkWithSpacesRetainsItsLabelAndDestination() throws {
        let value = try content(#"Read [review](<Notes/review draft.md>) and [web](https://example.com/review)."#)
        XCTAssertEqual(value.plainText, "Read review and web.")
        let links = value.attributed.runs.compactMap(\.link)
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links.first?.relativeString, "Notes/review%20draft.md")
        XCTAssertEqual(links.last?.absoluteString, "https://example.com/review")
    }

    func testReferenceLinksResolveAgainstEachTaskWorkspaceWithoutMutatingContent() throws {
        let value = try content("[review][file] and [web](https://example.com)\n\n[file]: <Notes/한글 draft.md>")
        let first = value.resolved(relativeTo: URL(fileURLWithPath: "/tmp/task-one", isDirectory: true))
        let second = value.resolved(relativeTo: URL(fileURLWithPath: "/tmp/task-two", isDirectory: false))
        XCTAssertEqual(first.runs.compactMap(\.link).first?.path, "/tmp/task-one/Notes/한글 draft.md")
        XCTAssertEqual(second.runs.compactMap(\.link).first?.path, "/tmp/task-two/Notes/한글 draft.md")
        XCTAssertEqual(first.runs.compactMap(\.link).last, second.runs.compactMap(\.link).last)
        XCTAssertNil(value.attributed.runs.compactMap(\.link).first?.scheme)
    }

    /// A file named in code opens as Claude Code's `file_path:line_number` and Codex's inline path do, and
    /// a folder too (in Finder); a path that is not there, `/` alone and a plain word stay code.
    func testAFileNamedInCodeLinksWhenItIsThere() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-code-file-\(UUID())")
        try FileManager.default.createDirectory(at: root.appending(path: "Sources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appending(path: "Sources/App.swift"))
        let value = try content("`Sources/App.swift:12` and `Sources/App.swift#L3-L5` and `\(root.path)/Sources/App.swift` "
            + "and `Sources/Gone.swift` and `Sources` and `swift build` and `/` and `Sources/`")
        let links = value.resolved(relativeTo: root).runs.compactMap(\.link)
        XCTAssertEqual(links.count, 4)
        XCTAssertEqual(links[3].path(percentEncoded: false), root.appending(path: "Sources/").standardizedFileURL.path(percentEncoded: false))
        XCTAssertEqual(links[0].path(percentEncoded: false), root.appending(path: "Sources/App.swift").standardizedFileURL.path)
        XCTAssertEqual(links[0].fragment, "L12")
        XCTAssertEqual(links[1].fragment, "L3")
        XCTAssertNil(links[2].fragment)
        XCTAssertTrue(value.attributed.runs.allSatisfy { $0.link == nil }, "The parsed content keeps no file links")
    }

    /// `..` is read from the task's folder without an extra level, and `~/` from the home folder.
    func testLinksOutsideTheWorkspaceResolveFromItsParentAndTheHomeFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-inline-link-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let value = try content("[parent](../outside.txt) and [home](<~/Library/Application Support/notes.md:4>)")
        let links = value.resolved(relativeTo: root).runs.compactMap(\.link)
        XCTAssertEqual(links[0].standardizedFileURL.path, root.deletingLastPathComponent().appending(path: "outside.txt").standardizedFileURL.path)
        XCTAssertEqual(links[1].path(percentEncoded: false),
                       FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/notes.md:4").path(percentEncoded: false))
    }

    func testMixedUnicodeAndExistingPercentEscapesAreNotEscapedTwice() throws {
        let value = try content("[source](Sources/한글%20파일.swift#L3) and [hash](Notes/a%23b.txt) and [literal](Notes/100%done.txt)")
        let links = value.resolved(relativeTo: URL(filePath: "/tmp/workspace", directoryHint: .isDirectory)).runs.compactMap(\.link)
        XCTAssertEqual(links[0].path(percentEncoded: false), "/tmp/workspace/Sources/한글 파일.swift")
        XCTAssertEqual(links[0].fragment, "L3")
        XCTAssertEqual(links[1].path(percentEncoded: false), "/tmp/workspace/Notes/a#b.txt")
        XCTAssertEqual(links[2].path(percentEncoded: false), "/tmp/workspace/Notes/100%done.txt")
    }

    func testNestedStylesCombineWithoutLosingCodeOrEscapes() throws {
        let value = try content(#"***both*** and **`code`** and ~~old~~ &amp; ![alt](image.png)"#)
        XCTAssertEqual(value.plainText, "both and code and old & alt")
        let both = try XCTUnwrap(value.attributed.runs.first)
        XCTAssertEqual(both.inlinePresentationIntent, [.emphasized, .stronglyEmphasized])
        let code = try XCTUnwrap(value.attributed.runs.first { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertEqual(code.inlinePresentationIntent, [.code, .stronglyEmphasized])
        XCTAssertTrue(value.attributed.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true })
        XCTAssertTrue(value.attributed.runs.compactMap(\.link).isEmpty)
    }

    /// Only two tildes strike; one stays a tilde, as a range ("240~400ms") or "about" ("~5") writes it.
    func testOnlyDoubleTildesStrike() throws {
        func struck(_ value: TranscriptInlineContent) -> [String] {
            value.attributed.runs.filter { $0.inlinePresentationIntent?.contains(.strikethrough) == true }
                .map { String(value.attributed[$0.range].characters) }
        }
        let range = try content("240~400ms에서 110~150ms로, ~*about*~ ~`5`~ ~[five](https://example.com)~ and ~~gone~~")
        XCTAssertEqual(range.plainText, "240~400ms에서 110~150ms로, ~about~ ~5~ ~five~ and gone")
        XCTAssertEqual(struck(range), ["gone"])
        XCTAssertEqual(range.attributed.runs.first { $0.inlinePresentationIntent == .emphasized }
            .map { String(range.attributed[$0.range].characters) }, "about")
        // The same in a list, a quote and a table, and around and inside a double pair.
        let nested = try XCTUnwrap(TranscriptMarkdownDocument("- > ~~a ~b~ c~~ 1~2").blocks.first)
        guard case let .unorderedList(items, _) = nested, case let .blockQuote(quoted) = items.first?.blocks.first,
              case let .paragraph(quote) = quoted.first else { return XCTFail("\(nested)") }
        XCTAssertEqual(quote.plainText, "a ~b~ c 1~2")
        XCTAssertEqual(struck(quote).joined(), "a ~b~ c")
        guard case let .table(_, rows, _) = try XCTUnwrap(TranscriptMarkdownDocument("| a |\n| - |\n| 1~2 ~~x~~ 3~4 |").blocks.first)
        else { return XCTFail() }
        XCTAssertEqual(rows.first?.first?.plainText, "1~2 x 3~4")
        XCTAssertEqual(rows.first.flatMap(\.first).map(struck), ["x"])
    }

}
