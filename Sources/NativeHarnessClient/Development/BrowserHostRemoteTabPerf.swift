#if DEBUG
import AppKit
import Foundation
import ImageIO
import Network
import YardletAgentTools
import YardletRemote

/// DEBUG-only timing of what a remote device sees of a task's tab (docs/REMOTE_PROTOCOL.md §15.25), run by
/// `run-check.sh … --ui-fixture-browser-check-only=remote-tab-perf`. A phone watches the agent's tab on `/remote-perf`
/// through the real server, bridge and browser host, over loopback and over links that delay and narrow the bytes as a
/// relay path does, and acknowledges each frame once it is decoded, as the phone apps do. For each link it records the
/// frames a second while the page scrolls, the time from each scroll and each typed character to the first decoded
/// picture that shows it (the page counts them in two colored blocks), the bytes per frame and the CPU the app and the
/// browser used. It also times one picture's steps alone. It writes `remote-tab-perf.json` and `result.json`.
@MainActor
final class BrowserHostRemoteTabPerf {
    private let output: URL
    private let base: String
    private let session: UUID
    private var record: [String: JSONValue] = [:]
    private var checks: [JSONValue] = []
    private var client: BrowserHostClient { MacBrowserHost.shared.client }
    private var broker: AgentToolBroker { MacAgentToolService.shared.broker }
    private var token = ""

    /// A phone's watch: its screen in CSS pixels and in image pixels.
    static let phone = RemoteTabViewport(width: 390, height: 844, mobile: true)
    static let phonePixels = (width: 1_170, height: 2_532)

    struct Link {
        var name: String
        var oneWayMs: Double
        /// nil for loopback as it is.
        var megabitsPerSecond: Double?
        var runs: Int
        /// The watch's `framesInFlight`; a server that does not take it sends one at a time.
        var framesInFlight = 1
    }

    /// Each link with one frame at a time and with two, one after the other, so both see the Mac as busy.
    static let links = [
        Link(name: "loopback", oneWayMs: 0, megabitsPerSecond: nil, runs: 3),
        Link(name: "relay", oneWayMs: 40, megabitsPerSecond: 20, runs: 3),
        Link(name: "slow", oneWayMs: 100, megabitsPerSecond: 5, runs: 1)
    ].flatMap { link in
        var two = link
        two.name += "+2"
        two.framesInFlight = 2
        return [link, two]
    }

    enum Scenario: String, CaseIterable {
        case scroll, type

        var inputs: Int { self == .scroll ? 50 : 30 }
        /// A phone sends scrolls at most ten a second (§15.25); a person types about five characters a second.
        var gap: Double { self == .scroll ? 0.1 : 0.2 }
        var input: String {
            self == .scroll ? #"{"kind":"scroll","x":195,"y":500,"deltaX":0,"deltaY":120}"# : #"{"kind":"text","text":"a"}"#
        }
    }

    init(output: URL, base: String, panelSession: UUID) {
        self.output = output
        self.base = base
        session = panelSession
    }

    func run() async {
        try? FileManager.default.createDirectory(at: output.appending(path: "markers"), withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(3))
        guard let model = BrowserHostQAFixture.model, let launch = broker.agentToolServer(for: session, workspaceRoots: []) else {
            check("the broker issues a task its tools", false, "no launch")
            return await finish()
        }
        token = launch.environment[AgentToolEnvironment.token] ?? ""
        let opened = await call(AgentToolCatalog.navigate, ["url": .string(base + "remote-perf")])
        check("the agent's tab loads", !opened.isError, opened.text)
        guard let tab = client.tab(forSession: session) else {
            check("the tab is found", false, "")
            return await finish()
        }
        await timeSteps(tab, model: model)
        await timeRemote(tab, model: model)
        await finish()
    }

    // MARK: - One picture's steps

