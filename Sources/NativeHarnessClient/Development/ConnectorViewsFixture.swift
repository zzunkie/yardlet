#if DEBUG
import AppKit
import Foundation
import WebKit

/// A Claude Code task whose conversation called a stand-in connector's tools that name MCP App views, so a QA
/// bundle shows the views in a real window without a model turn (docs/CONNECTORS.md, "MCP Apps", and
/// `scripts/connector-qa/mcp-apps-server.py`). The connector is the one QA adds as "QA Apps", so its tools are
/// `qa_apps_…`; a view is drawn once the connector is connected when the window opens.
///
/// - `--ui-fixture=connector-views`: one turn that read the stand-in's profile view.
/// - `--ui-fixture-connector-views=github` with `--ui-fixture-get-me=<file>` (a `get_me` result's text, kept outside
///   the repository): one turn that read GitHub's own profile view.
/// - `--ui-fixture-connector-views=pull-request`: one turn whose call shows GitHub's own view for a new pull request,
///   with a finished result.
/// - `--ui-fixture-connector-views=long`: 300 turns, a call with a view in every sixth and in the last.
/// - `--ui-fixture-connector-views-report=<folder>`: what each view's row shows, twice a second for 30 seconds,
///   to `views.log`, and then the window as the app draws it, to `window.png` (`ConnectorViewsFixtureReport`).
extension VisualFixtureScenario {
    static func makeConnectorViews(arguments: [String], workspaceURL: URL) -> VisualFixtureScenario {
        let isLong = arguments.contains("--ui-fixture-connector-views=long")
        let isGitHub = arguments.contains("--ui-fixture-connector-views=github")
        let isPullRequest = arguments.contains("--ui-fixture-connector-views=pull-request")
        if let folder = arguments.first(where: { $0.hasPrefix("--ui-fixture-connector-views-report=") }) {
            let url = URL(filePath: String(folder.dropFirst("--ui-fixture-connector-views-report=".count)),
                          directoryHint: .isDirectory)
            Task { @MainActor in await ConnectorViewsFixtureReport.run(into: url) }
        }
        let getMe = arguments.first { $0.hasPrefix("--ui-fixture-get-me=") }
            .flatMap { try? String(contentsOfFile: String($0.dropFirst("--ui-fixture-get-me=".count)), encoding: .utf8) }
        let start = Date().addingTimeInterval(isLong ? -400_000 : -600)
        let session = SessionRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000F701")!,
            harness: .claudeCode,
            workspaceURL: workspaceURL,
            runtimeExecutableURL: URL(filePath: "/usr/bin/true"),
            title: isLong ? "A long conversation with views" : "Connector views",
            createdAt: start,
            updatedAt: start.addingTimeInterval(isLong ? 300 * 60 : 120),
            providerSessionID: "visual-connector-views",
            completionState: .completed
        )
        let profile = #"{"login":"octo","name":"Mona Lisa Octocat","company":"Example","repos":42,"followers":1337}"#
        func view(_ id: String, tool: String, input: String?, output: String, at time: Date) -> TranscriptEntry {
            TranscriptEntry(createdAt: time, content: .activity(
                HarnessActivity(id: id, kind: "mcp__yardlet__qa_apps_\(tool)", title: "mcp__yardlet__qa_apps_\(tool)",
                                input: input, output: output),
                state: .completed))
        }
        var entries: [TranscriptEntry] = []
        if isLong {
            for turn in 0..<300 {
                let at = start.addingTimeInterval(Double(turn) * 60)
                entries.append(TranscriptEntry(createdAt: at, content: .user(text: "Request \(turn)")))
                for call in 0..<7 {
                    entries.append(TranscriptEntry(createdAt: at.addingTimeInterval(Double(call) + 1), content: .activity(
                        HarnessActivity(id: "read-\(turn)-\(call)", kind: "Read", title: "Read", input: "file \(call)",
                                        output: "text"),
                        state: .completed)))
                }
                if turn % 6 == 5 {
                    entries.append(view("view-\(turn)", tool: "get_profile", input: #"{"login":"octo"}"#, output: profile,
                                        at: at.addingTimeInterval(20)))
                }
                entries.append(TranscriptEntry(createdAt: at.addingTimeInterval(30),
                                               content: .assistant(text: "Done \(turn).", isStreaming: false)))
            }
        } else if isGitHub, let getMe {
            entries.append(TranscriptEntry(createdAt: start, content: .user(text: "Who am I on GitHub?")))
            entries.append(view("view-github", tool: "get_me", input: nil, output: getMe, at: start.addingTimeInterval(4)))
            entries.append(TranscriptEntry(createdAt: start.addingTimeInterval(6),
                                           content: .assistant(text: "That is your GitHub profile.", isStreaming: false)))
        } else if isPullRequest {
            entries.append(TranscriptEntry(createdAt: start, content: .user(text: "Open the pull request.")))
            entries.append(view("view-pull-request", tool: "show_pull_request",
                                input: #"{"base":"main","head":"mcp-apps","owner":"example","repo":"demo","title":"Draw MCP App views"}"#,
                                output: #"{"id":"7001","url":"https://github.com/example/demo/pull/7"}"#,
                                at: start.addingTimeInterval(4)))
            entries.append(TranscriptEntry(createdAt: start.addingTimeInterval(6),
                                           content: .assistant(text: "The pull request is open.", isStreaming: false)))
        } else {
            entries.append(TranscriptEntry(createdAt: start, content: .user(text: "Look up octo's profile.")))
            entries.append(TranscriptEntry(createdAt: start.addingTimeInterval(2),
                                           content: .assistant(text: "Let me look up the profile.", isStreaming: false)))
            entries.append(view("view-profile", tool: "get_profile", input: #"{"login":"octo"}"#, output: profile,
                                at: start.addingTimeInterval(4)))
            entries.append(TranscriptEntry(createdAt: start.addingTimeInterval(6),
                                           content: .assistant(text: "Mona Lisa Octocat has 42 repositories.", isStreaming: false)))
        }
        return VisualFixtureScenario(
            sessions: [session], transcripts: [session.id: entries], errors: [:], codexPresentation: [:],
            codexQueues: [:], codexCapabilities: [:], providerCapabilities: [:], providerUsage: [:],
            initialTaskSurface: nil, initialCodexCapabilitySection: nil, initialCodexHistoryQuery: nil,
            initialSettingsSection: nil, initialNotificationAuthorization: nil)
    }
}

