#if DEBUG
import AppKit
import Foundation
import ImageIO
import SwiftUI
import YardletAgentTools
import YardletRemote

/// QA for the pictures a remote device gets of a task's tabs (docs/REMOTE_PROTOCOL.md §15.25), against the real browser
/// host, run by `run-check.sh … --ui-fixture-browser-check-only=remote-frames --ui-fixture-browser-agent-visible=3`. The
/// page is dark, as a person's own may be, with text, a 2D canvas, a WebGL canvas and a video, in an agent's tab no panel
/// ever showed. Each picture must show the page itself, in its colors at their places, not only come back: hidden and
/// then watched, at the sizes a side panel or a phone asks for, while other tasks' tabs hid after it and memory is
/// critical, and in the window another Mac opens for this one over loopback, in light and dark.
@MainActor
final class BrowserHostRemoteFramesQA {
    private let output: URL
    private let base: String
    private let session: UUID
    private var record: [String: JSONValue] = [:]
    private var checks: [JSONValue] = []
    private var client: BrowserHostClient { MacBrowserHost.shared.client }
    private var broker: AgentToolBroker { MacAgentToolService.shared.broker }
    private var token = ""
    private var bridge: RemoteTabBridge?
    private var frames: URL { output.appending(path: "frames") }

    /// Where `/remote-frames` draws what must show, in fractions of its 1280 by 800 page, and the color there.
    private static let marks: [(name: String, x: Double, y: Double, isColor: (Int, Int, Int) -> Bool)] = [
        ("the 2D canvas", 200 / 1_280, 260 / 800, { red, green, blue in red > 180 && green < 110 && blue < 110 }),
        ("the WebGL canvas", 560 / 1_280, 260 / 800, { red, green, blue in green > 150 && red < 110 && blue < 130 })
    ]

    init(output: URL, base: String, panelSession: UUID) {
        self.output = output
        self.base = base
        session = panelSession
    }

    func run() async {
        try? FileManager.default.createDirectory(at: output.appending(path: "markers"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(3))
        guard let model = BrowserHostQAFixture.model, let launch = broker.agentToolServer(for: session, workspaceRoots: []) else {
            check("the broker issues a task its tools", false, "no launch")
            return await finish()
        }
        token = launch.environment[AgentToolEnvironment.token] ?? ""
        let hostClient = client
        bridge = RemoteTabBridge(model: model, environment: RemoteTabBridge.Environment(client: { hostClient }))

        let opened = await call(AgentToolCatalog.navigate, ["url": .string(base + "remote-frames")])
        check("the agent's tab loads", !opened.isError, opened.text)
        let ready = await call(AgentToolCatalog.evaluate, ["function": .string(Self.videoReady)])
        check("the video shows its first frame", !ready.isError && ready.text.contains("2"), ready.text)
        guard let tab = client.tab(forSession: session) else {
            check("the tab is found", false, "")
            return await finish()
        }

        // Past the agent's window the tab hides, as a task's tab does while nobody looks at it.
        try? await Task.sleep(for: client.agentVisibleWindow + .seconds(2))
        check("the tab is hidden", !tab.isShown, "")
        watch(tab)
        await picture(tab, named: "as-the-watch-starts")
        try? await Task.sleep(for: .seconds(1))
        await picture(tab, named: "a-second-later")
        for (width, height) in [(320, 320), (860, 1_500), (1_400, 1_800), (2_560, 2_560)] {
            await picture(tab, named: "panel-\(width)x\(height)", width: width, height: height)
        }
        tab.send(.navigation(tab: tab.id, action: .reload))
        try? await Task.sleep(for: .seconds(2))
        await picture(tab, named: "reloaded")
        bridge?.setWatched([])

        // Chromium lets a hidden tab's drawing go when other tabs hide after it and when memory is short.
        var others: [BrowserTab] = []
        for index in 0..<12 {
            if let other = try? client.openTab(forSession: UUID(), url: base + "tall?other=\(index)",
                                               viewport: .offscreenDefault, byAgent: true) { others.append(other) }
        }
        try? await Task.sleep(for: client.agentVisibleWindow + .seconds(2))
        _ = try? await tab.devTools.send("Memory.simulatePressureNotification", ["level": .string("critical")], timeout: .seconds(5))
        try? await Task.sleep(for: .seconds(1))
        watch(tab)
        await picture(tab, named: "after-other-tabs-hid")
        bridge?.setWatched([])

        for scheme in [NSAppearance.Name.aqua, .darkAqua] { await anotherMac(showing: tab, appearance: scheme) }
        await finish()
    }

    /// Waits for the video's first frame.
    private static let videoReady = """
        async () => { const clip = document.getElementById('clip'); \
        for (let i = 0; i < 100 && clip.readyState < 2; i++) await new Promise(r => setTimeout(r, 50)); \
        return clip.readyState >= 2 ? 2 : clip.readyState; }
        """

    private func watch(_ tab: BrowserTab) {
        bridge?.setWatched([RemoteTabWatch(taskID: session.uuidString, tabID: tab.key.uuidString)])
    }

    /// One picture as a remote device gets it: it must show the page.
    private func picture(_ tab: BrowserTab, named name: String, width: Int = 1_400, height: Int = 1_800) async {
        guard let bridge else { return }
        switch await bridge.capture(taskID: session.uuidString, tabID: tab.key.uuidString, maxWidth: width, maxHeight: height) {
        case let .success(frame):
            try? frame.image.write(to: frames.appending(path: "\(name).jpg"))
            let missing = Self.missing(in: frame.image)
            check("picture \(name)", missing.isEmpty, "\(frame.width)x\(frame.height), \(frame.image.count) bytes"
                  + (missing.isEmpty ? "" : ", without \(missing.joined(separator: ", "))"))
        case let .failure(error):
            check("picture \(name)", false, "refused: \(error.message)")
        }
    }

    /// What the picture does not show of what the page draws.
    private static func missing(in image: Data) -> [String] {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return ["any picture"] }
        let bitmap = NSBitmapImageRep(cgImage: picture)
        return marks.filter { mark in
            let color = bitmap.colorAt(x: Int(Double(bitmap.pixelsWide) * mark.x), y: Int(Double(bitmap.pixelsHigh) * mark.y))?
                .usingColorSpace(.sRGB)
            let parts = [color?.redComponent, color?.greenComponent, color?.blueComponent].map { Int(($0 ?? 0) * 255) }
            return !mark.isColor(parts[0], parts[1], parts[2])
        }.map(\.name)
    }

