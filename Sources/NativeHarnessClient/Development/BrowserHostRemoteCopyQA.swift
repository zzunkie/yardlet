#if DEBUG
import AppKit
import Foundation
import SwiftUI
import YardletAgentTools
import YardletRemote

/// QA for what a remote device copies from a task's tab (docs/REMOTE_PROTOCOL.md §15.25, `tabCopied`), against the real
/// browser host, run by `run-check.sh … --ui-fixture-browser-check-only=remote-copy`: this Mac as a host on loopback and
/// another Mac's window following it, whose clipboard is a pasteboard of its own here. The window's clicks on the page's
/// Copy buttons (the async Clipboard API, and `execCommand` on a selected textarea) and its ⌘C and ⌘X on a selected word
/// and a field must land on that pasteboard; a password field's selection must not, nor what a page the window's click
/// opened writes as it loads; and this Mac's own clipboard must not change (only its change count is read, never what it
/// holds).
@MainActor
final class BrowserHostRemoteCopyQA {
    private let output: URL
    private let base: String
    private let session: UUID
    private var record: [String: JSONValue] = [:]
    private var checks: [JSONValue] = []
    private var client: BrowserHostClient { MacBrowserHost.shared.client }
    private var broker: AgentToolBroker { MacAgentToolService.shared.broker }
    private var token = ""
    /// The other Mac's clipboard.
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.zzunkie.yardlet.qa.remote-copy.\(UUID().uuidString)"))

    init(output: URL, base: String, panelSession: UUID) {
        self.output = output
        self.base = base
        session = panelSession
    }

    func run() async {
        try? FileManager.default.createDirectory(at: output.appending(path: "markers"), withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(3))
        defer { pasteboard.releaseGlobally() }
        guard let model = BrowserHostQAFixture.model, let launch = broker.agentToolServer(for: session, workspaceRoots: []) else {
            check("the broker issues a task its tools", false, "no launch")
            return await finish()
        }
        token = launch.environment[AgentToolEnvironment.token] ?? ""
        let opened = await call(AgentToolCatalog.navigate, ["url": .string(base + "remote-copy")])
        check("the agent's tab loads", !opened.isError, opened.text)
        guard let tab = client.tab(forSession: session) else {
            check("the tab is found", false, "")
            return await finish()
        }
        let hostClipboard = NSPasteboard.general.changeCount
        await anotherMac(copyingFrom: tab, model: model)
        check("this Mac's clipboard did not change", NSPasteboard.general.changeCount == hostClipboard,
              "change count \(hostClipboard) → \(NSPasteboard.general.changeCount)")
        await finish()
    }

