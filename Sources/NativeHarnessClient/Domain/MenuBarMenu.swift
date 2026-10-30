import Foundation

/// What the menu bar item's menu lists, after the Codex app's tray menu (ChatGPT.app `app.asar`,
/// `.vite/build/main-*.js`, `getNativeTrayMenuItems` fed by the renderer's `trayMenuThreads`):
/// sections Running, Unread, Pinned and Recent, each with its first three tasks and the rest under
/// More, then Usage. Sections without tasks are left out. Each task row carries the sidebar's state
/// mark, and Usage lists one line per account. Built when the menu opens, never while it is closed.
struct MenuBarMenu: Equatable, Sendable {
    enum SectionKind: String, CaseIterable, Sendable {
        case running
        case unread
        case pinned
        case recent

        /// Codex `trayMenu.runningThreads` "Running", `unreadThreads` "Unread", `pinnedThreads`
        /// "Pinned", `recentThreads` "Recent".
        var title: String {
            switch self {
            case .running: L10n.string("Running")
            case .unread: L10n.string("Unread")
            case .pinned: L10n.string("Pinned")
            case .recent: L10n.string("Recent")
            }
        }
    }

    struct TaskRow: Equatable, Sendable {
        let sessionID: UUID
        /// The task's title, cut as the Codex menu cuts it (`MenuBarMenuProjection.menuTitle`).
        let title: String
        /// Its project, or "Chats" for a chat (Codex `sublabel`: the project or `projectlessThreads`).
        let subtitle: String
        /// The mark the task's sidebar row ends with (`SidebarTaskIndicatorProjection.status`); nil for
        /// a task with nothing to show.
        var status: SidebarTaskStatus? = nil
    }

    struct Section: Equatable, Sendable {
        let kind: SectionKind
        /// The rows the section shows (Codex `e7`, three).
        let rows: [TaskRow]
        /// The rest, under More.
        let more: [TaskRow]
    }

    /// One account under Usage: the account as its title, and under it the harnesses that use it,
    /// what is left of its five-hour window and of its weekly window, and how old the reading is
    /// once it is old.
    struct UsageAccount: Equatable, Sendable {
        /// The harness whose mark the line shows (the first, for an account several harnesses use).
        let harness: HarnessKind
        let line: String
        /// The account in full and each window with its reset time, for the line's help.
        let help: String
        /// The line under the title (`NSMenuItem.subtitle`).
        var detail: String = ""
    }

    /// A staged build ready to install (`YardletStagedUpdate`): one line before Quit, the sidebar's
    /// strip over its account button too.
    enum UpdateLine: Equatable, Sendable {
        /// "Restart to update", the build in its help.
        case ready(build: String?)
        /// The update waits for tasks to finish, as the app menu's dimmed "Waiting to Update" says.
        case waiting

        var title: String {
            switch self {
            case .ready: L10n.string("Restart to update")
            case .waiting: L10n.string("Waiting to Update")
            }
        }

        /// The Claude app's strip says "Relaunch to update · v1.2.3"; a staged build has a commit
        /// rather than a version.
        var help: String {
            switch self {
            case let .ready(build): [title, build].compactMap { $0 }.joined(separator: " · ")
            case .waiting: L10n.string("Yardlet installs the update and restarts once no task is running.")
            }
        }
    }

    var sections: [Section] = []
    var usage: [UsageAccount] = []
    var update: UpdateLine?
    /// The screen is kept unlocked while tasks work: the menu says so first, with a way to stop it.
    var keepsScreenAwake = false
    /// The setting is on, but a battery under 20% lets the screen lock: the menu says so first.
    var screenAwakePausedForBattery = false
    /// The Mac stays awake with its lid closed while tasks work: the menu says so first, with a way
    /// to stop it.
    var keepsAwakeWithLidClosed = false
    /// The lid setting is on, but the battery or the heat lets the Mac sleep: the menu says so first.
    var lidAwakePause: LidAwakePause?