    /// The bridge's whole picture, then each CDP call in it alone, then the picture at other qualities and scales, and
    /// the JSON the server writes for one frame.
    private func timeSteps(_ tab: BrowserTab, model: AppModel) async {
        let hostClient = client
        let bridge = RemoteTabBridge(model: model, environment: RemoteTabBridge.Environment(
            client: { hostClient }, latestSurface: { MacBrowserHost.shared.latestFrame(of: $0) }))
        let task = session.uuidString
        let tabID = tab.key.uuidString
        bridge.setWatched([RemoteTabWatch(taskID: task, tabID: tabID, viewport: Self.phone)])
        try? await Task.sleep(for: .seconds(2))
        var times: [Double] = []
        var sizes: [Double] = []
        var last: RemoteTabFrame?
        for _ in 0..<20 {
            await evaluate(tab, "scrollBy(0, 97)")
            try? await Task.sleep(for: .milliseconds(80))
            let start = Self.now()
            if case let .success(frame) = await bridge.capture(taskID: task, tabID: tabID, maxWidth: Self.phonePixels.width,
                                                              maxHeight: Self.phonePixels.height) {
                times.append(Self.now() - start)
                sizes.append(Double(frame.image.count))
                last = frame
            }
        }
        check("the bridge pictures the tab", times.count == 20, "\(times.count) of 20")
        var steps: [String: JSONValue] = ["bridgeCaptureMs": Self.stats(times), "bridgeCaptureBytes": Self.stats(sizes)]
        if let last {
            steps["picture"] = .object(["width": .integer(Int64(last.width)), "height": .integer(Int64(last.height)),
                                        "viewportWidth": .number(last.viewportWidth), "viewportHeight": .number(last.viewportHeight)])
        }

        let metrics = try? await tab.devTools.send("Page.getLayoutMetrics", timeout: .seconds(5))
        let visual = metrics?["cssVisualViewport"]
        let width = visual?["clientWidth"]?.doubleValue ?? 390
        let height = visual?["clientHeight"]?.doubleValue ?? 844
        let ratio = (try? await tab.devTools.send("Runtime.evaluate", [
            "expression": .string("devicePixelRatio"), "returnByValue": .bool(true)
        ], timeout: .seconds(5)))?["result"]?["value"]?.doubleValue ?? 1
        steps["devicePixelRatio"] = .number(ratio)
        let calls: [(String, String, [String: JSONValue])] = [
            ("Page.enable", "Page.enable", [:]),
            ("Page.getFrameTree", "Page.getFrameTree", [:]),
            ("Page.getLayoutMetrics", "Page.getLayoutMetrics", [:]),
            ("Runtime.evaluate devicePixelRatio", "Runtime.evaluate",
             ["expression": .string("devicePixelRatio"), "returnByValue": .bool(true)])
        ]
        for (name, method, parameters) in calls {
            var spent: [Double] = []
            for _ in 0..<20 {
                let start = Self.now()
                _ = try? await tab.devTools.send(method, parameters, timeout: .seconds(5))
                spent.append(Self.now() - start)
            }
            steps[name] = Self.stats(spent)
        }
        var shots: [JSONValue] = []
        let fits = Array(Set([1.0, 1.5, 2.0, 3.0, ratio].filter { $0 <= ratio + 0.01 })).sorted()
        for format in ["jpeg", "webp"] {
            for quality in [40, 60, 80] {
                for fit in fits {
                    var spent: [Double] = []
                    var bytes: [Double] = []
                    for _ in 0..<8 {
                        await evaluate(tab, "scrollBy(0, 97)")
                        try? await Task.sleep(for: .milliseconds(60))
                        let page = (try? await tab.devTools.send("Page.getLayoutMetrics", timeout: .seconds(5)))?["cssVisualViewport"]
                        let start = Self.now()
                        let shot = try? await tab.devTools.send("Page.captureScreenshot", [
                            "format": .string(format), "quality": .integer(Int64(quality)),
                            "clip": .object(["x": .number(page?["pageX"]?.doubleValue ?? 0), "y": .number(page?["pageY"]?.doubleValue ?? 0),
                                             "width": .number(width), "height": .number(height),
                                             "scale": .number(fit / ratio)])
                        ], timeout: .seconds(5))
                        spent.append(Self.now() - start)
                        bytes.append(Double(shot?["data"]?.stringValue.flatMap { Data(base64Encoded: $0) }?.count ?? 0))
                    }
                    shots.append(.object(["format": .string(format), "quality": .integer(Int64(quality)), "fit": .number(fit),
                                          "ms": Self.stats(spent), "bytes": Self.stats(bytes)]))
                }
            }
        }
        steps["screenshots"] = .array(shots)
        // The visible page without a clip, at a phone's size and at a side panel's: its picture's own size against the
        // viewports Chromium reports.
        var whole: [JSONValue] = []
        for viewport in [Self.phone, RemoteTabViewport(width: 700, height: 900, mobile: false)] {
            bridge.setWatched([RemoteTabWatch(taskID: task, tabID: tabID, viewport: viewport)])
            try? await Task.sleep(for: .seconds(2))
            let page = try? await tab.devTools.send("Page.getLayoutMetrics", timeout: .seconds(5))
            let pixelRatio = (try? await tab.devTools.send("Runtime.evaluate", [
                "expression": .string("devicePixelRatio"), "returnByValue": .bool(true)
            ], timeout: .seconds(5)))?["result"]?["value"]?.doubleValue ?? 0
            var spent: [Double] = []
            var size = ""
            for _ in 0..<8 {
                let start = Self.now()
                let shot = try? await tab.devTools.send("Page.captureScreenshot", ["format": .string("jpeg"), "quality": .integer(60)],
                                                        timeout: .seconds(5))
                spent.append(Self.now() - start)
                if let data = shot?["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) }),
                   let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    size = "\(image.width)x\(image.height), \(data.count) bytes"
                }
            }
            func side(_ name: String, _ key: String) -> JSONValue { page?[name]?[key] ?? .null }
            whole.append(.object([
                "asked": .string("\(viewport.width)x\(viewport.height) mobile \(viewport.mobile ?? false)"), "picture": .string(size),
                "devicePixelRatio": .number(pixelRatio), "ms": Self.stats(spent),
                "visual": .array([side("cssVisualViewport", "clientWidth"), side("cssVisualViewport", "clientHeight"),
                                  side("cssVisualViewport", "scale")]),
                "layout": .array([side("cssLayoutViewport", "clientWidth"), side("cssLayoutViewport", "clientHeight")])
            ]))
        }
        steps["withoutClip"] = .array(whole)
        bridge.setWatched([RemoteTabWatch(taskID: task, tabID: tabID, viewport: Self.phone)])
        if let last {
            var event = RemoteEvent(.tabFrame)
            event.taskId = task
            event.tabId = tabID
            event.frame = 1
            event.image = last.image
            event.mediaType = last.mediaType
            event.width = last.width
            event.height = last.height
            event.viewportWidth = last.viewportWidth
            event.viewportHeight = last.viewportHeight
            var spent: [Double] = []
            for _ in 0..<20 {
                let start = Self.now()
                _ = RemoteJSON.string(event)
                spent.append(Self.now() - start)
            }
            steps["eventJSONMs"] = Self.stats(spent)
        }
        record["steps"] = .object(steps)
        bridge.setWatched([])
        await evaluate(tab, "qa.reset()")
        write()
    }

