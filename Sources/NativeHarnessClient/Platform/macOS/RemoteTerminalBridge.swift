import Foundation
import YardletRemote

/// Remote shells are the host task's ordinary terminal tabs, visible to its local panel and tools. A shell's output goes
/// to the one connection attached to it; one kept after its connection ended (§15.29) goes on with the host's screen
/// alone until its device attaches again, and the attach starts with a repaint of that screen. Each connection is one of
/// the shell's renderers for its size (`NativeTerminalSession.use`), and the size goes out with the output after it.
@MainActor
final class RemoteTerminalBridge {
    static let isAvailable = true

    final class Entry {
        let taskID: String
        let session: NativeTerminalSession
        /// The attached connection's permit and output; nil while kept without one.
        fileprivate(set) var permit: RemoteTerminalPermit?
        fileprivate var output: (@Sendable (RemoteTerminalUpdate) async -> Void)?
        /// What the host's emulator took and the attached connection has not been given yet, in order.
        fileprivate var pending: [RemoteTerminalUpdate] = []
        /// The one producer giving `pending` to `output`; the PTY's next read waits for it.
        fileprivate var delivery: Task<Void, Never>?
        /// Told when the shell ends after it was detached (`detach`).
        fileprivate var ended: (@Sendable () async -> Void)?

        init(taskID: String, session: NativeTerminalSession) {
            self.taskID = taskID
            self.session = session
        }
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
        let entry = Entry(taskID: task.id.uuidString, session: session)
        entry.permit = permit
        entry.output = output
        sessions[terminalID] = entry
        guard let hosting = session.hosting as? LocalTerminalHosting else {
            session.end(); sessions[terminalID] = nil; return RemoteError(.unavailable)
        }
        // Local Close/Restart must release a producer waiting for an ACK immediately.
        session.onStop = { [weak self] in self?.stopped(terminalID) }
        // The emulator took these bytes: they go to whichever connection is attached now, so a repaint taken at an
        // attach and the output after it never miss or repeat a byte.
        session.onOutput = { [weak entry] bytes in
            guard let entry, entry.output != nil else { return }
            entry.pending.append(.output(Data(bytes)))
        }
        // The size goes with the output after it, which the shell writes for that size.
        session.onResize = { [weak entry] size in
            guard let entry, entry.output != nil else { return }
            entry.pending.append(.resized(columns: size.columns, rows: size.rows))
        }
        hosting.outputConsumer = { [weak self] update in
            await self?.consume(update, terminalID: terminalID)
        }
        session.request(.remote(terminalID), columns: columns, rows: rows)
        session.use(.remote(terminalID))
        entry.pending = [.resized(columns: session.size.columns, rows: session.size.rows)]
        guard permit.isValid else { close(taskID: task.id.uuidString, terminalID: terminalID); return RemoteError(.notAllowed) }
        session.start()
        guard session.isRunning else { close(taskID: task.id.uuidString, terminalID: terminalID); return RemoteError(.unavailable) }
        return nil
    }

    /// A kept shell for another connection: sized for it first, so the repaint fits its screen and the shell's own
    /// redraw for the new size follows.
    func attach(taskID: String, terminalID: String, columns: Int, rows: Int, permit: RemoteTerminalPermit,
                output: @escaping @Sendable (RemoteTerminalUpdate) async -> Void) -> RemoteError? {
        guard permit.isValid else { return RemoteError(.notAllowed) }
        guard let entry = sessions[terminalID], entry.taskID == taskID, entry.session.isRunning else { return RemoteError(.notFound) }
        entry.permit?.revoke()
        entry.session.request(.remote(terminalID), columns: columns, rows: rows)
        entry.session.use(.remote(terminalID))
        guard let repaint = entry.session.screenRepaint else { return RemoteError(.notFound) }
        entry.permit = permit
        entry.output = output
        entry.pending = [.resized(columns: entry.session.size.columns, rows: entry.session.size.rows), .output(repaint)]
        Task { await deliver(terminalID) }
        return nil
    }