    static let empty = MenuBarMenu()
}

/// Why "Keep tasks working with the lid closed" lets the Mac sleep for now (`RunningWorkActivity`).
enum LidAwakePause: Equatable, Sendable {
    /// On a battery under 20%, until the Mac is on power.
    case battery
    /// At a critical heat, until the Mac cools down.
    case heat
}

enum MenuBarMenuProjection {
    /// Rows a section shows before More (Codex `e7`).
    static let rowsPerSection = 3
    /// The longest title shown whole (Codex `DXe`); a longer one keeps 34 characters and "…".
    static let titleLimit = 35

    /// The menu for the tasks the sidebar lists. Attention follows the one definition the sidebar,
    /// `⌥⌘A`, the activity view and the Dock badge read (`TaskAttentionProjection`), in its order:
    ///
    /// - Running: tasks waiting on the person or working (`waiting` first, then `active`), as a Codex
    ///   thread waiting for an approval is still running.
    /// - Unread: tasks with a finished result the person has not read.
    /// - Pinned: the tasks under Pinned in the sidebar, most recently active first, whatever their
    ///   state (Codex lists a pinned thread here as well as under Running or Unread).
    /// - Recent: every other task, most recently active first, leaving out the unread ones (Codex
    ///   `recentThreads` drops unread keys only).
    static func menu(
        sessions: [SessionRecord],
        pinnedIDs: Set<UUID>,
        details: [UUID: TaskAttentionDetail] = [:],
        shellBusy: Set<UUID> = [],
        place: (SessionRecord) -> String,
        usage: [MenuBarMenu.UsageAccount] = []
    ) -> MenuBarMenu {
        func row(_ session: SessionRecord) -> MenuBarMenu.TaskRow {
            MenuBarMenu.TaskRow(
                sessionID: session.id, title: menuTitle(session.title), subtitle: place(session),
                status: SidebarTaskIndicatorProjection.status(
                    of: session, detail: details[session.id], isShellBusy: shellBusy.contains(session.id)))
        }
        let listed = TaskAttentionProjection.activityList(in: sessions, details: details, shellBusy: shellBusy)
        func state(_ session: SessionRecord) -> TaskAttentionState {
            TaskAttentionProjection.state(of: session, detail: details[session.id],
                                          isShellBusy: shellBusy.contains(session.id))
        }
        let running = listed.filter { state($0) != .unread }
        let unread = listed.filter { state($0) == .unread }
        let unreadIDs = Set(unread.map(\.id))
        let byRecency = sessions.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let pinned = byRecency.filter { pinnedIDs.contains($0.id) }
        let recent = byRecency.filter { !pinnedIDs.contains($0.id) && !unreadIDs.contains($0.id) }

        let lists: [(MenuBarMenu.SectionKind, [SessionRecord])] = [
            (.running, running), (.unread, unread), (.pinned, pinned), (.recent, recent),
        ]
        let sections = lists.compactMap { kind, sessions -> MenuBarMenu.Section? in
            guard !sessions.isEmpty else { return nil }
            let rows = sessions.map(row)
            return MenuBarMenu.Section(kind: kind, rows: Array(rows.prefix(rowsPerSection)),
                                       more: Array(rows.dropFirst(rowsPerSection)))
        }
        return MenuBarMenu(sections: sections, usage: usage)
    }

    /// A title as the Codex menu shows it: whole up to 35 characters, else its first 34 and "…".
    static func menuTitle(_ title: String) -> String {
        let characters = Array(title)
        guard characters.count > titleLimit else { return title }
        let kept = String(characters.prefix(titleLimit - 1))
        return kept.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + "…"
    }

    // MARK: - Usage

