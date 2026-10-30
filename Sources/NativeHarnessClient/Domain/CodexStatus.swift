import Foundation

/// One window of a Codex plan limit, as the App Server's `RateLimitWindow` reports it.
struct CodexRateLimitWindow: Codable, Equatable, Sendable {
    var usedPercent: Double
    var windowDurationMinutes: Int64?
    /// Unix seconds.
    var resetsAt: Int64?
}

/// One metered limit, the App Server's `RateLimitSnapshot`: the account's general Codex limit or
/// one model's own.
struct CodexRateLimitSnapshot: Codable, Equatable, Sendable {
    var limitID: String?
    var limitName: String?
    var primary: CodexRateLimitWindow?
    var secondary: CodexRateLimitWindow?
}

/// What `account/rateLimits/read` reported for the account a task runs under.
struct CodexAccountRateLimits: Codable, Equatable, Sendable {
    /// The general limit: `rateLimits`, the `codex` bucket.
    var general: CodexRateLimitSnapshot?
    /// The named limits of single models: the other `rateLimitsByLimitId` buckets.
    var models: [CodexRateLimitSnapshot] = []

    init(general: CodexRateLimitSnapshot?, models: [CodexRateLimitSnapshot] = []) {
        self.general = general
        self.models = models
    }

    init(response: JSONValue?) {
        let general = response?["rateLimits"].flatMap(Self.snapshot)
        let keyed = response?["rateLimitsByLimitId"]?.objectValue ?? [:]
        let generalID = general?.limitID ?? "codex"
        self.general = general ?? keyed[generalID].flatMap(Self.snapshot)
        // As the Codex app reads its usage response, a model's limit counts only with a name.
        models = keyed.filter { $0.key != generalID }.sorted { $0.key < $1.key }.compactMap { key, value in
            guard var snapshot = Self.snapshot(value),
                  let name = snapshot.limitName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
            else { return nil }
            snapshot.limitName = name
            snapshot.limitID = snapshot.limitID ?? key
            return snapshot
        }
    }

    private static func snapshot(_ value: JSONValue) -> CodexRateLimitSnapshot? {
        guard value.objectValue != nil else { return nil }
        return CodexRateLimitSnapshot(
            limitID: value["limitId"]?.stringValue, limitName: value["limitName"]?.stringValue,
            primary: window(value["primary"]), secondary: window(value["secondary"]))
    }

    private static func window(_ value: JSONValue?) -> CodexRateLimitWindow? {
        guard let used = value?["usedPercent"]?.doubleValue, used.isFinite else { return nil }
        return CodexRateLimitWindow(
            usedPercent: used,
            windowDurationMinutes: value?["windowDurationMins"]?.doubleValue.map { Int64($0) },
            resetsAt: value?["resetsAt"]?.doubleValue.map { Int64($0) })
    }
}

/// An open `/status` panel's reading of the account's rate limits.
struct CodexStatusReading: Equatable, Sendable {
    var rateLimits: CodexAccountRateLimits?
    var isReading = false
}

/// The Codex app's `/status` panel (`composer.statusPlain.*`), row by row: the chat's session and
/// thread IDs, the context it has left, and the account's rate limits for the selected model.
struct CodexStatusProjection: Equatable {
    enum Row: Equatable {
        /// `Session/Thread:`, `Session:`, `Thread:` or `Threads:` with IDs that can be selected.
        case identifiers(label: String, ids: [String])
        /// A label and its value; the value's parenthetical part reads quieter.
        case value(label: String, text: String, metadata: String?)
        /// A rate-limit window, whose bar fills with the share left.
        case rateLimit(label: String, remainingPercent: Double, text: String, metadata: String)
        /// A model's own limits, as a heading over its windows.
        case section(String)
        /// The gap before an alert.
        case spacer
    }

    /// The panel's words in the app's language, or in one named language.
    struct Words: Equatable {
        var languageCode: String?
        var locale: Locale = .current

        func string(_ key: String) -> String {
            languageCode.map { L10n.string(key, languageCode: $0) } ?? L10n.string(key)
        }

        func format(_ key: String, _ arguments: CVarArg...) -> String {
            String(format: string(key), locale: locale, arguments: arguments)
        }
    }

