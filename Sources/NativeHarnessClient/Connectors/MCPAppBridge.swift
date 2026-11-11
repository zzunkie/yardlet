import Foundation
import YardletAgentTools

/// What a drawn view knows of its host, sent in `ui/initialize`'s answer (`hostContext`) and again in part when it
/// changes (`ui/notifications/host-context-changed`).
struct MCPAppHostContext: Equatable, Sendable {
    var isDark: Bool
    /// BCP 47, as the spec asks: `ko-KR` for the `ko_KR` the system names.
    var locale = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
    var timeZone = TimeZone.current.identifier
    /// The tallest the frame grows before the view scrolls inside it.
    var maximumHeight = 600

    /// Colors, fonts and radii in the spec's names, each a `light-dark()` pair, so a view that follows them reads as
    /// part of the conversation in either appearance.
    static let styleVariables: [String: String] = [
        "--color-background-primary": "light-dark(#ffffff, #1e1e1e)",
        "--color-background-secondary": "light-dark(#f5f5f7, #262626)",
        "--color-background-tertiary": "light-dark(#ececee, #2f2f2f)",
        "--color-text-primary": "light-dark(#1d1d1f, #f2f2f2)",
        "--color-text-secondary": "light-dark(#5f5f64, #b0b0b5)",
        "--color-text-tertiary": "light-dark(#8a8a8e, #8a8a8e)",
        "--color-text-danger": "light-dark(#c4161c, #ff6b63)",
        "--color-text-success": "light-dark(#1f7a33, #5fd07a)",
        "--color-border-primary": "light-dark(#d2d2d7, #48484b)",
        "--color-border-secondary": "light-dark(#e3e3e8, #3a3a3c)",
        "--color-ring-primary": "light-dark(#0a66d8, #4c9aff)",
        "--font-sans": "-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", sans-serif",
        "--font-mono": "ui-monospace, \"SF Mono\", Menlo, monospace",
        "--border-radius-sm": "4px",
        "--border-radius-md": "6px",
        "--border-radius-lg": "8px"
    ]

    func json(tool: ToolJSON?) -> ToolJSON {
        var fields: [String: ToolJSON] = [
            "theme": .string(isDark ? "dark" : "light"),
            "styles": .object(["variables": .object(Self.styleVariables.mapValues(ToolJSON.string))]),
            "displayMode": .string("inline"),
            "availableDisplayModes": .array([.string("inline")]),
            "containerDimensions": .object(["maxHeight": .integer(Int64(maximumHeight))]),
            "locale": .string(locale),
            "timeZone": .string(timeZone),
            "platform": .string("desktop"),
            "userAgent": .string("Yardlet"),
            "deviceCapabilities": .object(["touch": .bool(false), "hover": .bool(true)])
        ]
        if let tool { fields["toolInfo"] = .object(["tool": tool]) }
        return .object(fields)
    }
}

/// Yardlet's side of one view's JSON-RPC over `postMessage` (MCP Apps, spec 2026-01-26), apart from the web view
/// that carries it, so the protocol is the same on every platform and is tested without one. The view is someone
/// else's page: every message is checked, only the methods below are answered, and what it asks of a connector
/// goes through `Host`, which holds the checks a model's call gets (docs/CONNECTORS.md, "MCP Apps").
@MainActor
final class MCPAppBridge {
    /// What the bridge may ask of Yardlet for one view.
    struct Host {
        /// The tool as its server listed it (`hostContext.toolInfo`).
        var tool: ToolJSON?
        /// The call's arguments (`ui/notifications/tool-input`).
        var arguments: ToolJSON
        /// The call's result (`ui/notifications/tool-result`).
        var result: ToolJSON
        var version: String
        /// A `tools/call` by the server's own name for the tool: the result, or a refusal.
        var callTool: @MainActor (_ name: String, _ arguments: ToolJSON) async throws -> ToolJSON
        /// A `resources/read`.
        var readResource: @MainActor (_ uri: String) async throws -> ToolJSON
        /// Opens an `http` or `https` address as a link in the conversation opens.
        var openLink: @MainActor (URL) -> Void
    }

