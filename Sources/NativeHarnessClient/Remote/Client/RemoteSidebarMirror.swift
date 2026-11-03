import Foundation
import YardletRemote

/// A host's projects and tasks in the shapes this Mac's own sidebar and Task menu read (`WorkspaceGroup`,
/// `SessionRecord`, `TaskAttentionDetail`), so another Mac's window lists them with the same sidebar: in the host's
/// order, nested as the host nests them, with the mark the host's row shows (§4.1). A task keeps the host's ID, a
/// UUID. A project's folder is a path no Mac has, standing only for its group: nothing reads it and nothing here
/// touches this Mac's disk.
struct RemoteSidebarMirror: Equatable {
    var groups: [WorkspaceGroup] = []
    var chats: [SessionRecord] = []
    var details: [UUID: TaskAttentionDetail] = [:]
    /// The host's projects, as the sidebar's project rows and New task in a project read them.
    var projects: [Project] = []
    /// The host's project ID of each group, by the group's folder.
    var projectIDs: [URL: String] = [:]

    var sessions: [SessionRecord] { groups.flatMap(\.sessions) + chats }

    init() {}

    init(hostID: String, projects remoteProjects: [RemoteProject], tasks: [RemoteTask]) {
        let root = URL(filePath: "/yardlet-remote", directoryHint: .isDirectory).appending(path: hostID, directoryHint: .isDirectory)
        var folders: [String: URL] = [:]
        var projectsByID: [String: Project] = [:]
        for (index, remote) in remoteProjects.enumerated() where remote.kind != .chats {
            // The group's name is its folder's last part where no project names it.
            let folder = root.appending(path: "\(index)", directoryHint: .isDirectory)
                .appending(path: remote.name.isEmpty ? remote.id : remote.name, directoryHint: .isDirectory)
            folders[remote.id] = folder
            projectIDs[folder.standardizedFileURL] = remote.id
            if remote.kind == .project, let id = UUID(uuidString: remote.id) {
                let project = Project(id: id, name: remote.name, primaryRoot: folder)
                projectsByID[remote.id] = project
                projects.append(project)
            }
        }
        let chatsFolder = root.appending(path: "chats", directoryHint: .isDirectory)
        var sessionsByProject: [String: [SessionRecord]] = [:]
        for task in tasks {
            guard let id = UUID(uuidString: task.id) else { continue }
            // A task of a project the host does not list is a chat, as the host's sidebar would list it.
            let projectID = task.projectId.flatMap { folders[$0] == nil ? nil : $0 } ?? RemoteTaskProjection.chatsProjectID
            let session = Self.session(task, id: id, folder: folders[projectID] ?? chatsFolder, project: projectsByID[projectID])
            sessionsByProject[projectID, default: []].append(session)
            if let detail = Self.detail(task) { details[id] = detail }
        }
        for remote in remoteProjects where remote.kind != .chats {
            guard let folder = folders[remote.id] else { continue }
            groups.append(WorkspaceGroup(workspaceURL: folder, sessions: sessionsByProject[remote.id] ?? [],
                                         project: projectsByID[remote.id]))
        }
        chats = sessionsByProject[RemoteTaskProjection.chatsProjectID] ?? []
    }

    /// The host's task as a record the sidebar reads: its harness, title, when it was last active, its pin, the task
    /// it is nested under, and a status the host's mark reads back from.
    static func session(_ task: RemoteTask, id: UUID, folder: URL, project: Project?) -> SessionRecord {
        let status: SessionStatus = switch task.indicator {
        // A tab handed to the person is the browser's wait, not the turn's (`detail`).
        case .needsInput? where isHandoff(task): task.running ? .running : .ready
        case .awaitingApproval?, .needsInput?: .waitingForApproval
        case .failed?: .failed
        case .running?: .running
        case .usageLimit?, .unread?, nil: task.running ? .running : .ready
        }
        let updatedAt = Date(timeIntervalSince1970: TimeInterval(task.lastActivityAt) / 1000)
        return SessionRecord(id: id, harness: HarnessKind(rawValue: task.harness), workspaceURL: folder,
                             runtimeExecutableURL: folder, title: task.title, status: status, createdAt: updatedAt,
                             updatedAt: updatedAt, hasUnreadUpdate: task.unread,
                             completionState: completion(task), isPinned: task.pinned,
                             projectID: project?.id, parentTaskID: task.parentTaskId.flatMap(UUID.init(uuidString:)))
    }

    /// How the latest turn ended, where the host's list says: failed, or finished with a result still unread.
    private static func completion(_ task: RemoteTask) -> SessionCompletionState {
        if task.indicator == .failed { return .failed }
        return task.unread && !task.running ? .completed : .none
    }

    /// What the host's mark says beyond the record: the request a task waits on, a tab handed to the person, a plan
    /// limit.
    static func detail(_ task: RemoteTask) -> TaskAttentionDetail? {
        var detail = TaskAttentionDetail()
        if isHandoff(task) { detail.browserWait = BrowserPersonWait(kind: .handoff, id: task.id) }
        switch task.indicator {
        case .awaitingApproval?: detail.pendingRequest = .approval
        case .needsInput? where !isHandoff(task): detail.pendingRequest = .input
        case .usageLimit?: detail.usageLimit = HarnessRateLimit(status: .rejected)
        default: break
        }
        return detail == .none ? nil : detail
    }

    /// A tab the host's agent handed to the person (§15.18), which the host lists as a wait for input.
    private static func isHandoff(_ task: RemoteTask) -> Bool {
        task.attention == .waiting && task.pendingKind == "browserHandoff"
    }
}
