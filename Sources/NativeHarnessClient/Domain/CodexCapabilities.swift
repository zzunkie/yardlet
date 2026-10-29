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

/// The locked App Server exposes per-turn sandbox policy through `sandboxPolicy`.
/// `automatic` is an app-local choice that omits the override and keeps the thread's
/// configured policy. The remaining cases map directly to the installed schema's
/// discriminated policy objects; no host-side permission bypass is performed here.
enum CodexRunLocation: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
    case automatic
    case readOnly
    case workspaceWrite
    case dangerFullAccess

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: L10n.string("Default")
        case .readOnly: L10n.string("Read-only")
        case .workspaceWrite: L10n.string("Workspace write")
        case .dangerFullAccess: L10n.string("Full access")
        }
    }

    /// Where a task keeps its choice, so a restart, a resume and a child on Codex keep it too.
    static let storageKey = "codex.runLocation"

    static func restored(from options: [String: String]) -> Self {
        options[storageKey].flatMap(Self.init(rawValue:)) ?? .automatic
    }

    /// The approval policy that goes with the sandbox, as the Codex app pairs them (26.1016
    /// agent modes): Full access is `never` with `dangerFullAccess`, the others `on-request`.
    /// Without `never`, a full-access turn still asked before MCP tools and Computer Use.
    var approvalPolicy: String? {
        switch self {
        case .automatic: nil
        case .readOnly, .workspaceWrite: "on-request"
        case .dangerFullAccess: "never"
        }
    }

    /// `thread/start` and `thread/resume` set the thread's own policy, which every later turn
    /// keeps; a resume that sent the default would undo the task's choice.
    var threadApprovalPolicy: String { approvalPolicy ?? "on-request" }

    var threadSandbox: String {
        switch self {
        case .automatic, .workspaceWrite: "workspace-write"
        case .readOnly: "read-only"
        case .dangerFullAccess: "danger-full-access"
        }
    }

    /// The exact `TurnStartParams.sandboxPolicy` envelope for this selection.
    /// `automatic` intentionally returns nil so the provider retains its thread policy.
    var sandboxPolicy: JSONValue? {
        switch self {
        case .automatic:
            nil
        case .readOnly:
            .object([
                "type": .string("readOnly"),
                "networkAccess": .bool(false)
            ])
        case .workspaceWrite:
            .object([
                "type": .string("workspaceWrite"),
                "networkAccess": .bool(false)
            ])
        case .dangerFullAccess:
            .object(["type": .string("dangerFullAccess")])
        }
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
    var isCloud: Bool = false

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
    var selectedRunLocation: CodexRunLocation = .automatic
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