    enum Phase: Equatable {
        /// Loaded; the view has not sent `ui/initialize`.
        case loading
        /// Answered `ui/initialize`; waiting for `ui/notifications/initialized`.
        case initializing
        /// The view has its input and result.
        case ready
        case tornDown
    }

    static let protocolVersion = "2026-01-26"
    /// A message longer than this is not read.
    static let maximumMessageLength = 1024 * 1024
    /// Calls and reads one view may have under way at once.
    static let maximumRequests = 4
    /// How long a view has to answer `ui/resource-teardown`.
    static let teardownWait: Duration = .seconds(1)

    private(set) var phase: Phase = .loading
    private let host: Host
    private var context: MCPAppHostContext
    /// Posts a message into the view.
    private let post: @MainActor (ToolJSON) -> Void
    /// The view's height as it reports it (`ui/notifications/size-changed`).
    var onHeight: (@MainActor (Double) -> Void)?
    /// The view took its input and result.
    var onReady: (@MainActor () -> Void)?
    private var requestsUnderWay = 0
    private var lastLink: ContinuousClock.Instant?
    private var nextID: Int64 = 1
    private var teardownReply: (id: Int64, continuation: CheckedContinuation<Void, Never>)?

    init(host: Host, context: MCPAppHostContext, post: @escaping @MainActor (ToolJSON) -> Void) {
        self.host = host
        self.context = context
        self.post = post
    }

    /// A message the view posted, as the JSON text the page passed on.
    func receive(_ text: String) {
        guard text.utf8.count <= Self.maximumMessageLength,
              let message = try? JSONDecoder().decode(ToolJSON.self, from: Data(text.utf8)) else { return }
        receive(message)
    }

    func receive(_ message: ToolJSON) {
        guard phase != .tornDown, message["jsonrpc"]?.stringValue == "2.0" else { return }
        let id = message["id"].flatMap { id -> ToolJSON? in
            switch id {
            case .string, .integer: id
            default: nil
            }
        }
        guard let method = message["method"]?.stringValue else {
            // An answer: only the teardown request is Yardlet's.
            if let reply = teardownReply, case .integer(reply.id)? = id {
                teardownReply = nil
                reply.continuation.resume()
            }
            return
        }
        let params = message["params"] ?? .object([:])
        guard let id else {
            notification(method, params)
            return
        }
        request(method, params, id: id)
    }

    /// The appearance changed.
    func setDark(_ isDark: Bool) {
        guard context.isDark != isDark else { return }
        context.isDark = isDark
        guard phase == .ready || phase == .initializing else { return }
        send(method: "ui/notifications/host-context-changed", params: .object([
            "theme": .string(isDark ? "dark" : "light")
        ]))
    }