/// What a QA run reads of the views without the screen: a QA bundle's window is clear and off every screen
/// (`QABackground`), so a capture of the display shows nothing of it. Each line of `views.log` is a row's view at
/// one moment: its state, the height the row gives it, and whether the server asked for a border. `window.png` is the
/// window drawn by the app into an image, each web view's own picture over its place.
@MainActor
enum ConnectorViewsFixtureReport {
    static let taskID = UUID(uuidString: "00000000-0000-0000-0000-00000000F701")!

    static func run(into folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var lines: [String] = []
        let started = ContinuousClock.now
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(500))
            let seconds = (ContinuousClock.now - started).components.seconds
            for (key, controller) in MCPAppViewPool.shared.controllers(forTask: taskID).sorted(by: { $0.key < $1.key }) {
                let display = controller.display
                lines.append("\(seconds)s \(display.uri ?? key) \(display.state) height=\(Int(display.height)) "
                    + "border=\(display.prefersBorder.map(String.init) ?? "none") webView=\(controller.webView != nil)")
            }
            try? lines.joined(separator: "\n").write(to: folder.appending(path: "views.log"), atomically: true, encoding: .utf8)
        }
        guard let window = NSApp.windows.filter(\.isVisible).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let content = window.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        for webView in webViews(in: content) {
            // Only the part the conversation's scroll view shows.
            let visible = webView.visibleRect
            guard !visible.isEmpty else { continue }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = visible
            guard let snapshot = try? await webView.takeSnapshot(configuration: configuration) else { continue }
            var frame = webView.convert(visible, to: content)
            if content.isFlipped { frame.origin.y = content.bounds.height - frame.maxY }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            snapshot.draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()
        }
        try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "window.png"))
        // Each view whole, as tall as it reported, even where the conversation scrolls part of it out of sight.
        for (index, webView) in webViews(in: content).enumerated() {
            guard let snapshot = try? await webView.takeSnapshot(configuration: nil),
                  let image = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: folder.appending(path: "view-\(index + 1).png"))
        }
    }

    private static func webViews(in view: NSView) -> [MCPAppWebView] {
        ((view as? MCPAppWebView).map { [$0] } ?? []) + view.subviews.flatMap(webViews)
    }
}
#endif
