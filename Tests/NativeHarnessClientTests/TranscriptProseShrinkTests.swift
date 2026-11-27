import AppKit
import XCTest
@testable import NativeHarnessClient

/// A streaming message that loses rows (`isProse` flips from true to false when a table, mermaid
/// or details block joins a list, reusing the same `TranscriptProseContainerView`) must not keep the
/// old maximum height: TextKit 2's `usageBoundsForTextContainer` is a high-water mark and does not
/// shrink with the text, which left a ~450pt empty band under what became a two-line block.
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
}
