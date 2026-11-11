import AppKit
import SwiftUI
import WebKit
import XCTest
import YardletAgentTools
@testable import NativeHarnessClient

/// A connector call's view drawn in its row by the real web view, in an unshown window, against the local fake
/// server (`FakeAppServer`): the handshake, the isolation the view runs under, and the row in both appearances under
/// `.build/mcp-apps-qa/`.
@MainActor
final class MCPAppViewRenderingTests: XCTestCase {
    /// A view written as a server would, without an SDK: it initializes, shows the profile it is given, and then
    /// tries what a view must not be able to do, reporting each attempt through a call to the view-only tool.
    static let probeView = #"""
    <!doctype html><html><head><meta charset="utf-8">
    <style>
    :root { color-scheme: light dark; }
    body { margin: 0; font: 13px var(--font-sans, -apple-system); color: var(--color-text-primary, #111); }
    .card { display: flex; gap: 12px; align-items: center; padding: 14px 16px; min-height: 172px; box-sizing: border-box; }
    .avatar { width: 44px; height: 44px; border-radius: 50%; background: linear-gradient(135deg, #4c9aff, #7b61ff); }
    .name { font-weight: 600; font-size: 15px; }
    .meta { color: var(--color-text-secondary, #666); margin-top: 2px; }
    .stats { display: flex; gap: 16px; margin-top: 8px; color: var(--color-text-secondary, #666); }
    .stats b { color: var(--color-text-primary, #111); }
    </style></head><body>
    <div class="card"><div class="avatar"></div><div>
      <div class="name" id="name">Loading…</div><div class="meta" id="meta"></div>
      <div class="stats"><span><b id="repos">0</b> repositories</span><span><b id="followers">0</b> followers</span></div>
    </div></div>
    <script>
    const probes = { blocked: [] };
    document.addEventListener('securitypolicyviolation', (e) => probes.blocked.push(e.violatedDirective));
    let next = 0; const pending = {};
    function request(method, params) {
      const id = ++next;
      parent.postMessage({ jsonrpc: '2.0', id, method, params }, '*');
      return new Promise((resolve) => { pending[id] = resolve; });
    }
    function notify(method, params) { parent.postMessage({ jsonrpc: '2.0', method, params }, '*'); }
    function theme(name) { document.documentElement.style.colorScheme = name; }
    window.addEventListener('message', async (event) => {
      if (event.source !== parent) { return; }
      const message = event.data;
      if (message.id && pending[message.id]) { pending[message.id](message); delete pending[message.id]; return; }
      if (message.method === 'ui/notifications/host-context-changed' && message.params.theme) { theme(message.params.theme); }
      if (message.method !== 'ui/notifications/tool-result') { return; }
      const user = message.params.structuredContent || {};
      document.getElementById('name').textContent = user.name || user.login;
      document.getElementById('meta').textContent = '@' + user.login + ' · ' + (user.company || '');
      document.getElementById('repos').textContent = user.repos;
      document.getElementById('followers').textContent = user.followers;
      probes.handler = typeof (window.webkit && window.webkit.messageHandlers
        && window.webkit.messageHandlers.yardletMCPApp);
      try { probes.parent = parent.document.title === undefined ? 'empty' : 'reachable'; }
      catch (error) { probes.parent = 'blocked'; }
      probes.popup = window.open('https://popup.invalid/') ? 'opened' : 'none';
      probes.secure = window.isSecureContext;
      fetch('https://undeclared.invalid/data').catch(() => {});
      await new Promise((resolve) => setTimeout(resolve, 300));
      await request('tools/call', { name: 'ui_lookup', arguments: probes });
      location.href = 'https://elsewhere.invalid/';
      await new Promise((resolve) => setTimeout(resolve, 500));
      await request('tools/call', { name: 'ui_lookup', arguments: { stillHere: true } });
    });
    (async () => {
      const answer = await request('ui/initialize', { appCapabilities: {}, appInfo: { name: 'probe', version: '1' },
                                                     protocolVersion: '2026-01-26' });
      const context = answer.result.hostContext;
      for (const [name, value] of Object.entries(context.styles.variables)) {
        document.documentElement.style.setProperty(name, value);
      }
      theme(context.theme);
      notify('ui/notifications/initialized', {});
      const report = () => notify('ui/notifications/size-changed',
        { width: document.body.scrollWidth, height: document.documentElement.scrollHeight });
      new ResizeObserver(report).observe(document.body);
      report();
    })();
    </script></body></html>
    """#

    private func connectedCenter(_ server: FakeAppServer) async throws -> (ConnectorCenter, ConnectorRecord) {
        let environment = ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(), credentials: InMemoryConnectorCredentialStore(), http: server,
            userAgent: nil, sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9", now: { Date() },
            refreshRetrySleep: { _ in })
        let center = ConnectorCenter(environment: environment)
        let record = try await center.add(name: "Viewer", serverURL: FakeAppServer.url)
        center.connect(record.id)
        await center.waitForConnection(record.id)
        return (center, try XCTUnwrap(center.record(record.id)))
    }

    func testAViewDrawsInItsRowIsolatedFromYardletUnderItsPolicy() async throws {
        let server = FakeAppServer()
        server.viewHTML = Self.probeView
        let (center, record) = try await connectedCenter(server)
        ConnectorToolLabels.shared.update([record])
        defer { ConnectorToolLabels.shared.update([]) }
        let directory = try WindowlessRender.directory("mcp-apps-qa")

        for appearance in WindowlessRender.Appearance.allCases {
            let taskID = UUID()
            let task = ConnectorToolContext(taskID: taskID)
            server.result = .object([
                "content": .array([.object(["type": .string("text"), "text": .string("Mona Lisa Octocat (@octo)")])]),
                "structuredContent": .object(["login": .string("octo"), "name": .string("Mona Lisa Octocat"),
                                              "company": .string("Example"), "repos": .integer(42),
                                              "followers": .integer(1_337)])
            ])
            _ = await center.callConnectorTool(named: "viewer_get_profile", arguments: .object(["login": .string("octo")]),
                                               for: task)
            let host = ConnectorViewHost(taskID: taskID, center: center, context: { task }, ask: { _, _, _ in false })
            let activity = HarnessActivity(id: "call-\(appearance.suffix)", kind: "mcp__yardlet__viewer_get_profile",
                                           title: "mcp__yardlet__viewer_get_profile", input: #"{"login":"octo"}"#,
                                           output: "Mona Lisa Octocat (@octo)")
            let item = ConversationItem(
                id: activity.id,
                kind: ConversationActivityProjection.kind(activity, harness: .claudeCode, phase: .completed, isApproved: false),
                phase: .completed, source: .transcript(TranscriptEntry(content: .plan(""))))
            let row = VStack(alignment: .leading, spacing: 8) {
                Text("Let me look up your GitHub profile.")
                    .font(.system(size: 14))
                ConversationWorkLine(item: item, harness: .claudeCode, workspaceURL: nil)
                    .environment(\.connectorViews, host)
            }
            .padding(20)
            .frame(width: 680, alignment: .topLeading)
            .background(appearance == .dark ? Color(white: 0.12) : Color.white)
            .environment(\.colorScheme, appearance.colorScheme)
            let window = WindowlessRender.Host(row, size: NSSize(width: 680, height: 260), appearance: appearance)
            defer { window.close() }
            let callsBefore = server.calls.count
            await window.settle(until: { server.calls.count >= callsBefore + 2 }, timeout: 30)

            // What the view could do, as it reported it.
            let probes = try XCTUnwrap(server.arguments.dropFirst(callsBefore).first)
            XCTAssertEqual(probes["handler"], .string("undefined"), "The bridge's handler is not in the view's world")
            XCTAssertEqual(probes["parent"], .string("blocked"), "The outer page is another origin")
            XCTAssertEqual(probes["popup"], .string("none"))
            XCTAssertTrue(probes["blocked"]?.arrayValue?.contains(.string("connect-src")) == true,
                          "A connection to an undeclared host is refused by the policy: \(probes)")
            XCTAssertEqual(server.arguments.last?["stillHere"], .bool(true), "The view's own navigation went nowhere")
            let controller = MCPAppViewPool.shared.controller(taskID.uuidString + " " + item.id)
            XCTAssertEqual(controller.display.state, .live)
            XCTAssertEqual(controller.display.height, 172, accuracy: 2, "The row is as tall as the view reported")
            XCTAssertEqual(controller.display.prefersBorder, false)

            let webView = try XCTUnwrap(Self.webView(in: window.hosting))
            let snapshot = try await webView.takeSnapshot(configuration: nil)
            let capture = try window.capture()
            Self.draw(snapshot, of: webView, into: capture.bitmap, hosting: window.hosting)
            try WindowlessRender.writePNG(capture.bitmap,
                                          to: directory.appending(path: "profile-row-\(appearance.suffix).png"))
            XCTAssertLessThanOrEqual(MCPAppViewPool.shared.liveCount, MCPAppViewPool.limit)
        }
    }

    /// A view that only initializes and says how tall it is.
    static let quietView = #"""
    <!doctype html><html><body style="margin:0"><div style="box-sizing:border-box;height:140px;border:2px dashed #4c9aff;
    border-radius:8px;display:flex;align-items:center;justify-content:center;font:14px -apple-system;color:#4c9aff">
    The view's own page, 140 points tall</div><script>
    let next = 0;
    window.addEventListener('message', (event) => {
      if (event.source !== parent || event.data.id !== 1) { return; }
      parent.postMessage({ jsonrpc: '2.0', method: 'ui/notifications/initialized', params: {} }, '*');
      parent.postMessage({ jsonrpc: '2.0', method: 'ui/notifications/size-changed', params: { width: 600, height: 140 } }, '*');
    });
    parent.postMessage({ jsonrpc: '2.0', id: 1, method: 'ui/initialize', params: { appCapabilities: {} } }, '*');
    </script></body></html>
    """#

    /// A long conversation with many views: only the views on screen get a web view, never more than the pool keeps,
    /// and a streamed answer in the latest turn neither reloads nor redraws them.
    func testALongConversationDrawsOnlyTheViewsOnScreen() async throws {
        let server = FakeAppServer()
        server.viewHTML = Self.quietView
        let (center, record) = try await connectedCenter(server)
        ConnectorToolLabels.shared.update([record])
        defer { ConnectorToolLabels.shared.update([]) }
        let taskID = UUID()
        let task = ConnectorToolContext(taskID: taskID)
        let host = ConnectorViewHost(taskID: taskID, center: center, context: { task }, ask: { _, _, _ in false })

        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var entries: [TranscriptEntry] = []
        var views = 0
        for turn in 0..<300 {
            let at = start.addingTimeInterval(Double(turn) * 60)
            entries.append(TranscriptEntry(createdAt: at, content: .user(text: "Request \(turn)")))
            for call in 0..<7 {
                entries.append(TranscriptEntry(createdAt: at.addingTimeInterval(Double(call) + 1), content: .activity(
                    HarnessActivity(id: "read-\(turn)-\(call)", kind: "Read", title: "Read", input: "file \(call)", output: "text"),
                    state: .completed)))
            }
            if turn % 6 == 5 {
                views += 1
                entries.append(TranscriptEntry(createdAt: at.addingTimeInterval(20), content: .activity(
                    HarnessActivity(id: "view-\(turn)", kind: "mcp__yardlet__viewer_get_profile",
                                    title: "mcp__yardlet__viewer_get_profile", input: #"{"login":"octo"}"#, output: "octo"),
                    state: .completed)))
            }
            entries.append(TranscriptEntry(createdAt: at.addingTimeInterval(30), content: .assistant(text: "Done \(turn).", isStreaming: false)))
        }
        XCTAssertEqual(views, 50)
        XCTAssertGreaterThan(entries.count, 2_700)

        func timeline(_ entries: [TranscriptEntry]) -> some View {
            ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .ready,
                                                     latestTurnIsComplete: true),
                                 actions: ConversationActions(connectorViews: host))
                .frame(width: 760, height: 600)
        }
        let window = WindowlessRender.Host(timeline(entries), size: NSSize(width: 760, height: 600), appearance: .light)
        defer { window.close() }
        await window.settle(until: {
            MCPAppViewPool.shared.controllers(forTask: taskID).values.contains { $0.display.state == .live }
        }, timeout: 30)
        for _ in 0..<10 { window.settle(passes: 1, interval: 0.05); await Task.yield() }

        let rows = MCPAppViewPool.shared.controllers(forTask: taskID)
        let started = rows.values.filter { $0.display.state != .idle }
        try WindowlessRender.writePNG(try window.capture().bitmap,
                                      to: try WindowlessRender.directory("mcp-apps-qa").appending(path: "long-conversation.png"))
        XCTAssertEqual(rows.count, 2, "The drawn window of turns holds two of the 50 views")
        XCTAssertEqual(rows.values.map(\.display.state).sorted { "\($0)" < "\($1)" }, [.idle, .live],
                       "The one above the screen is not drawn")
        XCTAssertLessThan(rows.count, views, "Only rows of the drawn turns have a place for a view")
        XCTAssertGreaterThan(started.count, 0)
        XCTAssertLessThanOrEqual(started.count, MCPAppViewPool.limit, "Only views on screen are drawn")
        XCTAssertEqual(server.reads.count, 1, "One read of the view for every row that shows it")
        let webViews = Set(started.compactMap { $0.webView.map(ObjectIdentifier.init) })

        // The latest turn streams an answer: the drawn views keep their web views.
        var streaming = entries
        for word in 0..<20 {
            streaming.append(TranscriptEntry(createdAt: start.addingTimeInterval(400_000 + Double(word)),
                                             content: .assistant(text: String(repeating: "word ", count: word + 1), isStreaming: true)))
            window.hosting.rootView = timeline(streaming)
            window.settle(passes: 1, interval: 0.01)
        }
        let after = MCPAppViewPool.shared.controllers(forTask: taskID).values.filter { $0.display.state != .idle }
        XCTAssertEqual(Set(after.compactMap { $0.webView.map(ObjectIdentifier.init) }), webViews,
                       "No view was made again while the turn streamed")
        XCTAssertEqual(server.reads.count, 1)
    }

    private static func webView(in view: NSView) -> MCPAppWebView? {
        (view as? MCPAppWebView) ?? view.subviews.lazy.compactMap(webView).first
    }

    /// The web view's own picture over the window's capture, which leaves a web view's remote layer out.
    private static func draw(_ snapshot: NSImage, of webView: NSView, into bitmap: NSBitmapImageRep, hosting: NSView) {
        var frame = webView.convert(webView.bounds, to: hosting)
        if hosting.isFlipped { frame.origin.y = hosting.bounds.height - frame.maxY }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        snapshot.draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()
    }
}
