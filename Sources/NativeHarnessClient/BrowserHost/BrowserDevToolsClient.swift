import Foundation

enum BrowserDevToolsError: LocalizedError, Equatable {
    case notSent(String)
    case protocolError(String, JSONValue)
    case timedOut(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .notSent(let method): "CDP \(method) could not be sent to the browser host"
        case .protocolError(let method, let error): "CDP \(method) failed: \(error.readableText ?? "")"
        case .timedOut(let method): "CDP \(method) timed out"
        case .closed: "The browser tab closed"
        }
    }
}

/// A frame from another site that renders in a process of its own and answers on a DevTools session of its own
/// (an out-of-process iframe), which the tab's session attached to (`attachFrames()`).
struct BrowserFrameSession: Equatable, Sendable {
    /// The session's id, which a message for the frame carries as `sessionId`.
    let id: String
    /// The frame's id (its target's id).
    let frameID: String
    /// The session it was attached from: nil for the tab's own, or the session of the frame that holds it.
    let parent: String?
}

/// Chrome DevTools Protocol over the browser host's `devTools` messages. It knows only CDP JSON,
/// so the same client serves any host that speaks CDP (CEF, WebView2).
@MainActor
final class BrowserDevToolsClient {
    /// Delivers a raw message to the host; returns false when it cannot.
    private let transport: (String) -> Bool
    private var nextID: Int64 = 1
    private var pending: [Int64: (method: String, session: String?, continuation: CheckedContinuation<JSONValue, Error>)] = [:]
    private var eventWaiters: [(token: Int64, method: String, continuation: CheckedContinuation<JSONValue?, Never>)] = []
    /// Every event of the tab's own session received, in order, but a binding's call. A frame session's events stay
    /// out of it.
    private(set) var events: [(method: String, params: JSONValue)] = []
    /// The frames from other sites attached now, in the order they attached (`attachFrames()`).
    private(set) var frameSessions: [BrowserFrameSession] = []
    /// The page's main frame, which keeps its id for the tab's life: from the tree a caller read (`Page.getFrameTree`),
    /// and from each main-frame commit after.
    var mainFrameID: String?
    /// Whether each frame session attaches the frames it holds in turn.
    private var attachesFrames = false
    /// Called when a call times out, and when one is answered, with its method: whether the page
    /// answers is what `BrowserTab.unresponsive` follows.
    var onTimeout: ((String) -> Void)?
    var onAnswer: ((String) -> Void)?
    /// Called with every event as it arrives (the panel's vault watch).
    private var eventObservers: [UUID: (String, JSONValue) -> Void] = [:]

    func observeEvents(_ observer: @escaping (String, JSONValue) -> Void) -> UUID {
        let token = UUID()
        eventObservers[token] = observer
        return token
    }

    func stopObservingEvents(_ token: UUID) {
        eventObservers[token] = nil
    }

    init(transport: @escaping (String) -> Bool) {
        self.transport = transport
    }