    let rows: [Row]
    /// The language the rows were written in, for the panel's own heading and buttons.
    let words: Words

    /// - Parameters:
    ///   - sessionID: the thread's `sessionId`, which threads of one session tree share; the
    ///     thread's own ID stands in for it when the thread has not reported one.
    ///   - rateLimits: the account's last reading; nil with `isReadingRateLimits` while the first
    ///     reading is on its way, which leaves the rate-limit rows out until it arrives.
    init(sessionID: String? = nil, threadID: String?, descendantThreadIDs: [String], tokenUsage: CodexThreadTokenUsage?,
         rateLimits: CodexAccountRateLimits?, isReadingRateLimits: Bool = false, selectedModel: String?,
         now: Date = Date(), words: Words = Words()) {
        var rows: [Row] = []
        // As in the Codex app: the session, then the thread when it is not the session's root,
        // then the subagent threads the chat spawned.
        let sessionID = sessionID ?? threadID
        var seen = Set(sessionID.map { [$0] } ?? [])
        let threadIDs = ([threadID].compactMap { $0 } + descendantThreadIDs).filter { seen.insert($0).inserted }
        if let sessionID {
            rows.append(.identifiers(label: words.string(threadIDs.isEmpty ? "Session/Thread:" : "Session:"), ids: [sessionID]))
        }
        if !threadIDs.isEmpty {
            rows.append(.identifiers(label: words.string(threadIDs.count == 1 ? "Thread:" : "Threads:"), ids: threadIDs))
        }
        if let context = Self.context(tokenUsage, words: words) { rows.append(context) }
        if rateLimits != nil || !isReadingRateLimits {
            rows += Self.rateLimitRows(rateLimits, selectedModel: selectedModel, now: now, words: words)
        }
        self.rows = rows
        self.words = words
    }

    /// The subagent threads the chat spawned, which the Codex app lists as the session's threads.
    static func descendantThreadIDs(in state: CodexTaskState?) -> [String] {
        var seen = Set<String>(), ids: [String] = []
        for turn in state?.thread?.turns ?? [] {
            for item in turn.items {
                switch item.content {
                case let .collaboration(call) where call.tool == "spawnAgent":
                    for id in call.receiverThreadIDs where seen.insert(id).inserted { ids.append(id) }
                case let .subagentActivity(activity) where activity.kind == "started":
                    if seen.insert(activity.agentThreadID).inserted { ids.append(activity.agentThreadID) }
                default:
                    break
                }
            }
        }
        return ids
    }

    /// The last turn's tokens against the model window, as the Codex app counts them.
    private static func context(_ usage: CodexThreadTokenUsage?, words: Words) -> Row? {
        guard let usage, let window = usage.modelContextWindow, window > 0, usage.last.totalTokens >= 0 else { return nil }
        let used = min(usage.last.totalTokens, window)
        let remaining = max(0, (100 - Double(used) / Double(window) * 100).rounded())
        let thousands = (Double(window) / 1_000).rounded()
        let number = IntegerFormatStyle<Int64>.number.locale(words.locale)
        let total = thousands > 0 ? "\(Int64(thousands).formatted(number))K" : window.formatted(number)
        return .value(label: words.string("Context:"), text: words.format("%lld%% left", Int64(remaining)),
                      metadata: words.format("(%@ used / %@)", used.formatted(number), total))
    }