    /// Tells the view it is about to go and waits a moment for it to answer, so it can keep what it must.
    func tearDown() async {
        guard phase != .tornDown else { return }
        let wasShown = phase == .ready || phase == .initializing
        phase = .tornDown
        guard wasShown else { return }
        let id = nextID
        nextID += 1
        await withCheckedContinuation { continuation in
            teardownReply = (id, continuation)
            post(.object(["jsonrpc": .string("2.0"), "id": .integer(id), "method": .string("ui/resource-teardown"),
                          "params": .object(["reason": .string("The view left the screen.")])]))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.teardownWait)
                guard let self, let reply = self.teardownReply, reply.id == id else { return }
                self.teardownReply = nil
                reply.continuation.resume()
            }
        }
    }

    // MARK: Messages

    private func notification(_ method: String, _ params: ToolJSON) {
        switch method {
        case "ui/notifications/initialized":
            guard phase == .initializing else { return }
            phase = .ready
            send(method: "ui/notifications/tool-input", params: .object(["arguments": host.arguments]))
            send(method: "ui/notifications/tool-result", params: host.result)
            onReady?()
        case "ui/notifications/size-changed":
            guard let height = Self.number(params["height"]), height.isFinite, height >= 0 else { return }
            onHeight?(min(height, 100_000))
        default:
            // `notifications/message` (logs), `ui/notifications/request-teardown` and anything else: nothing of a
            // view's own words is written anywhere.
            break
        }
    }

    private func request(_ method: String, _ params: ToolJSON, id: ToolJSON) {
        switch method {
        case "ui/initialize":
            guard phase == .loading || phase == .initializing else {
                return fail(id, code: -32600, "The view was already initialized.")
            }
            phase = .initializing
            answer(id, .object([
                "protocolVersion": .string(Self.protocolVersion),
                "hostInfo": .object(["name": .string("Yardlet"), "version": .string(host.version)]),
                "hostCapabilities": .object([
                    "openLinks": .object([:]),
                    "serverTools": .object([:]),
                    "serverResources": .object([:]),
                    "logging": .object([:])
                ]),
                "hostContext": context.json(tool: host.tool)
            ]))
        case "ping":
            answer(id, .object([:]))
        case _ where phase == .loading:
            fail(id, code: -32002, "The view has not sent ui/initialize.")
        case "tools/call":
            guard let name = params["name"]?.stringValue, !name.isEmpty else {
                return fail(id, code: -32602, "tools/call needs a tool name.")
            }
            let arguments = params["arguments"] ?? .object([:])
            guard arguments.objectValue != nil else { return fail(id, code: -32602, "Tool arguments must be an object.") }
            run(id) { [host] in try await host.callTool(name, arguments) }
        case "resources/read":
            guard let uri = params["uri"]?.stringValue, !uri.isEmpty else {
                return fail(id, code: -32602, "resources/read needs a uri.")
            }
            run(id) { [host] in try await host.readResource(uri) }
        case "ui/open-link":
            guard let text = params["url"]?.stringValue, let url = URL(string: text),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                return fail(id, code: -32000, "Yardlet opens only http and https links.")
            }
            let now = ContinuousClock.now
            if let lastLink, now - lastLink < .seconds(1) {
                return fail(id, code: -32000, "Yardlet opens at most one link a second for a view.")
            }
            lastLink = now
            host.openLink(url)
            answer(id, .object([:]))
        case "ui/request-display-mode":
            answer(id, .object(["mode": .string("inline")]))
        case "ui/message", "ui/update-model-context":
            fail(id, code: -32000, "Yardlet does not pass a view's messages to the task yet.")
        default:
            fail(id, code: -32601, "Yardlet does not answer \(method).")
        }
    }

    /// Runs a request that waits on a connector, at most `maximumRequests` at a time.
    private func run(_ id: ToolJSON, _ work: @escaping @MainActor () async throws -> ToolJSON) {
        guard requestsUnderWay < Self.maximumRequests else {
            return fail(id, code: -32000, "The view has \(Self.maximumRequests) requests under way already.")
        }
        requestsUnderWay += 1
        Task { @MainActor [weak self] in
            let outcome: Result<ToolJSON, Error>
            do { outcome = .success(try await work()) } catch { outcome = .failure(error) }
            guard let self else { return }
            self.requestsUnderWay -= 1
            switch outcome {
            case .success(let result): self.answer(id, result)
            case .failure(let error): self.fail(id, code: -32000, Self.words(error))
            }
        }
    }

    private static func words(_ error: Error) -> String {
        switch error {
        case MCPAppViewFailure.refused(let message): message
        case MCPAppViewFailure.noView: "The connector no longer has this tool."
        case MCPAppViewFailure.notConnected(let name): "\(name) is not connected in Yardlet."
        case MCPAppViewFailure.timedOut: "The server did not answer in time."
        case MCPHTTPError.rpc(_, let message): message
        default: "The request failed."
        }
    }

    private static func number(_ value: ToolJSON?) -> Double? {
        switch value {
        case .integer(let number)?: Double(number)
        case .number(let number)?: number
        default: nil
        }
    }

    private func answer(_ id: ToolJSON, _ result: ToolJSON) {
        guard phase != .tornDown else { return }
        post(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private func fail(_ id: ToolJSON, code: Int64, _ message: String) {
        guard phase != .tornDown else { return }
        post(.object(["jsonrpc": .string("2.0"), "id": id,
                      "error": .object(["code": .integer(code), "message": .string(message)])]))
    }

    private func send(method: String, params: ToolJSON) {
        post(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
    }
}
