#if DEBUG
import AppKit
import Foundation
import IOSurface
import YardletAgentTools

/// QA for how well an agent uses the browser, against the real browser host (docs/AGENT_BROWSER_TOOLS.md, "QA (without a model turn)"), run by
/// `run-check.sh … --ui-fixture-browser-check-only=browser-use`: screen sizes (the agent's browser_resize and
/// the panel drawing a size larger than itself), reading and acting across frames and shadow roots, and
/// handing a tab to the person and waiting. The agent's calls go through the Yardlet MCP broker as a
/// harness's would, for the task the QA window shows, so its tabs are the panel's. It also records how
/// large a snapshot of each QA page is. Checks land in `result.json`.
@MainActor
final class BrowserHostBrowserUseQA {
    private let output: URL
    private let base: String
    /// The task the QA window shows: the agent's calls are this task's, so its panel shows the agent's tabs.
    private let session: UUID
    private var record: [String: JSONValue] = [:]
    private var checks: [JSONValue] = []
    private var client: BrowserHostClient { MacBrowserHost.shared.client }
    private var broker: AgentToolBroker { MacAgentToolService.shared.broker }
    private var token = ""

    init(output: URL, base: String, panelSession: UUID) {
        self.output = output
        self.base = base
        session = panelSession
    }

    func run() async {
        try? FileManager.default.createDirectory(at: output.appending(path: "markers"), withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(3))
        guard let launch = broker.agentToolServer(for: session, workspaceRoots: []) else {
            check("the broker issues a task its tools", false, "no launch")
            return await finish()
        }
        token = launch.environment[AgentToolEnvironment.token] ?? ""
        await exerciseViewport()
        await exerciseFrames()
        await exerciseHandoff()
        await measureSnapshots()
        await finish()
    }

    // MARK: Screen sizes

    private func exerciseViewport() async {
        await navigate("viewport")
        let mobile = await call("browser_resize", ["preset": .string("mobile")])
        let phone = await pageValue("window.qa.read()")
        check("viewport: preset mobile gives the page a 375×812 touch phone",
              !mobile.isError && phone?["width"] == .integer(375) && phone?["height"] == .integer(812)
                && phone?["ratio"]?.doubleValue == 2 && phone?["coarse"] == .bool(true) && phone?["touchPoints"] == .integer(5)
                && phone?["userAgent"]?.stringValue?.contains("Android") == true && phone?["mobile"] == .bool(true),
              mobile.text + " / " + Self.describe(phone))

        await navigate("viewport")
        let reloaded = await pageValue("window.qa.read()")
        check("viewport: the phone size and touch stay after the page loads again",
              reloaded?["width"] == .integer(375) && reloaded?["touch"] == .bool(true), Self.describe(reloaded))

        let snapshot = await call(AgentToolCatalog.snapshot)
        if let target = Self.ref(in: snapshot.text, role: "button", name: "Tap target") {
            let clicked = await call(AgentToolCatalog.click, ["ref": .string(target)])
            let clicks = await pageValue("window.qa.clicks")
            check("viewport: a click by reference lands on the phone page's target", !clicked.isError && clicks == .integer(1),
                  clicked.text + " clicks \(Self.describe(clicks))")
        } else {
            check("viewport: a click by reference lands on the phone page's target", false, "no Tap target in " + snapshot.text)
        }

        let shot = await call(AgentToolCatalog.screenshot)
        let size = Self.imageSize(shot)
        check("viewport: a screenshot is the phone's 375×812", size.map { $0 == (375, 812) } ?? false,
              "\(size.map { "\($0.0)×\($0.1)" } ?? "no image") " + shot.text)

        let dark = await call("browser_resize", ["colorScheme": .string("dark")])
        let darkRead = await pageValue("window.qa.read()")
        check("viewport: colorScheme dark makes the page's prefers-color-scheme dark",
              !dark.isError && darkRead?["dark"] == .bool(true) && darkRead?["width"] == .integer(375),
              dark.text + " / " + Self.describe(darkRead))

        let full = await call(AgentToolCatalog.screenshot, ["fullPage": .bool(true)])
        let afterFull = await pageValue("window.qa.read()")
        check("viewport: a full-page screenshot leaves the phone emulation as it was",
              !full.isError && afterFull?["width"] == .integer(375) && afterFull?["mobile"] == .bool(true)
                && afterFull?["touchPoints"] == .integer(5),
              full.text + " / " + Self.describe(afterFull))

        let desktop = await call("browser_resize", ["preset": .string("desktop")])
        let desktopRead = await pageValue("window.qa.read()")
        check("viewport: preset desktop returns the tab to its own size and user agent, keeping the color scheme",
              !desktop.isError && desktopRead?["width"] == .integer(Int64(BrowserViewport.offscreenDefault.width))
                && desktopRead?["userAgent"]?.stringValue?.contains("Android") == false && desktopRead?["dark"] == .bool(true),
              desktop.text + " / " + Self.describe(desktopRead))

        // A size larger than the panel: the tab is drawn at it, and the panel shows it scaled down to fit.
        let large = await call("browser_resize", ["width": .integer(1600), "height": .integer(1000)])
        let largeRead = await pageValue("window.qa.read()")
        check("viewport: a custom 1600×1000 size reaches the page", !large.isError && largeRead?["width"] == .integer(1600),
              large.text + " / " + Self.describe(largeRead))
        await exerciseViewportInPanel()
    }

