import Foundation

/// A thread of a dot's room as the provider's room-live observer reports it. Only the fields the
/// provider's own client reads are kept; the rest of each record is not looked at.
struct PersonalAgentLiveThread: Equatable, Sendable {
    enum StreamState: String, Sendable { case attaching, attached }
    enum TurnStatus: String, Sendable { case inProgress = "in_progress", completed, failed, interrupted }
    enum ComputerStatus: String, Sendable { case usingComputer = "using_computer", stoppedUsingComputer = "stopped_using_computer" }

    let threadID: String
    let streamState: StreamState
    let turnID: String?
    let turnStatus: TurnStatus?
    let isActive: Bool?
    var computerStatus: ComputerStatus?
    /// The provider's activity, as its `status_type` and `status_label` name it; nil when it gives none.
    let activityType: String?
    let activityLabel: String?

    var isInProgressTurn: Bool { turnID != nil && turnStatus == .inProgress }
}

/// One state of a dot's room, bound to the observer that registered for it.
struct PersonalAgentLiveState: Equatable, Sendable {
    let roomID: String
    let subscriptionID: String
    let revision: Int64
    var threads: [PersonalAgentLiveThread]
}

/// What a room observer tells its window: the state to show (nil for none), or that the login it
/// was reading with is gone, which ends every reading of the account, as any read's would.
enum PersonalAgentLiveUpdate: Equatable, Sendable {
    case state(PersonalAgentLiveState?)
    case failed(PersonalAgentFailure)
}

/// What the room's topic carries: a state, or the end of the observation.
enum PersonalAgentLiveEvent: Equatable, Sendable {
    case state(PersonalAgentLiveState)
    case unavailable(roomID: String, subscriptionID: String, revision: Int64, temporarily: Bool)

    var roomID: String {
        switch self {
        case let .state(state): state.roomID
        case let .unavailable(room, _, _, _): room
        }
    }

    var subscriptionID: String {
        switch self {
        case let .state(state): state.subscriptionID
        case let .unavailable(_, subscription, _, _): subscription
        }
    }

    var revision: Int64 {
        switch self {
        case let .state(state): state.revision
        case let .unavailable(_, _, revision, _): revision
        }
    }
}

/// The room-live wire format, as the provider's client validates it. Anything outside it is not
/// guessed at: the caller ends the observation.
enum DotsLiveProtocol {
    static let readyType = "calpico-room-live-ready"
    static let envelopeType = "calpico-room-live"

    static func topic(for roomID: String) -> String { "calpico-room-live:" + roomID }

    /// The stream's one event: which subscription the server registered for which room.
    static func ready(_ value: JSONValue) -> (roomID: String, subscriptionID: String)? {
        guard value["type"]?.stringValue == readyType, isVersionOne(value["version"]),
              let room = value["room_id"]?.stringValue, let subscription = value["subscription_id"]?.stringValue
        else { return nil }
        return (room, subscription)
    }

    /// A message on the room's topic: `{type: "calpico-room-live", payload: state | error}`.
    static func event(_ value: JSONValue) -> PersonalAgentLiveEvent? {
        guard value["type"]?.stringValue == envelopeType, let payload = value["payload"],
              isVersionOne(payload["version"]), let room = payload["room_id"]?.stringValue,
              let subscription = payload["subscription_id"]?.stringValue,
              let revision = revision(payload["revision"]) else { return nil }
        switch payload["type"]?.stringValue {
        case "calpico-room-live-state":
            guard case let .array(items)? = payload["threads"] else { return nil }
            var threads: [PersonalAgentLiveThread] = []
            for item in items {
                guard let thread = thread(item) else { return nil }
                threads.append(thread)
            }
            return .state(.init(roomID: room, subscriptionID: subscription, revision: revision, threads: threads))
        case "calpico-room-live-error":
            switch payload["code"]?.stringValue {
            case "room_unavailable": return .unavailable(roomID: room, subscriptionID: subscription, revision: revision, temporarily: false)
            case "temporarily_unavailable": return .unavailable(roomID: room, subscriptionID: subscription, revision: revision, temporarily: true)
            default: return nil
            }
        default:
            return nil
        }
    }

