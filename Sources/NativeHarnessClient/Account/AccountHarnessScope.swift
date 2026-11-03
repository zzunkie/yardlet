import Foundation

/// Which harnesses the accounts list covers. Before the user picks a filter it shows the harnesses
/// in use, so runtimes that merely happen to be installed stay out of the way; the filter still
/// reaches every harness the list can show.
enum AccountHarnessScope {
    /// What the app knows about how harnesses are used, outside the accounts store.
    struct Usage: Equatable {
        var withTasks: Set<HarnessKind>
        var chosenForNewTask: HarnessKind?
        /// Harnesses an agent ran a subagent on (`run_agent`) within `SubagentUse.window`.
        var withSubagents: Set<HarnessKind> = []
    }

    /// The filter the accounts list starts with.
    enum Filter: Hashable {
        case inUse
        case all
        case harness(HarnessKind)

        var harness: HarnessKind? {
            if case let .harness(value) = self { value } else { nil }
        }
    }

    /// Harnesses the list can show at all: installed, with saved accounts, or with a signed-in
    /// default login. Catalog order.
    static func available(
        catalog: [HarnessKind],
        installed: Set<HarnessKind>,
        savedAccounts: Set<HarnessKind>,
        signedInDefaults: Set<HarnessKind>
    ) -> [HarnessKind] {
        catalog.filter { installed.contains($0) || savedAccounts.contains($0) || signedInDefaults.contains($0) }
    }

    /// The available harnesses in use: with tasks, with subagents run lately, with saved accounts,
    /// or chosen for the next new task. When none qualifies yet (a new install), every available
    /// harness.
    static func inUse(
        available: [HarnessKind],
        withTasks: Set<HarnessKind>,
        withSubagents: Set<HarnessKind> = [],
        savedAccounts: Set<HarnessKind>,
        chosenForNewTask: HarnessKind?
    ) -> [HarnessKind] {
        let used = withTasks.union(withSubagents).union(savedAccounts).union(chosenForNewTask.map { [$0] } ?? [])
        let inUse = available.filter(used.contains)
        return inUse.isEmpty ? available : inUse
    }

    /// The harnesses whose accounts a filter lists.
    static func harnesses(for filter: Filter, available: [HarnessKind], inUse: [HarnessKind]) -> [HarnessKind] {
        switch filter {
        case .inUse: inUse
        case .all: available
        case let .harness(harness): [harness]
        }
    }

    /// When an agent last ran a subagent on each harness (`run_agent`), so a harness used only that
    /// way counts as in use for `window`. One preference keeps the harness and the time and nothing
    /// else. An entry older than `window` is dropped when a run is noted or Yardlet starts, and the
    /// preference goes once none is left.
    enum SubagentUse {
        static let key = "Yardlet.subagentHarnessUse"
        static let window: TimeInterval = 30 * 24 * 60 * 60

        static func note(_ harness: HarnessKind, at date: Date = Date(), in defaults: UserDefaults) {
            var recent = entries(in: defaults, now: date)
            recent[harness.rawValue] = date
            defaults.set(recent, forKey: key)
        }

        static func harnesses(in defaults: UserDefaults, now: Date = Date()) -> Set<HarnessKind> {
            Set(entries(in: defaults, now: now).keys.map(HarnessKind.init(rawValue:)))
        }

        static func prune(in defaults: UserDefaults, now: Date = Date()) {
            guard let saved = defaults.dictionary(forKey: key) else { return }
            let recent = entries(in: defaults, now: now)
            guard recent.count != saved.count else { return }
            if recent.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(recent, forKey: key) }
        }

        private static func entries(in defaults: UserDefaults, now: Date) -> [String: Date] {
            (defaults.dictionary(forKey: key) ?? [:]).compactMapValues { $0 as? Date }
                .filter { now.timeIntervalSince($0.value) < window }
        }
    }
}
