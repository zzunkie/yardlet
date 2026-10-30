import Foundation

/// The room-live observer's times, as the provider's client keeps them. Tests shorten them.
struct DotsLiveTiming: Sendable {
    /// How long an attempt waits for its first state before it registers again.
    var watchdog: Duration = .seconds(30)
    var firstRetry: Duration = .seconds(1)
    var longestRetry: Duration = .seconds(30)
    /// How long a using-computer indication lasts without being said again.
    var computerHold: Duration = .seconds(120)
    /// How long a refused topic subscription waits before it is asked again.
    var resubscribe: Duration = .seconds(5)
}

/// The user's event socket, which the provider's events and Yardlet's commands pass on. A protocol so
/// tests can stand in for the provider's.
protocol DotsEventSocket: AnyObject, Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: DotsEventSocket {}

/// The observer of one dot's room. It registers only to read: its request carries no body, and
/// nothing it does sends, resumes or pauses work. Only the `DotsService` actor touches it.
final class DotsRoomLive {
    let id = UUID()
    let agent: PersonalAgent
    let output: AsyncStream<PersonalAgentLiveUpdate>.Continuation
    var topic: String { DotsLiveProtocol.topic(for: agent.id.roomID) }
    /// A malformed or refused observation stays ended until the window asks for a new one.
    var ended = false
    /// The current attempt; anything that finishes for an earlier one is dropped.
    var attempt = 0
    var observation: PersonalAgentLiveObservation?
    var retryDelay: Duration
    var wantsTopic = false
    var subscribeCommand: Int64?
    var subscribed = false
    var stream: Task<Void, Never>?
    var watchdog: Task<Void, Never>?
    var retry: Task<Void, Never>?
    var computerHold: Task<Void, Never>?
    var resubscribe: Task<Void, Never>?
    var hasShown = false
    var shown: PersonalAgentLiveState?

    init(agent: PersonalAgent, output: AsyncStream<PersonalAgentLiveUpdate>.Continuation, retryDelay: Duration) {
        self.agent = agent
        self.output = output
        self.retryDelay = retryDelay
    }
}

