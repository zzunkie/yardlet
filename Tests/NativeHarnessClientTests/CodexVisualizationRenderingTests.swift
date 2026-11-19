import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import NativeHarnessClient

/// A Codex inline visualization drawn by the real web view in its message: the isolation it runs under (another
/// origin than Yardlet's page, no bridge handler, nothing fetched, no window), the height it reports, the state it
/// saves, the app's appearance as it changes, the same page moved into the expanded sheet and back, and the skill's
/// kit around the fragment when a Codex home on the Mac holds one. Review images go to `.build/chat-media-qa/`.
@MainActor
final class CodexVisualizationRenderingTests: XCTestCase {
    private let decoder = CodexTaskDecoder()
    private var workspace: URL!
    private var home: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-visualization-\(UUID().uuidString)",
                                                                    directoryHint: .isDirectory)
        workspace = root.appending(path: "work", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root = workspace?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: root) }
    }

    /// What the page could do, which it saves as its widget state for the test to read.
    static let probe = #"""
    <div class="probe" style="height:180px;padding:16px;box-sizing:border-box;border-radius:8px;
      background:light-dark(#eef4ff,#1d2733);font:14px -apple-system">A visualization, 180 points tall</div>
    <script>
    const probes = { blocked: [] };
    document.addEventListener('securitypolicyviolation', (event) => probes.blocked.push(event.violatedDirective));
    matchMedia('(prefers-color-scheme: dark)').addEventListener('change', (event) =>
      window.openai.setWidgetState({ probes, changedToDark: event.matches }));
    (async () => {
      fetch('https://example.com/data').catch(() => {});
      fetch('file:///etc/hosts').catch(() => {});
      await new Promise((resolve) => setTimeout(resolve, 300));
      probes.handler = typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.yardletMCPApp);
      try { probes.parent = parent.document.title === undefined ? 'empty' : 'reachable'; }
      catch (error) { probes.parent = 'blocked'; }
      probes.popup = window.open('https://popup.invalid/') ? 'opened' : 'none';
      probes.kit = getComputedStyle(document.documentElement).getPropertyValue('--yardlet-test-kit').trim() || 'none';
      probes.dark = matchMedia('(prefers-color-scheme: dark)').matches;
      window.openai.setWidgetState({ probes });
    })();
    </script>
    """#

    func testAVisualizationDrawsIsolatedAndTellsItsHeight() async throws {
        try Self.probe.write(to: workspace.appending(path: "probe.html"), atomically: true, encoding: .utf8)
        let directory = try WindowlessRender.directory("chat-media-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let itemID = "answer-\(appearance.suffix)"
            let key = "codex-visualization:\(itemID):[1]:probe.html"
            let host = WindowlessRender.Host(
                conversation(itemID: itemID, answer: "Here is the chart.\n\n::codex-inline-vis{file=\"probe.html\"}\n\nDone.")
                    .frame(width: 900, height: 700),
                size: NSSize(width: 900, height: 700), appearance: appearance)
            defer { host.close() }
            await host.settle(until: { CodexVisualizationStates.shared.state(key) != nil }, timeout: 30)

            let state = try XCTUnwrap(CodexVisualizationStates.shared.state(key))
            let probes = try XCTUnwrap(
                (try JSONSerialization.jsonObject(with: Data(state.utf8)) as? [String: Any])?["probes"] as? [String: Any])
            XCTAssertEqual(probes["handler"] as? String, "undefined", "Yardlet's handler is not in the page's world")
            XCTAssertEqual(probes["parent"] as? String, "blocked", "The outer page is another origin")
            XCTAssertEqual(probes["popup"] as? String, "none")
            XCTAssertTrue((probes["blocked"] as? [String])?.contains("connect-src") == true,
                          "Nothing is fetched: \(probes)")
            XCTAssertEqual(probes["dark"] as? Bool, appearance == .dark, "The page sees the app's appearance, as the kit's theme follows it")
            let controller = MCPAppViewPool.shared.controller(key)
            XCTAssertEqual(controller.display.state, .live)
            XCTAssertEqual(controller.display.height, 180, accuracy: 2, "The row is as tall as the page reported")

            let webView = try XCTUnwrap(MCPAppViewRenderingTests.webView(in: host.hosting))
            let snapshot = try await webView.takeSnapshot(configuration: nil)
            let capture = try host.capture()
            MCPAppViewRenderingTests.draw(snapshot, of: webView, into: capture.bitmap, hosting: host.hosting)
            try WindowlessRender.writePNG(capture.bitmap, to: directory.appending(
                path: "codex-visualization-probe-\(appearance.suffix).png"))

            // The app's appearance reaches the page as it changes, without loading it again.
            controller.setDark(appearance != .dark)
            await host.settle(until: { CodexVisualizationStates.shared.state(key)?.contains("changedToDark") == true },
                              timeout: 10)
            XCTAssertTrue(CodexVisualizationStates.shared.state(key)?.contains("\"changedToDark\":\(appearance != .dark)") == true)
            controller.setDark(appearance == .dark)

            // Expanded, the same web view moves into the sheet and back to its row after.
            let row = try XCTUnwrap(webView.superview)
            let shown = Shown()
            let sheet = WindowlessRender.Host(
                ShownIf(shown: shown) {
                    CodexVisualizationExpanded(title: "Probe", controller: controller, close: {})
                        .frame(width: 1_064, height: 560)
                        .background(Color(nsColor: .windowBackgroundColor))
                },
                size: NSSize(width: 1_064, height: 560), appearance: appearance)
            defer { sheet.close() }
            await sheet.settle(until: { webView.window === sheet.window })
            XCTAssertTrue(webView.window === sheet.window, "The row's own web view, not another")
            let expanded = try sheet.capture()
            MCPAppViewRenderingTests.draw(try await webView.takeSnapshot(configuration: nil), of: webView,
                                          into: expanded.bitmap, hosting: sheet.hosting)
            try WindowlessRender.writePNG(expanded.bitmap, to: directory.appending(
                path: "codex-visualization-expanded-\(appearance.suffix).png"))
            shown.value = false
            await sheet.settle(until: { webView.superview === row })
            XCTAssertTrue(webView.superview === row, "Back in its row")
            XCTAssertEqual(controller.display.state, .live)

            // The pool keeps views live past their rows; another suite counts the live ones.
            await controller.park()
        }
    }

    /// A long conversation with many visualizations: only those on screen get a web view, never more than the pool
    /// keeps, and an answer streaming in the latest turn neither reloads nor redraws them.
    func testALongConversationDrawsOnlyTheVisualizationsOnScreen() async throws {
        try #"<div style="height:140px">A quiet visualization</div>"#.write(
            to: workspace.appending(path: "quiet.html"), atomically: true, encoding: .utf8)
        let run = "long-\(UUID().uuidString)"
        func turn(_ index: Int, answer: String, status: String = "completed") -> CodexTurnState {
            decoder.turn(from: .object([
                "id": .string("turn-\(index)"), "status": .string(status), "durationMs": .integer(3_000),
                "items": .array([
                    .object(["id": .string("u\(index)"), "type": .string("userMessage"),
                             "content": .array([.object(["type": .string("text"), "text": .string("Request \(index)")])])]),
                    .object(["id": .string("\(run)-\(index)"), "type": .string("agentMessage"), "text": .string(answer),
                             "phase": .string("final_answer")])
                ])
            ]), fallbackID: "turn-\(index)")!
        }
        var turns: [CodexTurnState] = []
        var visualizations = 0
        for index in 0..<300 {
            if index % 3 == 2 {
                visualizations += 1
                turns.append(turn(index, answer: "Chart \(index).\n\n::codex-inline-vis{file=\"quiet.html\"}\n\nDone."))
            } else {
                turns.append(turn(index, answer: "Done \(index)."))
            }
        }
        XCTAssertEqual(visualizations, 100)
        func timeline(_ turns: [CodexTurnState]) -> some View {
            var thread = decoder.thread(from: .object(["id": .string("thread-long")]))!
            thread.turns = turns
            return ConversationTimeline(source: .codex(CodexTaskState(thread: thread), workspaceURL: workspace,
                                                       historySelection: nil))
                .environment(\.transcriptWorkspaceURL, workspace)
                .frame(width: 760, height: 600)
        }
        let window = WindowlessRender.Host(timeline(turns), size: NSSize(width: 760, height: 600), appearance: .light)
        defer { window.close() }
        await window.settle(until: {
            MCPAppViewPool.shared.controllers(withPrefix: "codex-visualization:\(run)").values.contains { $0.display.state == .live }
        }, timeout: 30)
        for _ in 0..<10 { window.settle(passes: 1, interval: 0.05); await Task.yield() }

        let rows = MCPAppViewPool.shared.controllers(withPrefix: "codex-visualization:\(run)")
        let started = rows.values.filter { $0.display.state != .idle }
        XCTAssertLessThan(rows.count, 10, "Only rows of the drawn turns have a place for a visualization: \(rows.count)")
        XCTAssertGreaterThan(started.count, 0)
        XCTAssertLessThanOrEqual(started.count, MCPAppViewPool.limit, "Only visualizations on screen are drawn")
        let webViews = Set(started.compactMap { $0.webView.map(ObjectIdentifier.init) })

        // The latest turn streams an answer: the drawn visualizations keep their web views.
        for word in 0..<20 {
            var streaming = turns
            streaming.append(turn(300, answer: String(repeating: "word ", count: word + 1), status: "inProgress"))
            window.hosting.rootView = timeline(streaming)
            window.settle(passes: 1, interval: 0.01)
        }
        let after = MCPAppViewPool.shared.controllers(withPrefix: "codex-visualization:\(run)").values
            .filter { $0.display.state != .idle }
        XCTAssertEqual(Set(after.compactMap { $0.webView.map(ObjectIdentifier.init) }), webViews,
                       "No visualization was made again while the turn streamed")
        for controller in after { await controller.park() }
    }

    /// The skill's kit, from the newest `visualize` a Codex home holds, wraps the fragment: its stylesheet, its widgets
    /// around the fragment and its bridge. A whole document keeps its own head.
    func testTheSkillsKitWrapsTheFragment() throws {
        for (version, marker) in [("1.0.9", "old"), ("1.0.10", "new")] {
            let assets = home.appending(path: ".codex/plugins/cache/openai-bundled/visualize/\(version)/skills/visualize/assets")
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            try ":root{--yardlet-test-kit:\(marker)}".write(to: assets.appending(path: "visualize.css"),
                                                           atomically: true, encoding: .utf8)
            try "<div class=kit>\(CodexVisualizationKit.placeholder)</div>".write(
                to: assets.appending(path: "visualize.html"), atomically: true, encoding: .utf8)
            try "/* bridge \(marker) </script> */".write(to: assets.appending(path: "standalone-host-bridge.js"),
                                                      atomically: true, encoding: .utf8)
        }
        let kit = try XCTUnwrap(CodexVisualizationKit.installed(home: home))
        XCTAssertTrue(kit.stylesheet.contains("new"), "The newest version's kit")
        let page = CodexVisualizationPage.page("<p>chart</p>", kit: kit, state: #"{"a":"</script>"}"#)
        XCTAssertTrue(page.contains("<div class=kit><p>chart</p></div>"))
        XCTAssertTrue(page.contains("/* bridge new <\\/script> */"), "The bridge cannot end its script early")
        // The saved state cannot end its script either: `<` is written as its JSON escape.
        XCTAssertTrue(page.contains(#"{"widgetState":{"a":"\u003c/script>"},"statePersistence":"local"}"#))
        let document = CodexVisualizationPage.page("<!doctype html><html><head><title>t</title></head><body class=x><p>doc</p>",
                                                   kit: kit, state: nil)
        XCTAssertTrue(document.hasPrefix("<!doctype html><html><head><title>t</title></head><body class=x><script"))
        XCTAssertFalse(document.contains("--yardlet-test-kit"), "A whole document keeps its own styles")
    }

    /// Only an HTML file in the task's folder or in a Codex home's thread visualizations is read.
    func testOnlyAVisualizationInTheTasksFolderOrACodexHomeIsRead() throws {
        let codex = home.appending(path: ".codex")
        try FileManager.default.createDirectory(at: codex.appending(path: "sessions"), withIntermediateDirectories: true)
        let thread = codex.appending(path: "visualizations/2026/11/19/01a1f000-0000-7000-8000-000000000001/flow.html")
        let nested = thread.deletingLastPathComponent().appending(path: "mock/index.html")
        for file in [thread, nested] {
            XCTAssertEqual(try CodexVisualizationPage.allowedFile(file.path(percentEncoded: false), workspace: workspace, home: home),
                           file.standardizedFileURL)
        }
        XCTAssertEqual(try CodexVisualizationPage.allowedFile("out/chart.html", workspace: workspace, home: home),
                       workspace.appending(path: "out/chart.html").standardizedFileURL)
        for path in ["/etc/hosts.html", "\(home.path(percentEncoded: false))notes/a.html", "out/chart.png", "../escape.html",
                     "\(home.path(percentEncoded: false))elsewhere/visualizations/2026/11/19/t/flow.html",
                     codex.appending(path: "visualizations/notes/a/b/c/flow.html").path(percentEncoded: false),
                     codex.appending(path: "visualizations/2026/11/19/flow.html").path(percentEncoded: false)] {
            XCTAssertThrowsError(try CodexVisualizationPage.allowedFile(path, workspace: workspace, home: home), path)
        }
    }

    /// For review, not for CI: every visualization under `~/.codex/visualizations` of the home the test runs in (set
    /// `CFFIXED_USER_HOME` to a copy, with a kit under its `.codex/plugins/cache`) drawn in a message, with what each
    /// came to in `visualizations.tsv`. Skipped unless the home holds `.codex/visualization-qa`.
    func testEveryVisualizationInAHomeForReview() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        try XCTSkipUnless(FileManager.default.fileExists(atPath: home.appending(path: ".codex/visualization-qa").path))
        let root = home.appending(path: ".codex/visualizations")
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "html" }.sorted { $0.path < $1.path }
        let directory = try WindowlessRender.directory("chat-media-qa/visualizations")
        var report = "file\tappearance\tstate\theight\n"
        for (index, file) in files.enumerated() {
            for appearance in WindowlessRender.Appearance.allCases {
                let itemID = "qa-\(index)-\(appearance.suffix)"
                let path = file.path(percentEncoded: false)
                let key = "codex-visualization:\(itemID):[1]:\(path)"
                let host = WindowlessRender.Host(
                    conversation(itemID: itemID, answer: "Here it is.\n\n::codex-inline-vis{path=\"\(path)\"}\n\nDone.")
                        .frame(width: 900, height: 1_600),
                    size: NSSize(width: 900, height: 1_600), appearance: appearance)
                let controller = MCPAppViewPool.shared.controller(key)
                await host.settle(until: { controller.display.state == .live && controller.display.height > 24
                    || controller.display.state == .failed }, timeout: 20)
                // Scripts and fonts from the CDNs settle.
                for _ in 0..<15 { await host.settle(until: { true }); try? await Task.sleep(for: .milliseconds(100)) }
                report += "\(file.lastPathComponent)\t\(appearance.suffix)\t\(controller.display.state)\t\(Int(controller.display.height))\n"
                let name = "\(index)-\(file.deletingPathExtension().lastPathComponent)-\(appearance.suffix)"
                if let webView = MCPAppViewRenderingTests.webView(in: host.hosting),
                   let snapshot = try? await webView.takeSnapshot(configuration: nil) {
                    let capture = try host.capture()
                    MCPAppViewRenderingTests.draw(snapshot, of: webView, into: capture.bitmap, hosting: host.hosting)
                    try WindowlessRender.writePNG(capture.bitmap, to: directory.appending(path: "\(name).png"))
                    // Expanded, in a sheet of its ideal size.
                    let size = NSSize(width: 1_064, height: 760)
                    let sheet = WindowlessRender.Host(
                        CodexVisualizationExpanded(title: file.lastPathComponent, controller: controller, close: {})
                            .frame(width: size.width, height: size.height)
                            .background(Color(nsColor: .windowBackgroundColor)),
                        size: size, appearance: appearance)
                    await sheet.settle(until: { webView.window === sheet.window }, timeout: 5)
                    for _ in 0..<10 { await sheet.settle(until: { true }); try? await Task.sleep(for: .milliseconds(100)) }
                    if let snapshot = try? await webView.takeSnapshot(configuration: nil) {
                        let expanded = try sheet.capture()
                        MCPAppViewRenderingTests.draw(snapshot, of: webView, into: expanded.bitmap, hosting: sheet.hosting)
                        try WindowlessRender.writePNG(expanded.bitmap, to: directory.appending(path: "\(name)-expanded.png"))
                    }
                    sheet.close()
                    controller.expandedContainer = nil
                }
                host.close()
                await controller.park()
            }
        }
        try report.write(to: directory.appending(path: "visualizations.tsv"), atomically: true, encoding: .utf8)
    }

    @Observable final class Shown {
        var value = true
    }

    private struct ShownIf<Content: View>: View {
        let shown: Shown
        @ViewBuilder let content: () -> Content

        var body: some View {
            if shown.value { content() } else { Color.clear }
        }
    }

    private func conversation(itemID: String, answer: String) -> some View {
        var thread = decoder.thread(from: .object(["id": .string("thread-visualization")]))!
        thread.turns = [decoder.turn(from: .object([
            "id": .string("turn-1"), "status": .string("completed"), "durationMs": .integer(3_000),
            "items": .array([
                .object(["id": .string("u1"), "type": .string("userMessage"),
                         "content": .array([.object(["type": .string("text"), "text": .string("Chart it.")])])]),
                .object(["id": .string(itemID), "type": .string("agentMessage"), "text": .string(answer),
                         "phase": .string("final_answer")])
            ])
        ]), fallbackID: "turn-1")!]
        return ConversationTimeline(source: .codex(CodexTaskState(thread: thread), workspaceURL: workspace, historySelection: nil))
            .environment(\.transcriptWorkspaceURL, workspace)
            .background(ParityTheme.canvas)
    }
}
