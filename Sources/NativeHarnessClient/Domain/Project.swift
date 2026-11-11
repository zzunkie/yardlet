import Foundation

/// A Yardlet-owned project: a name, one or more root folders, and exactly one primary folder.
/// The primary folder is the cwd a task runs in; the remaining roots are handed to the harness
/// through its own multi-root mechanism. Yardlet never merges, copies, or creates instruction
/// files for these roots — they stay owned by the folder and the harness.
struct Project: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    private(set) var roots: [URL]
    private(set) var primaryRoot: URL
    var isPinned: Bool
    var isHidden: Bool
    let createdAt: Date
    var updatedAt: Date
    /// The home stops naming the project as left alone for a while, until it is active after this:
    /// its latest activity when the person dismissed it there, as the Codex app's Mission Control
    /// keeps a dismissal (`dismissedThrough`) until the conversation is active again.
    var setAsideThrough: Date?

    init(
        id: UUID = UUID(),
        name: String,
        primaryRoot: URL,
        additionalRoots: [URL] = [],
        isPinned: Bool = false,
        isHidden: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = Project.normalizedName(name, fallback: primaryRoot)
        let normalizedPrimary = Project.canonical(primaryRoot)
        self.primaryRoot = normalizedPrimary
        self.roots = Project.normalizedRoots([normalizedPrimary] + additionalRoots)
        self.isPinned = isPinned
        self.isHidden = isHidden
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case roots
        case primaryRoot
        case isPinned
        case isHidden
        case createdAt
        case updatedAt
        case setAsideThrough
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let decodedRoots = try container.decodeIfPresent([URL].self, forKey: .roots) ?? []
        let decodedPrimary = try container.decodeIfPresent(URL.self, forKey: .primaryRoot)
        // A record written by a newer or damaged writer still has to produce one usable primary
        // folder, because a project without a cwd cannot start a task.
        guard let primary = (decodedPrimary ?? decodedRoots.first).map(Project.canonical) else {
            throw DecodingError.dataCorruptedError(
                forKey: .primaryRoot,
                in: container,
                debugDescription: "A project needs at least one root folder"
            )
        }
        primaryRoot = primary
        // A saved project keeps the order its folders were added in; the primary folder is only
        // put in front when the record somehow lost it.
        roots = Project.normalizedRoots(
            decodedRoots.contains(where: { Project.isSamePath($0, primary) })
                ? decodedRoots
                : [primary] + decodedRoots
        )
        name = Project.normalizedName(
            try container.decodeIfPresent(String.self, forKey: .name) ?? "",
            fallback: primary
        )
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        setAsideThrough = try container.decodeIfPresent(Date.self, forKey: .setAsideThrough)
    }

    /// Roots other than the cwd. These are the paths passed to Codex `runtimeWorkspaceRoots`
    /// and Claude `--add-dir`.
    var additionalRoots: [URL] {
        roots.filter { !Project.isSamePath($0, primaryRoot) }
    }

    var hasMultipleRoots: Bool { roots.count > 1 }

    func contains(root: URL) -> Bool {
        let key = ProjectSidebarPresentation.folderKey(for: root)
        return roots.contains { ProjectSidebarPresentation.folderKey(for: $0) == key }
    }

    @discardableResult
    mutating func addRoot(_ url: URL) -> Bool {
        let normalized = Project.canonical(url)
        guard !contains(root: normalized) else { return false }
        roots.append(normalized)
        return true
    }

    /// The primary folder and the last remaining root are never removable: a project always has
    /// a cwd for its next task.
    @discardableResult
    mutating func removeRoot(_ url: URL) -> Bool {
        guard roots.count > 1, !Project.isSamePath(url, primaryRoot) else { return false }
        let before = roots.count
        roots.removeAll { Project.isSamePath($0, url) }
        return roots.count != before
    }

    @discardableResult
    mutating func setPrimaryRoot(_ url: URL) -> Bool {
        let normalized = Project.canonical(url)
        guard contains(root: normalized), !Project.isSamePath(normalized, primaryRoot) else {
            return false
        }
        primaryRoot = normalized
        return true
    }

    /// One spelling per folder, so a project root compares and renders the same way a task's
    /// `workspaceURL` does: no trailing slash and no directory hint.
    static func canonical(_ url: URL) -> URL {
        URL(filePath: ProjectSidebarPresentation.normalizedPath(for: url))
    }

    static func isSamePath(_ lhs: URL, _ rhs: URL) -> Bool {
        ProjectSidebarPresentation.folderKey(for: lhs) == ProjectSidebarPresentation.folderKey(for: rhs)
    }

    static func normalizedName(_ value: String, fallback: URL) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let component = fallback.standardizedFileURL.lastPathComponent
        return component.isEmpty ? fallback.path(percentEncoded: false) : component
    }

    private static func normalizedRoots(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let canonical = Project.canonical(url)
            guard seen.insert(ProjectSidebarPresentation.folderKey(for: canonical)).inserted else { continue }
            result.append(canonical)
        }
        return result
    }
}