    // MARK: - Over the server

    private func timeRemote(_ tab: BrowserTab, model: AppModel) async {
        let hostClient = client
        let task = session.uuidString
        let tabID = tab.key.uuidString
        do {
            let identity = try RemoteIdentity(noisePrivateKey: Data(RemoteRandom.bytes(32)), relayPrivateKey: Data(RemoteRandom.bytes(32)))
            var configuration = RemoteServer.Configuration(server: RemoteServerInfo(name: "QA Mac", appVersion: "qa"),
                                                           macKey: identity.noise.publicKey)
            // `--ui-fixture-remote-tab-interval=<seconds>` tries another shortest gap between frames than the server's.
            if let interval = BrowserHostQAFixture.argument("ui-fixture-remote-tab-interval").flatMap(Double.init) {
                configuration.tabFrameInterval = interval
            }
            record["tabFrameInterval"] = .number(configuration.tabFrameInterval)
            let server = RemoteServer(
                configuration: configuration,
                bridge: AppModelRemoteBridge(model: model, browser: RemoteTabBridge.Environment(
                    client: { hostClient }, latestSurface: { MacBrowserHost.shared.latestFrame(of: $0) })),
                devices: RemoteDeviceStore(fileURL: nil))
            await server.start()
            let listener = RemoteSecureListener(server: server, staticKey: identity.noise, port: 0, advertisement: nil, loopbackOnly: true)
            listener.start()
            defer { listener.stop() }
            var listening: UInt16?
            _ = await waitUntil(.seconds(5)) {
                if case let .ready(ready) = listener.currentState { listening = ready }
                return listening != nil
            }
            guard let listening else { return check("the host listens", false, "") }
            let key = RemoteKeyPair.generate()
            let ticket = await server.openPairing()
            let pairing = RemoteHandshakeHello(name: "QA Phone", platform: "ios", appVersion: "qa",
                                               pair: RemoteEncoding.base64url(ticket.secret))
            let (paired, reply) = try await RemoteClientSocket.open(
                url: URL(string: "ws://127.0.0.1:\(listening)/")!, clientKey: key, hostKey: identity.noise.publicKey,
                hello: pairing, timeout: 10)
            paired.close()
            check("the phone pairs", reply.paired == true, "")

            var runs: [JSONValue] = []
            for link in Self.links {
                var shaped: ShapedLink?
                var port = listening
                if let rate = link.megabitsPerSecond {
                    let made = try ShapedLink(upstream: listening, oneWayMs: link.oneWayMs, megabitsPerSecond: rate)
                    guard let opened = await made.start() else {
                        check("the \(link.name) link opens", false, "")
                        continue
                    }
                    shaped = made
                    port = opened
                }
                defer { shaped?.stop() }
                let (socket, _) = try await RemoteClientSocket.open(
                    url: URL(string: "ws://127.0.0.1:\(port)/")!, clientKey: key, hostKey: identity.noise.publicKey,
                    hello: RemoteHandshakeHello(name: "QA Phone", platform: "ios", appVersion: "qa"), timeout: 15)
                let phone = PerfPhone(socket: socket, misreads: output.appending(path: "misreads-\(link.name)"))
                phone.start()
                defer { socket.close() }
                phone.expectReset()
                await evaluate(tab, "qa.reset()")
                let viewport = #"{"width":\#(Self.phone.width),"height":\#(Self.phone.height),"mobile":true}"#
                phone.send(#"{"id":"watch","type":"watchTab","taskId":"\#(task)","tabId":"\#(tabID)","maxWidth":\#(Self.phonePixels.width),"maxHeight":\#(Self.phonePixels.height),"viewport":\#(viewport),"framesInFlight":\#(link.framesInFlight)}"#)
                let watching = await waitUntil(.seconds(10)) { phone.response("watch") != nil }
                check("the \(link.name) phone watches the tab", watching && phone.response("watch")?.ok == true,
                      phone.response("watch")?.error?.message ?? "")
                let first = await waitUntil(.seconds(15)) { !phone.isResetting }
                check("the \(link.name) phone gets a first picture", first, "")
                guard watching, first else { continue }
                for scenario in Scenario.allCases {
                    for index in 1...link.runs {
                        runs.append(await measure(scenario, run: index, link: link, phone: phone, tab: tab, task: task, tabID: tabID))
                        record["runs"] = .array(runs)
                        write()
                    }
                }
                phone.send(#"{"id":"unwatch","type":"unwatchTab","taskId":"\#(task)"}"#)
                _ = await waitUntil(.seconds(5)) { phone.response("unwatch") != nil }
            }
            record["runs"] = .array(runs)
            record["summary"] = Self.summarize(runs)
        } catch {
            check("the phone follows the host", false, "\(error)")
        }
    }

    /// One run: the page back at its top with nothing typed, then the scenario's input at its pace, then whatever
    /// pictures still come within a few seconds.
    private func measure(_ scenario: Scenario, run: Int, link: Link, phone: PerfPhone, tab: BrowserTab, task: String,
                         tabID: String) async -> JSONValue {
        phone.expectReset()
        await evaluate(tab, "qa.reset()")
        let reset = await waitUntil(.seconds(10)) { !phone.isResetting }
        // Idle first, as a person looks before they touch.
        try? await Task.sleep(for: .milliseconds(1_200))
        _ = phone.takeFrames()
        let cpuBefore = Self.cpu()
        let started = Self.now()
        var sent: [Double] = []
        // Each run's requests have their own ids: answers of an earlier run stay apart.
        let prefix = "\(link.name)-\(scenario.rawValue)-\(run)-"
        for index in 0..<scenario.inputs {
            sent.append(Self.now())
            phone.send(#"{"id":"\#(prefix)\#(index)","type":"tabInput","taskId":"\#(task)","tabId":"\#(tabID)","input":\#(scenario.input)}"#)
            let wait = started + Double(index + 1) * scenario.gap * 1_000 - Self.now()
            if wait > 0 { try? await Task.sleep(for: .milliseconds(wait)) }
        }
        let inputsEnded = Self.now()
        let caughtUp = await waitUntil(.seconds(8)) { phone.highestCount >= scenario.inputs }
        try? await Task.sleep(for: .milliseconds(300))
        let ended = Self.now()
        let cpuAfter = Self.cpu()
        let frames = phone.takeFrames()
        let refused = (0..<scenario.inputs).compactMap { phone.response("\(prefix)\($0)")?.error?.code.rawValue }
        let answers = sent.enumerated().compactMap { index, at in phone.answered("\(prefix)\(index)").map { $0 - at } }
        let counts = await evaluateValue(tab, "qa.counts()")

        var latencies: [Double] = []
        var missing = 0
        for (index, at) in sent.enumerated() {
            if let shown = frames.first(where: { ($0.count ?? -1) >= index + 1 }) {
                latencies.append(shown.shownAt - at)
            } else {
                missing += 1
            }
        }
        let during = frames.filter { $0.receivedAt >= started && $0.receivedAt <= inputsEnded }
        let gaps = zip(during.dropFirst(), during).map { $0.receivedAt - $1.receivedAt }
        // Seconds, from the clock's milliseconds.
        let span = (inputsEnded - started) / 1_000
        let wall = (ended - started) / 1_000
        return .object([
            "link": .string(link.name), "scenario": .string(scenario.rawValue), "run": .integer(Int64(run)),
            "reset": .bool(reset), "caughtUp": .bool(caughtUp),
            "framesPerSecond": .number(Double(during.count) / span),
            "frames": .integer(Int64(frames.count)),
            "shiftedFrames": .integer(Int64(frames.filter(\.shifted).count)),
            "frameGapMs": Self.stats(gaps),
            "inputToPictureMs": Self.stats(latencies),
            "inputsWithoutPicture": .integer(Int64(missing)),
            "bytesPerFrame": Self.stats(during.map { Double($0.bytes) }),
            "decodeMs": Self.stats(during.map { $0.shownAt - $0.receivedAt }),
            "pictureSize": .string(frames.last.map { "\($0.width)x\($0.height)" } ?? ""),
            "appCores": .number((cpuAfter.app - cpuBefore.app) / wall),
            "browserCores": .number((cpuAfter.browser - cpuBefore.browser) / wall),
            "refusedInputs": .array(refused.map(JSONValue.string)),
            "inputAnswerMs": Self.stats(answers),
            "pageCounts": counts ?? .null
        ])
    }

    // MARK: - Summary

    private static func summarize(_ runs: [JSONValue]) -> JSONValue {
        var groups: [String: [JSONValue]] = [:]
        var order: [String] = []
        for run in runs {
            let key = "\(run["link"]?.stringValue ?? "")/\(run["scenario"]?.stringValue ?? "")"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(run)
        }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        return .array(order.map { key in
            let group = groups[key] ?? []
            func values(_ path: [String]) -> [Double] {
                group.compactMap { run in
                    var value: JSONValue? = run
                    for part in path { value = value?[part] }
                    return value?.doubleValue
                }
            }
            return .object([
                "group": .string(key), "runs": .integer(Int64(group.count)),
                "framesPerSecond": .array(values(["framesPerSecond"]).map(JSONValue.number)),
                "inputToPictureP50Ms": .array(values(["inputToPictureMs", "p50"]).map(JSONValue.number)),
                "inputToPictureP95Ms": .array(values(["inputToPictureMs", "p95"]).map(JSONValue.number)),
                "bytesPerFrameMean": .array(values(["bytesPerFrame", "mean"]).map(JSONValue.number)),
                "appCores": .array(values(["appCores"]).map(JSONValue.number)),
                "browserCores": .array(values(["browserCores"]).map(JSONValue.number)),
                "medianFramesPerSecond": .number(median(values(["framesPerSecond"]))),
                "medianP50Ms": .number(median(values(["inputToPictureMs", "p50"]))),
                "medianP95Ms": .number(median(values(["inputToPictureMs", "p95"])))
            ])
        })
    }

    static func stats(_ values: [Double]) -> JSONValue {
        guard !values.isEmpty else { return .object(["n": .integer(0)]) }
        let sorted = values.sorted()
        func at(_ fraction: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))] }
        let mean = values.reduce(0, +) / Double(values.count)
        return .object(["n": .integer(Int64(values.count)), "mean": .number(Self.round(mean)), "p50": .number(Self.round(at(0.5))),
                        "p95": .number(Self.round(at(0.95))), "max": .number(Self.round(sorted.last ?? 0))])
    }

