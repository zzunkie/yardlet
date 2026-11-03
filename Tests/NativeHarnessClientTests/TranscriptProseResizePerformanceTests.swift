import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Windowless resize measurements. No provider events are published by this fixture.
@MainActor
final class TranscriptProseResizePerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NHC_PERF_BENCH"] == "1", "Set NHC_PERF_BENCH=1 to measure resizing")
    }

    private func text(_ source: String) -> TranscriptProseContainerView {
        let view = TranscriptProseContainerView()
        let blocks = TranscriptMarkdownDocument(source).blocks.enumerated().map {
            TranscriptProseBlock(block: $1, path: [$0])
        }
        view.update(blocks: blocks, style: TranscriptProseStyle())
        return view
    }
    /// Exercise real message layout separately from provider publications and row construction.
    func testLongMessageWidthChangesReportLayoutCost() throws {
        let source = (0..<1_000).map { index in
            "Paragraph \(index). " + String(repeating: "Words that wrap across the line as an answer does. ", count: 8)
        }.joined(separator: "\n\n")
        var finalHeights: [CGFloat] = []
        for live in [false, true] {
            let text = text(source)
            let initial = text.size(forWidth: 760)
            text.frame = NSRect(origin: .zero, size: initial)
            text.layoutSubtreeIfNeeded()
            let before = text.newWidthLayouts
            if live { text.viewWillStartLiveResize() }
            var samples: [Double] = []
            for width in [720.0, 680, 640, 600, 560, 520, 560, 600, 640, 680, 600] {
                let start = CFAbsoluteTimeGetCurrent()
                let size = text.size(forWidth: width)
                text.frame = NSRect(origin: .zero, size: size)
                text.layoutSubtreeIfNeeded()
                samples.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
                XCTAssertEqual(text.laidOutHeight, ceil(size.height))
            }
            if live { XCTAssertEqual(text.newWidthLayouts, before) }
            let end = CFAbsoluteTimeGetCurrent()
            if live { text.viewDidEndLiveResize() }
            let final = text.size(forWidth: 600)
            text.frame = NSRect(origin: .zero, size: final)
            text.layoutSubtreeIfNeeded()
            let commit = (CFAbsoluteTimeGetCurrent() - end) * 1_000
            XCTAssertEqual(text.laidOutHeight, ceil(final.height))
            finalHeights.append(final.height)
            if live { XCTAssertEqual(text.newWidthLayouts - before, 1) }
            PerfBenchRecord.write("prose-width-\(live ? "deferred" : "immediate")", [
                "resizeMainMs": samples.reduce(0, +), "resizeWorstMs": samples.max() ?? 0,
                "finalMainMs": commit, "widthLayoutCount": Double(text.newWidthLayouts - before)
            ])
            print("[prose-width] live=\(live) paragraphs=1000 widths=11 layoutChanges=\(text.newWidthLayouts - before) mainMilliseconds=\(samples) commitMilliseconds=\(commit)")
        }
        XCTAssertEqual(finalHeights[0], finalHeights[1])
    }

    func testLongConversationWidthChangesReportLayoutCost() throws {
        let entries = LongConversationFixture.claude(turns: 1_000, seed: "width-bench")
        for appearance in WindowlessRender.Appearance.allCases {
            for middle in [false, true] {
                for live in [false, true] {
                    let position = TranscriptReadingPosition()
                    if middle {
                        position.bookmark = .init(anchorID: LongConversationFixture.claudeTurnID(seed: "width-bench", turn: 500),
                                                  fraction: 0.4, followsLatest: false)
                    }
                    let view = ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode,
                                                                       status: .ready, latestTurnIsComplete: true),
                                                    readingPosition: position, actions: ConversationActions())
                        .environment(\.colorScheme, appearance == .light ? .light : .dark)
                    let host = WindowlessRender.Host(view, size: NSSize(width: 760, height: 700), appearance: appearance)
                    defer { host.close(); ViewBodyCensus.isEnabled = false; ViewBodyCensus.reset() }
                    host.settle()
                    let scroll = try XCTUnwrap(BlankFrameProbe.conversationScrollView(in: host.hosting))
                    let initialBookmark = position.bookmark
                    let initialDistance = (scroll.documentView?.bounds.maxY ?? 0) - scroll.contentView.bounds.maxY
                    ViewBodyCensus.isEnabled = true
                    ViewBodyCensus.reset()
                    let texts = TranscriptProseRenderingTests.containers(in: host.hosting)
                    if live { texts.forEach { $0.viewWillStartLiveResize() } }
                    var samples: [Double] = []
                    for width in [720.0, 680, 640, 600, 560, 520, 560, 600, 640, 680, 720] {
                        let start = CFAbsoluteTimeGetCurrent()
                        host.window.setContentSize(NSSize(width: width, height: 700))
                        host.hosting.layoutSubtreeIfNeeded()
                        samples.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
                    }
                    let finishing = CFAbsoluteTimeGetCurrent()
                    if live { texts.forEach { $0.viewDidEndLiveResize() } }
                    host.settle()
                    let finishWallMilliseconds = (CFAbsoluteTimeGetCurrent() - finishing) * 1_000
                    let distance = (scroll.documentView?.bounds.maxY ?? 0) - scroll.contentView.bounds.maxY
                    if middle {
                        XCTAssertEqual(position.bookmark.anchorID, initialBookmark.anchorID)
                        XCTAssertEqual(position.bookmark.fraction, initialBookmark.fraction, accuracy: 0.02)
                    } else {
                        XCTAssertEqual(distance, initialDistance, accuracy: 2, "Resizing keeps the conversation at its reading end")
                    }
                    for text in TranscriptProseRenderingTests.containers(in: host.hosting) {
                        XCTAssertEqual(text.laidOutHeight, ceil(text.bounds.height), accuracy: 1, "The final height is exact")
                    }
                    try WindowlessRender.writePNG(host.capture().bitmap,
                        to: WindowlessRender.directory("prose-width").appending(path: "\(appearance.rawValue)-middle-\(middle)-live-\(live).png"))
                    PerfBenchRecord.write("conversation-width-\(appearance.rawValue)-\(middle ? "middle" : "end")-\(live ? "deferred" : "immediate")", [
                        "resizeMainMs": samples.reduce(0, +), "resizeWorstMs": samples.max() ?? 0,
                        "finishWallMs": finishWallMilliseconds,
                        "rowLayoutCount": Double(ViewBodyCensus[.conversationRowLaidOut]),
                        "rowBodyCount": Double(ViewBodyCensus[.conversationTurn])
                    ])
                    print("[conversation-width] appearance=\(appearance.rawValue) middle=\(middle) live=\(live) entries=\(entries.count) widths=11 rowLayouts=\(ViewBodyCensus[.conversationRowLaidOut]) rowBodies=\(ViewBodyCensus[.conversationTurn]) mainMilliseconds=\(samples) finishWallMilliseconds=\(finishWallMilliseconds) bottomDistance=\(distance) before=\(initialBookmark) after=\(position.bookmark)")
                }
            }
        }
    }
}