    private static func thread(_ value: JSONValue) -> PersonalAgentLiveThread? {
        guard case .object = value, let id = value["thread_id"]?.stringValue,
              let stream = value["stream_state"]?.stringValue.flatMap(PersonalAgentLiveThread.StreamState.init(rawValue:))
        else { return nil }
        // Each optional field is absent, null where the provider allows it, or exactly its type.
        guard let turnID = nullable(value["turn_id"], { $0.stringValue }),
              let turnStatus = nullable(value["turn_status"], { $0.stringValue.flatMap(PersonalAgentLiveThread.TurnStatus.init(rawValue:)) }),
              let isActive = nullable(value["is_active"], { if case let .bool(flag) = $0 { flag } else { nil } }),
              nullable(value["summary_item_id"], { $0.stringValue }) != nil else { return nil }
        if let summary = value["summary"] {
            guard case let .array(lines) = summary, lines.allSatisfy({ $0.stringValue != nil }) else { return nil }
        }
        var computer: PersonalAgentLiveThread.ComputerStatus?
        if let raw = value["computer_status"] {
            guard let status = raw.stringValue.flatMap(PersonalAgentLiveThread.ComputerStatus.init(rawValue:)) else { return nil }
            computer = status
        }
        var activity: (String, String)?
        if let raw = value["activity_status"], raw != .null {
            guard let type = raw["status_type"]?.stringValue, let label = raw["status_label"]?.stringValue else { return nil }
            activity = (type, label)
        }
        return .init(threadID: id, streamState: stream, turnID: turnID ?? nil, turnStatus: turnStatus ?? nil,
                     isActive: isActive ?? nil, computerStatus: computer, activityType: activity?.0, activityLabel: activity?.1)
    }

    /// `.some(nil)` for an absent or null field, `.some(value)` for one of the right type, nil otherwise.
    private static func nullable<T>(_ value: JSONValue?, _ read: (JSONValue) -> T?) -> T?? {
        guard let value, value != .null else { return .some(nil) }
        guard let read = read(value) else { return nil }
        return .some(read)
    }

    private static func isVersionOne(_ value: JSONValue?) -> Bool {
        value == .integer(1) || value == .number(1)
    }

    private static func revision(_ value: JSONValue?) -> Int64? {
        switch value {
        case let .integer(number)? where number >= 0: number
        case let .number(number)? where number >= 0 && number.rounded() == number && number < 9.2e18: Int64(number)
        default: nil
        }
    }
}

/// One attempt of the room-live observer: the subscription the stream bound, the revisions taken,
/// and the newest event of each subscription seen before the stream named its own. It holds no
/// timer; the transport keeps those and asks it what each event means.
struct PersonalAgentLiveObservation {
    enum Outcome: Equatable {
        /// Nothing to show: an event for another subscription, an older revision, or one held for later.
        case ignored
        /// The observation ends; `retry` when the provider's client would register again.
        case ended(retry: Bool)
        /// The state to show, with whether a computer indication starts (or restarts) its hold.
        case shown(PersonalAgentLiveState, holdsComputer: Bool)
    }

    static let heldSubscriptions = 4

    let roomID: String
    private(set) var subscriptionID: String?
    private var revision: Int64 = -1
    private var held: [PersonalAgentLiveEvent] = []
    /// The last state taken, before the computer indication is applied to it.
    private var latest: PersonalAgentLiveState?
    private(set) var isHoldingComputer = false

    init(roomID: String) { self.roomID = roomID }

    /// The stream's event. A ready that names another room, or a second subscription, ends it.
    mutating func ready(_ value: JSONValue) -> Outcome {
        guard let ready = DotsLiveProtocol.ready(value), ready.roomID == roomID,
              subscriptionID == nil || subscriptionID == ready.subscriptionID else { return .ended(retry: false) }
        subscriptionID = ready.subscriptionID
        let pending = held.first { $0.subscriptionID == ready.subscriptionID }
        held = []
        guard let pending else { return .ignored }
        return take(pending)
    }

    /// A message on the room's topic.
    mutating func receive(_ value: JSONValue) -> Outcome {
        guard var event = DotsLiveProtocol.event(value), event.roomID == roomID else { return .ended(retry: false) }
        if subscriptionID != nil { return take(event) }
        let previous = held.firstIndex { $0.subscriptionID == event.subscriptionID }
        if let previous {
            if event.revision <= held[previous].revision { return .ignored }
            // A held state's computer indication carries over to the same turn's next state that omits it.
            if case var .state(next) = event, case let .state(old) = held[previous],
               let first = next.threads.first, first.isInProgressTurn, first.computerStatus == nil,
               let before = old.threads.first, before.computerStatus != nil,
               first.threadID == before.threadID, first.turnID == before.turnID {
                next.threads[0].computerStatus = before.computerStatus
                event = .state(next)
            }
            held.remove(at: previous)
        }
        held.append(event)
        if held.count > Self.heldSubscriptions { held.removeFirst() }
        return .ignored
    }

    /// The hold on a using-computer indication ran out: the same state without it.
    mutating func computerHoldEnded() -> PersonalAgentLiveState? {
        isHoldingComputer = false
        return latest.map(presented)
    }

    private mutating func take(_ event: PersonalAgentLiveEvent) -> Outcome {
        guard event.subscriptionID == subscriptionID, event.revision > revision else { return .ignored }
        revision = event.revision
        switch event {
        case let .unavailable(_, _, _, temporarily):
            return .ended(retry: temporarily)
        case let .state(state):
            let before = latest?.threads.first
            latest = state
            let first = state.threads.first
            let inProgress = first?.isInProgressTurn == true
            // A changed thread or turn, one no longer in progress, or a state that names its own
            // computer status ends the hold; an in-progress turn using the computer starts a new one.
            if !inProgress || first?.threadID != before?.threadID || first?.turnID != before?.turnID
                || first?.computerStatus != nil {
                isHoldingComputer = false
            }
            let holds = inProgress && first?.computerStatus == .usingComputer
            if holds { isHoldingComputer = true }
            return .shown(presented(state), holdsComputer: holds)
        }
    }