    /// The Usage lines, one per account as Settings › Accounts groups accounts (an account two
    /// harnesses use is one line), from each account's latest reading; an account without a limit is
    /// left out. Nothing here checks an account: these are the readings Yardlet already has
    /// (`account-snapshots.json` and the checks it runs), and the menus that show them check them as
    /// they open (`ProviderConnectionStore.checkUsageAccounts`).
    ///
    /// A line's title is the account in full, with its organization when that is a team's. Under
    /// it, the harnesses that use it in words (the mark alone did not tell one address's Claude and
    /// Codex accounts apart), then the five-hour and weekly windows as the Codex app's Usage menu
    /// words them ("{window} 72% left"); a reading with neither lists its windows by their own
    /// names, and the resets of them the account holds follow. A reading an hour old or older ends
    /// with its age, and one whose latest check could not
    /// finish says so, in the account list's words, before its age ("Couldn't refresh · 2 days ago").
    /// The help has each window with its reset time.
    static func usage(choices: [AccountChoice], status: (AccountChoice) -> AccountReadingStatus? = { _ in nil },
                      isChecking: (AccountChoice) -> Bool = { _ in false }, now: Date = Date(),
                      locale: Locale = .current, timeZone: TimeZone = .current) -> [MenuBarMenu.UsageAccount] {
        usageReadings(choices: choices).map { account in
            let label = account.group.identity.displayLabel
            let windows = account.metrics.map { (kind: windowKind(of: $0), window: AccountLimitWindow(metric: $0)) }
            var parts = [LimitWindowKind.fiveHour, .weekly].compactMap { kind in
                windows.first { $0.kind == kind }.map { "\(kind.title) \(leftText($0.window))" }
            }
            if parts.isEmpty { parts = windows.map { "\($0.window.name) \(leftText($0.window))" } }
            // As the Codex app's profile menu counts them ("2 available resets").
            if let resets = account.group.choices.compactMap({ $0.snapshot?.usageResets?.availableCount }).max(),
               resets > 0 {
                parts.append(UsageResetText.available(resets))
            }
            let harnesses = account.group.harnesses.map(\.displayName).joined(separator: ", ")
            var detail = [harnesses] + parts
            let freshness = AccountFreshnessProjection.freshness(of: account.group.choices, status: status,
                                                                 isChecking: isChecking)
            if freshness.status == .checkFailed, !freshness.isChecking, let checkedAt = freshness.checkedAt {
                detail += [L10n.string("Couldn't refresh"), age(of: checkedAt, now: now, locale: locale)]
            } else if let checkedAt = account.group.usageBlocks.compactMap(\.checkedAt).max(),
               now.timeIntervalSince(checkedAt) >= staleAfter {
                detail.append(age(of: checkedAt, now: now, locale: locale))
            }
            return MenuBarMenu.UsageAccount(
                harness: account.group.harnesses[0],
                line: account.name,
                help: ([[label, harnesses].joined(separator: " · ")] + windows.map {
                    limitLine($0.window, now: now, locale: locale, timeZone: timeZone)
                }).joined(separator: "\n"),
                detail: detail.joined(separator: " · ")
            )
        }
    }

    /// A reading older than this says its age on its line: an hour is a fifth of the shortest window.
    static let staleAfter: TimeInterval = 60 * 60

    /// The Codex app's "{remainingPercent} left" (`72% left`), "–" without a figure.
    static func leftText(_ window: AccountLimitWindow) -> String {
        window.remainingPercent.map { L10n.format("%lld%% left", Int64(min(max($0, 0), 100).rounded())) } ?? "–"
    }

    /// "11 hr. ago", as the account list's "Updated 11 hr. ago" says it.
    static func age(of date: Date, now: Date, locale: Locale) -> String {
        RelativeTime.ago(date, relativeTo: now, locale: locale)
    }