    /// The connection ended. A later attach may already have replaced `permit`; then this is stale and changes nothing.
    func detach(taskID: String, terminalID: String, permit: RemoteTerminalPermit, ended: @escaping @Sendable () async -> Void) {
        guard let entry = sessions[terminalID], entry.taskID == taskID, entry.session.isRunning else {
            Task { await ended() }
            return
        }
        entry.ended = ended
        guard entry.permit === permit else { return }
        entry.permit = nil
        entry.output = nil
        entry.pending.removeAll()
        entry.session.removeViewer(.remote(terminalID))
    }

    private func consume(_ update: TerminalStreamUpdate, terminalID: String) async {
        guard let entry = sessions[terminalID] else { return }
        if case let .exited(status) = update {
            guard entry.output != nil else {
                // Kept with no connection: the server forgets it, and the host tab stays as local tabs do.
                let ended = entry.ended
                close(taskID: entry.taskID, terminalID: terminalID)
                await ended?()
                return
            }
            entry.pending.append(.exited(status))
        }
        await deliver(terminalID)
    }

    /// Gives what is pending to the attached connection, waiting for its room; one delivery at a time.
    private func deliver(_ terminalID: String) async {
        while let entry = sessions[terminalID] {
            if let running = entry.delivery {
                await running.value
                continue
            }
            guard !entry.pending.isEmpty, entry.output != nil else { return }
            let delivery = Task { @MainActor [weak entry] in
                while let entry, let output = entry.output, let permit = entry.permit, !entry.pending.isEmpty {
                    let update = entry.pending.removeFirst()
                    guard case let .output(data) = update else { await output(update); continue }
                    for offset in stride(from: 0, to: data.count, by: RemoteProtocol.maxTerminalChunkBytes) {
                        guard permit.isValid else { break }
                        await output(.output(data.subdata(in: offset..<min(data.count, offset + RemoteProtocol.maxTerminalChunkBytes))))
                    }
                }
                entry?.delivery = nil
            }
            entry.delivery = delivery
            await delivery.value
        }
    }

    /// The host closed or restarted the tab, or its task ended.
    private func stopped(_ terminalID: String) {
        guard let entry = sessions.removeValue(forKey: terminalID) else { return }
        entry.session.removeViewer(.remote(terminalID))
        entry.permit?.revoke()
        // Notify even if the process delegate already finished or its queued exit was discarded by revocation.
        if let output = entry.output { Task { await output(.exited(nil)) } }
        if let ended = entry.ended { Task { await ended() } }
        release(entry)
    }

    func input(taskID: String, terminalID: String, data: Data, permit: RemoteTerminalPermit) -> RemoteError? {
        guard let entry = sessions[terminalID], entry.taskID == taskID, entry.permit === permit,
              permit.isValid else { return RemoteError(.notAllowed) }
        guard entry.session.isRunning else { return RemoteError(.unavailable) }
        entry.session.use(.remote(terminalID))
        entry.session.send(Array(data)[...])
        return nil
    }

    func resize(taskID: String, terminalID: String, columns: Int, rows: Int, permit: RemoteTerminalPermit) -> RemoteError? {
        guard let entry = sessions[terminalID], entry.taskID == taskID, entry.permit === permit,
              permit.isValid else { return RemoteError(.notAllowed) }
        entry.session.request(.remote(terminalID), columns: columns, rows: rows)
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
        entry.session.removeViewer(.remote(terminalID))
        entry.permit?.revoke()
        release(entry)
        // A naturally exited tab already visible on the host keeps its screen, as local tabs do.
        if entry.session.isRunning || !entry.session.hasVisiblePanel { entry.session.end() }
    }

    private func release(_ entry: Entry) {
        entry.output = nil
        entry.pending.removeAll()
        entry.ended = nil
        entry.session.onOutput = nil
        entry.session.onExit = nil
        entry.session.onStop = nil
        entry.session.onResize = nil
        (entry.session.hosting as? LocalTerminalHosting)?.outputConsumer = nil
    }
}
