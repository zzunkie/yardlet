import Foundation

/// A preset from `collaborationMode/list`. The installed App Server (0.157.1) lists Plan and
/// Default with `model: null`; as in the Codex app, a turn in a preset runs on the chat's own
/// model and effort, so the preset's model is only a fallback.
struct CodexCollaborationPreset: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let mode: String
    let model: String?
    let reasoningEffort: String?

    var id: String { [name, mode, model ?? "", reasoningEffort ?? ""].joined(separator: "|") }

    /// Where a task keeps the mode a person chose, so a restart, a resume and a fork keep it. A
    /// task without one stays in the harness's default mode, as before.
    static let storageKey = "codex.collaborationMode"

    var storedValue: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Only the modes Yardlet sends (`default`, `plan`) read back; anything else is no mode.
    static func restored(from options: [String: String]) -> Self? {
        guard let data = options[storageKey]?.data(using: .utf8),
              let preset = try? JSONDecoder().decode(Self.self, from: data),
              preset.mode == "default" || preset.mode == "plan" else { return nil }
        return preset
    }

    /// The runtime's own preset for the saved mode: the listed preset with the same mode, since
    /// its name and settings may change between App Server versions.
    func matching(_ listed: [CodexCollaborationPreset]) -> CodexCollaborationPreset? {
        listed.first { $0.id == id } ?? listed.first { $0.mode == mode }
    }
}

/// A Codex task's permission, as the Codex app's composer offers it (ChatGPT.app 26.1027): Ask for
/// approval, Approve for me and Full access, its agent modes, each sent the way the app sends it (a
/// built-in permission profile, an approval policy and who answers the requests it raises); and
/// Custom, which sends none of the three so the App Server takes them from `config.toml`. Read-only
/// is the app's read-only mode, which its menu offers only where policy allows nothing more; Yardlet
/// keeps it for a task the session tools must keep reading only, and for a task that chose it.
/// Nothing here bypasses a permission on the host.
enum CodexRunLocation: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
    case askForApproval
    case approveForMe
    case dangerFullAccess
    case custom
    case readOnly

    var id: String { rawValue }

    /// The choice's name in the menu, the app's words.
    var displayName: String {
        switch self {
        case .askForApproval: L10n.string("Ask for approval")
        case .approveForMe: L10n.string("Approve for me")
        case .dangerFullAccess: L10n.string("Full access")
        case .custom: L10n.string("Custom (config.toml)")
        case .readOnly: L10n.string("Read-only")
        }
    }

    /// The name on the composer's button, where the app shortens Custom's.
    var shortName: String {
        self == .custom ? L10n.string("Custom") : displayName
    }

    /// The line under the choice's name in the menu, the app's words.
    var choiceDescription: String {
        switch self {
        case .askForApproval: L10n.string("Always ask to edit external files and use the internet")
        case .approveForMe: L10n.string("Only ask for actions detected as potentially unsafe")
        case .dangerFullAccess: L10n.string("Unrestricted access to the internet and any file on your computer")
        case .custom: L10n.string("Uses permissions defined in config.toml")
        case .readOnly: L10n.string("Always ask to edit files and use the internet")
        }
    }

    /// The menu's choices, in the app's order: the three agent modes, Approve for me unless
    /// `config.toml` turns it off, and Custom where `config.toml` sets permissions none of them is
    /// (`CodexPermissionConfig`). A choice the task already has stays listed, Read-only first.
    static func menu(current: Self, config: CodexPermissionConfig) -> [Self] {
        var choices: [Self] = current == .readOnly ? [.readOnly, .askForApproval] : [.askForApproval]
        if config.offersApproveForMe || current == .approveForMe { choices.append(.approveForMe) }
        choices.append(.dangerFullAccess)
        if config.offersCustom || current == .custom { choices.append(.custom) }
        return choices
    }

    /// Where a task keeps its choice, so a restart, a resume and a child on Codex keep it too.
    static let storageKey = "codex.runLocation"

    static func restored(from options: [String: String]) -> Self {
        stored(options[storageKey])
    }

    /// A kept value, including those earlier versions wrote: no value (their Default) and
    /// `workspaceWrite` started threads as Ask for approval does, in the workspace sandbox asking on
    /// request. An unknown value is Ask for approval too.
    static func stored(_ value: String?) -> Self {
        value.flatMap(Self.init(rawValue:)) ?? .askForApproval
    }

    /// The value a task keeps, nil for Ask for approval, which tasks keep as no value.
    var storedValue: String? { self == .askForApproval ? nil : rawValue }

    /// The built-in permission profile (`permissions`); Custom sends none.
    var permissionProfile: String? {
        switch self {
        case .askForApproval, .approveForMe: ":workspace"
        case .readOnly: ":read-only"
        case .dangerFullAccess: ":danger-full-access"
        case .custom: nil
        }
    }

    /// Full access asks nothing (`never`); without it a full-access turn still asked before MCP
    /// tools and Computer Use. Custom sends none.
    var approvalPolicy: String? {
        switch self {
        case .askForApproval, .approveForMe, .readOnly: "on-request"
        case .dangerFullAccess: "never"
        case .custom: nil
        }
    }

    /// Who answers what the policy asks: the person, or for Approve for me Codex's auto-review agent,
    /// by the name the app still sends (`guardian_subagent`, which the App Server takes for
    /// `auto_review`). Custom sends none.
    var approvalsReviewer: String? {
        switch self {
        case .approveForMe: "guardian_subagent"
        case .custom: nil
        case .askForApproval, .readOnly, .dangerFullAccess: "user"
        }
    }

    /// The fields the choice sets on `thread/start`, `thread/resume` and `turn/start`, as the app
    /// sends them; each holds for the thread's later turns.
    var permissionParams: [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        if let permissionProfile { params["permissions"] = .string(permissionProfile) }
        if let approvalPolicy { params["approvalPolicy"] = .string(approvalPolicy) }
        if let approvalsReviewer { params["approvalsReviewer"] = .string(approvalsReviewer) }
        return params
    }

    /// How much the choice lets Codex do without the person, on Claude Code's scale
    /// (`ClaudePermissionMode.freedom`): Read-only reads, Ask for approval asks, Approve for me lets a
    /// reviewer answer for the person as Auto lets a classifier, Full access asks nothing. Custom is
    /// whatever `config.toml` says, so it counts as the most.
    var freedom: Int {
        switch self {
        case .readOnly: ClaudePermissionMode.freedom(ClaudePermissionMode.plan)
        case .askForApproval: ClaudePermissionMode.freedom(nil)
        case .approveForMe: ClaudePermissionMode.freedom(ClaudePermissionMode.auto)
        case .dangerFullAccess, .custom: ClaudePermissionMode.freedom(ClaudePermissionMode.bypassPermissions)
        }
    }
}