    /// The state as shown: the first thread uses the computer only while the hold lasts, and keeps an
    /// explicit stop.
    private func presented(_ state: PersonalAgentLiveState) -> PersonalAgentLiveState {
        guard let first = state.threads.first else { return state }
        var shown = state
        if isHoldingComputer { shown.threads[0].computerStatus = .usingComputer }
        else if first.computerStatus != .stoppedUsingComputer { shown.threads[0].computerStatus = nil }
        return shown
    }
}

/// What a dot is doing, as the provider's app works it out from its room's bound state. Without an
/// attached state it is doing nothing that can be shown: never presumed at work.
struct PersonalAgentStatus: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case none, working, searching, creating, payment, thinking, needsInput, ready, paused, error
    }

    let kind: Kind
    /// The provider's own words for the work under way, shown while its turn is active.
    let heading: String?
    let isActive: Bool

    static let idle = PersonalAgentStatus(kind: .none, heading: nil, isActive: false)

    /// The pet's motion: its working row while the dot works, searches, creates, pays or thinks.
    var motion: PersonalAgentSpriteLayout.Motion {
        switch kind {
        case .working, .searching, .creating, .payment, .thinking: .working
        case .none, .needsInput, .ready, .paused, .error: .idle
        }
    }

    init(kind: Kind, heading: String?, isActive: Bool) {
        self.kind = kind
        self.heading = heading
        self.isActive = isActive
    }

    /// Where the dot's thread runs, as its host names it. Yardlet reads no host for a dot, so it is
    /// unknown (nil), as it is to the provider's app before the host answers, and that app then takes
    /// the room's state; a local thread would not.
    enum ExecutionMode: Equatable, Sendable { case local, durable }

    /// The provider's app also reads the thread's runtime from its host (waiting on input, asleep);
    /// Yardlet reads none, so only what the room says is used. `isPaused` is the profile as last
    /// read: it stands unless the room has since shown a turn under way, which it cannot have paused.
    init(live: PersonalAgentLiveState?, isPaused: Bool, mode: ExecutionMode? = nil) {
        let paused = PersonalAgentStatus(kind: .paused, heading: nil, isActive: false)
        guard mode != .local, let thread = live?.threads.first, thread.streamState == .attached else {
            self = isPaused ? paused : .idle
            return
        }
        let active = thread.isActive == true
        let heading = active ? thread.activityLabel.flatMap(Self.heading) : nil
        if isPaused, !active, !thread.isInProgressTurn { self = paused; return }
        let activity = thread.activityType?.lowercased()
        let kind: Kind
        if thread.turnStatus == .failed { kind = .error }
        else if activity == "ready" || (thread.turnStatus != .inProgress && !active) { kind = .ready }
        else {
            switch activity {
            case "working": kind = .working
            case "searching": kind = .searching
            case "creating": kind = .creating
            case "payment": kind = .payment
            case "needs input": kind = .needsInput
            case "paused": kind = .paused
            default: kind = .thinking
            }
        }
        self.init(kind: kind, heading: heading, isActive: active)
    }

    /// What the conversation's header says of it: the provider's words, or the kind's own, while the
    /// turn is active; Paused for a paused dot.
    var label: String? {
        if isActive {
            if let heading { return heading }
            switch kind {
            case .working: return L10n.string("Working")
            case .searching: return L10n.string("Searching")
            case .creating: return L10n.string("Creating")
            case .payment: return L10n.string("Making a payment")
            case .thinking: return L10n.string("Thinking")
            case .needsInput: return L10n.string("Needs input")
            case .paused: return L10n.string("Paused")
            case .none, .ready, .error: return nil
            }
        }
        return kind == .paused ? L10n.string("Paused") : nil
    }

    /// The label's last line with words, as plain text: a trailing comment or a line of emphasis
    /// markers alone is not one.
    static func heading(_ label: String) -> String? {
        for raw in label.split(whereSeparator: \.isNewline).reversed() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("<!--") else { continue }
            while let mark = line.first, mark == "#" { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            // Emphasis and code marks are dropped; a single `*` or `_` is left, as it may be a word's own.
            for mark in ["**", "__", "`"] { line = line.replacingOccurrences(of: mark, with: "") }
            for wrap in ["*", "_"] where line.count > 2 && line.hasPrefix(wrap) && line.hasSuffix(wrap) {
                line = String(line.dropFirst().dropLast())
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty, line.contains(where: { $0.isLetter || $0.isNumber }) { return String(line.prefix(160)) }
        }
        return nil
    }
}