    private func anotherMac(copyingFrom tab: BrowserTab, model: AppModel) async {
        let hostClient = client
        let task = session.uuidString
        do {
            let identity = try RemoteIdentity(noisePrivateKey: Data(RemoteRandom.bytes(32)), relayPrivateKey: Data(RemoteRandom.bytes(32)))
            let bridge = AppModelRemoteBridge(model: model, browser: RemoteTabBridge.Environment(
                client: { hostClient }, usesMacEditingCommands: true))
            let server = RemoteServer(
                configuration: RemoteServer.Configuration(server: RemoteServerInfo(name: "Mac Studio", appVersion: "qa"),
                                                          macKey: identity.noise.publicKey),
                bridge: bridge, devices: RemoteDeviceStore(fileURL: nil))
            await server.start()
            let listener = RemoteSecureListener(server: server, staticKey: identity.noise, port: 0, advertisement: nil, loopbackOnly: true)
            listener.start()
            defer { listener.stop() }
            var port: UInt16?
            _ = await waitUntil(.seconds(5)) {
                if case let .ready(ready) = listener.currentState { port = ready }
                return port != nil
            }
            let ticket = await server.openPairing()
            guard let port, let link = RemoteSecurePairingURL(macKey: identity.noise.publicKey, secret: ticket.secret, name: "Mac Studio",
                                                              hosts: ["127.0.0.1:\(port)"]).url else {
                return check("the host listens", false, "")
            }
            let hosts = RemoteHostDirectory(store: RemoteHostStore(fileURL: nil), keys: RemoteMemoryClientKeys(),
                                            hello: RemoteHandshakeHello(name: "MacBook Pro", platform: "macos", appVersion: "qa"))
            let board = pasteboard
            hosts.copyText = { text in
                board.clearContents()
                board.setString(text, forType: .string)
            }
            let paired = try await hosts.pair(link: link.absoluteString)
            defer { hosts.close(paired.id) }
            guard let remote = hosts.model(for: paired.id),
                  await waitUntil(.seconds(20), { remote.hasSnapshot && remote.task(task) != nil }) else {
                return check("the window lists the task", false, "")
            }
            check("the host offers copies", remote.browser.copiesFromPage, "")
            remote.select(.task(task))
            let size = NSSize(width: 1_512, height: 949)
            let hosting = NSHostingView(rootView: RemoteHostView(model: remote, directory: hosts))
            hosting.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(x: -9_000, y: -9_000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            try? await Task.sleep(for: .seconds(2))
            remote.browser.show(taskID: task, tabID: tab.key.uuidString)
            let drew = await waitUntil(.seconds(15)) {
                guard let frame = remote.browser.frame, let size = remote.browser.viewport else { return false }
                return frame.viewportWidth == Double(size.width) && frame.viewportHeight == Double(size.height)
            }
            check("the window shows the page", drew, "")
            try? await Task.sleep(for: .seconds(1))
            // Without a panel on this Mac the watched page has no focus, so Chromium refuses its own
            // `navigator.clipboard.writeText` ("Document is not focused"); recorded only, nothing is written to find out.
            record["watchedPageHasFocus"] = .string(await evaluate("document.hasFocus()", in: tab) ?? "")
            guard let points = await centers(of: ["copy", "legacy", "words", "field", "pass", "next"], in: tab),
                  let page = Self.pageView(in: hosting) else {
                return check("the page's parts and the window's page are found", false, "")
            }
            let browser = remote.browser
            func copied() -> String? { pasteboard.string(forType: .string) }
            func command(_ key: String) -> NSEvent? {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                 windowNumber: window.windowNumber, context: nil, characters: key,
                                 charactersIgnoringModifiers: key, isARepeat: false, keyCode: key == "c" ? 8 : 7)
            }

            // The page's Copy button: `navigator.clipboard.writeText` after the window's click.
            browser.input(.click(x: points["copy"]!.x, y: points["copy"]!.y))
            let key = await waitUntil(.seconds(10)) { copied() == "sk-qa-0123456789abcdef" }
            check("a Copy button's text lands on the other Mac's clipboard", key, copied() ?? "nothing")
            let succeeded = await waitUntil(.seconds(5)) {
                await self.evaluate("document.getElementById('status').textContent", in: tab) == "Copied"
            }
            check("the page's copy succeeds", succeeded, await evaluate("JSON.stringify(qa)", in: tab) ?? "")

            // `execCommand('copy')` on a textarea the page selects, only once the page's copies are known to be taken:
            // Chromium's own would write this Mac's clipboard.
            if key {
                browser.input(.click(x: points["legacy"]!.x, y: points["legacy"]!.y))
                let legacy = await waitUntil(.seconds(10)) { copied() == "legacy-copied-text" }
                check("an execCommand copy lands on the other Mac's clipboard", legacy, copied() ?? "nothing")
            }

            // ⌘C on a word the window's double click selected, through the window's own key handling.
            browser.input(.click(x: points["words"]!.x, y: points["words"]!.y))
            browser.input(.click(x: points["words"]!.x, y: points["words"]!.y, clickCount: 2))
            try? await Task.sleep(for: .milliseconds(500))
            if let event = command("c") { page.keyDown(with: event) }
            let word = await waitUntil(.seconds(10)) { copied() == "Pomegranate" }
            check("⌘C copies the selected word", word, copied() ?? "nothing")

            // ⌘A and Edit › Cut in a field: the field's text, cut from the page.
            browser.input(.click(x: points["field"]!.x, y: points["field"]!.y))
            browser.input(.key("Meta+a"))
            try? await Task.sleep(for: .milliseconds(300))
            page.cut(nil)
            let cut = await waitUntil(.seconds(10)) { copied() == "plain field text" }
            check("Cut copies a field's text", cut, copied() ?? "nothing")
            let emptied = await waitUntil(.seconds(5)) {
                await self.evaluate("document.getElementById('field').value", in: tab) == ""
            }
            check("Cut takes the text out of the field", emptied, "")

            // A password field's selection copies nothing, by ⌘C or Cut, and its text stays.
            browser.input(.click(x: points["pass"]!.x, y: points["pass"]!.y))
            browser.input(.text("qa-secret-pass"))
            browser.input(.key("Meta+a"))
            try? await Task.sleep(for: .milliseconds(300))
            if let event = command("c") { page.keyDown(with: event) }
            page.cut(nil)
            try? await Task.sleep(for: .seconds(2))
            let kept = await evaluate("document.getElementById('pass').value.length", in: tab)
            check("a password field's selection is not copied", copied() == "plain field text", copied() ?? "nothing")
            check("a password field keeps its text", kept == "14", kept ?? "")
            check("no refusal shows", browser.refusal == nil, browser.refusal ?? "")
            record["page"] = .string(await evaluate("JSON.stringify(qa)", in: tab) ?? "")

            // A page the window's click opens writes the clipboard as it loads: no activation of the window's, so not
            // the window's copy; it goes on as the page asked, where Chromium refuses it (the page has no focus here).
            browser.input(.click(x: points["next"]!.x, y: points["next"]!.y))
            let loaded = await waitUntil(.seconds(10)) {
                await self.evaluate("document.getElementById('status')?.textContent", in: tab).map { $0 == "Copied" || $0 == "Failed" } == true
            }
            try? await Task.sleep(for: .seconds(1))
            let next = await evaluate("JSON.stringify(qa)", in: tab) ?? ""
            record["loadedPage"] = .string(next)
            check("a page the click opened puts nothing on the other Mac's clipboard", loaded && copied() == "plain field text",
                  "\(copied() ?? "nothing"); page: \(next)")

            // The window goes: the page's copies go as it asks again, and its next document has no script.
            hosts.close(paired.id)
            let control = bridge.browser.copies.control
            let unwatched = await waitUntil(.seconds(10)) { !tab.isRemotelyWatched }
            try? await Task.sleep(for: .seconds(1))
            tab.send(.navigation(tab: tab.id, action: .reload))
            let clean = await waitUntil(.seconds(15)) {
                await self.evaluate("globalThis[\(RemoteJSON.string(control))] === undefined "
                    + "&& Clipboard.prototype.writeText.toString().includes('[native code]') "
                    + "&& document.readyState === 'complete'", in: tab) == "true"
            }
            check("the page takes no copies once the window goes", unwatched && clean, "watch ended \(unwatched)")
        } catch {
            check("another Mac follows the host", false, "\(error)")
        }
    }