    /// The panel shows the agent's 1600×1000 tab scaled down to fit and passes the person's click to where it
    /// lands on the page; when the agent's turn ends, its size goes and the tab takes the panel's size again.
    private func exerciseViewportInPanel() async {
        guard let controller = await openPanel(), let view = controller.view else { return }
        _ = await waitUntilAsync(.seconds(10)) { controller.tab?.currentURL?.contains("/viewport") == true }
        try? await Task.sleep(for: .seconds(1))
        let scale = view.window?.backingScaleFactor ?? 2
        let surfaceWidth = view.viewSurface.map { IOSurfaceGetWidth($0) } ?? 0
        check("viewport: the panel's tab is drawn at the emulated 1600 points wide",
              surfaceWidth == Int(1600 * scale), "surface \(surfaceWidth) px at scale \(scale), view \(view.bounds.size)")
        capture(view, named: "viewport-panel-scaled.png")

        // Where the panel draws the page: scaled to fit, centered across and from the top, as the Claude app.
        let fit = min(1, view.bounds.width / 1600, view.bounds.height / 1000)
        let left = (view.bounds.width - 1600 * fit) / 2
        let box = await pageValue("(() => { const r = document.getElementById('target').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2] })()")
        let center = box?.arrayValue?.compactMap(\.doubleValue) ?? []
        let before = await pageValue("window.qa.clicks")?.integerValue ?? 0
        if center.count == 2 {
            click(view, at: NSPoint(x: left + center[0] * fit, y: center[1] * fit))
        }
        let landed = await waitUntilAsync(.seconds(3)) { (await self.pageValue("window.qa.clicks")?.integerValue ?? 0) > before }
        check("viewport: the person's click on the scaled page lands on the target", landed,
              "fit \(fit), target \(center), view \(view.bounds.size)")

        broker.taskTurnEnded(session)
        let cleared = await waitUntilAsync(.seconds(5)) {
            (await self.pageValue("innerWidth")?.integerValue).map { abs(Double($0) - view.bounds.width) < 2 } ?? false
        }
        check("viewport: the agent's size goes when its turn ends, and the tab takes the panel's size",
              cleared, "innerWidth \(Self.describe(await pageValue("innerWidth"))), panel \(view.bounds.width)")
        await exerciseViewportMenu(controller, view)
    }

