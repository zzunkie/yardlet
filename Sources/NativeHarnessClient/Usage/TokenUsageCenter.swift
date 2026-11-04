import Foundation
import Observation

/// Settings › Usage › Count token usage, on by default. Off, nothing is read and the counts are deleted.
enum TokenUsagePreference {
    static let key = "YardletTokenUsage"

    static func isOn(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

/// Tells which transcript files changed under some folders until it is stopped
/// (`Platform/macOS/TokenUsageWatcher`).
protocol TokenUsageWatching: AnyObject {
    func stop()
}

/// Starts watching the folders; `rescan` asks for every file to be looked at again.
typealias TokenUsageWatch = (_ roots: [URL], _ onChange: @escaping @Sendable (_ paths: [String], _ rescan: Bool) -> Void)
    -> (any TokenUsageWatching)?

/// The app's token counts on the main actor: what the ledger last summarized, published only when it
/// changed, so a streaming turn redraws the Home band and the usage page a few times a minute at most,
/// and nothing else.
@MainActor @Observable
final class TokenUsageCenter {
    private(set) var isEnabled = false
    /// The last 30 days as the ledger last read them; nil until the first read finishes.
    private(set) var summary: TokenUsageSummary?
    /// How many summaries changed what the views show, for the main thread's budget checks.
    @ObservationIgnored private(set) var publications = 0
    @ObservationIgnored let pace = TokenUsagePace()
    @ObservationIgnored private(set) var ledger: TokenUsageLedger?
    @ObservationIgnored private var watcher: (any TokenUsageWatching)?
    /// How file changes are watched, which the app's platform layer sets; without it the ledger reads
    /// only when asked (tests hand it their changes).
    @ObservationIgnored var watch: TokenUsageWatch?
    @ObservationIgnored private var midnight: Task<Void, Never>?
    @ObservationIgnored let directory: URL

    /// Today's tokens and their API-equivalent cost in one line, for the usage menus; nil while nothing
    /// is counted.
    var todayLine: String? {
        guard isEnabled, let today = summary?.days.last?.amount else { return nil }
        return TokenUsageFormat.today(today)
    }

    init(directory: URL, summary: TokenUsageSummary? = nil) {
        self.directory = directory
        self.summary = summary
        isEnabled = summary != nil
    }

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: YardletProduct.storageDirectoryName, directoryHint: .isDirectory)
            .appending(path: "usage", directoryHint: .isDirectory)
    }

    /// Starts counting the roots' transcripts, or stops and deletes what was counted. `resolve` names the
    /// accounts of the sessions each read counted.
    func setEnabled(_ isOn: Bool, roots: TokenUsageLedger.Roots,
                    resolve: @escaping TokenUsageLedger.Resolve = { _ in TokenUsageLedger.Attribution() }) {
        guard isOn != isEnabled else { return }
        isEnabled = isOn
        if isOn {
            start(roots: roots, resolve: resolve)
        } else {
            stop()
            summary = nil
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func receive(_ summary: TokenUsageSummary) {
        guard isEnabled, summary.days != self.summary?.days || summary.groups != self.summary?.groups else { return }
        publications += 1
        self.summary = summary
    }

    private func start(roots: TokenUsageLedger.Roots, resolve: @escaping TokenUsageLedger.Resolve) {
        let ledger = TokenUsageLedger(directory: directory, roots: roots, resolve: resolve)
        self.ledger = ledger
        // The first read of a long history takes a minute or two; it yields to what the person is doing.
        Task(priority: .utility) { [weak self] in
            await ledger.start { summary in
                Task { @MainActor in self?.receive(summary) }
            }
        }
        watcher = watch?(roots.all) { paths, rescan in
            Task {
                if rescan { await ledger.scanAll() } else { await ledger.changed(paths) }
            }
        }
        midnight = Task { [weak self] in
            while !Task.isCancelled {
                let calendar = Calendar.current
                let next = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date())
                try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow + 1)))
                guard !Task.isCancelled, let ledger = self?.ledger else { return }
                await ledger.republish()
            }
        }
    }

    private func stop() {
        watcher?.stop()
        watcher = nil
        midnight?.cancel()
        midnight = nil
        if let ledger { Task { await ledger.stop() } }
        ledger = nil
    }
}

/// How fast each limit window is being used, from the readings Yardlet already takes of it (the
/// account checks the usage lines make): the share used over the last hour, and when that pace would
/// spend the window. Kept in memory only; tokens never stand in for a limit's own reading.
final class TokenUsagePace {
    struct Reading: Equatable {
        let at: Date
        let used: Double
        let resetsAt: Date?
    }

    private var readings: [String: [Reading]] = [:]

    /// Readings at least this far apart give a pace; none older than `window` is used.
    static let span: TimeInterval = 15 * 60
    static let window: TimeInterval = 60 * 60

    func record(_ key: String, used: Double, resetsAt: Date?, at: Date) {
        var list = readings[key] ?? []
        guard list.last?.at != at else { return }
        list.append(Reading(at: at, used: used, resetsAt: resetsAt))
        list.removeAll { at.timeIntervalSince($0.at) > Self.window * 2 }
        readings[key] = list
    }

    /// When the window runs out at the pace of its readings within the last hour, if that comes before
    /// it resets and the latest reading is recent.
    func runsOutAt(_ key: String, now: Date) -> Date? {
        guard let list = readings[key], let latest = list.last,
              now.timeIntervalSince(latest.at) <= Self.window / 2 else { return nil }
        let sameWindow = list.filter { reading in
            switch (reading.resetsAt, latest.resetsAt) {
            case let (a?, b?): abs(a.timeIntervalSince(b)) < 120
            case (nil, nil): true
            default: false
            }
        }
        guard let earliest = sameWindow.first(where: { latest.at.timeIntervalSince($0.at) <= Self.window }),
              latest.at.timeIntervalSince(earliest.at) >= Self.span, latest.used > earliest.used else { return nil }
        let perSecond = (latest.used - earliest.used) / latest.at.timeIntervalSince(earliest.at)
        let out = latest.at.addingTimeInterval((1 - latest.used) / perSecond)
        guard out > now else { return nil }
        if let reset = latest.resetsAt, out >= reset { return nil }
        return out
    }
}
