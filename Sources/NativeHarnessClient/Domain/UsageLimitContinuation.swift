import Foundation

/// An armed automatic continue for the task's limit card, with the task identity it was armed for.
/// The continue message is sent only while the task still matches all of it. The card is known by
/// the reset it names rather than by its entry: a conversation read back from Claude's saved history
/// after a relaunch holds the same card under another entry ID.
struct UsageLimitAutoContinue: Codable, Equatable, Sendable {
    let resetsAt: Date
    let providerSessionID: String?
    let connection: ProviderConnection?

    /// Whether a limit card names this reset.
    func waits(for reset: Date?) -> Bool {
        Self.isSameReset(reset, resetsAt)
    }

    /// The CLI's report names a reset to the second and its own words to the minute, so a card read
    /// back from its words names the same reset as the live card did.
    static func isSameReset(_ one: Date?, _ other: Date?) -> Bool {
        guard let one, let other else { return false }
        return abs(one.timeIntervalSince(other)) < 60
    }

    static let preferenceKey = "Yardlet.usageLimitAutoContinue"

    /// The armed continues a relaunch arms again, by task.
    static func load(from defaults: UserDefaults) -> [UUID: Self] {
        guard let data = defaults.data(forKey: preferenceKey),
              let saved = try? JSONDecoder().decode([String: Self].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    static func save(_ armed: [UUID: Self], to defaults: UserDefaults) {
        guard !armed.isEmpty, let data = try? JSONEncoder().encode(
            Dictionary(uniqueKeysWithValues: armed.map { ($0.key.uuidString, $0.value) })) else {
            defaults.removeObject(forKey: preferenceKey)
            return
        }
        defaults.set(data, forKey: preferenceKey)
    }
}

/// What a task stopped by a plan limit sends to pick up where it stopped. The words go to the model,
/// so they are English whatever language Yardlet shows, as the tools' descriptions and Yardlet's
/// envelopes for other tasks' messages are (2026-10-27, the person's call; the Claude app sends its own message
/// in the app's language).
enum UsageLimitContinuation {
    /// The Claude app's own message for continuing once the limit has reset.
    static let afterReset =
        "I hit my usage limit while you were working, but it has reset now. Please continue from where you left off."

    /// The same request after moving to another account, which has not reset anything.
    static let afterAccountSwitch =
        "I hit my usage limit while you were working, and I've switched to another account now. Please continue from where you left off."

    /// The limit card a stopped task continues from: the transcript's last entry, or the last one
    /// before notices Claude Code wrote itself when background work ended after it, which no turn
    /// has answered. A subagent the same limit stopped reports so right after the card, and the CLI
    /// waits for the reset before it answers.
    static func card(in entries: [TranscriptEntry]) -> TranscriptEntry? {
        for entry in entries.reversed() {
            switch entry.content {
            case .usageLimit: return entry
            case let .user(text, _) where ClaudeTaskNotification.parse(text) != nil: continue
            default: return nil
            }
        }
        return nil
    }
}

/// The words a task shows for its provider's plan limits, retries and compaction, in the Claude
/// app's own phrasing where it has one.
enum ProviderNoticeText {
    static func limitHeadline(_ limit: HarnessRateLimit) -> String {
        switch limit.window {
        case .session: L10n.string("Session limit reached")
        case .weekly: L10n.string("Weekly limit reached")
        case .model: limit.model.map { L10n.format("%@ limit reached", $0) } ?? L10n.string("Usage limit reached")
        case .overage, nil: L10n.string("Usage limit reached")
        }
    }

    /// When the limit resets, with the day named unless it is today.
    static func limitReset(_ limit: HarnessRateLimit, now: Date = Date()) -> String? {
        guard let resetsAt = limit.resetsAt else { return nil }
        let time = resetTime(resetsAt, now: now)
        return switch limit.window {
        case .session: L10n.format("Your session limit resets at %@.", time)
        case .weekly: L10n.format("Your weekly limit resets at %@.", time)
        case .model: limit.model.map { L10n.format("Your %1$@ limit resets at %2$@.", $0, time) }
            ?? L10n.format("Your usage limit resets at %@.", time)
        case .overage, nil: L10n.format("Your usage limit resets at %@.", time)
        }
    }

    static func resetTime(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// A warning's one line: how much of the window is used, or that it is close, and its reset.
    static func limitWarning(_ limit: HarnessRateLimit, now: Date = Date()) -> String {
        let percent = limit.usedFraction.map { Int64(min(100, max(0, ($0 * 100).rounded(.down)))) }
        let usage: String = switch (limit.window, percent) {
        case let (.session, percent?): L10n.format("You've used %lld%% of your session limit", percent)
        case (.session, nil): L10n.string("Approaching your session limit")
        case let (.weekly, percent?): L10n.format("You've used %lld%% of your weekly limit", percent)
        case (.weekly, nil): L10n.string("Approaching your weekly limit")
        case let (.model, percent?):
            limit.model.map { L10n.format("You've used %2$lld%% of your %1$@ limit", $0, percent) }
                ?? L10n.format("You've used %lld%% of your usage limit", percent)
        case let (_, percent?): L10n.format("You've used %lld%% of your usage limit", percent)
        case (_, nil): L10n.string("Approaching your usage limit")
        }
        guard let resetsAt = limit.resetsAt else { return usage }
        return usage + " · " + L10n.format("Resets %@", resetTime(resetsAt, now: now))
    }

    /// The running status line while the provider retries: why, then which attempt of how many.
    static func retry(_ retry: HarnessProviderRetry) -> String {
        let attempt = L10n.format("Retrying (%lld/%lld)", Int64(retry.attempt), Int64(retry.maxRetries))
        let cause: String? = switch retry.cause {
        case .overloaded: L10n.string("API overloaded")
        case .rateLimited: L10n.string("Rate limited")
        case .serverError: L10n.string("Server error")
        case .connection: L10n.string("Network error")
        case .other: nil
        }
        return cause.map { "\($0) · \(attempt)" } ?? attempt
    }

    static func compaction(_ compaction: HarnessContextCompaction) -> String {
        switch compaction.phase {
        case .started:
            return L10n.string("Compacting session…")
        case .failed:
            return L10n.string("Compaction failed")
        case .completed:
            if let saved = compaction.savedTokens {
                return L10n.format("Compacted session · saved %@ tokens",
                    ConversationSessionStatusProjection.compactTokenCount(saved))
            }
            if let before = compaction.tokensBefore {
                return L10n.format("Compacted session · from %@ tokens",
                    ConversationSessionStatusProjection.compactTokenCount(before))
            }
            return L10n.string("Compacted session")
        }
    }
}
