import Foundation

/// "Idle compaction" in Yardlet's General settings, after Claude Code's own (`idleCompaction` in its
/// settings.json, "Idle compaction" in its `/config`, on by default). Claude Code compacts a long
/// conversation while its session is idle, shortly before the prompt cache expires, but only in an
/// interactive session or one an app it knows launched; it never does in the sessions Yardlet runs.
/// This switch has Yardlet do the same for its Claude Code tasks (`AppModel.armIdleCompaction`).
///
/// Nothing is written to Claude Code's settings: Yardlet reads them, and a person whose settings
/// turn idle compaction or auto-compact off gets no idle compaction whatever this switch says.
/// Turned off, the timers it armed do nothing when they fire.
enum IdleCompactionPreference {
    static let key = "YardletIdleCompaction"

    static func isOn(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

/// What the last request of a Claude Code session's main conversation left in the prompt cache, as
/// the CLI's stream reported it (`ClaudeAdapter`). Claude Code keeps the same in its request journal
/// and cache tracker (2.1.322: `requestJournal`, `summary`).
struct ClaudePromptCacheState: Equatable, Sendable {
    enum Lifetime: String, Sendable {
        case fiveMinutes = "5m"
        case oneHour = "1h"

        var seconds: TimeInterval { self == .oneHour ? 3_600 : 300 }
    }

    /// When the request's response began (`message_start`), the nearest the stream comes to when the
    /// CLI sent it and the cache was last used.
    var requestAt: Date
    /// The cache lifetime the request wrote at: an hour when it wrote 1-hour cache tokens, five
    /// minutes when it wrote 5-minute ones, and the previous request's when it wrote none, as the
    /// CLI keeps it (`aLt`).
    var lifetime: Lifetime
    /// Whether the request read or wrote the cache at all. One that did neither left nothing to keep.
    var usedCache: Bool
    /// The request's input, cache writes and cache reads.
    var promptTokens: UInt64
    /// What the response has written so far (`message_delta`).
    var outputTokens: UInt64 = 0

    /// The context the response left, counted as the CLI counts it for this (`UI`): its input, cache
    /// writes, cache reads and output.
    var contextTokens: UInt64 { promptTokens + outputTokens }

    /// When the cache expires unless something uses it again.
    var expiresAt: Date { requestAt.addingTimeInterval(lifetime.seconds) }

    /// A response's start (`message_start`'s `message.usage`), as the CLI records the request
    /// (`M0i`): the lifetime of the cache it wrote, or the previous request's when it wrote none.
    init?(responseStart usage: JSONValue?, at date: Date, previous: Self?) {
        guard let usage, usage.objectValue != nil else { return nil }
        func number(_ value: JSONValue?) -> UInt64 { ClaudeEventProjector.unsigned(value) ?? 0 }
        let written = number(usage["cache_creation_input_tokens"])
        let read = number(usage["cache_read_input_tokens"])
        let split = usage["cache_creation"]
        let lifetime: Lifetime? = if number(split?["ephemeral_5m_input_tokens"]) > 0 {
            .fiveMinutes
        } else if number(split?["ephemeral_1h_input_tokens"]) > 0 {
            .oneHour
        } else {
            nil
        }
        requestAt = date
        self.lifetime = written == 0 ? previous?.lifetime ?? lifetime ?? .fiveMinutes : lifetime ?? .fiveMinutes
        usedCache = written + read > 0
        promptTokens = number(usage["input_tokens"]) + written + read
    }
}

/// The settings of Claude Code's own that stop an idle compaction, read from the CLI when a timer
/// fires without writing anything (`ClaudeAdapter.idleCompactionFacts`).
struct ClaudeCompactionSettings: Equatable, Sendable {
    /// `get_context_usage`'s `isAutoCompactEnabled`: `autoCompactEnabled` in its settings, and no
    /// `DISABLE_COMPACT` or `DISABLE_AUTO_COMPACT` in its environment.
    var autoCompact: Bool
    /// `idleCompaction` in its effective settings (`get_settings`), on unless set to false.
    var idleCompaction: Bool
    /// `max(100000, CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS ?? 200000)`.
    var minimumContextTokens: UInt64
}

/// What a session's CLI reports when an idle-compaction timer fires.
struct IdleCompactionFacts: Equatable, Sendable {
    var cache: ClaudePromptCacheState?
    /// The latest plan-limit status the CLI reported; nil before any, which is "allowed".
    var rateLimit: HarnessRateLimit.Status?
    /// The session was set to another model since the request, so its cache is not the next request's
    /// (the CLI's `zbn`: the session model it was made on).
    var modelChanged = false
    /// Nil when the CLI did not answer.
    var settings: ClaudeCompactionSettings?
}

/// Claude Code's idle compaction (2.1.322: `class Lgn`, its check `Ukr`): armed after a request that
/// used the 1-hour prompt cache, it fires nine tenths of the way to the cache's expiry, about 54
/// minutes after the request, and compacts only when every condition below holds. Yardlet's own
/// conditions on the task (idle, no move to another account) are `AppModel`'s.
enum IdleCompaction {
    /// How far into the cache's life the timer fires (`Hkr`).
    static let firesAtFraction = 0.9
    /// How late a timer may fire and still compact (`Bkr`): a Mac that slept through it does not.
    static let latenessAllowed: TimeInterval = 60
    /// The smallest context it compacts (`$kr`), and the default (`Fkr`).
    static let leastMinimumTokens: UInt64 = 100_000
    static let defaultMinimumTokens: UInt64 = 200_000
    static let minimumTokensVariable = "CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS"

    /// Why a timer did not compact, in Claude Code's own words for it.
    enum Skip: String, Equatable, Sendable {
        case compactionOff = "compaction_off"
        case idleCompactionOff = "idle_compaction_off"
        case prefixChanged = "prefix_changed"
        case notOneHour = "not_one_hour"
        case lapsed
        case small
        case newerRequest = "newer_request"
        case nearLimit = "near_limit"
    }

    /// `Dgn`: the variable when it is a whole number, never less than the least.
    static func minimumContextTokens(variable: String?) -> UInt64 {
        let chosen = variable.flatMap { UInt64($0.trimmingCharacters(in: .whitespaces)) } ?? defaultMinimumTokens
        return max(leastMinimumTokens, chosen)
    }

    /// When a timer armed after `cache`'s request fires; nil when none is armed: a request that did
    /// not use the 1-hour cache.
    static func fireDate(for cache: ClaudePromptCacheState?) -> Date? {
        guard let cache, cache.lifetime == .oneHour, cache.usedCache else { return nil }
        return cache.requestAt.addingTimeInterval(cache.lifetime.seconds * firesAtFraction)
    }

    /// Why the timer armed after `armed`'s request, due at `due`, does not compact now, or nil when it
    /// does: Claude Code's checks in its order. A CLI that did not report its settings compacts nothing.
    static func skip(armed: ClaudePromptCacheState, due: Date, now: Date, facts: IdleCompactionFacts) -> Skip? {
        guard let settings = facts.settings, settings.autoCompact else { return .compactionOff }
        guard settings.idleCompaction else { return .idleCompactionOff }
        guard !facts.modelChanged else { return .prefixChanged }
        guard let current = facts.cache, current.lifetime == .oneHour else { return .notOneHour }
        guard current.usedCache, now < current.expiresAt,
              now.timeIntervalSince(due) <= latenessAllowed else { return .lapsed }
        guard current.contextTokens >= settings.minimumContextTokens else { return .small }
        guard current.requestAt <= armed.requestAt else { return .newerRequest }
        guard (facts.rateLimit ?? .allowed) == .allowed else { return .nearLimit }
        return nil
    }
}
