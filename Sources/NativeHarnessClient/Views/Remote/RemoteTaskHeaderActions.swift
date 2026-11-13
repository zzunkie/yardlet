import Foundation
import YardletRemote

extension RemoteHostModel {
    var taskHeaderActions: TaskHeaderActions {
        TaskHeaderActions(
            canManageTask: taskActions, managesWorkspace: false,
            accountName: { session in self.tasks.first { $0.id == session.id.uuidString }?.accountName },
            hasOriginalConversation: { session in self.tasks.first { $0.id == session.id.uuidString }?.originalConversation == true },
            hasProviderSession: { session in self.tasks.first { $0.id == session.id.uuidString }?.hasProviderSession == true },
            isAttached: { session in self.tasks.first { $0.id == session.id.uuidString }?.attached == true },
            onResume: { self.taskAction($0, .init(.resume)) },
            onRename: { self.renameTitle = $0.title; self.renameTask = $0 },
            onTogglePinned: { self.send(.setPinned(taskID: $0.id.uuidString, pinned: !$0.isPinned)) },
            onArchive: { self.send(.archiveTask(taskID: $0.id.uuidString)) },
            onBackToConversation: { self.select(.task($0.id.uuidString)) },
            projectName: { session in self.sidebar.projects.first { $0.id == session.projectID }?.name ?? L10n.string("Chats") },
            projectMoveOptions: projectMoveOptions,
            onMoveToProject: { self.taskAction($0, .init(.move, value: $1?.id.uuidString)) },
            onChooseAccount: taskActions ? { self.accountTask = $0 } : nil,
            canOpenOriginalConversation: { session in self.tasks.first { $0.id == session.id.uuidString }?.canOpenOriginalConversation == true },
            onOpenOriginalConversation: { session in
                Task {
                    let answer = await self.response(to: .openOriginalConversation(taskID: session.id.uuidString))
                    if answer.ok, let id = answer.taskId { self.select(.task(id)) }
                    else { self.commandError = Self.message(for: answer.error, host: self.name) }
                }
            },
            pullRequest: { session in
                RemoteSidebarMirror.pullRequest(self.tasks.first { $0.id == session.id.uuidString }?.pullRequest)
            })
    }
}
