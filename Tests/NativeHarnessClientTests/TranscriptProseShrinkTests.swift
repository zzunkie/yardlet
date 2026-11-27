import AppKit
import XCTest
@testable import NativeHarnessClient

/// A streaming message that loses rows (`isProse` flips from true to false when a table, mermaid
/// or details block joins a list, reusing the same `TranscriptProseContainerView`) must not keep the
/// old maximum height: TextKit 2's `usageBoundsForTextContainer` is a high-water mark and does not
/// shrink with the text, which left a ~450pt empty band under what became a two-line block.
///
/// The shrink is read from the last layout fragment's `maxY`, so an ordinary message needs no width
/// bounce: TextKit's width high-water mark leaks into reported size only through
/// `usageBoundsForTextContainer.maxX`, which `size(forWidth:)` overrides with the proposed width. A
/// fits-width message does return the container's own width, so that case still bounces the width,
/// but the bounce lives inside `layOutWhole(atWidth:)` so a caller running between `update(blocks:)`
/// and `size(forWidth:)` (notably `update(find:)`) never finds a zero-width container.
@MainActor
final class TranscriptProseShrinkTests: XCTestCase {
    func testAProseContainerShrinksWhenItsBlockDoes() {
        let view = TranscriptProseContainerView()
        let style = TranscriptProseStyle()
        let width: CGFloat = 400

        // A long paragraph that lays out well over a hundred points at `width`, filling the bug's
        // high-water mark.
        let longText = String(repeating: "This sentence is long enough that it wraps. ", count: 60)
        let long = TranscriptProseBlock(block: .paragraph(TranscriptInlineContent(plainText: longText)), path: [0])
        _ = view.update(blocks: [long], style: style)
        let longHeight = view.size(forWidth: width).height
        XCTAssertGreaterThan(longHeight, 200, "The long block must lay out tall enough to seed the high-water mark")
        XCTAssertEqual(view.laidOutHeight, longHeight, accuracy: 1,
                       "The debug laidOutHeight tracks the current layout, not the measurement cache")

        // The same width, a short block: height must drop back, not stay at the long block's height.
        let short = TranscriptProseBlock(block: .paragraph(TranscriptInlineContent(plainText: "Short. Two words.")), path: [0])
        _ = view.update(blocks: [short], style: style)
        let shortHeight = view.size(forWidth: width).height
        XCTAssertLessThan(shortHeight, longHeight / 2,
                          "After shrinking, the laid-out height must match the shorter text, not the old high-water mark")
        XCTAssertLessThan(view.laidOutHeight, longHeight / 2,
                          "The debug laidOutHeight must also report the shorter height")
    }

    /// Inline markdown completion (e.g. `**bold` → `**bold**`) streams a shorter trailing paragraph
    /// at the same width. The previous code reset the container width on every shrink and re-laid the
    /// whole text out, so a streaming answer paid O(N) per token. Ordinary (non-fits-width) messages
    /// now reuse the width — `newWidthLayouts` stays at the first measurement's count.
    func testAStreamingShrinkInANonFitsWidthMessageReusesTheLaidOutWidth() {
        let view = TranscriptProseContainerView()
        XCTAssertFalse(view.fitsWidth)
        let style = TranscriptProseStyle()
        let width: CGFloat = 400

        let long = TranscriptProseBlock(
            block: .paragraph(TranscriptInlineContent(plainText: String(repeating: "word ", count: 200))), path: [0]
        )
        _ = view.update(blocks: [long], style: style)
        _ = view.size(forWidth: width)
        XCTAssertEqual(view.newWidthLayouts, 1, "The first measurement sets the container width once")

        let short = TranscriptProseBlock(
            block: .paragraph(TranscriptInlineContent(plainText: "word word word")), path: [0]
        )
        _ = view.update(blocks: [short], style: style)
        _ = view.size(forWidth: width)
        XCTAssertEqual(view.newWidthLayouts, 1,
                       "A shrink in a non-fits-width message must not restart the layout")
    }

    /// A fits-width message (a sent request bubble) returns the container's own width, so a shrink
    /// has to bounce the width to shed TextKit's maximum — but through the pending flag inside
    /// `layOutWhole`, not the caller. Both the width and the height must drop back.
    func testAFitsWidthShrinkStillReturnsTheShortWidthAndHeight() {
        let view = TranscriptProseContainerView()
        view.fitsWidth = true
        let style = TranscriptProseStyle()
        let width: CGFloat = 400

        let long = TranscriptProseBlock(
            block: .paragraph(TranscriptInlineContent(plainText: String(repeating: "This sentence is wide enough. ", count: 20))),
            path: [0]
        )
        _ = view.update(blocks: [long], style: style)
        let longSize = view.size(forWidth: width)
        XCTAssertGreaterThan(longSize.height, 100)

        let short = TranscriptProseBlock(block: .paragraph(TranscriptInlineContent(plainText: "Short.")), path: [0])
        _ = view.update(blocks: [short], style: style)
        let shortSize = view.size(forWidth: width)
        XCTAssertLessThan(shortSize.width, longSize.width,
                          "A fits-width shrink must report the shorter line, not the old maximum width")
        XCTAssertLessThan(shortSize.height, longSize.height / 2)
    }

    /// Find's rebuild runs between `update(blocks:)` and `size(forWidth:)` in `updateNSView`. The
    /// earlier placement set `container.size = .zero` before find ran, so a search with a query or an
    /// active selection laid out at 0pt — one glyph per line. The pending flag keeps the old width in
    /// place until `layOutWhole(atWidth:)` bounces it, so `update(find:)` reads the real geometry and
    /// size reporting still matches the proposed width.
    func testAShrinkWithActiveFindDoesNotLayOutAtZeroWidth() {
        let view = TranscriptProseContainerView()
        XCTAssertFalse(view.fitsWidth)
        let style = TranscriptProseStyle()
        let width: CGFloat = 400

        let long = TranscriptProseBlock(
            block: .paragraph(TranscriptInlineContent(plainText: String(repeating: "This is a sentence. ", count: 40))),
            path: [0]
        )
        _ = view.update(blocks: [long], style: style)
        let longHeight = view.size(forWidth: width).height
        XCTAssertGreaterThan(longHeight, 100)

        var find = TranscriptProseFind()
        find.query = "sentence"
        view.update(find: find, contentChanged: true)

        let short = TranscriptProseBlock(
            block: .paragraph(TranscriptInlineContent(plainText: "Short sentence inside.")), path: [0]
        )
        let changed = view.update(blocks: [short], style: style)
        // The find rebuild that runs before `size(forWidth:)` must not see a zero-width container.
        view.update(find: find, contentChanged: changed)
        let shortSize = view.size(forWidth: width)
        XCTAssertEqual(shortSize.width, width,
                       "A non-fits-width message reports the proposed width, not whatever the container held")
        XCTAssertLessThan(shortSize.height, longHeight / 2,
                          "The shrink still reports the shorter height even while find is active")
    }
}