    /// Each account with a limit and its latest reading, named as a Usage line names it: the account
    /// in full, with a team's organization after it, as one address can be two accounts (a personal
    /// plan and a team's).
    private static func usageReadings(choices: [AccountChoice])
        -> [(name: String, group: AccountGroup, metrics: [AccountUsageMetric])] {
        AccountGroupProjection.groups(from: choices.filter { !$0.quotas.isEmpty }).compactMap { group in
            let latest = group.usageBlocks.max { ($0.checkedAt ?? .distantPast) < ($1.checkedAt ?? .distantPast) }
            guard let latest, !latest.metrics.isEmpty, !group.harnesses.isEmpty else { return nil }
            let label = group.identity.displayLabel
            let organization = group.choices.lazy.compactMap {
                AccountIdentityProjection.sharedOrganization($0.snapshot?.accountOrganization, of: label)
            }.first
            return (organization.map { "\(label) (\($0))" } ?? label, group, latest.metrics)
        }
    }

    /// The windows with 10% or less left (`AccountLimitWindow.isNearlySpent`), in the Usage lines'
    /// words: the account's name, the window ("5h", "Weekly" or its own name) and the share left.
    static func nearlySpentWindows(choices: [AccountChoice]) -> [(account: String, window: String, remaining: String)] {
        usageReadings(choices: choices).flatMap { account in
            account.metrics.compactMap { metric -> (account: String, window: String, remaining: String)? in
                let window = AccountLimitWindow(metric: metric)
                guard window.remainingPercent != nil, window.isNearlySpent else { return nil }
                return (account.name, windowKind(of: metric)?.title ?? window.name, remainingText(window))
            }
        }
    }

    /// The two windows a Usage line names, as the Codex tray names them (`dli`: "5h", "Weekly").
    enum LimitWindowKind: Equatable, Sendable {
        case fiveHour
        case weekly

        var title: String {
            switch self {
            case .fiveHour: L10n.string("5h")
            case .weekly: L10n.string("Weekly")
            }
        }
    }

    /// Which window a reading is, from the name Yardlet gave it when it read it ("5 hour limit",
    /// "7 day limit", in English or Korean, after a Codex limit's name). A Claude limit for one
    /// model only ("Opus · 7 day limit") is neither.
    static func windowKind(of metric: AccountUsageMetric) -> LimitWindowKind? {
        let parts = metric.label.components(separatedBy: " · ")
        if metric.id.hasPrefix("claude:"), parts.count > 1 { return nil }
        let window = parts.last ?? metric.label
        func named(_ key: String, _ count: Double) -> Bool {
            [nil, "en", "ko"].contains { (language: String?) in
                let format = language.map { L10n.string(key, languageCode: $0) } ?? L10n.string(key)
                return window == String(format: format, count)
            }
        }
        if named("%.0f hour limit", 5) { return .fiveHour }
        if named("%.0f day limit", 7) { return .weekly }
        return nil
    }

    /// Codex `uli`: the share left, rounded; "–" without a figure.
    static func remainingText(_ window: AccountLimitWindow) -> String {
        window.remainingPercent.map { "\(Int(min(max($0, 0), 100).rounded()))%" } ?? "–"
    }

    /// Codex `settings.usage.limits.trayCompactLabel` "{window} {remaining}", with
    /// `trayCompactLabelWithReset` "{label} · {reset}" when the window has a reset time. The window
    /// is named as Settings › Accounts names it; the share left is rounded, "–" when unknown.
    static func limitLine(_ window: AccountLimitWindow, now: Date = Date(),
                          locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let label = "\(window.name) \(remainingText(window))"
        guard let resetsAt = window.resetsAt else { return label }
        return "\(label) · \(resetText(resetsAt, now: now, locale: locale, timeZone: timeZone))"
    }

    /// Codex `mli`: "now" once the time has passed, the time of day within a day, else the date.
    static func resetText(_ date: Date, now: Date = Date(), locale: Locale = .current,
                          timeZone: TimeZone = .current) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return RelativeTime.now(locale: locale) }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        if seconds < 24 * 60 * 60 {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        }
        return formatter.string(from: date)
    }
}

/// Settings › General › "Show in menu bar" (Codex `macMenuBarEnabled`): on unless turned off.
enum MenuBarPreference {
    static let key = "Yardlet.showInMenuBar"

    static func isShown(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}