/// What a Codex home's `config.toml` changes in the permission menu, as the Codex app reads it:
/// Approve for me goes when `features.guardian_approval` is false, and Custom (config.toml) comes
/// when the file sets `approval_policy`, `sandbox_mode` or `approvals_reviewer` (top level, with the
/// selected profile's over them) to permissions none of the app's modes is. Named permission
/// profiles, which the app lists in Custom's place, are not offered.
struct CodexPermissionConfig: Equatable, Sendable {
    var offersApproveForMe = true
    var offersCustom = false

    init(offersApproveForMe: Bool = true, offersCustom: Bool = false) {
        self.offersApproveForMe = offersApproveForMe
        self.offersCustom = offersCustom
    }

    /// From the file's values by table (`TOMLStringTables`).
    init(tables: [String: [String: String]]) {
        let top = tables[""] ?? [:]
        var values = top
        if let profile = top["profile"], let table = tables["profiles.\(profile)"] {
            values.merge(table) { _, profile in profile }
        }
        let features = tables["features"] ?? [:]
        let guardian = top["features.guardian_approval"] ?? features["guardian_approval"]
        offersApproveForMe = guardian != "false"
        let policy = values["approval_policy"], sandbox = values["sandbox_mode"]
        var reviewer = values["approvals_reviewer"]
        guard policy != nil || sandbox != nil || reviewer != nil else { return }
        if reviewer == "guardian_subagent", !offersApproveForMe { reviewer = "user" }
        let reviews = reviewer == "auto_review" || reviewer == "guardian_subagent"
        // The app's reading: no sandbox is read-only, and the policy follows the sandbox.
        let workspace = tables["sandbox_workspace_write"] ?? [:]
        let defaultWorkspace = ["network_access", "exclude_slash_tmp", "exclude_tmpdir_env_var"]
            .allSatisfy { (workspace[$0] ?? "false") == "false" }
        let mode: CodexRunLocation? = switch (sandbox ?? "read-only", policy) {
        case ("read-only", "on-request"?), ("read-only", nil):
            reviewer == nil || reviewer == "user" ? .readOnly : nil
        case ("workspace-write", "on-request"?), ("workspace-write", nil):
            defaultWorkspace ? (reviews ? .approveForMe : .askForApproval) : nil
        case ("danger-full-access", "never"?), ("danger-full-access", nil):
            reviewer == nil || reviewer == "user" ? .dangerFullAccess : nil
        default: nil
        }
        offersCustom = mode == nil || (mode == .approveForMe && !offersApproveForMe)
    }
}

struct CodexSkillSummary: Equatable, Identifiable, Sendable {
    let name: String
    let displayName: String
    let description: String
    let enabled: Bool
    let scope: String
    let path: String

