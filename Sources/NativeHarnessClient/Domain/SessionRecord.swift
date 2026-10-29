import Foundation

enum SessionStatus: String, Codable, Sendable {
    case ready
    case running
    case waitingForApproval
    case completed
    case failed

    var displayName: String {
        switch self {
        case .ready:
            L10n.string("Ready")
        case .running:
            L10n.string("Running")
        case .waitingForApproval:
            L10n.string("Needs approval")
        case .completed:
            L10n.string("Completed")
        case .failed:
            L10n.string("Failed")
        }
    }
}

enum SessionCompletionState: String, Codable, Sendable {
    case none
    case completed
    case failed
}

enum SessionEnvironmentScope: String, Codable, Sendable {
    /// New tasks use the harness's original home and provider session identity.
    case native
    /// Compatibility scope for existing Codex tasks stored under `~/.yardlet`.
    case yardlet
}

enum SessionTitleOrigin: String, Codable, Sendable {
    /// A record written before Yardlet persisted title provenance.
    case legacy
    /// The first user message shown while the provider is producing its title.
    case provisional
    /// A deterministic Yardlet fallback used when the provider exposes no title.
    case automatic
    /// A title supplied by the harness itself.
    case provider
    /// A title explicitly chosen by the user.
    case manual
}

struct SessionRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let harness: HarnessKind
    let workspaceURL: URL
    var runtimeExecutableURL: URL
    var title: String
    var titleOrigin: SessionTitleOrigin
    var status: SessionStatus
    let createdAt: Date
    var updatedAt: Date
    var providerSessionID: String?
    var hasUnreadUpdate: Bool
    var completionState: SessionCompletionState
    var isPinned: Bool
    var providerOptions: [String: String]
    let environmentScope: SessionEnvironmentScope
    var inheritedContext: SideChatContext?
    var connection: ProviderConnection?
    /// The Yardlet project this task belongs to. Tasks written before projects existed keep this
    /// nil and are matched to a project by their cwd at display time. Moving the task to another
    /// project (`assignProject`) is the one change after creation.
    private(set) var projectID: UUID?
    /// The project's other roots as they stood when the task was created or moved into it. These
    /// reach the harness through its own multi-root mechanism; the cwd stays `workspaceURL`.
    private(set) var additionalRoots: [String]
    /// The repository this task's folder was checked out from, recorded only when the cwd is a
    /// linked Git worktree. The cwd stays the worktree; this is what puts the task under the
    /// original project in the sidebar. A task in an ordinary checkout keeps it nil.
    var originWorkspacePath: String?
    /// The worktree folder's own name, recorded alongside the origin.
    var worktreeName: String?
    /// The branch the folder was on when the task was created, when HEAD pointed at one.
    var branch: String?
    /// The Yardlet task this one was started from, when that task is in Yardlet too: a fork, a
    /// subagent or original conversation opened from a task, or a conversation another app started
    /// from another (`TaskLineage`). The sidebar nests the task under that one. It is the same for
    /// every harness; nil is a top-level task.
    var parentTaskID: UUID?
    /// The person took the task out of the family it was listed in ("Detach to top level", as the
    /// Claude app's `lineageDetached`): it stays at the top level, and links read later from a
    /// harness or another app are not recorded for it.
    var isLineageDetached: Bool

    var additionalRootURLs: [URL] {
        additionalRoots.map { URL(filePath: $0, directoryHint: .isDirectory).standardizedFileURL }
    }

    /// The origin repository's folder, when this task runs in a worktree of it.
    var originWorkspaceURL: URL? {
        originWorkspacePath.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// Whether this task represents a cloud-hosted session.
    var isCloud: Bool {
        providerOptions["is_cloud"] == "true" || cloudURL != nil
    }

    /// Explicit remote or web URL for the session, if configured.
    var cloudURL: URL? {
        providerOptions["cloud_url"].flatMap(URL.init(string:))
    }

    /// The target URL to open when this cloud session is opened in the agent's web page or app.
    func cloudTargetURL() -> URL? {
        if let cloudURL { return cloudURL }
        guard isCloud, let id = providerSessionID else { return nil }
        switch harness {
        case .claudeCode:
            return URL(string: "https://claude.ai/code/\(id)")
        case .codex:
            return URL(string: "codex://threads/\(id)")
        default:
            return nil
        }
    }

    init(
        id: UUID = UUID(),
        harness: HarnessKind,
        workspaceURL: URL,
        runtimeExecutableURL: URL,
        title: String,
        titleOrigin: SessionTitleOrigin = .legacy,
        status: SessionStatus = .ready,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        providerSessionID: String? = nil,
        hasUnreadUpdate: Bool = false,
        completionState: SessionCompletionState = .none,
        isPinned: Bool = false,
        providerOptions: [String: String] = [:],
        environmentScope: SessionEnvironmentScope = .native,
        inheritedContext: SideChatContext? = nil,
        connection: ProviderConnection? = nil,
        projectID: UUID? = nil,
        additionalRoots: [String] = [],
        originWorkspacePath: String? = nil,
        worktreeName: String? = nil,
        branch: String? = nil,
        parentTaskID: UUID? = nil,
        isLineageDetached: Bool = false
    ) {
        self.id = id
        self.harness = harness
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.runtimeExecutableURL = runtimeExecutableURL.standardizedFileURL
        self.title = title
        self.titleOrigin = titleOrigin
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.providerSessionID = providerSessionID
        self.hasUnreadUpdate = hasUnreadUpdate
        self.completionState = completionState
        self.isPinned = isPinned
        self.providerOptions = providerOptions
        self.environmentScope = environmentScope
        self.inheritedContext = inheritedContext
        self.connection = connection
        self.projectID = projectID
        self.additionalRoots = SessionRecord.normalizedRoots(additionalRoots, excluding: workspaceURL)
        self.originWorkspacePath = SessionRecord.normalizedOrigin(
            originWorkspacePath,
            excluding: workspaceURL
        )
        self.worktreeName = SessionRecord.normalizedLabel(worktreeName)
        self.branch = SessionRecord.normalizedLabel(branch)
        self.parentTaskID = parentTaskID == id ? nil : parentTaskID
        self.isLineageDetached = isLineageDetached
    }

    /// Puts the task in another project, or in none, with the roots that come along
    /// (`TaskProjectMove`). The folder stays the cwd and is never among the roots.
    mutating func assignProject(_ id: UUID?, additionalRoots roots: [String]) {
        projectID = id
        additionalRoots = SessionRecord.normalizedRoots(roots, excluding: workspaceURL)
    }

    /// A folder is never its own origin, and a blank value is the same as no record at all.
    private static func normalizedOrigin(_ value: String?, excluding workspaceURL: URL) -> String? {
        guard let label = normalizedLabel(value) else { return nil }
        let origin = ProjectSidebarPresentation.normalizedPath(
            for: URL(filePath: label, directoryHint: .isDirectory)
        )
        return origin == ProjectSidebarPresentation.normalizedPath(for: workspaceURL) ? nil : origin
    }

    private static func normalizedLabel(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func normalizedRoots(_ roots: [String], excluding workspaceURL: URL) -> [String] {
        let cwd = ProjectSidebarPresentation.normalizedPath(for: workspaceURL)
        var seen: Set<String> = [cwd]
        var result: [String] = []
        for root in roots {
            let path = ProjectSidebarPresentation.normalizedPath(
                for: URL(filePath: root, directoryHint: .isDirectory)
            )
            guard seen.insert(path).inserted else { continue }
            result.append(path)
        }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case harness
        case workspaceURL
        case runtimeExecutableURL
        case title
        case titleOrigin
        case status
        case createdAt
        case updatedAt
        case providerSessionID
        case hasUnreadUpdate
        case completionState
        case isPinned
        case providerOptions
        case environmentScope
        case inheritedContext
        case connection
        case projectID
        case additionalRoots
        case originWorkspacePath
        case worktreeName
        case branch
        case parentTaskID
        case isLineageDetached
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connection = try container.decodeIfPresent(ProviderConnection.self, forKey: .connection)
        inheritedContext = try container.decodeIfPresent(SideChatContext.self, forKey: .inheritedContext)
        id = try container.decode(UUID.self, forKey: .id)
        harness = try container.decode(HarnessKind.self, forKey: .harness)
        workspaceURL = try container.decode(URL.self, forKey: .workspaceURL).standardizedFileURL
        runtimeExecutableURL = try container.decode(URL.self, forKey: .runtimeExecutableURL).standardizedFileURL
        title = try container.decode(String.self, forKey: .title)
        titleOrigin = try container.decodeIfPresent(
            SessionTitleOrigin.self,
            forKey: .titleOrigin
        ) ?? .legacy
        status = try container.decode(SessionStatus.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        providerSessionID = try container.decodeIfPresent(String.self, forKey: .providerSessionID)
        hasUnreadUpdate = try container.decodeIfPresent(Bool.self, forKey: .hasUnreadUpdate) ?? false
        completionState = try container.decodeIfPresent(SessionCompletionState.self, forKey: .completionState) ?? .none
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        providerOptions = try container.decodeIfPresent(
            [String: String].self,
            forKey: .providerOptions
        ) ?? [:]
        environmentScope = try container.decodeIfPresent(
            SessionEnvironmentScope.self,
            forKey: .environmentScope
        ) ?? .native
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
        additionalRoots = SessionRecord.normalizedRoots(
            try container.decodeIfPresent([String].self, forKey: .additionalRoots) ?? [],
            excluding: workspaceURL
        )
        originWorkspacePath = SessionRecord.normalizedOrigin(
            try container.decodeIfPresent(String.self, forKey: .originWorkspacePath),
            excluding: workspaceURL
        )
        worktreeName = SessionRecord.normalizedLabel(
            try container.decodeIfPresent(String.self, forKey: .worktreeName)
        )
        branch = SessionRecord.normalizedLabel(
            try container.decodeIfPresent(String.self, forKey: .branch)
        )
        let parent = try container.decodeIfPresent(UUID.self, forKey: .parentTaskID)
        parentTaskID = parent == id ? nil : parent
        isLineageDetached = try container.decodeIfPresent(Bool.self, forKey: .isLineageDetached) ?? false
    }
}

struct WorkspaceGroup: Identifiable, Hashable, Sendable {
    let workspaceURL: URL
    let sessions: [SessionRecord]
    /// The owning project, when the group's tasks belong to one. Tasks that belong to no project
    /// keep showing as a plain folder group.
    var project: Project?

    var id: URL { workspaceURL }
    var displayName: String { project?.name ?? workspaceURL.lastPathComponent }
    /// Every folder the group covers, primary folder first.
    var roots: [URL] { project?.roots ?? [workspaceURL] }
    var additionalRoots: [URL] { project?.additionalRoots ?? [] }
}