    /// The centers of the page's elements by ID, in CSS pixels of the visible page, read as the page lays out now.
    private func centers(of ids: [String], in tab: BrowserTab) async -> [String: (x: Double, y: Double)]? {
        let expression = "JSON.stringify(Object.fromEntries(\(RemoteJSON.string(ids)).map(id => { "
            + "const box = document.getElementById(id).getBoundingClientRect(); "
            + "return [id, [box.x + Math.min(box.width / 2, 60), box.y + box.height / 2]]; })))"
        guard let text = await evaluate(expression, in: tab),
              let boxes = try? JSONDecoder().decode([String: [Double]].self, from: Data(text.utf8)) else { return nil }
        return boxes.compactMapValues { $0.count == 2 ? (x: $0[0], y: $0[1]) : nil }
    }

    /// Reads the page in its own world, as no agent or person does: nothing here counts as input to the tab.
    private func evaluate(_ expression: String, in tab: BrowserTab) async -> String? {
        let answer = try? await tab.devTools.send("Runtime.evaluate", [
            "expression": .string("String(\(expression))"), "returnByValue": .bool(true)
        ], timeout: .seconds(5))
        return answer?["result"]?["value"]?.stringValue
    }

    private static func pageView(in view: NSView) -> RemoteBrowserPageView? {
        if let page = view as? RemoteBrowserPageView { return page }
        for child in view.subviews { if let page = pageView(in: child) { return page } }
        return nil
    }

    private func waitUntil(_ timeout: Duration, _ condition: @escaping @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return true
    }

    private func call(_ tool: String, _ arguments: [String: ToolJSON] = [:]) async -> AgentToolResult {
        await broker.handle(AgentToolCall(token: token, session: session.uuidString, tool: tool, arguments: .object(arguments)))
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