    private static func round(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    /// Milliseconds on a clock that only goes forward.
    nonisolated static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

    /// CPU seconds this app's process and its descendants (the browser host and its helpers) used so far.
    private static func cpu() -> (app: Double, browser: Double) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,ppid=,time="]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return (0, 0) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var parent: [Int32: Int32] = [:]
        var time: [Int32: Double] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { continue }
            parent[pid] = ppid
            time[pid] = fields[2].split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
        }
        let me = getpid()
        func descends(_ pid: Int32) -> Bool {
            var current = parent[pid]
            while let step = current, step > 1 {
                if step == me { return true }
                current = parent[step]
            }
            return false
        }
        let browser = time.filter { descends($0.key) }.values.reduce(0, +)
        return (time[me] ?? 0, browser)
    }

    // MARK: - Page and record

    private func evaluate(_ tab: BrowserTab, _ expression: String) async {
        _ = try? await tab.devTools.send("Runtime.evaluate", ["expression": .string(expression), "returnByValue": .bool(true)],
                                         timeout: .seconds(5))
    }

    private func evaluateValue(_ tab: BrowserTab, _ expression: String) async -> JSONValue? {
        (try? await tab.devTools.send("Runtime.evaluate", ["expression": .string(expression), "returnByValue": .bool(true)],
                                      timeout: .seconds(5)))?["result"]?["value"]
    }

    private func waitUntil(_ timeout: Duration, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func call(_ tool: String, _ arguments: [String: ToolJSON] = [:]) async -> AgentToolResult {
        await broker.handle(AgentToolCall(token: token, session: session.uuidString, tool: tool, arguments: .object(arguments)))
    }

    private func check(_ name: String, _ ok: Bool, _ detail: String) {
        checks.append(.object(["check": .string(name), "ok": .bool(ok), "detail": .string(String(detail.prefix(800)))]))
        write()
    }

    private func write() {
        record["checks"] = .array(checks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(JSONValue.object(record)) else { return }
        try? data.write(to: output.appending(path: "result.json"), options: .atomic)
        try? data.write(to: output.appending(path: "remote-tab-perf.json"), options: .atomic)
    }

    private func finish() async {
        write()
        try? "done".write(to: output.appending(path: "markers/finished"), atomically: true, encoding: .utf8)
        client.terminateHost()
        try? await Task.sleep(for: .seconds(1))
        endBrowserQA(checks: checks)
    }
}

/// A phone on one connection: it decodes each frame off the connection's thread, in order, reads how much input the
/// picture shows from the page's two blocks, and acknowledges the frame once decoded, as the phone apps do.
private final class PerfPhone: @unchecked Sendable {
    struct Frame {
        var number: Int
        var receivedAt: Double
        var shownAt: Double
        var bytes: Int
        /// How many inputs the picture shows, counted on from the last reset; nil when the blocks could not be read.
        var count: Int?
        var width: Int
        var height: Int
        /// Both blocks read white: the bar is not where the page draws it, as when the picture was taken off the
        /// visible page's place (a white band where the page was not drawn). No count the scenarios reach reads so.
        var shifted: Bool
    }

    private let socket: RemoteClientSocket
    private let decoding = DispatchQueue(label: "qa.remote-tab-perf.decode", qos: .userInitiated)
    private let lock = NSLock()
    private var frames: [Frame] = []
    private var responses: [String: RemoteResponse] = [:]
    private var answeredAt: [String: Double] = [:]
    private var resetting = false
    private var counted = 0
    private var receivedFrames = 0
    private var misreadsKept = 0

    /// Where a picture whose blocks read as a jump no input explains is kept, to look at.
    private let misreads: URL

    init(socket: RemoteClientSocket, misreads: URL) {
        self.socket = socket
        self.misreads = misreads
    }

    func start() {
        socket.start(onMessage: { [weak self] data in self?.received(data) }, onClose: { _ in })
    }

    func send(_ text: String) {
        socket.send(Data(text.utf8))
    }

    func response(_ id: String) -> RemoteResponse? { lock.withLock { responses[id] } }
    func answered(_ id: String) -> Double? { lock.withLock { answeredAt[id] } }
    /// Frames received since the phone began, also those before a reset showed.
    var receivedCount: Int { lock.withLock { receivedFrames } }
    var isResetting: Bool { lock.withLock { resetting } }
    var highestCount: Int { lock.withLock { counted } }

    /// The page goes back to no input: frames count again from the first that shows none.
    func expectReset() { lock.withLock { resetting = true } }

    func takeFrames() -> [Frame] {
        lock.withLock {
            defer { frames.removeAll() }
            return frames
        }
    }

    private struct Probe: Decodable {
        var re: String?
        var event: String?
    }

    private func received(_ data: Data) {
        let receivedAt = BrowserHostRemoteTabPerf.now()
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else { return }
        if let id = probe.re {
            if let response = try? JSONDecoder().decode(RemoteResponse.self, from: data) {
                lock.withLock {
                    responses[id] = response
                    answeredAt[id] = receivedAt
                }
            }
            return
        }
        guard probe.event == RemoteEvent.Name.tabFrame.rawValue, let event = try? JSONDecoder().decode(RemoteEvent.self, from: data),
              let number = event.frame else { return }
        decoding.async { [self] in
            let shown = Self.shownCount(event)
            let shownAt = BrowserHostRemoteTabPerf.now()
            send(#"{"id":"ack\#(number)","type":"tabFrameAck","taskId":"\#(event.taskId ?? "")","tabId":"\#(event.tabId ?? "")","frame":\#(number)}"#)
            lock.withLock {
                receivedFrames += 1
                var count: Int?
                let shifted = shown == 63
                if shifted, misreadsKept < 6, let image = event.image {
                    misreadsKept += 1
                    try? FileManager.default.createDirectory(at: misreads, withIntermediateDirectories: true)
                    try? image.write(to: misreads.appending(path: "shifted-frame-\(number).jpg"))
                }
                if let shown, !shifted {
                    if resetting {
                        if shown == 0 {
                            resetting = false
                            counted = 0
                            count = 0
                        }
                    } else {
                        // The blocks count modulo 64; the page's count only grows between resets, and by far less than
                        // 24 between two pictures. A larger step is a misread: kept aside, not counted.
                        let step = ((shown - counted % 64) + 64) % 64
                        if step <= 24 {
                            counted += step
                            count = counted
                        } else if misreadsKept < 12, let image = event.image {
                            misreadsKept += 1
                            try? FileManager.default.createDirectory(at: misreads, withIntermediateDirectories: true)
                            try? image.write(to: misreads.appending(path: "frame-\(number)-read-\(shown)-after-\(counted).jpg"))
                        }
                    }
                }
                guard !resetting else { return }
                frames.append(Frame(number: number, receivedAt: receivedAt, shownAt: shownAt, bytes: event.image?.count ?? 0,
                                    count: count, width: event.width ?? 0, height: event.height ?? 0, shifted: shifted))
            }
        }
    }

    private static let palette: [(Int, Int, Int)] = [(0, 0, 0), (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0),
                                                     (255, 0, 255), (0, 255, 255), (255, 255, 255)]

    /// Decodes the whole picture, as a phone does before it shows it, and reads the two blocks at the bar's right end
    /// (`/remote-perf`: 36 px blocks, 6 px apart, 8 px from the edge, in a 56 px bar).
    private static func shownCount(_ event: RemoteEvent) -> Int? {
        guard let data = event.image, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let viewport = event.viewportWidth, viewport > 0 else { return nil }
        let scale = Double(image.width) / viewport
        func block(_ centerX: Double) -> Int? {
            let side = max(4, Int(12 * scale))
            let rect = CGRect(x: Int(centerX * scale) - side / 2, y: Int(28 * scale) - side / 2, width: side, height: side)
            guard let crop = image.cropping(to: rect) else { return nil }
            var pixel = [UInt8](repeating: 0, count: 4)
            guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .medium
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let color = (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
            return palette.indices.min { first, second in
                distance(palette[first], color) < distance(palette[second], color)
            }
        }
        guard let low = block(viewport - 8 - 36 - 6 - 18), let high = block(viewport - 8 - 18) else { return nil }
        return low + 8 * high
    }

    private static func distance(_ first: (Int, Int, Int), _ second: (Int, Int, Int)) -> Int {
        let red = first.0 - second.0, green = first.1 - second.1, blue = first.2 - second.2
        return red * red + green * green + blue * blue
    }
}

/// A loopback TCP link that delays each direction's bytes and lets them through at a rate, as a path through the relay
/// does: the bytes a chunk needs at the rate, after the chunks before it, then the one-way delay.
private final class ShapedLink: @unchecked Sendable {
    /// One direction's bytes; only the link's queue touches it.
    private final class Lane: @unchecked Sendable {
        var free = DispatchTime.now()
        var waiting: [(at: DispatchTime, data: Data)] = []
    }

    private let queue = DispatchQueue(label: "qa.remote-tab-perf.link")
    private let listener: NWListener
    private let upstream: NWEndpoint.Port
    private let delay: Double
    private let bytesPerSecond: Double
    private var connections: [NWConnection] = []

    init(upstream: UInt16, oneWayMs: Double, megabitsPerSecond: Double) throws {
        listener = try NWListener(using: Self.parameters(local: true))
        self.upstream = NWEndpoint.Port(rawValue: upstream) ?? .any
        delay = oneWayMs / 1_000
        bytesPerSecond = megabitsPerSecond * 1_000_000 / 8
    }

    private static func parameters(local: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        if local { parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any) }
        return parameters
    }

    func start() async -> UInt16? {
        listener.newConnectionHandler = { [weak self] inbound in self?.accept(inbound) }
        listener.start(queue: queue)
        for _ in 0..<300 {
            if let port = listener.port?.rawValue, port != 0 { return port }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func stop() {
        queue.async { [self] in
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ inbound: NWConnection) {
        let outbound = NWConnection(host: .ipv4(.loopback), port: upstream, using: Self.parameters(local: false))
        connections += [inbound, outbound]
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        pump(from: inbound, to: outbound, lane: Lane())
        pump(from: outbound, to: inbound, lane: Lane())
    }

    private func pump(from source: NWConnection, to destination: NWConnection, lane: Lane) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [self] data, _, complete, error in
            if let data, !data.isEmpty {
                let start = max(DispatchTime.now(), lane.free)
                lane.free = start + Double(data.count) / bytesPerSecond
                let at = lane.free + delay
                lane.waiting.append((at, data))
                queue.asyncAfter(deadline: at) { [self] in deliver(lane, to: destination) }
            }
            if complete || error != nil {
                queue.asyncAfter(deadline: max(DispatchTime.now(), lane.free) + delay + 0.05) {
                    destination.cancel()
                    source.cancel()
                }
                return
            }
            pump(from: source, to: destination, lane: lane)
        }
    }

    private func deliver(_ lane: Lane, to destination: NWConnection) {
        let now = DispatchTime.now()
        while let first = lane.waiting.first, first.at <= now {
            lane.waiting.removeFirst()
            destination.send(content: first.data, completion: .idempotent)
        }
    }
}
#endif
