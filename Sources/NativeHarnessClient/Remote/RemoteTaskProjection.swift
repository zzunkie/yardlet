import Foundation
import YardletRemote

/// The projects and tasks the phone lists (docs/REMOTE_PROTOCOL.md §4.1): the sidebar's own — its
/// project groups and Chats, not archived tasks — each with the sidebar's attention state and row
/// mark, the same definitions the sidebar dots, the menu bar menu and the Dock badge read
/// (`TaskAttentionProjection`, `SidebarTaskIndicatorProjection`), and under the task the sidebar
/// draws it under (`SidebarProjection.Layout.nestingParents`). No folder paths, accounts or
/// settings are sent.
enum RemoteTaskProjection {
    static let chatsProjectID = "chats"

    static func snapshot(
        groups: [WorkspaceGroup],
        chats: [SessionRecord],
        pinnedIDs: Set<UUID>,
        nestingParents: [UUID: UUID],
        details: [UUID: TaskAttentionDetail],
        shellBusy: Set<UUID>,
        newestRequestID: (SessionRecord) -> String? = { _ in nil },
        requestSummary: (SessionRecord) -> (summary: String?, kind: String)? = { _ in nil }
    ) -> RemoteSnapshot {
        var projects: [RemoteProject] = []
        var listed: [(SessionRecord, String)] = []
        for group in groups {
            let id = projectID(for: group)
            projects.append(RemoteProject(id: id, name: group.displayName, kind: group.project == nil ? .folder : .project,
                                          canCreateTask: true))
            listed += group.sessions.map { ($0, id) }
        }
        if !chats.isEmpty {
            projects.append(RemoteProject(id: chatsProjectID, name: L10n.string("Chats"), kind: .chats, canCreateTask: true))
            listed += chats.map { ($0, chatsProjectID) }
        }
        var seen = Set<UUID>()
        var tasks: [RemoteTask] = []
        var requests: [String: String] = [:]
        var summaries: [String: String] = [:]
        for (session, projectID) in listed.sorted(by: { lhs, rhs in
            lhs.0.updatedAt != rhs.0.updatedAt ? lhs.0.updatedAt > rhs.0.updatedAt : lhs.0.id.uuidString < rhs.0.id.uuidString
        }) where seen.insert(session.id).inserted {
            var task = self.task(session, projectID: projectID, detail: details[session.id],
                                 isShellBusy: shellBusy.contains(session.id), isPinned: pinnedIDs.contains(session.id),
                                 nestedUnder: nestingParents[session.id])
            if task.attention == .waiting, let request = newestRequestID(session) {
                requests[task.id] = request
                let waiting = requestSummary(session)
                summaries[task.id] = waiting?.summary
                task.pendingSummary = waiting?.summary
                task.pendingKind = waiting?.kind
            }
            tasks.append(task)
        }
        return RemoteSnapshot(projects: projects, tasks: tasks, newestRequestIDs: requests, requestSummaries: summaries)
    }

    static func task(
        _ session: SessionRecord,
        projectID: String?,
        detail: TaskAttentionDetail?,
        isShellBusy: Bool,
        isPinned: Bool,
        nestedUnder: UUID?
    ) -> RemoteTask {
        let attention: RemoteAttention = switch TaskAttentionProjection.state(of: session, detail: detail, isShellBusy: isShellBusy) {
        case .waiting: .waiting
        case .unread: .unread
        case .active: .active
        case .idle: .idle
        }
        let indicator: RemoteIndicator? = switch SidebarTaskIndicatorProjection.status(of: session, detail: detail, isShellBusy: isShellBusy) {
        case .awaitingApproval?: .awaitingApproval
        // The phone's protocol has no word for a browser tab waiting; the person answers it on the Mac.
        case .needsInput?, .waitingInBrowser?: .needsInput
        case .failed?: .failed
        case .usageLimit?: .usageLimit
        // The phone's protocol has no word for waiting on the network; the task is still working.
        case .running?, .reconnecting?: .running
        case .unread?: .unread
        case nil: nil
        }
        let pending: RemotePendingRequest? = switch TaskAttentionProjection.waitingRequest(of: session, detail: detail) {
        case .approval?: .approval
        case .input?: .input
        case nil: nil
        }
        return RemoteTask(
            id: session.id.uuidString,
            title: session.title,
            harness: session.harness.rawValue,
            harnessName: session.harness.displayName,
            projectId: projectID,
            attention: attention,
            indicator: indicator,
            pendingRequest: pending,
            unread: session.hasUnreadUpdate,
            running: session.status == .running || session.status == .waitingForApproval || isShellBusy,
            pinned: isPinned,
            lastActivityAt: RemoteJSON.milliseconds(session.updatedAt),
            parentTaskId: nestedUnder?.uuidString
        )
    }

    /// The line an attention event says about a request (§5.2): a question's first line, or the call
    /// and what it does — its description, else its command — masked and capped. Never a diff or
    /// file contents.
    static func requestSummary(_ request: PermissionRequest) -> String? {
        switch request.structured {
        case let .questions(questions)?: RemoteSummary.line([questions.first?.question])
        case .plan?: RemoteSummary.line([request.title])
        case nil: RemoteSummary.line([request.title, request.detail ?? request.command])
        }
    }

    /// A request's kind as approval items name it (§6.5).
    static func requestKind(_ request: PermissionRequest) -> String {
        switch request.structured {
        case .questions?: "question"
        case .plan?: "planReview"
        case nil: "approval"
        }
    }

    static func requestKind(_ request: ConversationRequest) -> String {
        switch request.form {
        case .choices: "question"
        case .planReview: "planReview"
        case .freeText, .mcpForm: "form"
        case nil: "approval"
        }
    }

    static func requestSummary(_ request: ConversationRequest) -> String? {
        switch request.form {
        case let .choices(questions): RemoteSummary.line([questions.first?.question])
        case let .freeText(questions): RemoteSummary.line([questions.first?.text ?? request.title])
        case .planReview, .mcpForm: RemoteSummary.line([request.title])
        case nil: RemoteSummary.line([request.title, request.detail ?? request.command])
        }
    }

    /// A project's ID; a folder outside any project is named by a digest of its path, never the path.
    static func projectID(for group: WorkspaceGroup) -> String {
        if let project = group.project { return project.id.uuidString }
        return "folder:" + RemoteDigest.sha256(group.workspaceURL.standardizedFileURL.path(percentEncoded: false)).prefix(16)
    }
}
