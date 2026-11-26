import AppKit
import AVFoundation
import AVKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import NativeHarnessClient

/// Pictures an answer's Markdown names (`![alt](source)`), its Mermaid diagrams and a Codex inline visualization, drawn
/// in a conversation at two widths and in both appearances. Review images go to `.build/chat-media-qa/`;
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
        // A two-second screen recording and a three-second sound.
        try Self.writeMovie(to: workspace.appending(path: "docs/flow.mov"), pixels: CGSize(width: 1_280, height: 800))
        try Self.writeSound(to: workspace.appending(path: "voice.m4a"))
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
    /// its place from its size alone, decodes once it comes into view and lets its bitmap go once it leaves. The row
    /// list keeps the views of the rows a viewport above and below the one in view (`ConversationRowListController
    /// .overscan`), so some pictures are in the window without being on screen.
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
        XCTAssertGreaterThan(atEnd.count, drawnAtEnd.count, "the conversation should mount more pictures than fit")
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

    /// Mermaid blocks draw as diagrams, a flowchart and a sequence diagram, and again when the appearance changes; a
    /// block Mermaid cannot read stays its code.
    func testMermaidBlocksDrawAsDiagramsInBothAppearances() throws {
        let directory = try WindowlessRender.directory("chat-media-qa")
        let size = NSSize(width: 900, height: 1_400)
        // The window's appearance is the conversation's, so changing it changes the diagrams'.
        let host = WindowlessRender.Host(
            conversation(.claudeCode, entries: entries(answer: Self.mermaidAnswer))
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(ParityTheme.canvas),
            size: size, appearance: .light)
        defer { host.close() }
        for appearance in WindowlessRender.Appearance.allCases {
            host.window.appearance = NSAppearance(named: appearance.appKitName)
            let isDark = appearance == .dark
            let drawn = [Self.flowchart, Self.sequenceDiagram].map { MermaidDiagrams.Key(source: $0, isDark: isDark) }
            let broken = MermaidDiagrams.Key(source: Self.brokenDiagram, isDark: isDark)
            host.settle(until: {
                drawn.allSatisfy { MermaidDiagrams.shared.cached($0) != nil } && MermaidDiagrams.shared.cached(broken) != nil
                    && Self.diagrams(in: host.hosting).filter(\.isDrawn).count == 2
            })
            host.settle(passes: 5)
            guard case .failed? = MermaidDiagrams.shared.cached(broken) else { return XCTFail("Mermaid cannot read it") }
            XCTAssertEqual(Self.diagrams(in: host.hosting).count, 2, "the block Mermaid cannot read stays its code")
            try WindowlessRender.writePNG(try host.capture().bitmap, to: directory.appending(
                path: "mermaid\(label)-\(appearance.suffix)-900.png"))
        }
    }

    /// A long conversation with a diagram in every answer draws only the diagrams that come on screen, each once:
    /// one scrolled back into view is drawn from what was kept, without Mermaid.
    func testALongConversationDrawsOnlyTheDiagramsOnScreen() throws {
        // Sources no earlier test drew, so the shared cache does not answer for them.
        let run = UUID().uuidString
        var entries: [TranscriptEntry] = []
        for turn in 0..<120 {
            let at = start.addingTimeInterval(Double(turn) * 10)
            entries.append(TranscriptEntry(createdAt: at, content: .user(text: "Turn \(turn): draw the flow.")))
            entries.append(TranscriptEntry(createdAt: at.addingTimeInterval(2), content: .assistant(text: """
                Turn \(turn):

                ```mermaid
                flowchart LR
                  A[Request \(turn)] --> B{Cached?} --> C[Reply \(turn)]
                  %% \(run)
                ```

                It holds.
                """, isStreaming: false)))
        }
        let size = NSSize(width: 900, height: 900)
        let host = WindowlessRender.Host(
            conversation(.claudeCode, entries: entries).frame(width: size.width, height: size.height).background(ParityTheme.canvas),
            size: size, appearance: .light)
        defer { host.close() }
        let diagrams = MermaidDiagrams.shared
        let before = diagrams.renderCount
        host.settle(until: { Self.diagrams(in: host.hosting).contains(where: \.isDrawn) })
        host.settle(passes: 10)
        let mounted = Self.mermaidBlocks(in: host.hosting)
        let onScreenAtEnd = mounted.filter(\.isOnScreen).count
        let drawnAtEnd = Self.diagrams(in: host.hosting).filter(\.isDrawn)
        let rendersAtEnd = diagrams.renderCount - before
        XCTAssertGreaterThan(mounted.count, rendersAtEnd + 2, "the conversation should mount more diagrams than it draws")
        XCTAssertGreaterThan(rendersAtEnd, 0)
        XCTAssertLessThanOrEqual(rendersAtEnd, onScreenAtEnd, "only the diagrams on screen are drawn")

        // The reader's own scrolling, which stops the conversation following its end: a notch of the wheel, then on.
        let scroll = try XCTUnwrap(Self.scrollView(in: host.hosting))
        func read(to y: (NSView) -> CGFloat) throws {
            let document = try XCTUnwrap(scroll.documentView)
            let towardTop = (y(document) < scroll.contentView.bounds.minY) == document.isFlipped
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                              wheel1: towardTop ? 3 : -3, wheel2: 0, wheel3: 0))
            scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
            host.settle(passes: 2)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y(document)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        // Up through what is mounted: the diagrams now in view are drawn, those left behind let their bitmaps go.
        try read { $0.isFlipped ? 0 : $0.bounds.height - scroll.contentView.bounds.height }
        host.settle(until: { Self.diagrams(in: host.hosting).contains { $0.isDrawn && !drawnAtEnd.contains($0) } })
        host.settle(passes: 10)
        let drawnAtTop = Self.diagrams(in: host.hosting).filter(\.isDrawn)
        let onScreenAtTop = Self.mermaidBlocks(in: host.hosting).filter(\.isOnScreen).count
        let rendersAtTop = diagrams.renderCount - before
        XCTAssertGreaterThan(rendersAtTop, rendersAtEnd)
        XCTAssertLessThanOrEqual(rendersAtTop - rendersAtEnd, onScreenAtTop, "only the diagrams on screen are drawn")
        XCTAssertTrue(drawnAtEnd.allSatisfy { !$0.isDrawn }, "the diagrams scrolled away keep no bitmap")

        // Back down: the diagrams there show again from what was kept.
        try read { $0.isFlipped ? $0.bounds.height - scroll.contentView.bounds.height : 0 }
        host.settle(until: { Self.diagrams(in: host.hosting).contains { $0.isDrawn && !drawnAtTop.contains($0) } })
        host.settle(passes: 20)
        XCTAssertEqual(diagrams.renderCount - before, rendersAtTop, "a diagram scrolled back into view is not drawn again")
        print("mermaid long conversation: mounted \(mounted.count) blocks, \(onScreenAtEnd) on screen at the end; Mermaid drew \(rendersAtEnd) at the end, \(rendersAtTop) after scrolling to the top (\(onScreenAtTop) on screen there) and \(diagrams.renderCount - before) after scrolling back")
    }

    /// A video plays in place once pressed, and only then has a player; starting a sound pauses it.
    func testAVideoPlaysInPlaceWhenPressed() throws {
        let answer = "The flow: ![flow recording](docs/flow.mov)\n\nThe note: ![voice note](voice.m4a)"
        let size = NSSize(width: 900, height: 1_000)
        let host = WindowlessRender.Host(
            conversation(.claudeCode, entries: entries(answer: answer)).frame(width: size.width, height: size.height),
            size: size, appearance: .dark)
        defer { host.close() }
        host.settle(until: { Self.bitmaps(in: host.hosting).contains(where: \.isDrawn) })
        XCTAssertTrue(Self.players(in: host.hosting).isEmpty, "no player before the video is played")
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: "flow recording"))
        host.settle(until: { Self.players(in: host.hosting).count == 1 })
        let video = try XCTUnwrap(Self.players(in: host.hosting).first?.player)
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: "voice note"))
        host.settle(until: { Self.players(in: host.hosting).count == 2 })
        XCTAssertEqual(video.rate, 0, "starting the sound pauses the video")
    }

    /// A web image stays its name and host until the person asks for it, then draws from memory as a file does, and
    /// its bytes go with the conversation that loaded them. Nothing is fetched here: the load is the test's.
    func testAWebImageLoadsOnlyWhenAskedAndStaysInMemory() async throws {
        let png = try Data(contentsOf: workspace.appending(path: "before.png"))
        let address = try XCTUnwrap(URL(string: "https://images.example.com/chart.png"))
        let source = "The chart: ![latency chart](https://images.example.com/chart.png)"
        let picture = TranscriptMarkdownPicture(source: address.absoluteString, alt: "latency chart", title: nil, link: nil)
        let directory = try WindowlessRender.directory("chat-media-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let fetched = LockedCount()
            let webImages = TranscriptWebImages(fetch: { _ in fetched.increment(); return png })
            let size = NSSize(width: 720, height: 360)
            let host = WindowlessRender.Host(
                TranscriptMarkdownPictures(pictures: [picture], fullSource: source, dialect: .standard)
                    .environment(\.transcriptWebImages, webImages)
                    .padding(20).frame(width: size.width, height: size.height, alignment: .topLeading)
                    .background(ParityTheme.canvas),
                size: size, appearance: appearance)
            defer { host.close() }
            host.settle()
            XCTAssertEqual(fetched.value, 0, "Nothing is fetched before the person asks")
            XCTAssertTrue(Self.bitmaps(in: host.hosting).isEmpty)
            try WindowlessRender.writePNG(try host.capture().bitmap, to: directory.appending(
                path: "web-image-asked-\(appearance.suffix).png"))

            XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Load image")))
            await host.settle(until: { Self.bitmaps(in: host.hosting).contains(where: \.isDrawn) })
            XCTAssertEqual(fetched.value, 1)
            let memory = try XCTUnwrap(webImages.loaded(address))
            XCTAssertEqual(memory.scheme, TranscriptMemoryImages.scheme, "Kept in memory, not on disk")
            XCTAssertEqual(TranscriptMarkdownPictures.images(in: source, dialect: .standard, workspace: workspace,
                                                             webImages: webImages).map(\.url), [memory],
                           "The image preview opens it with the message's other images")
            try WindowlessRender.writePNG(try host.capture().bitmap, to: directory.appending(
                path: "web-image-loaded-\(appearance.suffix).png"))
        }

        // The bytes go with the conversation that loaded them.
        var webImages: TranscriptWebImages? = TranscriptWebImages(fetch: { _ in png })
        webImages?.load(address)
        try await waitUntil { webImages?.loaded(address) != nil }
        let memory = try XCTUnwrap(webImages?.loaded(address))
        XCTAssertNotNil(TranscriptMemoryImages.shared.data(for: memory))
        webImages = nil
        try await waitUntil { TranscriptMemoryImages.shared.data(for: memory) == nil }
    }

    /// Where a web image may be fetched from: `https` to a public address, never a private, loopback, link-local,
    /// shared or reserved one, written as a name or a number.
    func testAWebImageIsFetchedOnlyFromAPublicHTTPSAddress() throws {
        for address in ["93.184.215.14", "2606:2800:21f:cb07:6820:80da:af6b:8b2c", "8.8.8.8"] {
            XCTAssertTrue(TranscriptWebImageLoader.isPublic(address: address), address)
        }
        for address in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.169.254",
                        "100.64.0.1", "0.0.0.0", "224.0.0.1", "198.18.0.1", "::1", "::", "fe80::1", "fd00::1", "ff02::1",
                        "::ffff:127.0.0.1", "::ffff:10.0.0.1", "64:ff9b::a00:1", "fe80::1%en0", "not an address"] {
            XCTAssertFalse(TranscriptWebImageLoader.isPublic(address: address), address)
        }
        for url in ["http://93.184.215.14/a.png", "https://127.0.0.1/a.png", "https://localhost/a.png",
                    "https://[::1]/a.png", "https://169.254.169.254/latest/meta-data", "https://10.0.0.1/a.png",
                    "file:///etc/hosts", "data:image/png;base64,AAAA"] {
            XCTAssertFalse(TranscriptWebImageLoader.isAllowed(try XCTUnwrap(URL(string: url))), url)
        }
        XCTAssertTrue(TranscriptWebImageLoader.isAllowed(try XCTUnwrap(URL(string: "https://93.184.215.14/a.png"))))
    }

    /// For review, not for CI: a real fetch of `YARDLET_WEB_IMAGE_QA_URL` (an image) and of `YARDLET_WEB_IMAGE_QA_PAGE`
    /// (a page, refused). Skipped unless both are set.
    func testARealWebImageLoadsForReview() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let image = environment["YARDLET_WEB_IMAGE_QA_URL"].flatMap(URL.init(string:)),
              let page = environment["YARDLET_WEB_IMAGE_QA_PAGE"].flatMap(URL.init(string:)) else {
            throw XCTSkip("Set YARDLET_WEB_IMAGE_QA_URL and YARDLET_WEB_IMAGE_QA_PAGE")
        }
        let data = await TranscriptWebImageLoader.load(image)
        XCTAssertNotNil(data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }, "An image, read as one")
        let refused = await TranscriptWebImageLoader.load(page)
        XCTAssertNil(refused, "A page is not an image")
    }

    private static func players(in view: NSView) -> [AVPlayerView] {
        ((view as? AVPlayerView).map { [$0] } ?? []) + view.subviews.flatMap { players(in: $0) }
    }

    private static func bitmaps(in view: NSView) -> [TranscriptPictureBitmapView] {
        ((view as? TranscriptPictureBitmapView).map { [$0] } ?? []) + view.subviews.flatMap { bitmaps(in: $0) }
    }

    private static func diagrams(in view: NSView) -> [TranscriptMermaidBitmapView] {
        ((view as? TranscriptMermaidBitmapView).map { [$0] } ?? []) + view.subviews.flatMap { diagrams(in: $0) }
    }

    private static func mermaidBlocks(in view: NSView) -> [TranscriptOnScreenSignalView] {
        ((view as? TranscriptOnScreenSignalView).map { [$0] } ?? []) + view.subviews.flatMap { mermaidBlocks(in: $0) }
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

    The voice note: ![voice note](voice.m4a)

    A document: ![the spec](docs/spec.pdf)
    """

    private static let flowchart = """
    flowchart TD
      Client([Client]) --> Edge[Edge cache]
      Edge -->|hit| Reply[Send cached reply]
      Edge -->|miss| API[API server]
      API --> DB[(Postgres)]
      API --> Queue[[Job queue]]
      Queue --> Worker[Thumbnail worker]
      DB --> API --> Reply
    """

    private static let sequenceDiagram = """
    sequenceDiagram
      participant App
      participant Server
      participant IdP as Identity provider
      App->>Server: POST /session
      Server->>IdP: Verify the code
      IdP-->>Server: Token
      Note right of Server: Keeps the token for 1 hour
      Server-->>App: 201 Created
    """

    private static let brokenDiagram = "flowchart LR\n  A[Start --> B"

    private static let mermaidAnswer = """
    The request path, with the cache in front:

    ```mermaid
    \(flowchart)
    ```

    And the sign-in, step by step:

    ```mermaid
    \(sequenceDiagram)
    ```

    A block Mermaid cannot read stays its code:

    ```mermaid
    \(brokenDiagram)
    ```
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

    /// A two-second H.264 movie of bars that move, at `pixels`.
    static func writeMovie(to url: URL, pixels: CGSize) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(pixels.width), AVVideoHeightKey: Int(pixels.height)
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(pixels.width), kCVPixelBufferHeightKey as String: Int(pixels.height)
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<20 {
            while !input.isReadyForMoreMediaData { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let context = try XCTUnwrap(CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer), width: Int(pixels.width), height: Int(pixels.height),
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
            context.fill(CGRect(origin: .zero, size: pixels))
            for bar in 0..<6 {
                context.setFillColor(NSColor(hue: 0.08 + CGFloat(bar) * 0.1, saturation: 0.7, brightness: 0.9, alpha: 1).cgColor)
                let height = pixels.height * (0.2 + 0.6 * abs(sin(Double(bar + frame) * 0.4)))
                context.fill(CGRect(x: 60 + CGFloat(bar) * (pixels.width - 120) / 6, y: 60, width: (pixels.width - 120) / 6 - 20,
                                    height: height))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        let done = expectation(description: "movie written")
        writer.finishWriting { done.fulfill() }
        XCTWaiter().wait(for: [done], timeout: 30)
        XCTAssertEqual(writer.status, .completed)
    }

    /// A three-second tone as AAC.
    static func writeSound(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1
        ])
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 3))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) { samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 44_100) * 0.2) }
        try file.write(from: buffer)
    }

    private static func expectation(description: String) -> XCTestExpectation { XCTestExpectation(description: description) }

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

/// A count a `@Sendable` closure can raise.
private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
