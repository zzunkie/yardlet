import Foundation

/// Moving a task to another project, or out of its project to Chats, as the Codex app's sidebar
/// moves a thread ("Move to project"). The move is Yardlet's: only the task's project, the roots
/// that come with it and whether the person moved it to Chats change. Its folder stays its cwd, and
/// its provider session, storage scope, account, history, draft, pin and status stay as they are.
/// Nothing on disk is copied or moved, and nothing is written to the provider.
enum TaskProjectMove {
    /// What a task's menus offer.
    struct Options: Equatable, Sendable {
        /// The projects the task can move to: the sidebar's visible projects, in its order, but
        /// the one the task is in.
        var destinations: [Project] = []
        /// The project the task can leave for Chats: any task's project. A task whose folder a
        /// project holds stays in Chats because the move records it (`SessionRecord.isMovedToChats`),
        /// and keeps working in its folder.
        var removableFrom: Project?
        /// Whether the task can become a project of its own folder, once the person confirms it
        /// (`AppModel.makeProject(from:name:additionalRoots:)`):
        /// a task in no project, as a chat is, whose folder no listed project holds. A hidden project
        /// of the folder, which Remove project leaves, is shown again with the task in it. A task moved
        /// to Chats from its project's folder goes back with a move to that project instead.
        var canMakeProject = false

        static let none = Options()

        var isEmpty: Bool { destinations.isEmpty && removableFrom == nil && !canMakeProject }

        /// Whether the task can go to `destination` (nil: Chats).
        func allows(_ destination: Project?) -> Bool {
            guard let destination else { return removableFrom != nil }
            return destinations.contains { $0.id == destination.id }
        }
    }

    /// A move as one command, for the command palette, which lists commands rather than submenus.
    struct Command: Identifiable, Equatable, Sendable {
        enum Target: Equatable, Sendable {
            case project(Project)
            /// Out of the task's project, to Chats.
            case chats
            /// A project made of the task's own folder (`Options.canMakeProject`).
            case newProject
        }

        let target: Target
        let title: String

        /// The project the task moves to; nil for Chats and for a new project.
        var destination: Project? {
            if case let .project(project) = target { return project }
            return nil
        }

        var id: String {
            switch target {
            case let .project(project): "move-to-project-\(project.id.uuidString)"
            case .chats: "move-to-chats"
            case .newProject: "move-to-new-project"
            }
        }
    }

    /// - Parameters:
    ///   - visibleProjects: the projects the sidebar lists, in its order.
    ///   - projects: every project, hidden ones too, which is what a task's project resolves among.
    static func options(for session: SessionRecord, visibleProjects: [Project], projects: [Project]) -> Options {
        let current = ProjectProjection.project(for: session, in: projects)
        let destinations = visibleProjects.filter { !$0.isHidden && $0.id != current?.id }
        // The listed projects only: a hidden one of the folder is shown again (`ProjectStore.ensureProject(forRoot:)`).
        let canMakeProject = current == nil && !destinations.contains { $0.contains(root: session.workspaceURL) }
        return Options(destinations: destinations, removableFrom: current, canMakeProject: canMakeProject)
    }

    /// The submenu's title, the Codex app's ("Move to project").
    static var moveTitle: String { L10n.string("Move to project") }

    /// The move out of the task's project to Chats, named for where it goes as "Move to project" is.
    static var chatsTitle: String { L10n.string("Move to Chats") }

    /// The item under "Move to project" that makes the task a project of its own folder.
    static var newProjectTitle: String { L10n.string("New project") }

    /// The same move as one command, named as the moves to a project are.
    static var newProjectCommandTitle: String { L10n.string("Move to new project") }

    /// The name a project made of a task's folder starts with: the task's title as Chats lists it,
    /// which the agent gave the session or Yardlet made from its first request, so making the
    /// project starts no model turn. The person renames it as any project. An untitled task's project
    /// is named after its folder (`Project.normalizedName`).
    static func projectName(for session: SessionRecord) -> String {
        SessionTitleProjection.titleUnderProject(session, projectNames: [session.workspaceURL.lastPathComponent])
    }

    /// The moves as commands: one per destination, then a new project, then the move to Chats.
    static func commands(_ options: Options) -> [Command] {
        options.destinations.map { Command(target: .project($0), title: L10n.format("Move to project: %@", $0.name)) }
            + (options.canMakeProject ? [Command(target: .newProject, title: newProjectCommandTitle)] : [])
            + (options.removableFrom == nil ? [] : [Command(target: .chats, title: chatsTitle)])
    }

    /// The roots a task in `project` hands its harness besides its own folder: the project's roots,
    /// as a task started in the project gets them, without the task's folder and, for a worktree,
    /// without the root it was checked out from, which the worktree stands in for. The task keeps
    /// running in its own folder. In Chats (nil) a task gets none, as a new chat does. The
    /// project's own roots never change.
    static func additionalRoots(for session: SessionRecord, in project: Project?) -> [String] {
        guard let project else { return [] }
        let standIn = session.originWorkspaceURL.flatMap { project.contains(root: $0) ? $0 : nil }
        return project.roots
            .filter { root in
                !Project.isSamePath(root, session.workspaceURL)
                    && !(standIn.map { Project.isSamePath(root, $0) } ?? false)
            }
            .map { ProjectSidebarPresentation.normalizedPath(for: $0) }
    }

    /// The task as it is once in `project` (nil: Chats).
    static func moved(_ session: SessionRecord, to project: Project?) -> SessionRecord {
        var copy = session
        copy.assignProject(project?.id, additionalRoots: additionalRoots(for: session, in: project))
        return copy
    }
}

/// What the New project sheet starts with for a chat made a project of its own folder
/// (`AppModel.newProjectRequest(for:)`): the name, the primary folder and the other folders. For a
/// hidden project of the chat's folder, which is shown again, they are that project's own.
struct NewProjectRequest: Identifiable, Equatable {
    let session: SessionRecord
    let name: String
    let primaryRoot: URL
    let otherRoots: [URL]

    init(session: SessionRecord, name: String, primaryRoot: URL? = nil, otherRoots: [URL] = []) {
        self.session = session
        self.name = name
        self.primaryRoot = Project.canonical(primaryRoot ?? session.workspaceURL)
        self.otherRoots = otherRoots.map(Project.canonical)
    }

    var id: UUID { session.id }

    /// Whether the sheet can take `root` out: not the primary folder, nor the chat's own, which the
    /// project is made of.
    func canRemove(_ root: URL) -> Bool {
        !Project.isSamePath(root, primaryRoot) && !Project.isSamePath(root, session.workspaceURL)
    }
}
