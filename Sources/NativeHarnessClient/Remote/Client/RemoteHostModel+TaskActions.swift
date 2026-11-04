import Foundation
import YardletRemote

extension RemoteHostModel {
    func taskAction(_ session: SessionRecord, _ action: RemoteTaskAction) {
        guard taskActions else { return }
        send(.taskAction(taskID: session.id.uuidString, action: action))
    }

    func projectMoveOptions(_ session: SessionRecord) -> TaskProjectMove.Options {
        return .init(destinations: sidebar.projects.filter { $0.id != session.projectID },
                     removableFrom: tasks.first { $0.id == session.id.uuidString }?.canReturnToChats == true
                        ? sidebar.projects.first { $0.id == session.projectID } : nil)
    }

    func loadArchivedTasks(reset: Bool = true) async {
        guard taskActions, !readingArchive else { return }
        readingArchive = true
        defer { readingArchive = false }
        let answer = await response(to: .archivedTasks(cursor: reset ? nil : archiveCursor))
        if !answer.ok, answer.error?.code == .invalidCursor, !reset {
            readingArchive = false
            await loadArchivedTasks()
            return
        }
        guard answer.ok else { commandError = Self.message(for: answer.error, host: name); return }
        if reset { archiveProjectNames = [:] }
        let rows = (answer.archivedTasks ?? []).compactMap { archived -> ArchivedSessionRecord? in
            guard let id = UUID(uuidString: archived.task.id) else { return nil }
            archiveProjectNames[id] = archived.projectName
            let mirror = RemoteSidebarMirror(hostID: host.id, projects: projects, tasks: [archived.task])
            guard let session = mirror.sessions.first(where: { $0.id == id }) else { return nil }
            return ArchivedSessionRecord(session: session,
                archivedAt: Date(timeIntervalSince1970: Double(archived.archivedAt) / 1000), isProviderArchived: false)
        }
        archivedTasks = reset ? rows : (archivedTasks ?? []) + rows
        archiveCursor = answer.cursor
    }

    func restoreTask(_ record: ArchivedSessionRecord) async {
        restoringArchived.insert(record.id)
        defer { restoringArchived.remove(record.id) }
        if await perform(.taskAction(taskID: record.id.uuidString, action: .init(.unarchive))) {
            await loadArchivedTasks()
        }
    }
}
