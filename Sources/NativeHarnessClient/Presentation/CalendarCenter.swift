import Foundation
import Observation

/// Settings › General › Calendar: off until the person turns it on.
enum CalendarPreference {
    static let key = "YardletCalendar"

    static func isOn(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.object(forKey: key) as? Bool ?? false
    }
}

/// The app's one calendar: the calendars of the accounts connected in Settings › Connectors, and the events of
/// the days a screen shows, read from each service while it shows them and kept in memory only. Nothing of an
/// event is written to disk; turning the calendar off forgets it all.
///
/// A calendar can reach Yardlet two ways: through its own connector, and through the Mac's Calendar app when the
/// same Google or Outlook account was added there too. It is shown once, from its connector, which can answer
/// invitations (`copies`); the Mac's copy stands in while the connector cannot read it.
@MainActor @Observable
final class CalendarCenter {
    /// Whether the person turned the calendar on (`CalendarPreference`); off, it holds nothing.
    private(set) var isEnabled = false
    /// The accounts shown, in the order the person connected them.
    private(set) var accounts: [CalendarAccount] = []
    /// Each account's calendars as last read.
    private(set) var accountCalendars: [UUID: [CalendarInfo]] = [:]
    /// Accounts whose calendars could not be read last time, with why.
    private(set) var failures: [UUID: CalendarFailure] = [:]
    /// Every account's calendars, without the Mac's copies of calendars their connectors read.
    private(set) var calendars: [CalendarInfo] = []
    /// What each range a screen shows holds, every calendar together, by start.
    private(set) var shownEvents: [DateInterval: [CalendarEvent]] = [:]
    /// Ranges being read now.
    private(set) var loading: Set<DateInterval> = []

    @ObservationIgnored private var transports: [UUID: any CalendarAccountTransport] = [:]
    /// The Mac's calendars that are another way to a calendar a connector reads, to that calendar.
    @ObservationIgnored private var copies: [CalendarKey: CalendarKey] = [:]
    /// Each range's events as each calendar gave them, and when they were read.
    @ObservationIgnored private var reads: [DateInterval: RangeRead] = [:]
    /// The range each screen shows now.
    @ObservationIgnored private var viewers: [UUID: DateInterval] = [:]
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// How long what was read stands: a screen that shows it again within this reads nothing, and a screen that
    /// keeps showing it has it read again this often.
    @ObservationIgnored var refreshInterval: Duration = .seconds(300)

    /// Ranges no screen shows any more that are kept until `refreshInterval` passes, at most.
    static let keptUnshownRanges = 4

    private struct RangeRead {
        var events: [CalendarKey: [CalendarEvent]] = [:]
        /// Calendars whose events could not be read for the range.
        var failed: Set<CalendarKey> = []
        var readAt: ContinuousClock.Instant
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !enabled { forget() }
    }

    /// Shows these accounts, read through their transports. Accounts no longer listed are forgotten with everything
    /// read from them, and what a screen shows is read again.
    func setAccounts(_ entries: [(CalendarAccount, any CalendarAccountTransport)]) {
        guard isEnabled else { return }
        generation += 1
        accounts = entries.map(\.0)
        transports = Dictionary(entries.map { ($0.0.id, $0.1) }, uniquingKeysWith: { $1 })
        let kept = Set(accounts.map(\.id))
        accountCalendars = accountCalendars.filter { kept.contains($0.key) }
        failures = failures.filter { kept.contains($0.key) }
        reads = [:]
        shownEvents = [:]
        loading = []
        mergeCalendars()
        if !viewers.isEmpty { Task { await refresh() } }
    }

    func account(_ id: UUID) -> CalendarAccount? { accounts.first { $0.id == id } }

    // MARK: - Showing

    /// A screen shows the days of `range`. They are read unless what was read of them is newer than
    /// `refreshInterval`, and read again that often while any screen shows them.
    func show(_ range: DateInterval, for viewer: UUID) {
        guard isEnabled else { return }
        viewers[viewer] = range
        prune()
        if !isFresh(range) { Task { await read([range]) } }
        startRefreshing()
    }

    /// The screen no longer shows its range; nothing is read for a range no screen shows.
    func stopShowing(for viewer: UUID) {
        guard viewers.removeValue(forKey: viewer) != nil else { return }
        prune()
        if viewers.isEmpty {
            refreshing?.cancel()
            refreshing = nil
        }
    }