    /// Sends a command to the tab's own session, or with `session` to a frame's (`frameSessions`). Whether the
    /// page answers (`onTimeout`, `onAnswer`) follows the tab's own session only.
    func send(
        _ method: String, _ params: [String: JSONValue] = [:], session: String? = nil, timeout: Duration = .seconds(30)
    ) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        var fields: [String: JSONValue] = ["id": .integer(id), "method": .string(method), "params": .object(params)]
        if let session { fields["sessionId"] = .string(session) }
        let message = String(decoding: try JSONEncoder().encode(JSONValue.object(fields)), as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = (method, session, continuation)
            guard transport(message) else {
                pending.removeValue(forKey: id)?.continuation.resume(throwing: BrowserDevToolsError.notSent(method))
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let request = self.pending.removeValue(forKey: id) else { return }
                if request.session == nil { self.onTimeout?(method) }
                request.continuation.resume(throwing: BrowserDevToolsError.timedOut(method))
            }
        }
    }

    /// Attaches the page's frames from other sites, now and as they come, each on a session of its own
    /// (`Target.setAutoAttach` with flattened sessions, as Puppeteer reaches them); each such frame attaches the
    /// frames it holds in turn. Only frames: no worker or other target.
    func attachFrames() async throws {
        attachesFrames = true
        _ = try await send("Target.setAutoAttach", Self.frameAutoAttach, timeout: .seconds(15))
    }

    private static let frameAutoAttach: [String: JSONValue] = [
        "autoAttach": .bool(true), "waitForDebuggerOnStart": .bool(false), "flatten": .bool(true),
        "filter": .array([.object(["type": .string("iframe"), "exclude": .bool(false)]), .object(["exclude": .bool(true)])])
    ]

    /// Waits for the next event with this method name; nil after the timeout.
    func nextEvent(_ method: String, timeout: Duration = .seconds(30)) async -> JSONValue? {
        let token = nextID
        nextID += 1
        return await withCheckedContinuation { continuation in
            eventWaiters.append((token, method, continuation))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let index = self.eventWaiters.firstIndex(where: { $0.token == token }) else { return }
                self.eventWaiters.remove(at: index).continuation.resume(returning: nil)
            }
        }
    }

    func receive(_ message: String) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(message.utf8)) else { return }
        if let id = value["id"]?.integerValue {
            guard let request = pending.removeValue(forKey: id) else { return }
            if request.session == nil { onAnswer?(request.method) }
            if let error = value["error"] {
                request.continuation.resume(throwing: BrowserDevToolsError.protocolError(request.method, error))
            } else {
                request.continuation.resume(returning: value["result"] ?? .null)
            }
        } else if let method = value["method"]?.stringValue {
            let params = value["params"] ?? .null
            let session = value["sessionId"]?.stringValue
            followFrameSessions(method, params, from: session)
            guard session == nil else { return }
            // A binding's payload is for its observer alone: the vault's carries what the person typed into a sign-in.
            if method != "Runtime.bindingCalled" { events.append((method, params)) }
            if method == "Page.frameNavigated", params["frame"]?["parentId"] == nil,
               let id = params["frame"]?["id"]?.stringValue { mainFrameID = id }
            eventObservers.values.forEach { $0(method, params) }
            let matching = eventWaiters.filter { $0.method == method }
            eventWaiters.removeAll { $0.method == method }
            matching.forEach { $0.continuation.resume(returning: params) }
        }
    }

    /// Keeps `frameSessions` as the browser attaches and detaches frames, and has each new one attach its own.
    private func followFrameSessions(_ method: String, _ params: JSONValue, from parent: String?) {
        switch method {
        case "Target.attachedToTarget":
            guard let id = params["sessionId"]?.stringValue, params["targetInfo"]?["type"]?.stringValue == "iframe",
                  let frame = params["targetInfo"]?["targetId"]?.stringValue else { return }
            frameSessions.removeAll { $0.id == id }
            frameSessions.append(BrowserFrameSession(id: id, frameID: frame, parent: parent))
            if attachesFrames {
                Task { [weak self] in _ = try? await self?.send("Target.setAutoAttach", Self.frameAutoAttach, session: id) }
            }
        case "Target.detachedFromTarget":
            guard let id = params["sessionId"]?.stringValue else { return }
            // A frame's own frames go with it.
            var gone: Set<String> = [id]
            while let next = frameSessions.first(where: { $0.parent.map(gone.contains) == true && !gone.contains($0.id) }) {
                gone.insert(next.id)
            }
            frameSessions.removeAll { gone.contains($0.id) }
        default:
            break
        }
    }

    /// A navigation of the main frame to another document that Chromium started and that has neither committed nor
    /// ended, read from a tab's event log: where its start is in the log, and its address. The browser logs the start
    /// when it takes the navigation (`Page.frameStartedNavigating`), before the page's beforeunload handlers run and the
    /// request goes out, then a commit (`Page.frameNavigated`) or an end without one (`Page.frameStoppedLoading`); a
    /// navigation that replaces it logs a start of its own. The main frame is `mainFrame`, else the frame its latest
    /// commit in the log names. Read from the end of the log, back to that commit at most.
    static func pendingNavigation(in log: [(method: String, params: JSONValue)], mainFrame: String?)
        -> (index: Int, url: String)? {
        guard let main = mainFrame ?? log.last(where: {
            $0.method == "Page.frameNavigated" && $0.params["frame"]?["parentId"] == nil
        })?.params["frame"]?["id"]?.stringValue else { return nil }
        for index in log.indices.reversed() {
            let event = log[index]
            switch event.method {
            case "Page.frameNavigated" where event.params["frame"]?["id"]?.stringValue == main,
                 "Page.frameStoppedLoading" where event.params["frameId"]?.stringValue == main:
                return nil
            case "Page.frameStartedNavigating" where event.params["frameId"]?.stringValue == main:
                // A move within the document commits in the renderer and waits for nothing.
                if ["sameDocument", "historySameDocument"].contains(event.params["navigationType"]?.stringValue) { continue }
                return (index, event.params["url"]?.stringValue ?? "")
            default:
                continue
            }
        }
        return nil
    }

    func failPending() {
        let waiting = pending
        pending = [:]
        frameSessions = []
        waiting.values.forEach { $0.continuation.resume(throwing: BrowserDevToolsError.closed) }
    }
}
