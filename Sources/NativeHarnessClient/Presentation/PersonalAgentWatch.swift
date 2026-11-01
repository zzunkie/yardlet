import Foundation
import Observation

/// Settings › Notifications › "Personal agent messages", on by default, and the account it follows.
enum PersonalAgentNotificationPreference {
    static let key = "Yardlet.personalAgentNotifications"
    /// The account choice whose dots a window last opened. Kept only while the setting is on.
    static let accountKey = "Yardlet.personalAgentsAccount"

    static func isOn(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

/// What a dot's messages not yet seen in Yardlet ask of the person.
enum PersonalAgentUnread: Int, Comparable, Sendable {
    case message, request
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A notification to post for a dot: its newest message of a burst, or a request it asks.
struct PersonalAgentAnnouncement: Equatable, Sendable {
    let agent: PersonalAgent
    let accountChoiceID: String
    let preview: String
    let isRequest: Bool

    /// One identifier per dot and kind, so a later burst replaces the earlier notification.
    var identifier: String { Self.identifier(roomID: agent.id.roomID, isRequest: isRequest) }

    static func identifier(roomID: String, isRequest: Bool) -> String {
        "yardlet-dot-\(roomID)" + (isRequest ? "-request" : "")
    }
}

/// The app's one watch on the dots of the account the person last opened them with, while Yardlet
/// runs and the setting is on. It rides the same messaging topic a window's conversation does, on a
/// reader of its own, and reads only the newest page of a room the topic says changed. A message from
/// the dot that is newer than any read before marks the dot unread and is announced, unless a window
/// shows that dot's conversation. Unread is local: nothing is marked read at the provider.
@MainActor @Observable
final class PersonalAgentWatch {
    struct Source: Equatable {
        /// The account choice, its home and the runtime: another one is another watch.
        let key: String
        let accountChoiceID: String
    }

    /// Dots with a message not yet seen here, and whether one asks for the person's input.
    private(set) var unread: [PersonalAgentIdentity: PersonalAgentUnread] = [:]
    /// Whether any dot is unread; the sidebar's switch reads only this.
    private(set) var hasUnread = false

    @ObservationIgnored private(set) var source: Source?
    @ObservationIgnored private var makeClient: (() -> any PersonalAgentClient)?
    @ObservationIgnored private var client: (any PersonalAgentClient)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The dots watched, by room.
    @ObservationIgnored private var agents: [String: PersonalAgent] = [:]
    @ObservationIgnored private var rooms: [String: Room] = [:]
    /// The dot each window shows, by the window's center.
    @ObservationIgnored private var shown: [ObjectIdentifier: PersonalAgentIdentity] = [:]
    @ObservationIgnored private var pending: [String: Pending] = [:]
    /// How long a burst of messages from one dot is gathered into one notification.
    @ObservationIgnored var coalescing: Duration = .seconds(2)
    /// Whether Yardlet is the active app, so a window showing the dot is in front of the person.
    @ObservationIgnored var isActive: @MainActor () -> Bool = { false }
    @ObservationIgnored var announce: @MainActor (PersonalAgentAnnouncement) async -> Void = { _ in }
    /// Withdraws a dot's delivered notifications once its conversation is shown.
    @ObservationIgnored var withdraw: @MainActor (PersonalAgentIdentity) -> Void = { _ in }
#if DEBUG
    /// Rooms read since the watch started, for checks that only the changed room is read.
    @ObservationIgnored private(set) var roomReads = 0
#endif

    private struct Room {
        /// The messages of the last page read; with `newest`, what a later read is new against.
        var seen: Set<String> = []
        var newest: Date?
        var isBaselined = false
        var isReading = false
        var readsAgain = false
    }

    private struct Pending {
        var announcement: PersonalAgentAnnouncement
        let task: Task<Void, Never>
    }

    /// Whether the watch is connected to a source now; one that ended stays ended until asked again.
    var isRunning: Bool { task != nil }

    /// The watch's own reader and the account choice it follows, while it runs, for the session tools'
    /// reads of the dots: the same login and runtime, no second credential path. Callers only read
    /// through it; when the watch stops or moves, the reader stops and their reads end with it.
    var reading: (reader: any PersonalAgentClient, accountChoiceID: String)? {
        guard task != nil, let client, let source else { return nil }
        return (client, source.accountChoiceID)
    }

    /// Follows `source`: another one replaces the watch. The same source carries on, and one whose
    /// login ended stays ended until `restart`.
    func follow(_ source: Source, makeClient: @escaping () -> any PersonalAgentClient) {
        guard source != self.source else { return }
        stop()
        self.source = source
        self.makeClient = makeClient
        start()
    }

    /// Starts the current source again after its login ended, as when a window reconnected.
    func restart() {
        guard source != nil, task == nil else { return }
        start()
    }

    func stop() {
        end()
        source = nil
        makeClient = nil
        if !unread.isEmpty { unread = [:] }
        if hasUnread { hasUnread = false }
    }

    /// A window shows `identity`'s conversation, or no dot (nil): a shown dot is read and not announced.
    func setShown(_ identity: PersonalAgentIdentity?, by reporter: ObjectIdentifier) {
        guard shown[reporter] != identity else { return }
        shown[reporter] = identity
        guard let identity else { return }
        for isRequest in [false, true] {
            pending.removeValue(forKey: PersonalAgentAnnouncement.identifier(roomID: identity.roomID, isRequest: isRequest))?
                .task.cancel()
        }
        if unread.removeValue(forKey: identity) != nil { updateHasUnread() }
        withdraw(identity)
    }

    private func isShown(_ identity: PersonalAgentIdentity) -> Bool { shown.values.contains(identity) }

    private func start() {
        guard let makeClient else { return }
        generation += 1
        let current = generation
        let reader = makeClient()
        client = reader
        task = Task { [weak self] in await self?.run(reader, generation: current) }
    }

    /// Ends the connection and forgets what was read. A login that ended takes what is unread with it.
    private func end(clearing: Bool = false) {
        generation += 1
        task?.cancel()
        task = nil
        pending.values.forEach { $0.task.cancel() }
        pending = [:]
        agents = [:]
        rooms = [:]
        if let old = client { Task { await old.stop() } }
        client = nil
        if clearing, !unread.isEmpty { unread = [:]; updateHasUnread() }
    }

    private static func endsTheWatch(_ error: Error) -> Bool {
        switch error as? PersonalAgentFailure {
        case .network?, .unavailable?: false
        default: true
        }
    }

    private func run(_ reader: any PersonalAgentClient, generation current: Int) async {
        var values: [PersonalAgent] = []
        var delay = 2
        while true {
            do { values = try await reader.agents(); break } catch {
                guard current == generation, !Task.isCancelled else { return }
                // A connection that cannot be made now is tried again after a wait that doubles up to
                // a minute; a login that ended, or a runtime that cannot start, ends the watch.
                guard !Self.endsTheWatch(error) else { return end(clearing: true) }
                try? await Task.sleep(for: .seconds(delay))
                guard current == generation, !Task.isCancelled else { return }
                delay = min(60, delay * 2)
            }
        }
        // No dots, nothing to watch: the reader and its runtime stop.
        guard current == generation, !values.isEmpty else { return current == generation ? end() : () }
        agents = Dictionary(values.map { ($0.id.roomID, $0) }, uniquingKeysWith: { first, _ in first })
        let stream = await reader.roomUpdates(for: values)
        // Each room's newest page is what later messages are new against; nothing is announced for it.
        for room in agents.keys.sorted() {
            await read(room, from: reader, generation: current)
            guard current == generation else { return }
        }
        var connections = 0
        for await update in stream {
            guard current == generation, !Task.isCancelled else { return }
            switch update {
            case .connected:
                connections += 1
                // Reconnected: what changed meanwhile is unknown, so every room is read once.
                if connections > 1 { for room in agents.keys.sorted() { schedule(room, from: reader, generation: current) } }
            case let .changed(room):
                schedule(room, from: reader, generation: current)
            case .reconnecting:
                break
            case .failed:
                // The reader stops for good on these (a changed or ended login, a refused or invalid
                // answer); it does not try again by itself.
                return end(clearing: true)
            }
        }
        if current == generation { end() }
    }

    private func schedule(_ room: String, from reader: any PersonalAgentClient, generation current: Int) {
        guard agents[room] != nil, var state = rooms[room] else { return }
        if state.isReading {
            if !state.readsAgain { state.readsAgain = true; rooms[room] = state }
            return
        }
        Task { [weak self] in await self?.read(room, from: reader, generation: current) }
    }

    /// Reads the room's newest page, then again once if it changed meanwhile.
    private func read(_ room: String, from reader: any PersonalAgentClient, generation current: Int) async {
        guard let agent = agents[room] else { return }
        rooms[room, default: Room()].isReading = true
#if DEBUG
        roomReads += 1
#endif
        do {
            let page = try await reader.messages(for: agent, before: nil)
            guard current == generation else { return }
            note(page.messages, of: agent)
        } catch {
            guard current == generation else { return }
            let failure = error as? PersonalAgentFailure
            if failure == .accountChanged || failure == .signInRequired { return end(clearing: true) }
        }
        guard current == generation, var state = rooms[room] else { return }
        state.isReading = false
        let again = state.readsAgain
        state.readsAgain = false
        rooms[room] = state
        if again { await read(room, from: reader, generation: current) }
    }

    private func note(_ messages: [PersonalAgentMessage], of agent: PersonalAgent) {
        let room = agent.id.roomID
        var state = rooms[room] ?? Room()
        let fresh = state.isBaselined ? messages.filter { message in
            guard message.author == .agent, !message.isDeleted, !state.seen.contains(message.id) else { return false }
            // A message older than one already read only came into the page; it is not new.
            guard let newest = state.newest, let created = message.createdAt else { return true }
            return created > newest
        } : []
        state.seen = Set(messages.map(\.id))
        if let latest = messages.compactMap(\.createdAt).max(), state.newest.map({ latest > $0 }) ?? true {
            state.newest = latest
        }
        state.isBaselined = true
        rooms[room] = state
        guard !fresh.isEmpty, let source else { return }
        let requests = fresh.filter(Self.asks)
        if isShown(agent.id) {
            // In front of the person already: neither unread nor announced.
            if isActive() { return }
        } else {
            let mark: PersonalAgentUnread = requests.isEmpty ? .message : .request
            if unread[agent.id].map({ $0 < mark }) ?? true {
                unread[agent.id] = mark
                updateHasUnread()
            }
        }
        // A request is announced as one; the plain announcement is for a later message, if any.
        if let latest = fresh.last, requests.last?.id != latest.id {
            enqueue(.init(agent: agent, accountChoiceID: source.accountChoiceID, preview: Self.preview(latest), isRequest: false))
        }
        if let request = requests.last {
            enqueue(.init(agent: agent, accountChoiceID: source.accountChoiceID, preview: Self.preview(request), isRequest: true))
        }
    }

    /// One notification per dot and kind for a burst: a later message in it replaces the words.
    private func enqueue(_ announcement: PersonalAgentAnnouncement) {
        let key = announcement.identifier
        if pending[key] != nil {
            pending[key]?.announcement = announcement
            return
        }
        let current = generation
        let delay = coalescing
        let task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, current == self.generation,
                  let latest = self.pending.removeValue(forKey: key)?.announcement else { return }
            await self.announce(latest)
        }
        pending[key] = Pending(announcement: announcement, task: task)
    }

    private func updateHasUnread() {
        if hasUnread != !unread.isEmpty { hasUnread = !unread.isEmpty }
    }

    /// A request the person can answer: an input request the message does not close itself, or an
    /// option question with no option chosen.
    static func asks(_ message: PersonalAgentMessage) -> Bool {
        if let request = message.inputRequest.flatMap(DotsInputRequest.init), !request.isClosedByMessage { return true }
        if let picker = DotsOptionPicker(metadata: message.metadata), picker.selected == nil { return true }
        return false
    }

    static let previewLimit = 160

    /// The message's words on one line, cut to a notification's length; a message of files alone says so.
    static func preview(_ message: PersonalAgentMessage) -> String {
        let words = message.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if words.isEmpty {
            return message.attachments.isEmpty ? "" : L10n.string("Sent an attachment.")
        }
        guard words.count > previewLimit else { return words }
        return String(words.prefix(previewLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

#if DEBUG
    /// A rendered window's unread dots, with no connection.
    func useFixture(unread values: [PersonalAgentIdentity: PersonalAgentUnread]) {
        unread = values
        updateHasUnread()
    }
#endif
}