    var id: String { path }
}

struct CodexPluginSummary: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let displayName: String
    let description: String?
    let installed: Bool
    let enabled: Bool
    let availability: String
    let marketplace: String

    /// What the marketplace listing already says about this plugin. Codex owns installing and
    /// enabling a plugin, including the bundled ones a shared `~/.codex` home brings along, so
    /// Yardlet's list reports the state and offers no control over it.
    var statusLabels: [CodexPluginStatusLabel] {
        var labels = [installed ? CodexPluginStatusLabel.installed : .available]
        if installed, !enabled { labels.append(.disabled) }
        return labels
    }
}

enum CodexPluginStatusLabel: String, Equatable, Identifiable, Sendable {
    case installed
    case available
    case disabled

    var id: String { rawValue }

    var key: String {
        switch self {
        case .installed: "Installed"
        case .available: "Available"
        case .disabled: "Disabled"
        }
    }

    var text: String { L10n.string(key) }
}

struct CodexThreadSummary: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let preview: String
    let workspaceURL: URL
    let updatedAt: Date
    let forkedFromID: String?
    /// When a person last worked in the thread (`recencyAt`), the order the Codex app lists
    /// threads in. `updatedAt` also moves when only the thread's settings are written. Absent from
    /// older App Servers.
    var recencyAt: Date? = nil

    /// The thread's last activity as the Codex app orders its list.
    var lastActivityAt: Date { recencyAt ?? updatedAt }
}

struct CodexThreadSearchMatch: Equatable, Identifiable, Sendable {
    let thread: CodexThreadSummary
    let snippet: String?

    var id: String { thread.id }
}

struct CodexThreadSearchPage: Equatable, Sendable {
    let matches: [CodexThreadSearchMatch]
    let nextCursor: String?
}

struct CodexRecentThreadsPage: Equatable, Sendable {
    let threads: [CodexThreadSummary]
    let nextCursor: String?
}

/// UTF-16 offsets are part of the locked `thread/searchOccurrences` response contract.
/// Keeping them typed prevents a provider range from being confused with Swift grapheme
/// cluster offsets when a result is highlighted after hydration.
struct CodexTextRange: Codable, Equatable, Sendable {
    let start: Int
    let end: Int

    init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

struct CodexThreadSearchOccurrence: Equatable, Identifiable, Sendable {
    let turnID: String
    let itemID: String
    let snippet: String
    let snippetMatchRange: CodexTextRange
    let turnCursor: String

    var id: String {
        "\(turnID):\(itemID):\(snippetMatchRange.start):\(snippetMatchRange.end)"
    }
}

struct CodexThreadSearchOccurrencesPage: Equatable, Sendable {
    let occurrences: [CodexThreadSearchOccurrence]
    let nextCursor: String?
}

struct CodexCapabilityState: Equatable, Sendable {
    var modelCatalog = CodexModelCatalog()
    var modes: [CodexCollaborationPreset] = []
    var selectedModeID: CodexCollaborationPreset.ID?
    var selectedRunLocation: CodexRunLocation = .askForApproval
    /// What the account's `config.toml` changes in the permission menu.
    var permissionConfig = CodexPermissionConfig()
    var skills: [CodexSkillSummary] = []
    var plugins: [CodexPluginSummary] = []
    var isLoading = false
    var errors: [String] = []
    var actionMessage: String?
    /// Whether the harness settings sheet's reads (modes, skills, plugins) ran for this task. The
    /// composer's own reads fill only the model list and skills, so a state can exist without them.
    var hasListedCapabilities = false
    /// The thread's MCP servers from `mcpServerStatus/list`. Nil until read.
    var mcpServers: [HarnessMCPServerStatus]?