    /// The events of a range a screen shows, as last read.
    func events(in range: DateInterval) -> [CalendarEvent] { shownEvents[range] ?? [] }

    /// Reads every account's calendars again, and every range a screen shows.
    func refresh() async {
        guard isEnabled else { return }
        await readCalendars()
        await read(Array(Set(viewers.values)))
    }

    // MARK: - Invitations

    /// Answers an invitation on the event's own service and shows the answer at once.
    func respond(to event: CalendarEvent, _ response: CalendarResponse) async throws {
        let accountID = event.id.calendar.accountID
        guard let transport = transports[accountID], let account = account(accountID) else {
            throw CalendarFailure(kind: .unavailable, message: L10n.string("This account is no longer in the calendar."))
        }
        guard account.provider.answersInvitations, response != .needsAction else {
            throw CalendarFailure(kind: .unavailable, message: L10n.string("Answer this invitation in Calendar."))
        }
        let generation = generation
        do {
            try await transport.respond(to: event, response)
        } catch {
            let failure = Self.failure(error)
            if generation == self.generation, failure.kind == .signInRequired { failures[accountID] = failure }
            throw failure
        }
        guard generation == self.generation else { return }
        for range in Array(reads.keys) {
            guard var list = reads[range]?.events[event.id.calendar],
                  let index = list.firstIndex(where: { $0.id == event.id }) else { continue }
            list[index].response = response
            reads[range]?.events[event.id.calendar] = list
            mergeEvents(range)
        }
    }

    // MARK: - Reading

    private func readCalendars() async {
        let generation = generation
        await withTaskGroup(of: (UUID, Result<[CalendarInfo], Error>).self) { group in
            for (id, transport) in transports {
                group.addTask {
                    do { return (id, .success(try await transport.calendars())) } catch { return (id, .failure(error)) }
                }
            }
            for await (id, result) in group where generation == self.generation {
                switch result {
                case let .success(list):
                    accountCalendars[id] = list
                    failures[id] = nil
                case let .failure(error):
                    // What was read of it before stays, so its calendars are still known.
                    failures[id] = Self.failure(error)
                }
            }
        }
        guard generation == self.generation else { return }
        mergeCalendars()
    }

    /// Reads the shown calendars' events for each range. An account that could not be read counts as failed for
    /// every calendar of it, so the Mac's copies of them stand in.
    private func read(_ ranges: [DateInterval]) async {
        let ranges = ranges.filter { !loading.contains($0) }
        guard isEnabled, !ranges.isEmpty else { return }
        let generation = generation
        loading.formUnion(ranges)
        defer { if generation == self.generation { loading.subtract(ranges) } }
        if accounts.contains(where: { accountCalendars[$0.id] == nil && failures[$0.id] == nil }) { await readCalendars() }
        guard generation == self.generation else { return }
        let targets = calendarsToRead()
        let unreadable = accounts.filter { failures[$0.id] != nil }
            .flatMap { accountCalendars[$0.id] ?? [] }.map(\.id)
        var refused = false
        for range in ranges {
            var read = RangeRead(failed: Set(unreadable), readAt: .now)
            await withTaskGroup(of: (CalendarKey, Result<[CalendarEvent], Error>).self) { group in
                for (calendar, transport) in targets {
                    group.addTask {
                        do {
                            return (calendar.id, .success(try await transport.events(in: calendar, from: range.start, to: range.end)))
                        } catch {
                            return (calendar.id, .failure(error))
                        }
                    }
                }
                for await (key, result) in group {
                    switch result {
                    case let .success(events):
                        read.events[key] = events.filter { $0.overlaps(range) }
                    case let .failure(error):
                        read.failed.insert(key)
                        let failure = Self.failure(error)
                        if failure.kind == .signInRequired, generation == self.generation {
                            failures[key.accountID] = failure
                            refused = true
                        }
                    }
                }
            }
            guard generation == self.generation else { return }
            reads[range] = read
            mergeEvents(range)
        }
        if refused { mergeCalendars() }
    }

