import Foundation

/// Chrome's Memory Saver for the tasks' browser tabs (docs/BROWSER_HOST.md §3 "Memory saver"): a tab no one has seen
/// for a while is discarded, keeping its address, title, icon, place and history, and its page loads again when the
/// tab is shown or the agent uses it. The levels, times and the pages kept are Chrome's (Chromium's
/// MemorySaverModePolicy, DiscardEligibilityPolicy and UrgentPageDiscardingPolicy); the host checks what only the
/// engine knows (`BrowserHostCommand.discard`). A tab the agent opened that no one has seen goes sooner
/// (`Timing.unseenAgentTabIdle`).
enum BrowserMemorySaver {
    /// Chrome's Memory Saver levels (Settings › Performance "Moderate", "Balanced", "Maximum"; Chromium's
    /// MemorySaverModeAggressiveness kConservative, kMedium and kAggressive). Balanced is Chrome's default.
    enum Level: String, CaseIterable, Identifiable, Sendable {
        case moderate, balanced, maximum

        var id: String { rawValue }

        /// Chrome's names for the levels.
        var title: String {
            switch self {
            case .moderate: L10n.string("Moderate")
            case .balanced: L10n.string("Balanced (recommended)")
            case .maximum: L10n.string("Maximum")
            }
        }

        /// The level's line under its name, as Chrome has one, with its time.
        var detail: String {
            switch self {
            case .moderate: L10n.string("Tabs unused for 6 hours")
            case .balanced: L10n.string("Tabs unused for 4 hours")
            case .maximum: L10n.string("Tabs unused for 2 hours")
            }
        }

        /// A tab hidden this long is discarded (MemorySaverModePolicy::GetTimeBeforeDiscardForCurrentMode).
        var hiddenBeforeDiscard: Duration {
            switch self {
            case .moderate: .seconds(6 * 3600)
            case .balanced: .seconds(4 * 3600)
            case .maximum: .seconds(2 * 3600)
            }
        }

        /// A tab its person brought in front more often than this is not discarded for being hidden
        /// (MemorySaverModePolicy::GetMaxNumRevisitsForCurrentMode).
        var maxRevisits: Int {
            switch self {
            case .moderate: 5
            case .balanced, .maximum: 15
            }
        }
    }

    struct Timing: Equatable, Sendable {
        /// Replaces the level's time (`Level.hiddenBeforeDiscard`); QA runs shorten it.
        var hiddenBeforeDiscard: Duration?
        /// While the Mac's memory is critical Chrome discards one tab at a time this often (its urgent discarding's
        /// repeating timer), never one hidden more recently than `urgentProtection` (kNonVisiblePagesUrgentProtectionTime).
        var urgentInterval: Duration = .seconds(5)
        var urgentProtection: Duration = .seconds(10 * 60)
        /// A tab the agent opened that no panel has shown on screen is discarded once the agent has let it go this long
        /// (Chrome's kNonVisiblePagesUrgentProtectionTime: how long it keeps a hidden tab even while memory is critical).
        var unseenAgentTabIdle: Duration = .seconds(10 * 60)
        /// How often Yardlet looks for tabs past their time.
        var sweepInterval: Duration = .seconds(60)
        /// A tab the host kept (its page was one Chrome keeps) is not asked about again before this.
        var retryAfter: Duration = .seconds(30 * 60)

        func hiddenBeforeDiscard(at level: Level) -> Duration {
            hiddenBeforeDiscard ?? level.hiddenBeforeDiscard
        }
    }

    /// How many tabs one sweep asks the host about.
    static let discardsPerSweep = 4
    /// A page's title or icon that changes while it is hidden, later than this after its document began, is the
    /// page working in the background (a chat's unread count), which Chrome keeps.
    static let backgroundActivityGrace: Duration = .seconds(5)
    /// How long the agent's tools wait for a discarded page to load again before they go on.
    static let restoreWait: Duration = .seconds(30)

    /// What Yardlet knows of one hidden tab.
    struct Candidate: Equatable {
        var tab: BrowserTabID
        /// How long the tab has been hidden, not counting the Mac's sleep (Chrome's elapsed_not_suspended).
        var hidden: Duration
        /// A reason Chrome keeps the page whatever the memory: shown, in use, asking the person, typed into …
        var isProtected: Bool
        /// A reason Chrome keeps the page only from the discards that are not urgent: it worked in the background.
        var isProtectedFromProactive: Bool
        /// The host kept the tab within `Timing.retryAfter`.
        var refusedRecently: Bool
        /// How many times the person brought the tab in front of its task (Chrome's TabRevisitTracker num_revisits).
        var revisits = 0
        /// For a tab the agent opened that no panel has shown on screen, how long since the agent let it go: since it
        /// was hidden or since the agent's turn that used it ended, whichever came later. Nil for any other tab.
        var unseenAgentIdle: Duration?
    }

    /// The tabs to ask the host to discard now, longest hidden first: when memory is critical one tab hidden past
    /// `urgentProtection`, else up to `discardsPerSweep` past the level's time or, unseen agent tabs, past
    /// `unseenAgentTabIdle`.
    static func picks(_ candidates: [Candidate], urgent: Bool, level: Level = .balanced,
                      timing: Timing = Timing()) -> [BrowserTabID] {
        let eligible = candidates.filter { candidate in
            guard !candidate.isProtected, !candidate.refusedRecently else { return false }
            if urgent { return candidate.hidden >= timing.urgentProtection }
            guard !candidate.isProtectedFromProactive else { return false }
            if let idle = candidate.unseenAgentIdle, idle >= timing.unseenAgentTabIdle { return true }
            return candidate.hidden >= timing.hiddenBeforeDiscard(at: level) && candidate.revisits <= level.maxRevisits
        }
        let order = eligible.sorted { $0.hidden > $1.hidden }.map(\.tab)
        return Array(order.prefix(urgent ? 1 : discardsPerSweep))
    }

    /// Chrome keeps pages that are not on the web: an empty address, about:, file:, the PDF viewer … (kNotWebOrInternal
    /// and kInvalidURL: Chrome discards http, https, data and its own chrome: pages, which Yardlet's tabs never show).
    static func isWebPage(_ address: String?) -> Bool {
        guard let address, let scheme = URL(string: address)?.scheme?.lowercased() else { return false }
        return ["http", "https", "data"].contains(scheme)
    }
}
