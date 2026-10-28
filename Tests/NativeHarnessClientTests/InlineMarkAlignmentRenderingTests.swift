import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// A caret, spinner or icon set beside a line's words sits on the words' visual middle (their cap
/// height), not on their baseline or the top of the row (2026-10-22 alignment audit). Each line is
/// drawn alone, without a window on screen, light and dark, into `.build/alignment-qa/`; the test
/// finds the words' ink and the mark's ink and compares their vertical middles.
@MainActor
final class InlineMarkAlignmentRenderingTests: XCTestCase {
    /// How far a mark's middle may sit from the words' middle, in points: under a pixel at 2×.
    static let tolerance: CGFloat = 0.6

    func testAStatusLinesCaretSitsOnItsWordsMiddle() throws {
        for isOpen in [false, true] {
            let offset = try Self.offset(named: "status-line-caret-\(isOpen ? "open" : "closed")") {
                ConversationStatusLine(
                    words: [ConversationLineWords(verb: "EHEH")], phase: .completed, hasDetail: true,
                    startsOpen: isOpen, accessibilityLabel: "Command"
                ) { EmptyView() } actions: { EmptyView() } detail: { EmptyView() }
            }
            XCTAssertLessThanOrEqual(abs(offset), Self.tolerance, "open \(isOpen): \(offset) pt")
        }
    }

    func testAConnectorCallsIconSitsOnItsWordsMiddle() throws {
        let activity = HarnessActivity(id: "toolu_1", kind: "mcp__linear__list_issues", title: "mcp__linear__list_issues")
        let tool = ConversationTool(kind: .mcp, name: "EHEH",
                                    connector: ConnectorToolLabels.Label(connector: "Linear", presetID: nil, tool: "EHEH"))
        let item = ConversationItem(id: "t", kind: .tool(tool), phase: .completed,
                                    source: .transcript(TranscriptEntry(content: .activity(activity, state: .completed))))
        let offset = try Self.offset(named: "status-line-connector") {
            ConversationWorkLine(item: item, harness: .claudeCode, workspaceURL: nil)
        }
        XCTAssertLessThanOrEqual(abs(offset), Self.tolerance, "\(offset) pt")
    }

    func testADetailsBlocksCaretSitsOnItsSummarysMiddle() throws {
        // The card's left border is the first ink; the caret follows it.
        let offset = try Self.offset(named: "details-block-caret", markIsFirst: true, skipsBorder: true) {
            CodexDetailsBlock(summary: "EHEH", startsOpen: false, path: [0]) { EmptyView() }
        }
        XCTAssertLessThanOrEqual(abs(offset), Self.tolerance, "\(offset) pt")
    }

    func testTheTurnHeadersCaretSitsOnItsWordsMiddle() throws {
        let offset = try Self.offset(named: "turn-header-caret") {
            // As the turn header lays it out, in a row.
            HStack(spacing: 8) {
                CodexWorkSummaryLabel(status: .completed, timing: ConversationTurnTiming(durationMilliseconds: 50_000),
                                      isExpanded: false, canExpand: true)
            }
        }
        XCTAssertLessThanOrEqual(abs(offset), Self.tolerance, "\(offset) pt")
    }

    // MARK: - Measuring

    /// The mark's vertical middle less the words' (positive: the mark sits low), in points, from the
    /// light drawing. The mark is the last cluster of ink, or the first when `markIsFirst`.
    private static func offset<Content: View>(
        named name: String, markIsFirst: Bool = false, skipsBorder: Bool = false,
        @ViewBuilder content: () -> Content
    ) throws -> CGFloat {
        let directory = try WindowlessRender.directory("alignment-qa")
        let size = NSSize(width: 360, height: 44)
        let view = content()
        let captures = try WindowlessRender.hostedInBothAppearances(name, in: directory, size: size) { appearance in
            view
                .padding(.horizontal, 10)
                .frame(width: size.width, height: size.height, alignment: .leading)
                .background(ParityTheme.canvas)
                .environment(\.colorScheme, appearance.colorScheme)
        }
        let capture = captures[0]
        let clusters = Array(inkClusters(capture.bitmap).dropFirst(skipsBorder ? 1 : 0))
        XCTAssertGreaterThanOrEqual(clusters.count, 2, "\(name): \(clusters)")
        guard clusters.count >= 2 else { return .infinity }
        let mark = markIsFirst ? clusters[0] : clusters[clusters.count - 1]
        let words = markIsFirst ? clusters[1] : clusters[0]
        let offset = (mark.middle - words.middle) / capture.backingScaleFactor
        print("alignment \(name): \(offset) pt (mark \(mark), words \(words))")
        return offset
    }

    private struct Cluster: CustomStringConvertible {
        var minX: Int, maxX: Int, minY: Int, maxY: Int
        var middle: CGFloat { CGFloat(minY + maxY + 1) / 2 }
        var description: String { "x \(minX)…\(maxX) y \(minY)…\(maxY)" }
    }

    /// Runs of columns with ink, split where at least a few blank columns separate them, each with
    /// the rows its ink covers. "EHEH" is one cluster: its letters sit closer than the gap.
    private static func inkClusters(_ bitmap: NSBitmapImageRep) -> [Cluster] {
        // Inside a card when the line draws one: the right end of the middle row holds no ink.
        let background = bitmap.colorAt(x: bitmap.pixelsWide - 40, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB)
        func isInk(_ x: Int, _ y: Int) -> Bool {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), let b = background else { return false }
            let d = abs(c.redComponent - b.redComponent) + abs(c.greenComponent - b.greenComponent)
                + abs(c.blueComponent - b.blueComponent)
            return d > 0.12
        }
        let gap = Int(4 * (CGFloat(bitmap.pixelsWide) / 360))
        var clusters: [Cluster] = []
        var blank = gap
        // Inside the card's border, which is ink of its own.
        let inset = Int(8 * (CGFloat(bitmap.pixelsWide) / 360))
        for x in inset..<(bitmap.pixelsWide - inset) {
            let rows = (inset..<(bitmap.pixelsHigh - inset)).filter { isInk(x, $0) }
            guard let top = rows.first, let bottom = rows.last else { blank += 1; continue }
            if blank >= gap || clusters.isEmpty {
                clusters.append(Cluster(minX: x, maxX: x, minY: top, maxY: bottom))
            } else {
                clusters[clusters.count - 1].maxX = x
                clusters[clusters.count - 1].minY = min(clusters[clusters.count - 1].minY, top)
                clusters[clusters.count - 1].maxY = max(clusters[clusters.count - 1].maxY, bottom)
            }
            blank = 0
        }
        return clusters
    }
}
