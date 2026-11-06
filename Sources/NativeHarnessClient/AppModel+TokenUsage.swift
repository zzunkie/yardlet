import Foundation

/// Token counting follows Settings › Usage › Count token usage: on, the ledger reads Claude Code's
/// and Codex's transcripts as they are written; off, it stops and deletes its counts. The Home band
/// and the usage page read the overview below in their own bodies.
extension AppModel {
    /// `watch` is the platform's file watch (`TokenUsageWatcher.watch` on the Mac).
    func startTokenUsage(defaults: UserDefaults = .yardlet, watch: TokenUsageWatch?) {
        guard tokenUsagePreferenceObserver == nil else { return }
        tokenUsage.watch = watch
        nonisolated(unsafe) let watched = defaults
        tokenUsagePreferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                // Any setting posts this; only this one changes anything here.
                guard let self, TokenUsagePreference.isOn(in: watched) != self.tokenUsage.isEnabled else { return }
                self.followTokenUsage(defaults: watched)
            }
        }
        followTokenUsage(defaults: defaults)
    }

    func followTokenUsage(defaults: UserDefaults = .yardlet) {
        tokenUsage.setEnabled(TokenUsagePreference.isOn(in: defaults), roots: tokenUsageRoots()) { [weak self] sessions in
            await self?.tokenUsageAccounts(for: sessions) ?? TokenUsageLedger.Attribution()
        }
    }

    /// Claude Code's `projects` and Codex's `sessions` of the default logins and of every saved account
    /// folder that keeps its own (most link to the default one's, which counts once).
    func tokenUsageRoots() -> TokenUsageLedger.Roots {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func folders(_ harness: HarnessKind, _ defaultHome: String, _ child: String) -> [URL] {
            ([home.appending(path: defaultHome)] + connections.connections(for: harness).compactMap {
                $0.homePath.map { URL(filePath: $0, directoryHint: .isDirectory) }
            }).map { $0.appending(path: child, directoryHint: .isDirectory) }
        }
        return TokenUsageLedger.Roots(claude: folders(.claudeCode, ".claude", "projects"),
                                      codex: folders(.codex, ".codex", "sessions"))
    }

    /// The accounts the sessions ran on, as the Usage lines name them: a task's own account, and the
    /// default login for anything Yardlet did not start.
    func tokenUsageAccounts(for sessions: Set<String>) -> TokenUsageLedger.Attribution {
        let names = MenuBarMenuProjection.accountNames(
            choices: connections.menuBarUsageChoices(for: HarnessCatalog.builtIns.map(\.id)))
        var accounts: [String: String] = [:]
        for session in store.sessions {
            guard let provider = session.providerSessionID, sessions.contains(provider),
                  let name = names[session.connection?.id ?? AccountChoice.nativeID(for: session.harness)] else { continue }
            accounts[provider] = name
        }
        var defaults: [HarnessKind: String] = [:]
        for harness in HarnessCatalog.builtIns.map(\.id) {
            defaults[harness] = names[AccountChoice.nativeID(for: harness)]
        }
        return TokenUsageLedger.Attribution(accounts: accounts, defaults: defaults)
    }

    /// The accounts' limits as the Usage lines read them, each window with when it runs out at the pace
    /// of its readings in the last hour, where that comes before it resets.
    func tokenUsageLimitLines(now: Date = Date()) -> [TokenUsageLimitLine] {
        let accounts = MenuBarMenuProjection.limitAccounts(
            choices: connections.menuBarUsageChoices(for: HarnessCatalog.builtIns.map(\.id)))
        return accounts.map { account in
            var runsOutAt: [String: Date] = [:]
            for metric in account.metrics {
                let key = account.id + "|" + metric.id
                if let used = metric.usedFraction, let checkedAt = account.checkedAt {
                    tokenUsage.pace.record(key, used: used, resetsAt: metric.resetsAt, at: checkedAt)
                }
                runsOutAt[metric.id] = tokenUsage.pace.runsOutAt(key, now: now)
            }
            return TokenUsageLimitLine(id: account.id, account: account.name, address: account.address,
                                       harness: account.harness, windows: account.metrics, runsOutAt: runsOutAt)
        }
    }

    /// What the Home band and Settings › Usage draw. Read inside their bodies, so only they redraw when a
    /// new count or reading comes.
    func tokenUsageOverview() -> TokenUsageOverview {
        let summary = tokenUsage.isEnabled ? tokenUsage.summary : nil
        let names = TokenUsageNames(model: self)
        return TokenUsageOverview(
            days: summary?.days ?? [], limits: tokenUsageLimitLines(), updatedAt: summary?.updatedAt ?? Date(),
            rows: { range, grouping in
                guard let groups = summary?.groups[range] else { return [] }
                return self.tokenUsageRows(groups, grouping: grouping, names: names)
            })
    }

    /// What the rows of `tokenUsageOverview()` read right now, to tell whether a copy of them still stands.
    func tokenUsageRowsInputs() -> TokenUsageRowsInputs {
        TokenUsageRowsInputs(groups: tokenUsage.isEnabled ? tokenUsage.summary?.groups : nil,
                             projects: projects.projects,
                             tasks: store.sessions.map(TokenUsageRowsInputs.TaskName.init))
    }

    /// One range's counts grouped one way and named: models by name, tasks by title (a session Yardlet
    /// did not start by its folder), projects as the sidebar groups them, accounts as the Usage lines.
    func tokenUsageRows(_ groups: [TokenUsageGrouping: [TokenUsageSummary.Key: TokenUsageAmount]],
                        grouping: TokenUsageGrouping, names: TokenUsageNames) -> [TokenUsageRow] {
        var rows: [String: TokenUsageRow] = [:]
        func add(_ id: String, _ title: String, detail: String? = nil, harness: HarnessKind?, _ amount: TokenUsageAmount) {
            rows[id, default: TokenUsageRow(id: id, title: title, detail: detail, harness: harness,
                                            amount: TokenUsageAmount())].amount.add(amount)
        }
        switch grouping {
        case .model, .account:
            for (key, amount) in groups[grouping] ?? [:] {
                let title = grouping == .model ? TokenUsageModelName.title(key.value) : key.value
                let detail = grouping == .model && TokenUsagePrices.model(key.value) == nil ? L10n.string("No price") : nil
                add("\(key.harness?.rawValue ?? "")|\(key.value)", title.isEmpty ? L10n.string("Unknown") : title,
                    detail: detail, harness: key.harness, amount)
            }
        case .task, .project:
            func folderName(_ key: TokenUsageSummary.Key) -> String {
                URL(filePath: key.folder, directoryHint: .isDirectory).lastPathComponent
            }
            for (key, amount) in groups[.task] ?? [:] {
                let session = names.sessions[key.value]
                if grouping == .task {
                    if let session {
                        add(session.id.uuidString, session.title, detail: names.placeName(session), harness: session.harness, amount)
                    } else {
                        add(key.value, key.folder.isEmpty ? L10n.string("Unknown") : folderName(key),
                            detail: L10n.string("Not started in Yardlet"), harness: key.harness, amount)
                    }
                } else {
                    let project = session.flatMap { ProjectProjection.project(for: $0, in: names.projects) }
                        ?? names.project(containing: key.folder)
                    let name = project?.name ?? session.map(names.placeName) ?? folderName(key)
                    add(project?.id.uuidString ?? name, name.isEmpty ? L10n.string("Unknown") : name, harness: nil, amount)
                }
            }
        }
        return rows.values.sorted {
            ($0.amount.cost ?? 0, $0.amount.total) > ($1.amount.cost ?? 0, $1.amount.total)
        }
    }
}