/// Pure sidebar/task projection over projects. Sessions written before projects existed carry no
/// project ID; they are matched to a project at display time by their cwd, and the stored row is
/// never rewritten for that.
enum ProjectProjection {
    /// A task's project, in order: the ID it stored; none for a task the person moved to Chats
    /// (`SessionRecord.isMovedToChats`); the project that owns its cwd; and — for a task made in a
    /// linked worktree — the project that owns the repository the worktree came from. A task that
    /// matches none of these keeps showing as a plain folder group, or under Chats when it is a chat.
    static func project(for session: SessionRecord, in projects: [Project]) -> Project? {
        if let id = session.projectID, let match = projects.first(where: { $0.id == id }) {
            return match
        }
        if session.isMovedToChats { return nil }
        let index = RootIndex.of(projects)
        if let match = index.project(containing: session.workspaceURL) {
            return match
        }
        guard let origin = session.originWorkspaceURL else { return nil }
        return index.project(containing: origin)
    }

    static func project(containingRoot root: URL, in projects: [Project]) -> Project? {
        RootIndex.of(projects).project(containing: root)
    }

    /// Every project root by its folder, each pointing at the first project that holds it — the
    /// project `projects.first { $0.contains(root:) }` finds. The sidebar asks this of every task on
    /// every redraw, so the index of the last projects asked about is kept.
    private struct RootIndex: Sendable {
        let projects: [Project]
        let byPath: [String: Int]

        init(_ projects: [Project]) {
            self.projects = projects
            var byPath: [String: Int] = [:]
            for (offset, project) in projects.enumerated() {
                for root in project.roots {
                    let key = ProjectSidebarPresentation.folderKey(for: root)
                    if byPath[key] == nil { byPath[key] = offset }
                }
            }
            self.byPath = byPath
        }

        func project(containing url: URL) -> Project? {
            byPath[ProjectSidebarPresentation.folderKey(for: url)].map { projects[$0] }
        }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var last: RootIndex?

        static func of(_ projects: [Project]) -> RootIndex {
            lock.lock()
            defer { lock.unlock() }
            if let last, last.projects == projects { return last }
            let index = RootIndex(projects)
            last = index
            return index
        }
    }

    /// Whether the task is a chat: it is in no project, and the person moved it to Chats or its
    /// folder is one a harness app makes for a conversation with no project (`ChatWorkspaces`). A
    /// missing project ID alone does not make one: tasks written before projects existed carry none
    /// and still belong to their folder's project.
    static func isChat(_ session: SessionRecord, in projects: [Project],
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        project(for: session, in: projects) == nil && listsInChats(session, home: home)
    }

    /// Where a task in no project is listed: under Chats when the person moved it there or its
    /// folder is a chat's, else as its folder's group.
    private static func listsInChats(_ session: SessionRecord, home: URL) -> Bool {
        session.isMovedToChats || ChatWorkspaces.isChat(session.workspaceURL, home: home)
    }