    private static func rateLimitRows(_ limits: CodexAccountRateLimits?, selectedModel: String?,
                                      now: Date, words: Words) -> [Row] {
        // The general limit, then the selected model's own (or, with no model chosen, the limit
        // the account names as active), as the Codex app filters its usage entries.
        let wanted = normalizedLimitName(selectedModel)
            ?? normalizedLimitName(limits?.general?.limitName).flatMap { $0 == "codex" ? nil : $0 }
        let models = wanted.map { name in limits?.models.filter { normalizedLimitName($0.limitName) == name } ?? [] } ?? []
        let entries = (limits?.general.map { [(name: String?.none, snapshot: $0)] } ?? [])
            + models.map { (name: $0.limitName, snapshot: $0) }

        var rows: [Row] = [], sections = Set<String>()
        for entry in entries {
            // The same windows the account list and a limit card draw, in the app's words.
            for window in AccountLimitWindow.windows(entry.snapshot, words: words) {
                if let name = entry.name {
                    let section = words.format("%@ limit:", name.replacingOccurrences(of: "_", with: "-"))
                    if sections.insert(section).inserted { rows.append(.section(section)) }
                }
                let remaining = window.remainingPercent ?? 0
                let phrase = window.resetsAt.map {
                    words.format("resets %@", resetTime($0, now: now, locale: words.locale))
                } ?? words.string("reset time unavailable")
                rows.append(.rateLimit(label: window.name + ":", remainingPercent: remaining,
                                       text: words.format("%lld%% left", Int64(remaining.rounded())),
                                       metadata: "(\(phrase))"))
            }
        }
        guard rows.isEmpty else { return rows }
        rows.append(.value(label: words.string("Rate limit:"), text: words.string("Unavailable"), metadata: nil))
        if let alert = alert(limits?.general ?? models.first) {
            rows.append(.spacer)
            rows.append(.value(label: words.string("Alert:"), text: words.format(
                "%1$lld%% left on %2$@", Int64(alert.remaining.rounded()), windowLabel(minutes: alert.minutes, words: words)),
                metadata: nil))
        }
        return rows
    }

    /// A limit nine-tenths used, which the Codex app still mentions when its windows have no
    /// length to list them by.
    private static func alert(_ snapshot: CodexRateLimitSnapshot?) -> (remaining: Double, minutes: Int64?)? {
        let primary = snapshot?.primary, secondary = snapshot?.secondary
        let primaryUsed = primary?.usedPercent ?? 0, secondaryUsed = secondary?.usedPercent ?? 0
        guard max(primaryUsed, secondaryUsed) >= 90 else { return nil }
        let window = secondaryUsed > primaryUsed || (secondaryUsed == primaryUsed
            && (secondary?.windowDurationMinutes ?? 0) > (primary?.windowDurationMinutes ?? 0)) ? secondary : primary
        return (min(max(100 - (window?.usedPercent ?? 0), 0), 100), window?.windowDurationMinutes)
    }

    /// The Codex app's name for a window by its length: `5h limit`, `7d limit`, `1mo limit`, …
    static func windowLabel(minutes: Int64?, words: Words = Words()) -> String {
        guard let minutes, minutes > 0 else { return words.string("Rate limit") }
        func near(_ value: Int64, _ target: Int64) -> Bool {
            Double(value) >= Double(target) * 0.95 && Double(value) <= Double(target) * 1.05
        }
        func multiple(of unit: Int64) -> Int64? {
            let count = max(1, Int64((Double(minutes) / Double(unit)).rounded()))
            return near(minutes, count * unit) ? count : nil
        }
        if near(minutes, 300) { return words.format("%lldh limit", Int64(5)) }
        if let years = multiple(of: 365 * 1_440) { return words.format("%lldy limit", years) }
        if let months = multiple(of: 30 * 1_440) { return words.format("%lldmo limit", months) }
        if minutes % 1_440 == 0 { return words.format("%lldd limit", minutes / 1_440) }
        if minutes % 60 == 0 { return words.format("%lldh limit", minutes / 60) }
        return words.format("%lldm limit", minutes)
    }

    /// When a window resets, as the Codex app says it: `now`, a time within a day, else a date.
    static func resetTime(_ date: Date, now: Date, locale: Locale) -> String {
        let seconds = date.timeIntervalSince(now).rounded(.down)
        if seconds <= 0 { return RelativeTime.now(locale: locale) }
        if seconds < 86_400 { return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)) }
        return date.formatted(Date.FormatStyle().month(.abbreviated).day().locale(locale))
    }

    /// The Codex app compares limit names and model IDs case-blind, with `_`, `.` and spaces as `-`.
    static func normalizedLimitName(_ name: String?) -> String? {
        guard let name else { return nil }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"[_\s.]+"#, with: "-", options: .regularExpression)
        return normalized.isEmpty ? nil : normalized
    }
}
