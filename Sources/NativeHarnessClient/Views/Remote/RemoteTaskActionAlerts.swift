import SwiftUI
import YardletRemote

struct RemoteTaskActionAlerts: ViewModifier {
    @Bindable var model: RemoteHostModel
    func body(content: Content) -> some View {
        content
            .sheet(item: $model.accountTask) { session in RemoteTaskAccounts(model: model, session: session) }
            .alert(L10n.string("Archive project chats?"), isPresented: Binding(
                get: { model.archiveProject != nil }, set: { if !$0 { model.archiveProject = nil } })) {
                Button(L10n.string("Cancel"), role: .cancel) { model.archiveProject = nil }
                Button(L10n.string("Archive chats"), role: .destructive) {
                    if let group = model.archiveProject, let id = model.sidebar.projectIDs[group.workspaceURL.standardizedFileURL] {
                        model.send(.projectAction(projectID: id, pinned: nil, archive: true))
                    }
                    model.archiveProject = nil
                }
            } message: {
                if let group = model.archiveProject {
                    Text(L10n.format("Archive project chats confirmation", group.displayName, group.sessions.count))
                    if group.sessions.contains(where: { session in session.harness == .codex && model.tasks.first { $0.id == session.id.uuidString }?.attached == true }) {
                        Text(L10n.string("Archive attached Codex tasks confirmation"))
                    }
                }
            }
            .modifier(TaskRenameAlert(session: $model.renameTask, title: $model.renameTitle) { session, title in
                model.taskAction(session, .init(.rename, value: title))
            })
            .alert(L10n.string("Delete task?"), isPresented: Binding(
                get: { model.deleteTask != nil }, set: { if !$0 { model.deleteTask = nil } })) {
                Button(L10n.string("Cancel"), role: .cancel) { model.deleteTask = nil }
                Button(L10n.string("Delete task"), role: .destructive) {
                    if let session = model.deleteTask { model.taskAction(session, .init(.delete, confirmed: true)) }
                    model.deleteTask = nil
                }
            } message: {
                if let session = model.deleteTask {
                    Text(L10n.format(session.harness == .codex && model.tasks.first { $0.id == session.id.uuidString }?.attached == true
                         ? "Delete attached Codex task confirmation" : "Delete task confirmation", session.title))
                }
            }
    }
}
