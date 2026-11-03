import Foundation

/// What was last read of one source's dots (an account choice and its home): the list, each room's
/// newest messages as shown, and the pictures. A window shows it while its own connection reads the
/// provider again, which then replaces all of it; nothing kept counts as read now.
struct PersonalAgentReading: Sendable {
    /// A room's newest messages as a window showed them, and its lifecycle as last read.
    struct Room: Codable, Equatable, Sendable {
        var messages: [PersonalAgentMessage]
        var lifecycle: String?
    }

    let accountID: String
    let userID: String
    var agents: [PersonalAgent]
    /// By room ID.
    var rooms: [String: Room] = [:]
    /// Profile pictures, by `pictureKey`.
    var avatars: [String: Data] = [:]
    /// Sprite sheets, by pet; each carries its version.
    var sheets: [String: PersonalAgentSpriteSheet] = [:]

    /// The most a room keeps: one page, as the provider gives it.
    static let messageCount = 20

    static func pictureKey(agentID: String, version: String) -> String { agentID + "\u{0}" + version }

    func isAccount(of identity: PersonalAgentIdentity) -> Bool {
        identity.accountID == accountID && identity.userID == userID
    }

    /// The avatars, rooms and sheets the list still names; the rest is dropped.
    mutating func keepOnlyListed() {
        let rooms = Set(agents.map(\.id.roomID))
        self.rooms = self.rooms.filter { rooms.contains($0.key) }
        let pictures = Set(agents.compactMap { agent in agent.avatar.map { Self.pictureKey(agentID: agent.id.agentID, version: $0.version) } })
        avatars = avatars.filter { pictures.contains($0.key) }
        let pets = Set(agents.compactMap(\.petID))
        sheets = sheets.filter { pets.contains($0.key) }
    }
}

/// Where readings are kept between launches. The platform owns the files; each call runs off the
/// main thread, in the order made.
protocol PersonalAgentReadingCache: Actor {
    /// What was last kept for `source`, under the account it was last read as.
    func reading(source: String) -> PersonalAgentReading?
    /// The list `source` read now under its account, which replaces the account's list and drops the
    /// rooms and pictures it no longer names. Another account `source` was read as before is
    /// forgotten when no other source names it.
    func saveList(_ agents: [PersonalAgent], accountID: String, userID: String, source: String)
    func saveRoom(_ room: PersonalAgentReading.Room, of identity: PersonalAgentIdentity)
    func saveAvatar(_ data: Data, of agent: PersonalAgent)
    /// A pet's sheet, or none when the pet is gone.
    func saveSheet(_ data: Data?, version: String, pet: String, of identity: PersonalAgentIdentity)
    /// Deletes everything kept of the account `source` was last read as.
    func forget(source: String)
    /// Deletes everything kept, of every account.
    func forgetAll()
}

/// The readings every window of this run shares, by source, and the cache they are kept in between
/// launches. A window shows them at once and refreshes them from the provider; what one window
/// reads, the next window shows. Selection, drafts, scroll position and observation stay per window.
@MainActor
final class PersonalAgentReadings {
    private var readings: [String: PersonalAgentReading] = [:]
    private let cache: (any PersonalAgentReadingCache)?
    /// Whether readings are kept in the cache for the next launch: while Settings › Notifications ›
    /// Personal agent messages is on. Turned off, everything kept is deleted and nothing more is
    /// written; the windows of this run still share what they read.
    var keepsFiles = true {
        didSet {
            guard keepsFiles != oldValue, !keepsFiles, let cache else { return }
            enqueue { await cache.forgetAll() }
        }
    }
    /// The last write, which the next one waits for, so they reach the cache in the order made.
    private var lastWrite: Task<Void, Never>?

    init(cache: (any PersonalAgentReadingCache)? = nil) {
        self.cache = cache
    }

