import Foundation
import YardletRemote

/// Remote shells are the host task's ordinary terminal tabs, visible to its local panel and tools.
@MainActor
final class RemoteTerminalBridge {
    static let isAvailable = true
    struct Entry {
        let taskID: String
        let session: NativeTerminalSession
        let permit: RemoteTerminalPermit
    }
    private(set) var sessions: [String: Entry] = [:]
    var launch: ShellLaunchEnvironment = .userLoginShell()

    func open(model: AppModel, task: SessionRecord, terminalID: String, columns: Int, rows: Int,
              permit: RemoteTerminalPermit, output: @escaping @Sendable (RemoteTerminalUpdate) async -> Void) -> RemoteError? {
        guard permit.isValid else { return RemoteError(.notAllowed) }
        guard sessions[terminalID] == nil else { return RemoteError(.badRequest) }
        let workspace = model.taskWorkspaces.state(for: task.id)
        let session = workspace.openTerminalTab(in: task.workspaceURL, launch: launch, taskID: task.id, allowsClipboard: false)
        session.markRemoteOrigin()
        sessions[terminalID] = Entry(taskID: task.id.uuidString, session: session, permit: permit)
        guard let hosting = session.hosting as? LocalTerminalHosting else {
            session.end(); sessions[terminalID] = nil; return RemoteError(.unavailable)
        }
        session.onStop = { [weak self, weak session, weak hosting] in
            // Local Close/Restart must release a producer waiting for an ACK immediately.
            permit.revoke()
            // Notify even if the process delegate already finished or its queued exit was discarded by revocation.
            Task { await output(.exited(nil)) }
            self?.sessions[terminalID] = nil
            hosting?.outputConsumer = nil
            session?.onStop = nil
        }
        hosting.outputConsumer = { update in
            switch update {
            case let .output(data):
                for offset in stride(from: 0, to: data.count, by: RemoteProtocol.maxTerminalChunkBytes) {
                    guard permit.isValid else { return }
                    await output(.output(data.subdata(in: offset..<min(data.count, offset + RemoteProtocol.maxTerminalChunkBytes))))
                }
            case let .exited(status): await output(.exited(status))
            }
        }
        session.resize(columns: columns, rows: rows)
        guard permit.isValid else { close(taskID: task.id.uuidString, terminalID: terminalID); return RemoteError(.notAllowed) }
        session.start()
        guard session.isRunning else { close(taskID: task.id.uuidString, terminalID: terminalID); return RemoteError(.unavailable) }
        return nil
    }

    func input(taskID: String, terminalID: String, data: Data, permit: RemoteTerminalPermit) -> RemoteError? {
        guard let entry = sessions[terminalID], entry.taskID == taskID, entry.permit === permit,
              permit.isValid else { return RemoteError(.notAllowed) }
        guard entry.session.isRunning else { return RemoteError(.unavailable) }
        entry.session.send(Array(data)[...])
        return nil
    }

    func resize(taskID: String, terminalID: String, columns: Int, rows: Int, permit: RemoteTerminalPermit) -> RemoteError? {
        guard let entry = sessions[terminalID], entry.taskID == taskID, entry.permit === permit,
              permit.isValid else { return RemoteError(.notAllowed) }
        entry.session.resize(columns: columns, rows: rows)
        return nil
    }

    func status(taskID: String, terminalID: String, permit: RemoteTerminalPermit) -> Result<RemoteTerminalStatus, RemoteError> {
        guard let entry = sessions[terminalID], entry.taskID == taskID, entry.permit === permit,
              permit.isValid else { return .failure(RemoteError(.notAllowed)) }
        return .success(RemoteTerminalStatus(isAtPrompt: entry.session.isAtPrompt, isRunningProgram: entry.session.isRunningProgram, workspaceRoot: entry.session.workspaceURL.path(percentEncoded: false)))
    }

    func close(taskID: String, terminalID: String) {
        guard let entry = sessions[terminalID], entry.taskID == taskID else { return }
        sessions[terminalID] = nil
        entry.permit.revoke()
        entry.session.onOutput = nil
        entry.session.onExit = nil
        entry.session.onStop = nil
        (entry.session.hosting as? LocalTerminalHosting)?.outputConsumer = nil
        // A naturally exited tab already visible on the host keeps its screen, as local tabs do.
        if entry.session.isRunning || !entry.session.hasVisiblePanel { entry.session.end() }
    }
}
