import Foundation
import Observation

struct ProjectSnapshot: Codable, Equatable, Sendable {
    var version = 1
    var projects: [Project] = []
    /// Set once the folder-path preferences have been converted, so the conversion stays a
    /// one-time read of the old settings rather than something that reruns on every launch.
    var didImportFolderPreferences = false

    private enum CodingKeys: String, CodingKey {
        case version
        case projects
        case didImportFolderPreferences
    }

    init(
        version: Int = 1,
        projects: [Project] = [],
        didImportFolderPreferences: Bool = false
    ) {
        self.version = version
        self.projects = projects
        self.didImportFolderPreferences = didImportFolderPreferences
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
        didImportFolderPreferences = try container.decodeIfPresent(
            Bool.self,
            forKey: .didImportFolderPreferences
        ) ?? false
    }
}

@MainActor
protocol ProjectRepository {
    func load() -> ProjectSnapshot?
    func save(_ snapshot: ProjectSnapshot)
}

@MainActor
final class InMemoryProjectRepository: ProjectRepository {
    var snapshot: ProjectSnapshot?

    init(snapshot: ProjectSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func load() -> ProjectSnapshot? { snapshot }
    func save(_ snapshot: ProjectSnapshot) { self.snapshot = snapshot }
}

/// Projects are Yardlet-owned records and live beside the other `~/.yardlet` files, using the
/// same storage shape as `FileSplitRepository`. They carry folder paths only — never credentials
/// or conversation content.
struct FileProjectRepository: ProjectRepository {
    let fileURL: URL

    static func live(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> FileProjectRepository {
        FileProjectRepository(
            fileURL: homeURL
                .appending(path: YardletProduct.storageDirectoryName, directoryHint: .isDirectory)
                .appending(path: "projects.json")
        )
    }

    func load() -> ProjectSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: data),
              snapshot.version == 1 else { return nil }
        return snapshot
    }

    func save(_ snapshot: ProjectSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// The folder-path keyed sidebar settings that projects replace. The settings surface itself is
/// gone; this reads the record it left in `UserDefaults` as a plain snapshot, so the conversion
/// only ever reads and the original record stays untouched.
struct LegacyProjectFolderPreferences: Equatable, Sendable {
    var pinnedPaths: Set<String> = []
    var aliasesByPath: [String: String] = [:]
    var hiddenPaths: Set<String> = []
    var registeredPaths: [String] = []

    var isEmpty: Bool {
        pinnedPaths.isEmpty && aliasesByPath.isEmpty && hiddenPaths.isEmpty && registeredPaths.isEmpty
    }

    private struct Stored: Decodable {
        var pinnedPaths: Set<String>?
        var aliasesByPath: [String: String]?
        var hiddenPaths: Set<String>?
        var registeredPaths: [String]?
    }

    init() {}

    init(
        pinnedPaths: Set<String>,
        aliasesByPath: [String: String],
        hiddenPaths: Set<String>,
        registeredPaths: [String]
    ) {
        self.pinnedPaths = pinnedPaths
        self.aliasesByPath = aliasesByPath
        self.hiddenPaths = hiddenPaths
        self.registeredPaths = registeredPaths
    }

    static func stored(
        in defaults: UserDefaults,
        storageKey: String = "yardlet.project-sidebar-preferences.v1"
    ) -> LegacyProjectFolderPreferences {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Stored.self, from: data) else {
            return LegacyProjectFolderPreferences()
        }
        func normalized(_ path: String) -> String {
            ProjectSidebarPresentation.normalizedPath(
                for: URL(filePath: path, directoryHint: .isDirectory)
            )
        }
        var result = LegacyProjectFolderPreferences()
        result.pinnedPaths = Set((decoded.pinnedPaths ?? []).map(normalized))
        result.hiddenPaths = Set((decoded.hiddenPaths ?? []).map(normalized))
        for key in (decoded.aliasesByPath ?? [:]).keys.sorted() {
            result.aliasesByPath[normalized(key)] = decoded.aliasesByPath?[key]
        }
        var seen = Set<String>()
        for path in decoded.registeredPaths ?? [] where seen.insert(normalized(path)).inserted {
            result.registeredPaths.append(normalized(path))
        }
        return result
    }
}

/// Owns the project records. A task keeps one primary folder as its cwd and a project ID; the
/// remaining roots reach the harness through its own multi-root mechanism.
@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [Project]
    private(set) var didImportFolderPreferences: Bool