    /// The chats, most recent first: the Chats section's tasks.
    static func chats(from sessions: [SessionRecord], projects: [Project],
                      home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [SessionRecord] {
        sessions.filter { isChat($0, in: projects, home: home) }.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    /// Groups tasks by project, falling back to the task's folder when it belongs to none. Chats
    /// belong to no group; they are listed on their own (`chats(from:projects:home:)`).
    static func workspaceGroups(
        from sessions: [SessionRecord],
        projects: [Project],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [WorkspaceGroup] {
        var projectsByKey: [String: Project] = [:]
        var sessionsByKey: [String: [SessionRecord]] = [:]
        var urlByKey: [String: URL] = [:]

        for session in sessions {
            let project = project(for: session, in: projects)
            if project == nil, listsInChats(session, home: home) { continue }
            let groupURL = project?.primaryRoot ?? session.workspaceURL.standardizedFileURL
            let key = ProjectSidebarPresentation.folderKey(for: groupURL)
            urlByKey[key] = groupURL
            if let project { projectsByKey[key] = project }
            sessionsByKey[key, default: []].append(session)
        }

        return sessionsByKey
            .map { key, grouped in
                WorkspaceGroup(
                    workspaceURL: urlByKey[key] ?? grouped[0].workspaceURL,
                    sessions: grouped.sorted { lhs, rhs in
                        if lhs.updatedAt == rhs.updatedAt { return lhs.id.uuidString < rhs.id.uuidString }
                        return lhs.updatedAt > rhs.updatedAt
                    },
                    project: projectsByKey[key]
                )
            }
            .sorted { lhs, rhs in
                let lhsLatest = lhs.sessions.map(\.updatedAt).max() ?? .distantPast
                let rhsLatest = rhs.sessions.map(\.updatedAt).max() ?? .distantPast
                if lhsLatest == rhsLatest { return lhs.id.path < rhs.id.path }
                return lhsLatest > rhsLatest
            }
    }

    /// The rendered sidebar order: projects with no task still appear, hidden projects do not,
    /// and pinned projects lead without otherwise disturbing recency order.
    static func visibleGroups(
        sessions: [SessionRecord],
        projects: [Project],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [WorkspaceGroup] {
        var groups = workspaceGroups(from: sessions, projects: projects, home: home)
        var represented = Set(groups.compactMap { $0.project?.id })
        for project in projects where represented.insert(project.id).inserted {
            groups.append(WorkspaceGroup(workspaceURL: project.primaryRoot, sessions: [], project: project))
        }
        return groups.enumerated()
            .filter { $0.element.project?.isHidden != true }
            .sorted { lhs, rhs in
                let lhsPinned = lhs.element.project?.isPinned ?? false
                let rhsPinned = rhs.element.project?.isPinned ?? false
                if lhsPinned != rhsPinned { return lhsPinned }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

/// One spelling per folder path, shared by projects, tasks, and the sidebar so the same folder
/// renders identically wherever it appears, and one key per folder, so it compares as the same
/// folder however it was written.
enum ProjectSidebarPresentation {
    /// The sidebar compares every task's folder with every project root on each redraw, and
    /// standardizing a URL is the costly part, so each spelling's answer is kept.
    static func normalizedPath(for workspaceURL: URL) -> String {
        folder(workspaceURL).path
    }

    /// The folder `workspaceURL` names, for deciding whether two folders are one (a task's project,
    /// a sidebar group, the tasks in a folder) and never for showing: on Windows a folder written in
    /// another case or with other separators is the same folder (`PathRules.key`). On macOS it is
    /// `normalizedPath(for:)` itself.
    static func folderKey(for workspaceURL: URL) -> String {
        folder(workspaceURL).key
    }

    private static func folder(_ workspaceURL: URL) -> (path: String, key: String) {
        let spelling = workspaceURL.absoluteString
        if let known = normalizedPaths.value(for: spelling) { return known }
        let path = withoutTrailingSlash(workspaceURL.standardizedFileURL.path(percentEncoded: false))
        let folder = (path: path, key: PathRules.current.key(path))
        normalizedPaths.set(folder, for: spelling)
        return folder
    }

    private static let normalizedPaths = NormalizedPaths()

    /// Folder spellings seen this launch. The tasks and projects are a few hundred folders; the
    /// table starts over past `limit` so a long run of new folders cannot grow it without end.
    private final class NormalizedPaths: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: (path: String, key: String)] = [:]
        private let limit = 8_192

        func value(for key: String) -> (path: String, key: String)? {
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }

        func set(_ value: (path: String, key: String), for key: String) {
            lock.lock()
            defer { lock.unlock() }
            if values.count >= limit { values.removeAll(keepingCapacity: true) }
            values[key] = value
        }
    }

    static func abbreviatedPath(
        for workspaceURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let path = normalizedPath(for: workspaceURL)
        let home = normalizedPath(for: homeDirectory)
        guard let relative = PathRules.current.relativePath(of: path, in: home) else { return path }
        return relative.isEmpty ? "~" : "~/" + relative
    }

    private static func withoutTrailingSlash(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