    static let empty = CodexCapabilityState()
}

protocol CodexCapabilityProviding: Actor {
    func modelCatalog(for session: HarnessSessionHandle) async throws -> CodexModelCatalog
    func selectModel(_ selection: CodexModelSelection, for session: HarnessSessionHandle) async throws -> CodexModelCatalog
    func collaborationModes() async throws -> [CodexCollaborationPreset]
    func skills(in workspaceURL: URL) async throws -> [CodexSkillSummary]
    func plugins(in workspaceURL: URL) async throws -> [CodexPluginSummary]
    func recentThreads(in workspaceURL: URL) async throws -> [CodexThreadSummary]
    func recentThreadsPage(
        in workspaceURL: URL,
        cursor: String?,
        limit: Int64
    ) async throws -> CodexRecentThreadsPage
    func searchThreads(
        in workspaceURL: URL,
        searchTerm: String,
        cursor: String?,
        limit: Int64
    ) async throws -> CodexThreadSearchPage
    /// Every folder's threads a person started (not `exec` runs or subagents), not archived, the
    /// most recently updated first. It reads; no thread is loaded or resumed.
    func interactiveThreadsPage(cursor: String?, limit: Int64) async throws -> CodexRecentThreadsPage
    /// The same threads among the archived ones (`thread/list` with `archived: true`), most
    /// recently updated first. It reads; nothing is unarchived, loaded or resumed.
    func archivedInteractiveThreadsPage(cursor: String?, limit: Int64) async throws -> CodexRecentThreadsPage
    func searchOccurrences(
        threadID: String,
        searchTerm: String,
        cursor: String?,
        limit: Int64
    ) async throws -> CodexThreadSearchOccurrencesPage
    func selectCollaborationMode(
        _ preset: CodexCollaborationPreset?,
        for session: HarnessSessionHandle
    ) async throws
    func selectRunLocation(
        _ location: CodexRunLocation,
        for session: HarnessSessionHandle
    ) async throws
    func fork(
        _ session: HarnessSessionHandle,
        newLocalSessionID: UUID
    ) async throws -> HarnessSessionHandle
    func fork(
        _ session: HarnessSessionHandle,
        newLocalSessionID: UUID,
        throughTurnID: String?
    ) async throws -> HarnessSessionHandle
    func startWorkingTreeReview(in session: HarnessSessionHandle) async throws
    func compactConversation(in session: HarnessSessionHandle) async throws
    func startReview(_ target: CodexReviewTarget, in session: HarnessSessionHandle) async throws
    /// The rate limits of the account this App Server runs under (`account/rateLimits/read`).
    /// It needs no thread and starts none.
    func accountRateLimits() async throws -> CodexAccountRateLimits
}

extension CodexCapabilityProviding {
    func startReview(_ target: CodexReviewTarget, in session: HarnessSessionHandle) async throws {
        guard target == .uncommittedChanges else { throw HarnessAdapterError.capabilityUnavailable("Branch review is unavailable") }
        try await startWorkingTreeReview(in: session)
    }

    func compactConversation(in session: HarnessSessionHandle) async throws {
        throw HarnessAdapterError.capabilityUnavailable(L10n.string("Context compaction is unavailable for this runtime."))
    }

    func accountRateLimits() async throws -> CodexAccountRateLimits {
        throw HarnessAdapterError.capabilityUnavailable("Codex rate limits are unavailable")
    }

    func fork(
        _ session: HarnessSessionHandle,
        newLocalSessionID: UUID,
        throughTurnID: String?
    ) async throws -> HarnessSessionHandle {
        guard throughTurnID == nil else {
            throw HarnessAdapterError.capabilityUnavailable("Turn-scoped fork is unavailable")
        }
        return try await fork(session, newLocalSessionID: newLocalSessionID)
    }

    func modelCatalog(for session: HarnessSessionHandle) async throws -> CodexModelCatalog {
        throw HarnessAdapterError.capabilityUnavailable("Codex model catalog is unavailable")
    }

    func selectModel(_ selection: CodexModelSelection, for session: HarnessSessionHandle) async throws -> CodexModelCatalog {
        throw HarnessAdapterError.capabilityUnavailable("Codex model selection is unavailable")
    }

    /// The page form is additive so older adapters/fakes that only expose the first recent page
    /// remain source-compatible. Providers that implement the page contract override this with
    /// their cursor-aware `thread/list` request.
    func recentThreadsPage(
        in workspaceURL: URL,
        cursor: String?,
        limit: Int64
    ) async throws -> CodexRecentThreadsPage {
        guard cursor == nil else {
            return CodexRecentThreadsPage(threads: [], nextCursor: nil)
        }
        return CodexRecentThreadsPage(
            threads: try await recentThreads(in: workspaceURL),
            nextCursor: nil
        )
    }

    func interactiveThreadsPage(cursor: String?, limit: Int64) async throws -> CodexRecentThreadsPage {
        throw HarnessAdapterError.capabilityUnavailable(L10n.string("Codex history is unavailable for this runtime"))
    }

    func archivedInteractiveThreadsPage(cursor: String?, limit: Int64) async throws -> CodexRecentThreadsPage {
        throw HarnessAdapterError.capabilityUnavailable(L10n.string("Codex history is unavailable for this runtime"))
    }

    /// Older installed runtimes may not expose the occurrence endpoint. Keeping a truthful
    /// default preserves the existing capability seam for test doubles and older adapters;
    /// callers retain their local hydrated-text fallback in that case.
    func searchOccurrences(
        threadID: String,
        searchTerm: String,
        cursor: String?,
        limit: Int64
    ) async throws -> CodexThreadSearchOccurrencesPage {
        throw HarnessAdapterError.capabilityUnavailable(
            L10n.string("Codex history occurrences are unavailable for this runtime")
        )
    }
}