    /// The home whose chat folders (`ChatWorkspaces`) hold chats rather than projects, and under
    /// which Yardlet makes a new chat's folder. Tests and fixtures use a folder of their own.
    @ObservationIgnored let chatWorkspaceHome: URL

    @ObservationIgnored private let repository: any ProjectRepository
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init(repository: any ProjectRepository = InMemoryProjectRepository(),
         chatWorkspaceHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.repository = repository
        self.chatWorkspaceHome = chatWorkspaceHome
        let snapshot = repository.load() ?? ProjectSnapshot()
        projects = snapshot.projects
        didImportFolderPreferences = snapshot.didImportFolderPreferences
    }

    // MARK: - Reading

    func project(id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func project(containingRoot root: URL) -> Project? {
        ProjectProjection.project(containingRoot: root, in: projects)
    }

    func project(for session: SessionRecord) -> Project? {
        ProjectProjection.project(for: session, in: projects)
    }

    /// Where a folder belongs, as the new-task screen names it: its project, "Chats" for a chat's own
    /// folder (`new-chat-3` is only where Yardlet keeps it), else the folder's name.
    func displayName(for workspaceURL: URL) -> String {
        if let project = project(containingRoot: workspaceURL) { return project.name }
        if ChatWorkspaces.isChat(workspaceURL, home: chatWorkspaceHome) { return L10n.string("Chats") }
        return workspaceURL.lastPathComponent
    }

    /// Where a task is listed, as the title bar, the rail and the menus name it: its project, "Chats"
    /// for a chat (`isChat`), else its folder's name.
    func displayName(for session: SessionRecord) -> String {
        if let project = project(for: session) { return project.name }
        return isChat(session) ? L10n.string("Chats") : session.workspaceURL.lastPathComponent
    }

    /// Whether the sidebar lists the task under Chats (`ProjectProjection.isChat`).
    func isChat(_ session: SessionRecord) -> Bool {
        ProjectProjection.isChat(session, in: projects, home: chatWorkspaceHome)
    }

    /// The main window, its title bar, the task menus and the Dock badge each read the sidebar's
    /// groups and chats several times per redraw, so the last answer is kept for the same tasks and
    /// projects. Reading `projects` here still makes the caller observe them.
    func visibleGroups(sessions: [SessionRecord]) -> [WorkspaceGroup] {
        let projects = projects
        if let memo = groupsMemo, memo.projects == projects, memo.sessions == sessions { return memo.value }
        let groups = ProjectProjection.visibleGroups(sessions: sessions, projects: projects, home: chatWorkspaceHome)
        groupsMemo = Memo(sessions: sessions, projects: projects, value: groups)
        return groups
    }

    /// The tasks the sidebar lists under Chats, most recent first.
    func chats(sessions: [SessionRecord]) -> [SessionRecord] {
        let projects = projects
        if let memo = chatsMemo, memo.projects == projects, memo.sessions == sessions { return memo.value }
        let chats = ProjectProjection.chats(from: sessions, projects: projects, home: chatWorkspaceHome)
        chatsMemo = Memo(sessions: sessions, projects: projects, value: chats)
        return chats
    }

    private struct Memo<Value> {
        let sessions: [SessionRecord]
        let projects: [Project]
        let value: Value
    }

    @ObservationIgnored private var groupsMemo: Memo<[WorkspaceGroup]>?
    @ObservationIgnored private var chatsMemo: Memo<[SessionRecord]>?

    /// Whether `folder` is one a harness app makes for a chat (`ChatWorkspaces`).
    func isChatFolder(_ folder: URL) -> Bool {
        ChatWorkspaces.isChat(folder, home: chatWorkspaceHome)
    }

    /// Where Yardlet makes a new chat's folder.
    var chatRoot: URL { ChatWorkspaces.yardletRoot(home: chatWorkspaceHome) }

    /// The name shown per group URL, used by sidebar search.
    func projectNames(for groups: [WorkspaceGroup]) -> [URL: String] {
        Dictionary(uniqueKeysWithValues: groups.map { ($0.workspaceURL, $0.displayName) })
    }

    // MARK: - Conversion from folder-path settings

    /// Converts the folder-path keyed settings and the existing tasks' folders into one-folder
    /// projects. Running it again adds nothing and changes no existing project, and the original
    /// settings record is only read.
    func importFolderPreferences(
        _ preferences: LegacyProjectFolderPreferences,
        sessionWorkspaceURLs: [URL] = [],
        now: Date = Date()
    ) {
        var candidates: [String] = preferences.registeredPaths
        var tail = Set(preferences.aliasesByPath.keys)
        tail.formUnion(preferences.pinnedPaths)
        tail.formUnion(preferences.hiddenPaths)
        // A chat's folder is not a project because a task runs in it (`ensureProject(forTaskIn:)`).
        for url in sessionWorkspaceURLs where !isChatFolder(url) {
            tail.insert(ProjectSidebarPresentation.normalizedPath(for: url))
        }
        candidates.append(contentsOf: tail.sorted())

        var didChange = false
        var seen = Set<String>()
        for path in candidates {
            guard seen.insert(path).inserted else { continue }
            let url = URL(filePath: path, directoryHint: .isDirectory)
            guard project(containingRoot: url) == nil else { continue }
            projects.append(
                Project(
                    name: preferences.aliasesByPath[path] ?? url.lastPathComponent,
                    primaryRoot: url,
                    isPinned: preferences.pinnedPaths.contains(path),
                    isHidden: preferences.hiddenPaths.contains(path),
                    createdAt: now,
                    updatedAt: now
                )
            )
            didChange = true
        }

        if !didImportFolderPreferences {
            didImportFolderPreferences = true
            didChange = true
        }
        if didChange { schedulePersist() }
    }

    // MARK: - Writing

    /// Gives each task that belongs to no project a project of its folder. A task already in one,
    /// by its project ID, its folder, or its worktree's repository, adds none, so a worktree or a
    /// subfolder imported into a project does not become a project of its own; a chat adds none.
    func ensureProjects(forTasks sessions: [SessionRecord]) {
        // A task the person moved to Chats keeps its folder, which makes no project and shows no
        // hidden one again.
        for session in sessions where project(for: session) == nil && !session.isMovedToChats {
            ensureProject(forTaskIn: session.workspaceURL)
        }
    }

    /// The project a task in `folder` belongs to: the one holding the folder, shown again if it was
    /// hidden, or a new one-folder project. A chat's folder (`ChatWorkspaces`) that no project holds
    /// gets none: its tasks are chats. This is the one place a task's folder becomes a project;
    /// a folder the person adds or chooses as a project goes through `ensureProject(forRoot:)`.
    @discardableResult
    func ensureProject(forTaskIn folder: URL) -> Project? {
        guard project(containingRoot: folder) != nil || !isChatFolder(folder) else { return nil }
        return ensureProject(forRoot: folder)
    }

    /// Returns the project owning this folder, creating a one-folder project when none does.
    /// Choosing a folder directly in the new-task screen goes through here.
    @discardableResult
    func ensureProject(forRoot root: URL, name: String? = nil) -> Project {
        if let existing = project(containingRoot: root) {
            if existing.isHidden {
                update(existing.id) { $0.isHidden = false }
                return project(id: existing.id) ?? existing
            }
            return existing
        }
        let project = Project(
            name: Project.normalizedName(name ?? "", fallback: root),
            primaryRoot: root
        )
        projects.append(project)
        schedulePersist()
        return project
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = trimmed }
    }