    /// The calendars whose events are read: each shown calendar of an account that answered, and the Mac's copy of
    /// a shown calendar too, so it can stand in at once.
    private func calendarsToRead() -> [(CalendarInfo, any CalendarAccountTransport)] {
        let byKey = Dictionary(accountCalendars.values.flatMap { $0 }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return accounts.filter { failures[$0.id] == nil }.flatMap { account -> [(CalendarInfo, any CalendarAccountTransport)] in
            guard let transport = transports[account.id] else { return [] }
            return (accountCalendars[account.id] ?? []).filter { calendar in
                let shown = copies[calendar.id].flatMap { byKey[$0] } ?? calendar
                return shown.isShownByDefault
            }.map { ($0, transport) }
        }
    }

    // MARK: - Merging

    private func mergeCalendars() {
        copies = Self.copies(in: accounts, calendars: accountCalendars)
        let merged = accounts.flatMap { account in
            (accountCalendars[account.id] ?? []).filter { calendar in
                // The Mac's copy is listed only while its connector's account cannot be read.
                guard let direct = copies[calendar.id] else { return true }
                return failures[direct.accountID] != nil
            }
        }
        if merged != calendars { calendars = merged }
    }

    private func mergeEvents(_ range: DateInterval) {
        guard let read = reads[range] else {
            shownEvents[range] = nil
            return
        }
        var events: [CalendarEvent] = []
        for (key, list) in read.events {
            // The Mac's copy stands in only where its connector could not read the calendar.
            if let direct = copies[key], !read.failed.contains(direct) { continue }
            events += list
        }
        events.sort { first, second in
            if first.start != second.start { return first.start < second.start }
            if first.isAllDay != second.isAllDay { return first.isAllDay }
            return first.title.localizedStandardCompare(second.title) == .orderedAscending
        }
        if shownEvents[range] != events { shownEvents[range] = events }
    }

    /// The Mac's calendars that are another way to a calendar a connector reads, to that calendar: the Mac calendar
    /// whose account in Calendar is the connector account's address and whose name is the calendar's (its own name
    /// or the service's). Only an exact match counts, the address in any case, and only when the connector account
    /// has one calendar of that name.
    static func copies(in accounts: [CalendarAccount], calendars: [UUID: [CalendarInfo]]) -> [CalendarKey: CalendarKey] {
        var direct: [String: [String: [CalendarKey]]] = [:]
        for account in accounts where account.provider != .apple {
            guard let address = account.address?.lowercased() else { continue }
            for calendar in calendars[account.id] ?? [] {
                for name in Set([calendar.name, calendar.serviceName].compactMap { $0 }) {
                    direct[address, default: [:]][name, default: []].append(calendar.id)
                }
            }
        }
        var copies: [CalendarKey: CalendarKey] = [:]
        for account in accounts where account.provider == .apple {
            for calendar in calendars[account.id] ?? [] {
                guard let source = calendar.source?.lowercased(),
                      let matches = direct[source]?[calendar.name], matches.count == 1 else { continue }
                copies[calendar.id] = matches[0]
            }
        }
        return copies
    }

    // MARK: - Keeping

    private func isFresh(_ range: DateInterval) -> Bool {
        if loading.contains(range) { return true }
        guard let read = reads[range] else { return false }
        return read.readAt.duration(to: .now) < refreshInterval
    }

    /// Forgets the ranges no screen shows that are older than `refreshInterval`, or past the few kept.
    private func prune() {
        let shown = Set(viewers.values)
        let unshown = reads.filter { !shown.contains($0.key) }.sorted { $0.value.readAt > $1.value.readAt }
        for (index, entry) in unshown.enumerated()
        where index >= Self.keptUnshownRanges || entry.value.readAt.duration(to: .now) >= refreshInterval {
            reads[entry.key] = nil
            shownEvents[entry.key] = nil
        }
    }

    private func startRefreshing() {
        guard refreshing == nil else { return }
        let interval = refreshInterval
        refreshing = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }

    private func forget() {
        generation += 1
        refreshing?.cancel()
        refreshing = nil
        accounts = []
        transports = [:]
        accountCalendars = [:]
        failures = [:]
        calendars = []
        copies = [:]
        reads = [:]
        shownEvents = [:]
        loading = []
        viewers = [:]
    }

    private static func failure(_ error: Error) -> CalendarFailure {
        if case OAuthAPISession.Failure.signInRequired = error {
            return CalendarFailure(kind: .signInRequired, message: L10n.string("Sign in to this account again in Settings › Connectors."))
        }
        return error as? CalendarFailure ?? CalendarFailure(kind: .unavailable, message: error.localizedDescription)
    }
}
