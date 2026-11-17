import Foundation
import YardletRemote

/// The computer whose tasks a sidebar lists and whose tasks its menus act on: this one (`AppModel`), or another
/// computer's Yardlet in its window (`RemoteHostModel`), as the Mac's `TaskSidebar` takes its lists and its actions
/// from the window that draws it. Another computer's tasks are its mirror (`RemoteSidebarMirror`), and what is done to
/// them is asked of that computer (docs/REMOTE_PROTOCOL.md), which may let this one only pin, archive and mark them read
/// (`RemoteHostModel.taskActions`).
@MainActor
enum TaskSource {
    case local(AppModel)
    case remote(RemoteHostModel)

    /// What a sidebar lists, read under the caller's observation.
    struct Lists {
        var groups: [WorkspaceGroup]
        var chats: [SessionRecord]
        var details: [UUID: TaskAttentionDetail]
        var shellBusy: Set<UUID>
        /// The task each archived task was started from, which keeps its family's place.
        var archivedParents: [UUID: UUID]
        var projectNames: [URL: String]
        /// The tasks are still being read: this computer's index, or the other computer's first snapshot.
        var isRestoring: Bool
    }

    func lists() -> Lists {
        switch self {
        case let .local(model):
            let listed = model.store.listedSessions
            let groups = model.projects.visibleGroups(sessions: listed)
            return Lists(groups: groups, chats: model.projects.chats(sessions: listed),
                         details: model.taskAttentionDetails, shellBusy: model.shellBusySessionIDs,
                         archivedParents: model.store.archivedParentIDs,
                         projectNames: model.projects.projectNames(for: groups), isRestoring: model.isRestoringIndex)
        case let .remote(model):
            let mirror = model.sidebar
            return Lists(groups: mirror.groups, chats: mirror.chats, details: mirror.details, shellBusy: [],
                         archivedParents: [:],
                         projectNames: Dictionary(mirror.groups.map { ($0.workspaceURL, $0.displayName) },
                                                  uniquingKeysWith: { first, _ in first }),
                         isRestoring: !model.hasSnapshot)
        }
    }

    func session(_ id: UUID) -> SessionRecord? {
        switch self {
        case let .local(model): model.store.sessions.first { $0.id == id }
        case let .remote(model): model.sidebar.sessions.first { $0.id == id }
        }
    }

    /// Whether the menus change this computer's projects and folders: Edit project, Remove project, Add project and
    /// the folder in File Explorer, which another computer's projects do not offer here, as on the Mac.
    var managesProjects: Bool {
        if case .local = self { true } else { false }
    }

    /// Whether this computer may rename, delete, mark unread and move the tasks, and archive a project's chats: always
    /// its own, another computer's when that computer allows it.
    var managesTasks: Bool {
        switch self {
        case .local: true
        case let .remote(model): model.taskActions
        }
    }

    /// Whether Home is listed: always here, and for another computer while it can start a task.
    var startsTasks: Bool {
        switch self {
        case .local: true
        case let .remote(model): model.newTask != nil
        }
    }

    /// Whether a Codex task is still attached to the Codex app, which the questions before deleting and archiving say.
    func isAttached(_ session: SessionRecord) -> Bool {
        guard session.harness == .codex else { return false }
        switch self {
        case let .local(model): return model.isAttached(session.id)
        case let .remote(model): return model.tasks.first { $0.id == session.id.uuidString }?.attached == true
        }
    }

    /// The account a task runs on, which its title menu names.
    func accountName(of session: SessionRecord) -> String? {
        switch self {
        case .local: session.connection?.name
        case let .remote(model): model.tasks.first { $0.id == session.id.uuidString }?.accountName
        }
    }
}
