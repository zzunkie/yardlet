import Foundation
import XCTest
@testable import NativeHarnessClient

/// The row list's place keeping (`ConversationRowGeometry`), without a window: whatever changes in the
/// list, the viewport goes back to the row it showed at the same point of it, or to the end while
/// following, and only the reader's scrolling moves what they see.
final class ConversationRowGeometryTests: XCTestCase {
    private let viewport: CGFloat = 600

    func testFindsTheRowsInAStretchOfTheList() {
        let geometry = ConversationRowGeometry(ids: ["a", "b", "c", "d"], heights: [100, 300, 50, 400])
        XCTAssertEqual(geometry.contentHeight, 850)
        XCTAssertEqual(geometry.rows(from: 0, to: 100), 0..<1, "a row ending at the stretch's bottom")
        XCTAssertEqual(geometry.rows(from: 99, to: 101), 0..<2)
        XCTAssertEqual(geometry.rows(from: 400, to: 451), 2..<4, "a row starting inside the stretch")
        XCTAssertEqual(geometry.rows(from: -500, to: 2_000), 0..<4)
        XCTAssertEqual(geometry.rows(from: 900, to: 1_000), 4..<4, "past the end")
        XCTAssertEqual(ConversationRowGeometry().rows(from: 0, to: 600), 0..<0)
    }

    func testRowsArrivingAboveKeepThePlaceRead() {
        var geometry = ConversationRowGeometry(ids: ["c", "d", "e"], heights: [400, 500, 700])
        let anchor = geometry.anchor(offset: 650, following: false)
        XCTAssertEqual(anchor, .row(id: "d", into: 250, height: 500))
        geometry.setRows(["a", "b", "c", "d", "e"], heights: [300, 900, 400, 500, 700])
        XCTAssertEqual(geometry.offset(for: anchor, viewportHeight: viewport, fallback: 650), 1_850,
                       "d's top went down by the rows above it, and the viewport with it")
    }

    func testTheFirstRowsLeadGivingWayToRowsAboveMovesNothingInView() {
        // The first row's lead is the conversation's top; once rows arrive above it, the space between turns.
        var geometry = ConversationRowGeometry(ids: ["c", "d"], heights: [460, 500], leads: [60, 24])
        let anchor = geometry.anchor(offset: 100, following: false)
        XCTAssertEqual(anchor, .row(id: "c", into: 40, height: 400))
        geometry.setRows(["a", "b", "c", "d"], heights: [360, 324, 424, 500], leads: [60, 24, 24, 24])
        XCTAssertEqual(geometry.offset(for: anchor, viewportHeight: viewport, fallback: 100), 748,
                       "c's content starts at 708, and the viewport 40 points into it")
    }

    func testARowAboveTheOneReadChangingHeightMovesNothingInView() {
        var geometry = ConversationRowGeometry(ids: ["a", "b", "c"], heights: [500, 500, 900])
        let anchor = geometry.anchor(offset: 1_100, following: false)
        geometry.setHeight(80, ofRow: 0)
        XCTAssertEqual(geometry.offset(for: anchor, viewportHeight: viewport, fallback: 1_100), 680)
        XCTAssertEqual(geometry.top(ofRow: 2), 580)
    }

    func testTheRowReadGrowingBelowTheViewportsTopKeepsWhatIsAboveIt() {
        var geometry = ConversationRowGeometry(ids: ["a", "b"], heights: [500, 900])
        let anchor = geometry.anchor(offset: 700, following: false)
        geometry.setHeight(1_400, ofRow: 1)
        XCTAssertEqual(geometry.offset(for: anchor, viewportHeight: viewport, fallback: 700), 700)
    }

    func testARowBelowChangingHeightKeepsTheViewport() {
        var geometry = ConversationRowGeometry(ids: ["a", "b", "c"], heights: [500, 500, 900])
        let anchor = geometry.anchor(offset: 200, following: false)
        geometry.setHeight(100, ofRow: 2)
        XCTAssertEqual(geometry.offset(for: anchor, viewportHeight: viewport, fallback: 200), 200)
        XCTAssertEqual(geometry.contentHeight, 1_100)
    }

    func testANewWidthKeepsThePointReadInItsRow() {
        var geometry = ConversationRowGeometry(ids: ["a", "b", "c"], heights: [400, 1_000, 600])
        let anchor = geometry.anchor(offset: 900, following: false)
        XCTAssertEqual(anchor, .row(id: "b", into: 500, height: 1_000))
        // Narrower: every row's lines wrap more, b half as tall again.
        geometry.setRows(["a", "b", "c"], heights: [600, 1_500, 900])
        XCTAssertEqual(geometry.offset(for: anchor, viewportHeight: viewport, scales: true, fallback: 900), 1_350,
                       "halfway into b, as before")
    }

    func testFollowingKeepsTheEndInViewAsTheConversationGrows() {
        var geometry = ConversationRowGeometry(ids: ["a", "b"], heights: [500, 900])
        let anchor = geometry.anchor(offset: 800, following: true)
        XCTAssertEqual(anchor, .end)
        geometry.setHeight(1_300, ofRow: 1)
        XCTAssertEqual(geometry.offset(for: anchor, viewportHeight: viewport, fallback: 800), 1_200)
        XCTAssertEqual(geometry.distanceFromEnd(offset: 1_200, viewportHeight: viewport), 0)
        geometry.setRows(["a", "b", "c"], heights: [500, 1_300, 200])
        XCTAssertEqual(geometry.offset(for: anchor, viewportHeight: viewport, fallback: 1_200), 1_400)
    }

    func testAPlaceStaysInsideTheList() {
        var geometry = ConversationRowGeometry(ids: ["a", "b"], heights: [500, 900])
        let anchor = geometry.anchor(offset: 700, following: false)
        geometry.setHeight(100, ofRow: 1)
        XCTAssertEqual(geometry.offset(for: anchor, viewportHeight: viewport, fallback: 700), 0,
                       "the list became shorter than the viewport")
        let gone = ConversationRowGeometry.Anchor.row(id: "z", into: 0, height: 10)
        XCTAssertEqual(geometry.offset(for: gone, viewportHeight: 300, fallback: 250), 250, "a row that left keeps the offset")
        XCTAssertEqual(geometry.offset(for: gone, viewportHeight: 300, fallback: 900), 300)
    }
}