    @discardableResult
    func addRoot(_ url: URL, to id: UUID) -> Bool {
        var didChange = false
        update(id) { didChange = $0.addRoot(url) }
        return didChange
    }

    @discardableResult
    func removeRoot(_ url: URL, from id: UUID) -> Bool {
        var didChange = false
        update(id) { didChange = $0.removeRoot(url) }
        return didChange
    }

    @discardableResult
    func setPrimaryRoot(_ url: URL, for id: UUID) -> Bool {
        var didChange = false
        update(id) { didChange = $0.setPrimaryRoot(url) }
        return didChange
    }

    func togglePinned(_ id: UUID) {
        update(id) { $0.isPinned.toggle() }
    }

    func hide(_ id: UUID) {
        update(id) { $0.isHidden = true }
    }

    func reveal(_ id: UUID) {
        update(id) { $0.isHidden = false }
    }

    /// The home's Dismiss on a project left alone for a while: not named there again until it is
    /// active after `latestActivity`.
    func setAside(_ id: UUID, through latestActivity: Date) {
        update(id) { $0.setAsideThrough = latestActivity }
    }

    func persistNow() {
        pendingSave?.cancel()
        pendingSave = nil
        repository.save(
            ProjectSnapshot(
                projects: projects,
                didImportFolderPreferences: didImportFolderPreferences
            )
        )
    }

    // MARK: - Internals

    private func update(_ id: UUID, _ body: (inout Project) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let before = projects[index]
        body(&projects[index])
        guard projects[index] != before else { return }
        projects[index].updatedAt = Date()
        schedulePersist()
    }

    private func schedulePersist() {
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.persistNow()
        }
    }
}