    /// What was last read for `source`: this run's, or else what the cache kept.
    func reading(for source: String) async -> PersonalAgentReading? {
        if let reading = readings[source] { return reading }
        guard keepsFiles, let cache else { return nil }
        let previous = lastWrite
        await previous?.value
        let kept = await cache.reading(source: source)
        // A window that read meanwhile has the newer reading.
        if let reading = readings[source] { return reading }
        guard var kept else { return nil }
        kept.keepOnlyListed()
        readings[source] = kept
        return kept
    }

    /// A room's newest messages as kept for `identity`'s account under `source`.
    func room(of identity: PersonalAgentIdentity, source: String) -> PersonalAgentReading.Room? {
        guard let reading = readings[source], reading.isAccount(of: identity) else { return nil }
        return reading.rooms[identity.roomID]
    }

    /// The dots `source` read now. Another account replaces what was kept; no dots keep nothing.
    func noteAgents(_ agents: [PersonalAgent], source: String) {
        guard let first = agents.first?.id else { return forget(source: source) }
        var reading = readings[source].flatMap { $0.isAccount(of: first) ? $0 : nil }
            ?? PersonalAgentReading(accountID: first.accountID, userID: first.userID, agents: agents)
        reading.agents = agents
        reading.keepOnlyListed()
        readings[source] = reading
        write { await $0.saveList(agents, accountID: first.accountID, userID: first.userID, source: source) }
    }

    /// The room's newest messages as shown after a read of its latest page, up to one page.
    func noteRoom(_ messages: [PersonalAgentMessage], lifecycle: String?, of agent: PersonalAgent, source: String) {
        guard var reading = readings[source], reading.isAccount(of: agent.id),
              reading.agents.contains(where: { $0.id == agent.id }) else { return }
        let room = PersonalAgentReading.Room(messages: Array(messages.suffix(PersonalAgentReading.messageCount)),
                                             lifecycle: lifecycle)
        // The same page read again changes nothing kept.
        guard reading.rooms[agent.id.roomID] != room else { return }
        reading.rooms[agent.id.roomID] = room
        readings[source] = reading
        write { await $0.saveRoom(room, of: agent.id) }
    }

    func noteAvatar(_ data: Data, of agent: PersonalAgent, source: String) {
        guard let avatar = agent.avatar, var reading = readings[source], reading.isAccount(of: agent.id),
              reading.agents.contains(where: { $0.id == agent.id && $0.avatar?.version == avatar.version }) else { return }
        let key = PersonalAgentReading.pictureKey(agentID: agent.id.agentID, version: avatar.version)
        guard reading.avatars[key] != data else { return }
        reading.avatars[key] = data
        readings[source] = reading
        write { await $0.saveAvatar(data, of: agent) }
    }

    /// A pet's sheet as read, or none when the pet is gone.
    func noteSheet(_ sheet: PersonalAgentSpriteSheet?, pet: String, of agent: PersonalAgent, source: String) {
        guard var reading = readings[source], reading.isAccount(of: agent.id),
              reading.agents.contains(where: { $0.petID == pet }) else { return }
        if let sheet, reading.sheets[pet] === sheet { return }
        if sheet == nil, reading.sheets[pet] == nil { return }
        reading.sheets[pet] = sheet
        readings[source] = reading
        let data = sheet?.data, version = sheet?.version ?? ""
        write { await $0.saveSheet(data, version: version, pet: pet, of: agent.id) }
    }

    /// Forgets what was kept for `source`, here and in the cache: its login ended or changed, or its
    /// account left Yardlet.
    func forget(source: String) {
        readings[source] = nil
        write { await $0.forget(source: source) }
    }

    private func write(_ body: @escaping @Sendable (any PersonalAgentReadingCache) async -> Void) {
        guard keepsFiles, let cache else { return }
        enqueue { await body(cache) }
    }

    private func enqueue(_ body: @escaping @Sendable () async -> Void) {
        let previous = lastWrite
        lastWrite = Task {
            await previous?.value
            await body()
        }
    }

    /// Waits for every write made so far to reach the cache.
    func settle() async {
        await lastWrite?.value
    }
}