extension DotsService {
    /// The selected dot's room as it is now: each bound state, or nil when there is none to show. Only
    /// one room is observed at a time; asking for another ends the first. The stream's end ends the
    /// observation, its registration and its topic subscription.
    func liveState(for agent: PersonalAgent) async -> AsyncStream<PersonalAgentLiveUpdate> {
        stopLive()
        let pair = AsyncStream<PersonalAgentLiveUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard !stopped else { pair.continuation.finish(); return pair.stream }
        let observer = DotsRoomLive(agent: agent, output: pair.continuation, retryDelay: liveTiming.firstRetry)
        live = observer
        let id = observer.id
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.stopLive(ifCurrent: id) } }
        beginLiveAttempt()
        return pair.stream
    }

    func stopLive(ifCurrent id: UUID? = nil) {
        guard let observer = live, id == nil || observer.id == id else { return }
        endLiveAttempt(observer)
        observer.ended = true
        live = nil
        observer.output.finish()
    }

    // MARK: The event socket

    func liveSocketOpened(_ socket: any DotsEventSocket) {
        openSocket = socket
        subscribeLiveTopic()
    }

    /// The socket the topic was on closed: the attempt registers again, after its wait.
    func liveSocketClosed(_ socket: any DotsEventSocket) {
        guard openSocket === socket else { return }
        openSocket = nil
        guard let observer = live, observer.wantsTopic else { return }
        observer.subscribed = false
        observer.subscribeCommand = nil
        retryLive(observer, retry: true)
    }

    /// A reply to one of the observer's commands: the subscription reply names its topic.
    func liveReply(_ command: JSONValue, _ reply: JSONValue) {
        guard let observer = live, let pending = observer.subscribeCommand, command == .integer(pending) else { return }
        observer.subscribeCommand = nil
        guard observer.wantsTopic else { return }
        let recovered: Bool = if case .bool = reply["recovered"] { true } else { false }
        guard reply["type"]?.stringValue == "subscribe", reply["topic_id"]?.stringValue == observer.topic, recovered else {
            let (id, attempt) = (observer.id, observer.attempt)
            observer.resubscribe?.cancel()
            observer.resubscribe = liveTimer(liveTiming.resubscribe) { await $0.resubscribeLive(id: id, attempt: attempt) }
            return
        }
        observer.subscribed = true
        startLiveStream(observer)
    }

    /// A message on a topic other than the messaging one: the room's state, when it is the observed room's.
    func liveMessage(topic: String, payload: JSONValue?) {
        guard let observer = live, topic == observer.topic, observer.wantsTopic, var observation = observer.observation
        else { return }
        let outcome = observation.receive(payload ?? .null)
        observer.observation = observation
        apply(outcome, to: observer)
    }

    // MARK: Attempts

    private func beginLiveAttempt() {
        guard let observer = live, !observer.ended, !stopped else { return }
        observer.attempt += 1
        let (id, attempt) = (observer.id, observer.attempt)
        observer.observation = PersonalAgentLiveObservation(roomID: observer.agent.id.roomID)
        observer.watchdog = liveTimer(liveTiming.watchdog) { await $0.liveWatchdogFired(id: id, attempt: attempt) }
        observer.wantsTopic = true
        subscribeLiveTopic()
    }

    private func subscribeLiveTopic() {
        guard let observer = live, observer.wantsTopic, !observer.subscribed, observer.subscribeCommand == nil,
              openSocket != nil else { return }
        observer.subscribeCommand = sendLiveCommand(["type": .string("subscribe"), "topic_id": .string(observer.topic)])
    }

    private func isCurrent(_ id: UUID, _ attempt: Int) -> DotsRoomLive? {
        guard let observer = live, observer.id == id, observer.attempt == attempt, !observer.ended, !stopped else { return nil }
        return observer
    }

    private func liveWatchdogFired(id: UUID, attempt: Int) {
        guard let observer = isCurrent(id, attempt) else { return }
        retryLive(observer, retry: true)
    }

    private func resubscribeLive(id: UUID, attempt: Int) {
        guard isCurrent(id, attempt) != nil else { return }
        subscribeLiveTopic()
    }

    private func computerHoldEnded(id: UUID, attempt: Int) {
        guard let observer = isCurrent(id, attempt), var observation = observer.observation else { return }
        observer.computerHold = nil
        let state = observation.computerHoldEnded()
        observer.observation = observation
        if let state { show(state, in: observer) }
    }

    private func apply(_ outcome: PersonalAgentLiveObservation.Outcome, to observer: DotsRoomLive) {
        switch outcome {
        case .ignored:
            return
        case let .ended(retry):
            retryLive(observer, retry: retry)
        case let .shown(state, holds):
            observer.watchdog?.cancel()
            observer.watchdog = nil
            if state.threads.contains(where: { $0.streamState == .attached }) { observer.retryDelay = liveTiming.firstRetry }
            if holds {
                let (id, attempt) = (observer.id, observer.attempt)
                observer.computerHold?.cancel()
                observer.computerHold = liveTimer(liveTiming.computerHold) { await $0.computerHoldEnded(id: id, attempt: attempt) }
            } else if observer.observation?.isHoldingComputer != true {
                observer.computerHold?.cancel()
                observer.computerHold = nil
            }
            show(state, in: observer)
        }
    }

    /// Ends the attempt; one that can be retried registers again after its wait, which doubles each
    /// time up to its longest.
    private func retryLive(_ observer: DotsRoomLive, retry: Bool) {
        endLiveAttempt(observer)
        guard retry else { observer.ended = true; return }
        let delay = observer.retryDelay
        observer.retryDelay = min(delay * 2, liveTiming.longestRetry)
        let id = observer.id
        observer.retry = liveTimer(delay) { await $0.retryFired(id: id) }
    }

    private func retryFired(id: UUID) {
        guard let observer = live, observer.id == id, !observer.ended else { return }
        observer.retry = nil
        beginLiveAttempt()
    }

    /// Cancels the stream, leaves the topic, stops the timers and clears what is shown.
    private func endLiveAttempt(_ observer: DotsRoomLive) {
        observer.attempt += 1
        observer.stream?.cancel()
        observer.stream = nil
        if observer.subscribed || observer.subscribeCommand != nil {
            _ = sendLiveCommand(["type": .string("unsubscribe"), "topic_id": .string(observer.topic)])
        }
        observer.wantsTopic = false
        observer.subscribed = false
        observer.subscribeCommand = nil
        for timer in [observer.watchdog, observer.retry, observer.computerHold, observer.resubscribe] { timer?.cancel() }
        (observer.watchdog, observer.retry, observer.computerHold, observer.resubscribe) = (nil, nil, nil, nil)
        observer.observation = nil
        show(nil, in: observer)
    }

    private func show(_ state: PersonalAgentLiveState?, in observer: DotsRoomLive) {
        guard !observer.hasShown || observer.shown != state else { return }
        observer.hasShown = true
        observer.shown = state
        observer.output.yield(.state(state))
    }

    private func sendLiveCommand(_ command: [String: JSONValue]) -> Int64? {
        guard let socket = openSocket else { return nil }
        let id = nextCommand
        nextCommand += 1
        let frame: JSONValue = .array([.object(["id": .integer(id), "command": .object(command)])])
        guard let data = try? JSONEncoder().encode(frame) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        Task { try? await socket.send(.string(text)) }
        return id
    }

    private func liveTimer(_ delay: Duration, _ action: @escaping @Sendable (DotsService) async -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await action(self)
        }
    }

    // MARK: The stream

    private func startLiveStream(_ observer: DotsRoomLive) {
        guard observer.stream == nil else { return }
        let (id, attempt) = (observer.id, observer.attempt)
        observer.stream = Task { [weak self] in await self?.runLiveStream(id: id, attempt: attempt) }
    }

    /// Statuses the provider's client registers again after: none at all, a timeout, too many requests
    /// and server errors.
    static func retriesLive(status: Int?) -> Bool {
        guard let status else { return true }
        return status == 408 || status == 429 || status >= 500
    }

    private func runLiveStream(id: UUID, attempt: Int) async {
        guard let observer = isCurrent(id, attempt) else { return }
        let agent = observer.agent
        do {
            let auth = try await credentials()
            guard auth.identity.account == agent.id.accountID, auth.identity.user == agent.id.userID else {
                throw PersonalAgentFailure.accountChanged
            }
            guard isCurrent(id, attempt) != nil else { return }
            var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/messaging/rooms/"
                                              + component(agent.id.roomID) + "/live")!)
            request.httpMethod = "POST"
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Yardlet/PersonalAgents", forHTTPHeaderField: "User-Agent")
            request.setValue("Bearer " + auth.token, forHTTPHeaderField: "Authorization")
            request.setValue(auth.identity.account, forHTTPHeaderField: "ChatGPT-Account-Id")
            let (bytes, response) = try await streamSession.bytes(for: request)
            guard isCurrent(id, attempt) != nil else { return }
            guard let http = response as? HTTPURLResponse else { return finishLive(id, attempt, retry: true) }
            guard (200...299).contains(http.statusCode) else {
                return finishLive(id, attempt, retry: Self.retriesLive(status: http.statusCode))
            }
            guard http.mimeType == "text/event-stream" else { return finishLive(id, attempt, retry: false) }
            // A stream that outlives an account switch must never show the old room.
            let current = try await credentials()
            guard current.identity == auth.identity, isCurrent(id, attempt) != nil else {
                throw PersonalAgentFailure.accountChanged
            }
            var events = DotsServerSentEvents()
            for try await byte in bytes {
                guard let event = try events.feed(byte) else { continue }
                guard let observer = isCurrent(id, attempt), var observation = observer.observation else { return }
                if event.name == "ping" { continue }
                if event.data == "[DONE]" { return finishLive(id, attempt, retry: true) }
                guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(event.data.utf8)) else {
                    return finishLive(id, attempt, retry: false)
                }
                // An error event carries the stream's own successful status, which is not retried.
                if Self.isError(value["error"]) { return finishLive(id, attempt, retry: Self.retriesLive(status: http.statusCode)) }
                let outcome = observation.ready(value)
                observer.observation = observation
                apply(outcome, to: observer)
            }
            // The stream ended without saying it was done.
            finishLive(id, attempt, retry: true)
        } catch let failure as PersonalAgentFailure {
            // A changed login or a lost sign-in ends the window's reading of the account; neither, nor
            // a stopped runtime, is this observer's to retry.
            if failure == .accountChanged || failure == .signInRequired, let observer = isCurrent(id, attempt) {
                // The attempt is cleared first, so the failure is the stream's last word and nothing follows it.
                observer.stream = nil
                endLiveAttempt(observer)
                observer.ended = true
                observer.output.yield(.failed(failure))
                observer.output.finish()
                return
            }
            finishLive(id, attempt, retry: failure == .network || failure == .unavailable)
        } catch {
            finishLive(id, attempt, retry: true)
        }
    }

    private func finishLive(_ id: UUID, _ attempt: Int, retry: Bool) {
        guard let observer = isCurrent(id, attempt) else { return }
        observer.stream = nil
        retryLive(observer, retry: retry)
    }

    private static func isError(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null?, .bool(false)?, .string("")?, .integer(0)?, .number(0)?: false
        default: true
        }
    }
}

/// Server-sent events from a stream of bytes: each blank line ends an event of its `event` name and
/// `data` lines. A line longer than any room-live event is refused.
struct DotsServerSentEvents {
    struct Event: Equatable {
        var name: String?
        var data: String
    }

    static let lineLimit = 256 * 1024
    private var line = Data()
    private var name: String?
    private var data: [String] = []

    mutating func feed(_ byte: UInt8) throws -> Event? {
        guard byte == 0x0A else {
            guard line.count < Self.lineLimit else { throw PersonalAgentFailure.invalidResponse }
            line.append(byte)
            return nil
        }
        var text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if text.hasSuffix("\r") { text.removeLast() }
        if text.isEmpty {
            defer { name = nil; data = [] }
            return data.isEmpty && name == nil ? nil : Event(name: name, data: data.joined(separator: "\n"))
        }
        if text.hasPrefix(":") { return nil }
        let field: Substring, value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            let rest = text[text.index(after: colon)...]
            value = rest.hasPrefix(" ") ? rest.dropFirst() : rest
        } else {
            (field, value) = (text[...], "")
        }
        switch field {
        case "event": name = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }
}
