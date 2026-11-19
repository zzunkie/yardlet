import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import NativeHarnessClient

/// Pictures an answer's Markdown names (`![alt](source)`) and a Codex inline visualization, drawn in a
/// conversation at two widths and in both appearances. Review images go to `.build/chat-media-qa/`;
/// set `YARDLET_MEDIA_QA_LABEL` to name a run (for example `before`).
@MainActor
final class ConversationMediaRenderingTests: XCTestCase {
    private let decoder = CodexTaskDecoder()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory.appending(path: "yardlet-media-\(UUID().uuidString)",
                                                                     directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace.appending(path: "docs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appending(path: "shots"), withIntermediateDirectories: true)
        // A chart as a Retina screenshot would be: 1,600 × 1,000 pixels at 144 dpi, 800 × 500 points.
        try Self.writeChart(to: workspace.appending(path: "docs/latency.png"), pixels: CGSize(width: 1_600, height: 1_000),
                            dpi: 144, hue: 0.58)
        // Two smaller pictures side by side.
        try Self.writeChart(to: workspace.appending(path: "before.png"), pixels: CGSize(width: 900, height: 600),
                            dpi: 144, hue: 0.02)
        try Self.writeChart(to: workspace.appending(path: "after.png"), pixels: CGSize(width: 900, height: 600),
                            dpi: 144, hue: 0.33)
        // A phone screenshot, taller than it is wide.
        try Self.writeChart(to: workspace.appending(path: "phone.png"), pixels: CGSize(width: 750, height: 1_624),
                            dpi: 144, hue: 0.75)
    }

    override func tearDownWithError() throws {
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
    }

    private var label: String {
        ProcessInfo.processInfo.environment["YARDLET_MEDIA_QA_LABEL"].map { "-" + $0 } ?? ""
    }

    func testAnAnswersPicturesDrawBetweenItsParagraphs() throws {
        let directory = try WindowlessRender.directory("chat-media-qa")
        for width in [720, 1_100] {
            for appearance in WindowlessRender.Appearance.allCases {
                let drawing = try ConversationDrawing.draw(
                    conversation(.claudeCode, entries: entries(answer: Self.answer)),
                    size: NSSize(width: width, height: 2_000), appearance: appearance, passes: 30
                )
                try WindowlessRender.writePNG(drawing.capture.bitmap, to: directory.appending(
                    path: "answer-pictures\(label)-\(appearance.suffix)-\(width).png"))
            }
        }
    }

    func testACodexInlineVisualizationDrawsInTheConversation() throws {
        let directory = try WindowlessRender.directory("chat-media-qa")
        try Self.visualization.write(to: workspace.appending(path: "growth.html"), atomically: true, encoding: .utf8)
        for appearance in WindowlessRender.Appearance.allCases {
            let drawing = try ConversationDrawing.draw(
                ConversationTimeline(source: .codex(codexThread(answer: Self.codexAnswer), workspaceURL: workspace,
                                                    historySelection: nil))
                    .environment(\.transcriptWorkspaceURL, workspace),
                size: NSSize(width: 900, height: 900), appearance: appearance, passes: 40
            )
            try WindowlessRender.writePNG(drawing.capture.bitmap, to: directory.appending(
                path: "codex-visualization\(label)-\(appearance.suffix)-900.png"))
        }
    }

    /// A long conversation with a picture in every answer holds bitmaps only for the pictures on screen: each takes
    /// its place from its size alone, decodes once it comes into view and lets its bitmap go once it leaves.
    func testALongConversationHoldsOnlyThePicturesInView() throws {
        for index in 0..<12 {
            try Self.writeChart(to: workspace.appending(path: "shots/\(index).png"), pixels: CGSize(width: 1_600, height: 1_000),
                                dpi: 144, hue: CGFloat(index) / 12)
        }
        var entries: [TranscriptEntry] = []
        for turn in 0..<120 {
            let at = start.addingTimeInterval(Double(turn) * 10)
            entries.append(TranscriptEntry(createdAt: at, content: .user(text: "Turn \(turn): show the chart.")))
            entries.append(TranscriptEntry(createdAt: at.addingTimeInterval(2), content: .assistant(
                text: "Here is turn \(turn).\n\n![chart \(turn)](shots/\(turn % 12).png)\n\nIt holds.", isStreaming: false)))
        }
        let size = NSSize(width: 900, height: 900)
        let host = WindowlessRender.Host(
            conversation(.claudeCode, entries: entries).frame(width: size.width, height: size.height).background(ParityTheme.canvas),
            size: size, appearance: .light)
        defer { host.close() }
        host.settle(until: { Self.bitmaps(in: host.hosting).contains(where: \.isDrawn) })
        host.settle(passes: 10)
        let scroll = try XCTUnwrap(Self.scrollView(in: host.hosting))
        let atEnd = Self.bitmaps(in: host.hosting)
        let drawnAtEnd = atEnd.filter(\.isDrawn)
        XCTAssertGreaterThan(atEnd.count, 4, "the conversation should mount more pictures than fit")
        XCTAssertLessThanOrEqual(drawnAtEnd.count, 3, "only the pictures in view hold bitmaps")

        // Scroll up through what is mounted: the pictures left behind let go, the ones now in view draw.
        let top = scroll.documentView.map { $0.isFlipped ? 0 : $0.bounds.height - scroll.contentView.bounds.height } ?? 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.settle(until: { Self.bitmaps(in: host.hosting).contains { $0.isDrawn && !drawnAtEnd.contains($0) } })
        host.settle(passes: 10)
        let drawnAtTop = Self.bitmaps(in: host.hosting).filter(\.isDrawn)
        XCTAssertLessThanOrEqual(drawnAtTop.count, 3)
        XCTAssertTrue(drawnAtEnd.allSatisfy { !$0.isDrawn }, "the pictures scrolled away keep no bitmap")
        print("media long conversation: mounted \(Self.bitmaps(in: host.hosting).count) pictures, drawn \(drawnAtEnd.count) at the end and \(drawnAtTop.count) at the top")
    }

    private static func bitmaps(in view: NSView) -> [TranscriptPictureBitmapView] {
        ((view as? TranscriptPictureBitmapView).map { [$0] } ?? []) + view.subviews.flatMap { bitmaps(in: $0) }
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        func all(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(all)
        }
        return all(view).max { $0.frame.height < $1.frame.height }
    }

    // MARK: - Conversations

    private static let answer = """
    The latency drops after the cache change. The chart below is p95 per endpoint over the last day:

    ![p95 latency per endpoint](docs/latency.png)

    Before and after the fix, side by side:

    ![before](before.png) ![after](after.png)

    The phone layout keeps the list readable: ![phone screenshot](phone.png) The header no longer clips.

    A file that is not there: ![missing](docs/missing.png)

    A picture on the web: ![badge](https://example.com/badge.png)

    A recording of the flow, with a long description: ![screen recording of the onboarding flow from the first launch](docs/flow.mov)
    """

    private static let codexAnswer = """
    Here is growth by month, drawn from `metrics.csv`.

    ::codex-inline-vis{file="growth.html" title="Growth by month"}

    March is the outlier: one customer doubled their seats.
    """

    private static let visualization = """
    <!doctype html><html><head><meta charset="utf-8"><style>
    :root{color-scheme:light dark;font:13px -apple-system,system-ui}
    body{margin:0;padding:12px}.bars{display:flex;gap:10px;align-items:flex-end;height:160px}
    .bar{flex:1;background:#4c8bf5;border-radius:4px 4px 0 0}.labels{display:flex;gap:10px;margin-top:6px}
    .labels span{flex:1;text-align:center;opacity:.7}
    </style></head><body><h3 style="margin:0 0 10px">Growth by month</h3>
    <div class="bars"><div class="bar" style="height:40%"></div><div class="bar" style="height:55%"></div>
    <div class="bar" style="height:100%"></div><div class="bar" style="height:62%"></div></div>
    <div class="labels"><span>Jan</span><span>Feb</span><span>Mar</span><span>Apr</span></div></body></html>
    """

    private func entries(answer: String) -> [TranscriptEntry] {
        [
            TranscriptEntry(createdAt: start, content: .user(text: "Show me the latency chart and the screenshots.")),
            TranscriptEntry(createdAt: start.addingTimeInterval(2), content: .assistant(text: answer, isStreaming: false))
        ]
    }

    private func conversation(_ harness: HarnessKind, entries: [TranscriptEntry]) -> some View {
        ConversationTimeline(
            source: .transcript(entries: entries, harness: harness, status: .ready, latestTurnIsComplete: true),
            actions: ConversationActions()
        )
        .environment(\.transcriptWorkspaceURL, workspace)
    }

    private func codexThread(answer: String) -> CodexTaskState {
        var thread = decoder.thread(from: .object(["id": .string("thread-media")]))!
        thread.turns = [decoder.turn(from: .object([
            "id": .string("turn-1"), "status": .string("completed"), "durationMs": .integer(4_000),
            "items": .array([
                .object(["id": .string("u1"), "type": .string("userMessage"),
                         "content": .array([.object(["type": .string("text"), "text": .string("Chart growth by month.")])])]),
                .object(["id": .string("a1"), "type": .string("agentMessage"), "text": .string(answer),
                         "phase": .string("final_answer")])
            ])
        ]), fallbackID: "turn-1")!]
        return CodexTaskState(thread: thread)
    }

    // MARK: - Pictures

    /// A bar chart of `pixels` at `dpi`, in one hue, as a PNG.
    static func writeChart(to url: URL, pixels: CGSize, dpi: Double, hue: CGFloat) throws {
        let width = Int(pixels.width), height = Int(pixels.height)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor(hue: hue, saturation: 0.08, brightness: 0.98, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let bars = 8
        let gap = CGFloat(width) * 0.02
        let barWidth = (CGFloat(width) - gap * CGFloat(bars + 1)) / CGFloat(bars)
        for index in 0..<bars {
            let fraction = 0.25 + 0.7 * abs(sin(Double(index) * 1.3 + Double(hue) * 10))
            context.setFillColor(NSColor(hue: hue, saturation: 0.65, brightness: 0.8, alpha: 1).cgColor)
            context.fill(CGRect(x: gap + CGFloat(index) * (barWidth + gap), y: CGFloat(height) * 0.08,
                                width: barWidth, height: CGFloat(height) * 0.8 * fraction))
        }
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