    /// This Mac as a host on loopback, and another Mac's window following it, which must draw the page in its panel.
    private func anotherMac(showing tab: BrowserTab, appearance: NSAppearance.Name) async {
        guard let model = BrowserHostQAFixture.model else { return }
        let hostClient = client
        let task = session.uuidString
        do {
            let identity = try RemoteIdentity(noisePrivateKey: Data(RemoteRandom.bytes(32)), relayPrivateKey: Data(RemoteRandom.bytes(32)))
            let server = RemoteServer(
                configuration: RemoteServer.Configuration(server: RemoteServerInfo(name: "Mac Studio", appVersion: "qa"),
                                                          macKey: identity.noise.publicKey),
                bridge: AppModelRemoteBridge(model: model, browser: RemoteTabBridge.Environment(client: { hostClient })),
                devices: RemoteDeviceStore(fileURL: nil))
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
            let paired = try await hosts.pair(link: link.absoluteString)
            defer { hosts.close(paired.id) }
            guard let remote = hosts.model(for: paired.id),
                  await waitUntil(.seconds(20), { remote.hasSnapshot && remote.task(task) != nil }) else {
                return check("the window lists the task", false, "")
            }
            remote.select(.task(task))
            let size = NSSize(width: 1_512, height: 949)
            let hosting = NSHostingView(rootView: RemoteHostView(model: remote, directory: hosts))
            hosting.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(x: -9_000, y: -9_000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hosting
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            try? await Task.sleep(for: .seconds(2))
            remote.browser.show(taskID: task, tabID: tab.key.uuidString)
            let drew = await waitUntil(.seconds(15)) { remote.browser.frame != nil }
            try? await Task.sleep(for: .seconds(2))
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                return check("the window draws", false, "")
            }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: frames.appending(path: "window-\(appearance.rawValue).png"))
            if let image = remote.browser.frame?.image { try? image.write(to: frames.appending(path: "window-\(appearance.rawValue).jpg")) }
            check("the window's panel shows the page, \(appearance.rawValue)", drew && Self.showsMarks(bitmap),
                  "frame \(remote.browser.frame?.number ?? -1), \(remote.browser.frame?.image.count ?? 0) bytes")
        } catch {
            check("another Mac follows the host", false, "\(error)")
        }
    }

    /// The window's right part holds a red and a green stretch of the page's canvases, as drawn at the panel's scale.
    private static func showsMarks(_ bitmap: NSBitmapImageRep) -> Bool {
        var found = marks.map { _ in false }
        for x in stride(from: bitmap.pixelsWide * 2 / 3, to: bitmap.pixelsWide, by: 8) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let (red, green, blue) = (Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
                for (index, mark) in marks.enumerated() where mark.isColor(red, green, blue) { found[index] = true }
            }
        }
        return found.allSatisfy { $0 }
    }

    private func waitUntil(_ timeout: Duration, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
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