    /// The person's Viewport menu: Mobile stays past the agent's turn, the agent's size over it says it replaced the
    /// person's and the menu marks it as the agent's, and Responsive returns the panel's size.
    private func exerciseViewportMenu(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async {
        controller.setViewport(BrowserViewportEmulation.mobile)
        let phone = await waitUntilAsync(.seconds(5)) { await self.pageValue("innerWidth") == .integer(375) }
        try? await Task.sleep(for: .milliseconds(800))
        capture(view, named: "viewport-panel-mobile.png")
        let scale = view.window?.backingScaleFactor ?? 2
        let surfaceWidth = view.viewSurface.map { IOSurfaceGetWidth($0) } ?? 0
        check("viewport: the person's Mobile shows the page at 375 points, centered in the panel",
              phone && surfaceWidth == Int(375 * scale) && controller.emulation?.owner == .person
                && abs(view.pageFrame.origin.x - (view.bounds.width - 375 * view.pageFrame.scale) / 2) < 1,
              "innerWidth \(Self.describe(await pageValue("innerWidth"))), surface \(surfaceWidth), frame \(view.pageFrame)")
        broker.taskTurnEnded(session)
        try? await Task.sleep(for: .seconds(1))
        check("viewport: the person's size stays when the agent's turn ends", await pageValue("innerWidth") == .integer(375),
              Self.describe(await pageValue("innerWidth")))
        let replaced = await call("browser_resize", ["width": .integer(500), "height": .integer(700)])
        check("viewport: the agent's size over the person's says it replaced theirs, and the menu marks it as the agent's",
              !replaced.isError && replaced.text.contains("the person picked") && controller.emulation?.owner == .agent
                && controller.emulation?.width == 500,
              replaced.text)
        controller.setViewport(nil)
        let responsive = await waitUntilAsync(.seconds(5)) {
            (await self.pageValue("innerWidth")?.integerValue).map { abs(Double($0) - view.bounds.width) < 2 } ?? false
        }
        check("viewport: Responsive returns the page to the panel's size", responsive && controller.emulation == nil,
              Self.describe(await pageValue("innerWidth")))
    }

    // MARK: Frames and shadow roots

    private func exerciseFrames() async {
        await navigate("frames")
        let loaded = await waitUntilAsync(.seconds(10)) {
            (await self.pageValue("window.qa.loaded.length")?.integerValue ?? 0) >= 3
        }
        if !loaded { check("frames: the page's three frames load", false, Self.describe(await pageValue("window.qa.loaded"))) }
        let snapshot = await call(AgentToolCatalog.snapshot)
        record["framesSnapshot"] = .string(snapshot.text)
        for name in ["Shadow button", "Closed shadow button", "Shadow field", "Same-origin button", "Cross-site button",
                     "Card number", "Nested button"] {
            check("frames: the snapshot reads “\(name)”", snapshot.text.contains("\"\(name)\""),
                  snapshot.text.split(separator: "\n").filter { $0.contains(name) }.joined(separator: " | "))
        }
        // browser_wait_for reads the page and its frames from the same origin, ignoring case and runs of spaces; a
        // frame from another origin it does not read, and its result says where the text is.
        let sameOrigin = await call(AgentToolCatalog.waitFor, ["text": .string("same-origin   BUTTON"), "timeout": .integer(5)])
        check("frames: browser_wait_for finds text in a frame from the same origin, ignoring case and spaces",
              !sameOrigin.isError, sameOrigin.text)
        let crossOrigin = await call(AgentToolCatalog.waitFor, ["text": .string("Cross-site button"), "timeout": .integer(1)])
        check("frames: browser_wait_for that runs out says the text is in a frame from another origin",
              crossOrigin.isError && crossOrigin.text.contains("“Cross-site button” is in a frame from ")
                && crossOrigin.text.contains("The page is at ") && crossOrigin.text.contains("Its text now"),
              crossOrigin.text)
        for (name, counter) in [("Same-origin button", "same"), ("Cross-site button", "cross"), ("Nested button", "nested"),
                                ("Shadow button", "shadow"), ("Closed shadow button", "closed")] {
            guard let ref = Self.ref(in: snapshot.text, role: "button", name: name) else {
                check("frames: a click by reference reaches “\(name)”", false, "no reference")
                continue
            }
            let clicked = await call(AgentToolCatalog.click, ["ref": .string(ref)])
            let reached = await waitUntilAsync(.seconds(3)) { (await self.pageValue("window.qa.\(counter)")?.integerValue ?? 0) > 0 }
            check("frames: a click by reference reaches “\(name)”", !clicked.isError && reached, clicked.text)
        }
        for (name, key, text) in [("Card number", "crossValue", "4242 4242 4242 4242"), ("Shadow field", "shadowValue", "in the shadow")] {
            guard let ref = Self.ref(in: snapshot.text, role: "textbox", name: name) else {
                check("frames: typing by reference reaches “\(name)”", false, "no reference")
                continue
            }
            let typed = await call(AgentToolCatalog.type, ["ref": .string(ref), "text": .string(text)])
            let value = await waitUntilAsync(.seconds(3)) { await self.pageValue("window.qa.\(key)") == .string(text) }
            check("frames: typing by reference reaches “\(name)”", !typed.isError && value,
                  typed.text + " / " + Self.describe(await pageValue("window.qa.\(key)")))
        }
    }

    // MARK: Handing a tab to the person

    /// The agent hands the tab to the person: the call waits; the task's panel opens on the tab with the agent's reason
    /// and the person's I'm done and Decline; text on the page also ends the wait; a timeout leaves the tab handed over,
    /// and the next call reads an answer given meanwhile; the end of the agent's turn ends a handoff.
    private func exerciseHandoff() async {
        await navigate("handoff")
        await closePanel()
        let previous = BrowserHostPaneController.current
        let started = ContinuousClock.now
        let answered = Answered()
        let first = Task {
            let result = await self.call("browser_handoff", ["reason": .string("Pass the page's check"), "timeout": .integer(30)])
            answered.result = result
            return result
        }
        try? await Task.sleep(for: .seconds(2))
        let early = answered.result
        check("handoff: browser_handoff waits for the person instead of answering at once", early == nil,
              early.map { "answered: " + $0.text } ?? "still waiting after 2 seconds")
        guard early == nil else { return }
        let opened = await waitUntilAsync(.seconds(5)) {
            BrowserHostPaneController.current !== previous && BrowserHostPaneController.current?.handoff != nil
        }
        guard let controller = BrowserHostPaneController.current, let view = controller.view else {
            check("handoff: the task's panel opens on the handed-over tab", false, "no panel")
            return await finishHandoff(first)
        }
        try? await Task.sleep(for: .milliseconds(600))
        capture(view, named: "handoff-panel.png")
        check("handoff: the task's panel opens on the handed-over tab, with the agent's reason",
              opened && controller.handoff?.reason == "Pass the page's check" && controller.tab?.currentURL?.contains("/handoff") == true,
              "handoff \(String(describing: controller.handoff)), address \(controller.tab?.currentURL ?? "none")")
        check("handoff: its notice waits with it", BrowserHandoffNotices.pending.count == 1, "\(BrowserHandoffNotices.pending.count)")
        let clicking = ContinuousClock.now
        _ = await pageValue("document.getElementById('human').click()")
        let clicked = ContinuousClock.now - clicking
        controller.answerHandoff(.done)
        let answeredAt = ContinuousClock.now - started
        let done = await first.value
        check("handoff: the person's I'm done ends the wait, the bar and the notice",
              !done.isError && done.text.contains("said they are done") && done.text.contains("/handoff")
                && controller.handoff == nil && BrowserHandoffNotices.pending.isEmpty,
              done.text + " (the page's click took \(clicked), answered \(answeredAt) after the call)")

        let second = Task { await self.call("browser_handoff", ["reason": .string("Approve the payment"), "timeout": .integer(30)]) }
        _ = await waitUntilAsync(.seconds(5)) { controller.handoff != nil }
        controller.answerHandoff(.declined)
        let declined = await second.value
        check("handoff: the person's Decline ends the wait and says so", declined.text.contains("declined"), declined.text)

        await navigate("handoff")
        let third = Task {
            await self.call("browser_handoff", ["reason": .string("Pass the page's check"), "text": .string("Verified"),
                                                "timeout": .integer(30)])
        }
        _ = await waitUntilAsync(.seconds(5)) { controller.handoff != nil }
        _ = await pageValue("document.getElementById('human').click()")
        let appeared = await third.value
        check("handoff: the text the agent named appearing on the page ends the wait",
              appeared.text.contains("“Verified” appeared") && controller.handoff == nil, appeared.text)

        let timedOut = await call("browser_handoff", ["reason": .string("Scan the QR code"), "timeout": .integer(1)])
        check("handoff: past its timeout the call answers and the tab stays handed over",
              timedOut.text.contains("has not answered") && controller.handoff?.reason == "Scan the QR code", timedOut.text)
        controller.answerHandoff(.done)
        let later = await call("browser_handoff", ["reason": .string("Scan the QR code"), "timeout": .integer(5)])
        check("handoff: an answer given after the timeout is the next call's", later.text.contains("said they are done"), later.text)

        let fourth = Task { await self.call("browser_handoff", ["reason": .string("Pass the page's check"), "timeout": .integer(30)]) }
        _ = await waitUntilAsync(.seconds(5)) { controller.handoff != nil }
        broker.taskTurnEnded(session)
        let ended = await fourth.value
        check("handoff: the end of the agent's turn ends a waiting handoff, its bar and its notice",
              ended.text.contains("turn ended") && controller.handoff == nil && BrowserHandoffNotices.pending.isEmpty, ended.text)
    }

    /// A call's result once it answers; nil while it waits. (A task group would wait for the call to end.)
    @MainActor private final class Answered {
        var result: AgentToolResult?
    }

    /// Ends a waiting handoff as the end of the turn would, so the run goes on.
    private func finishHandoff(_ call: Task<AgentToolResult, Never>) async {
        broker.taskTurnEnded(session)
        _ = await call.value
    }

    private func closePanel() async {
        NotificationCenter.default.post(name: BrowserHostQAFixture.closeBrowserPanel, object: nil)
        try? await Task.sleep(for: .milliseconds(800))
    }

    // MARK: Snapshot sizes

    /// How large reading each QA page is: characters, lines and references, and about a quarter as many tokens.
    private func measureSnapshots() async {
        var sizes: [String: JSONValue] = [:]
        for path in ["a11y", "large", "frames", "compat", "checkout", "login", "viewport", "vault/login"] {
            await navigate(path)
            try? await Task.sleep(for: .milliseconds(800))
            let text = await call(AgentToolCatalog.snapshot).text
            let refs = text.components(separatedBy: "[ref=").count - 1
            sizes[path] = .object(["characters": .integer(Int64(text.count)),
                                   "lines": .integer(Int64(text.split(separator: "\n").count)),
                                   "references": .integer(Int64(refs)),
                                   "aboutTokens": .integer(Int64(text.count / 4))])
        }
        record["snapshotSizes"] = .object(sizes)
        write()
    }

    // MARK: Panel

    private func openPanel() async -> BrowserHostPaneController? {
        let previous = BrowserHostPaneController.current
        NotificationCenter.default.post(name: BrowserHostQAFixture.openBrowserPanel, object: nil)
        guard await waitUntilAsync(.seconds(10), { BrowserHostPaneController.current !== previous
                && BrowserHostPaneController.current?.view != nil }),
              let controller = BrowserHostPaneController.current else {
            check("panel: the task's browser panel opens", false, "no panel")
            return nil
        }
        _ = await waitUntilAsync(.seconds(10)) { controller.hasTab && controller.view?.viewSurface != nil }
        return controller
    }

    private func capture(_ view: BrowserHostView, named name: String) {
        guard let content = view.window?.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appending(path: name))
    }