/// What usage rows are named from. Reading it takes a pass over every task, and a folder's project a walk
/// up its parents, so all the rows of one overview share it. It reads nothing until a row asks, which
/// keeps the Home band, which draws no rows, from following the tasks and projects.
@MainActor
final class TokenUsageNames {
    private let model: AppModel
    private var folderProjects: [String: Project?] = [:]

    init(model: AppModel) {
        self.model = model
    }

    private(set) lazy var sessions = Dictionary(
        model.store.sessions.compactMap { session in session.providerSessionID.map { ($0, session) } },
        uniquingKeysWith: { first, _ in first })
    private(set) lazy var placeName = model.taskPlaceNames()
    private(set) lazy var projects = model.projects.projects

    /// The project a folder is in: its own root or the nearest folder above it that is one. A history's
    /// folders share their parents, so each is looked at once.
    func project(containing folder: String) -> Project? {
        if let known = folderProjects[folder] { return known }
        var project: Project?
        if !folder.isEmpty {
            let url = URL(filePath: folder, directoryHint: .isDirectory).standardizedFileURL
            if url.path != "/" {
                project = ProjectProjection.project(containingRoot: url, in: projects)
                    ?? self.project(containing: url.deletingLastPathComponent().path)
            }
        }
        folderProjects[folder] = .some(project)
        return project
    }
}

/// Everything usage rows read: the counts, the projects and what a row shows of each task. A task's
/// status and recency change all through a turn and name nothing, so they are left out.
struct TokenUsageRowsInputs: Equatable {
    struct TaskName: Equatable {
        let id: UUID
        let providerSessionID: String?
        let title: String
        let harness: HarnessKind
        let projectID: UUID?
        let isMovedToChats: Bool
        let workspaceURL: URL
        let originWorkspacePath: String?

        init(_ session: SessionRecord) {
            id = session.id
            providerSessionID = session.providerSessionID
            title = session.title
            harness = session.harness
            projectID = session.projectID
            isMovedToChats = session.isMovedToChats
            workspaceURL = session.workspaceURL
            originWorkspacePath = session.originWorkspacePath
        }
    }

    let groups: [TokenUsageRange: [TokenUsageGrouping: [TokenUsageSummary.Key: TokenUsageAmount]]]?
    let projects: [Project]
    let tasks: [TaskName]
}

/// A model id as people read it: `claude-opus-5-5` as "Claude Opus 5.5", `gpt-6.1-sol` as "GPT-6.1 Sol".
enum TokenUsageModelName {
    static func title(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard let first = parts.first else { return id }
        if first == "claude" {
            let words = parts.dropFirst().prefix { !$0.allSatisfy(\.isNumber) }.map { $0.capitalized }
            let version = parts.dropFirst(1 + words.count).joined(separator: ".")
            return (["Claude"] + words + (version.isEmpty ? [] : [version])).joined(separator: " ")
        }
        if first == "gpt", parts.count >= 2 {
            return (["GPT-" + parts[1]] + parts.dropFirst(2).map { $0.capitalized }).joined(separator: " ")
        }
        return id
    }
}