    private func click(_ view: BrowserHostView, at point: NSPoint) {
        guard let window = view.window else { return }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: 1) else { continue }
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }

    // MARK: Calls

    private func call(_ tool: String, _ arguments: [String: ToolJSON] = [:]) async -> AgentToolResult {
        await broker.handle(AgentToolCall(token: token, session: session.uuidString, tool: tool, arguments: .object(arguments)))
    }

    private func navigate(_ path: String) async {
        let result = await call(AgentToolCatalog.navigate, ["url": .string(base + path)])
        if result.isError { check("load \(path)", false, result.text) }
    }

    /// A value from the agent's active tab itself, read over the tab's own CDP connection (not an agent tool).
    private func pageValue(_ expression: String) async -> JSONValue? {
        let result = try? await client.tab(forSession: session)?.devTools.send("Runtime.evaluate", [
            "expression": .string(expression), "returnByValue": .bool(true)
        ], timeout: .seconds(20))
        return result?["result"]?["value"]
    }

    private static func ref(in snapshot: String, role: String, name: String) -> String? {
        let line = snapshot.split(separator: "\n").first { $0.contains("- \(role)") && $0.contains("\"\(name)\"") }
        return line.flatMap { line in
            line.range(of: #"\[ref=(@e\d+)\]"#, options: .regularExpression).map { String(line[$0].dropFirst(5).dropLast()) }
        }
    }

    /// A PNG result's width and height, from its header.
    private static func imageSize(_ result: AgentToolResult) -> (Int, Int)? {
        for part in result.content {
            guard case .image(let data, _) = part, let bytes = Data(base64Encoded: data), bytes.count > 24 else { continue }
            let number = { (offset: Int) in bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) } }
            return (number(16), number(20))
        }
        return nil
    }

    private static func describe(_ value: JSONValue?) -> String {
        guard let value, let data = try? JSONEncoder().encode(value) else { return "nil" }
        return String(decoding: data, as: UTF8.self)
    }

    private func waitUntilAsync(_ timeout: Duration, _ condition: @escaping @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    // MARK: Record

    private func check(_ name: String, _ ok: Bool, _ detail: String) {
        checks.append(.object(["check": .string(name), "ok": .bool(ok), "detail": .string(String(detail.prefix(800)))]))
        write()
    }

    private func write() {
        record["checks"] = .array(checks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(JSONValue.object(record)).write(to: output.appending(path: "result.json"), options: .atomic)
    }

    private func finish() async {
        write()
        try? "done".write(to: output.appending(path: "markers/finished"), atomically: true, encoding: .utf8)
        client.terminateHost()
        try? await Task.sleep(for: .seconds(1))
        endBrowserQA(checks: checks)
    }
}
#endif
