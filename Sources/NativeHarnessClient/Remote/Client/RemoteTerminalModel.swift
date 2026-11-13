import Foundation
import Observation
import YardletRemote

/// The window's shells on the host. Reconnection never silently starts another shell or repeats input. A host that keeps
/// shells (`terminalReattach`, §15.29) keeps them when the window closes or the connection ends: a new connection attaches
/// them again, and the window's first terminal for a task, opened later, takes back what this device left there.
@MainActor @Observable
final class RemoteTerminalModel {
    @ObservationIgnored weak var model: RemoteHostModel?
    @ObservationIgnored private var streams: [UUID: RemoteTerminalStream] = [:]
    @ObservationIgnored private var byTerminalID: [String: RemoteTerminalStream] = [:]
    @ObservationIgnored var workspaces: [String: TaskWorkspaceState] = [:]
    /// Tasks this window opened a terminal for, and how many more kept shells are still being opened as tabs.
    @ObservationIgnored private var openedTasks: Set<String> = []
    @ObservationIgnored private var resuming: [String: Int] = [:]
    /// Kept shells whose tabs closed while the connection was away: the next connection ends them first.
    @ObservationIgnored private var closing: [(taskID: String, terminalID: String)] = []

    var keepsTerminals: Bool { model?.offersTerminalReattach == true }

    func makeStream(taskID: String) -> RemoteTerminalStream {
        let stream = RemoteTerminalStream(owner: self, taskID: taskID)
        if openedTasks.insert(taskID).inserted {
            stream.resumes = true
            stream.opensKeptTabs = true
        } else if let left = resuming[taskID], left > 0 {
            resuming[taskID] = left - 1
            stream.resumes = true
        }
        streams[stream.id] = stream
        return stream
    }

    func track(_ stream: RemoteTerminalStream) { streams[stream.id] = stream }
    func release(_ stream: RemoteTerminalStream) { streams[stream.id] = nil }
    func register(_ stream: RemoteTerminalStream, terminalID: String) { byTerminalID[terminalID] = stream }
    func unregister(_ terminalID: String?) { if let terminalID { byTerminalID[terminalID] = nil } }

    func receive(_ event: RemoteEvent) {
        guard let id = event.terminalId, let stream = byTerminalID[id], stream.taskID == event.taskId else { return }
        stream.receive(event)
    }

    /// The host kept `count` more of this device's shells in the task: each opens as a tab of its own, after the one
    /// that asked, which stays shown.
    func resumeKept(_ count: Int, taskID: String) {
        guard count > 0, let workspace = workspaces[taskID], let shown = workspace.shownTerminal else { return }
        let count = min(count, RemoteProtocol.maxTerminalsPerConnection - 1)
        resuming[taskID, default: 0] += count
        for _ in 0..<count {
            workspace.openTerminalTab(in: shown.workspaceURL, launch: .userLoginShell(), taskID: nil).start()
        }
        resuming[taskID] = nil
        workspace.showTerminalTab(shown)
    }

    /// The connection ended. `final` when it will not come back (removed, or this window stopped); otherwise a host
    /// that keeps shells has them waiting for the next connection.
    func disconnected(final: Bool) {
        for stream in Array(streams.values) { stream.disconnected(waits: !final && keepsTerminals) }
    }

    func closeWhenConnected(taskID: String, terminalID: String) { closing.append((taskID, terminalID)) }

    /// The host's snapshot arrived on a new connection.
    func connected() {
        if let model {
            for kept in closing { model.requestInOrder(.closeTerminal(taskID: kept.taskID, terminalID: kept.terminalID)) }
        }
        closing.removeAll()
        // Shells this window knows go first, so one opening without an ID cannot take theirs.
        let waiting = streams.values.filter(\.waitsForConnection).sorted { ($0.terminalID == nil ? 1 : 0) < ($1.terminalID == nil ? 1 : 0) }
        for stream in waiting { stream.reconnect() }
    }

    func removeTasks(_ ids: [String]) {
        for id in ids { workspaces.removeValue(forKey: id)?.endTerminal() }
    }

    /// The window closes. A host that keeps shells keeps them for this device's next window.
    func close() {
        if keepsTerminals { for stream in Array(streams.values) { stream.leave() } }
        for workspace in workspaces.values { workspace.endTerminal() }
        workspaces.removeAll()
        for stream in Array(streams.values) { stream.stop() }
        streams.removeAll()
        byTerminalID.removeAll()
        openedTasks.removeAll()
        closing.removeAll()
    }
}

@MainActor @Observable
final class RemoteTerminalStream {
    enum Phase: Equatable { case stopped, opening, running, ended, failed(String) }
    let id = UUID()
    let taskID: String
    private(set) var terminalID: String?
    private(set) var phase: Phase = .stopped
    private(set) var foreground: RemoteTerminalStatus?
    private(set) var workspaceURL: URL?
    private(set) var closeReason: String?
    @ObservationIgnored weak var owner: RemoteTerminalModel?
    @ObservationIgnored var onOutput: ((Data) -> Void)?
    @ObservationIgnored var onReady: (() -> Void)?
    @ObservationIgnored var onExit: ((Int32?) -> Void)?
    /// Its first open takes back a shell this device left in the task, if the host kept one.
    @ObservationIgnored var resumes = false
    /// The window's first tab for its task: it alone opens a tab for each further shell the device kept there.
    @ObservationIgnored var opensKeptTabs = false
    /// Opened on a host that keeps it when the connection ends; it waits for the next connection meanwhile.
    @ObservationIgnored private(set) var keepsRunning = false
    @ObservationIgnored private(set) var waitsForConnection = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var columns = 80
    @ObservationIgnored private var rows = 24
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var acknowledgement: Task<Void, Never>?

    init(owner: RemoteTerminalModel?, taskID: String) { self.owner = owner; self.taskID = taskID }

    func start() {
        guard phase != .opening, phase != .running else { return }
        guard let model = owner?.model, model.isConnected else { fail(RemoteError(.unavailable)); return }
        open(on: model)
    }

    /// Opens the shell, or attaches the one it had or the one this device left in the task (`resumes`).
    private func open(on model: RemoteHostModel) {
        owner?.track(self)
        generation += 1
        let current = generation
        let taskID = self.taskID
        let keeps = owner?.keepsTerminals == true
        let attaching = keeps ? terminalID : nil
        let resuming = keeps && attaching == nil && resumes
        let opensKeptTabs = resuming && self.opensKeptTabs
        resumes = false
        self.opensKeptTabs = false
        keepsRunning = keeps
        waitsForConnection = false
        phase = .opening
        model.requestInOrder(.openTerminal(taskID: taskID, columns: columns, rows: rows, keepRunning: keeps,
                                           terminalID: attaching, resume: resuming)) { [weak self, weak model] response in
            guard let self, current == self.generation else {
                if let id = response.terminalId { model?.requestInOrder(.closeTerminal(taskID: taskID, terminalID: id)) }
                return
            }
            if attaching != nil, !response.ok, response.error?.code == .notFound {
                // It ended on the host while no connection showed it.
                self.terminalID = nil
                self.phase = .ended
                self.owner?.release(self)
                self.onExit?(nil)
                return
            }
            guard response.ok, let id = response.terminalId else { self.terminalID = nil; self.fail(response.error); return }
            self.terminalID = id
            self.owner?.register(self, terminalID: id)
            self.sequence = 0
            self.phase = .running
            self.sendSize()
            if attaching == nil { self.onReady?() }
            Task { [weak self] in _ = await self?.readForeground() }
            if opensKeptTabs, let more = response.detachedTerminals { self.owner?.resumeKept(more, taskID: taskID) }
        }
    }

    func send(_ data: Data) {
        guard phase == .running, let terminalID, let model = owner?.model else { return }
        foreground = nil
        // Each input batch has a wire bound and a length-only host audit record.
        for offset in stride(from: 0, to: data.count, by: RemoteProtocol.maxTerminalChunkBytes) {
            let chunk = data.subdata(in: offset..<min(data.count, offset + RemoteProtocol.maxTerminalChunkBytes))
            let current = generation
            model.requestInOrder(.terminalInput(taskID: taskID, terminalID: terminalID, data: chunk)) { [weak self] response in
                guard let self, self.generation == current, self.phase == .running, !response.ok else { return }
                self.fail(response.error)
            }
        }
    }

    func readForeground() async -> RemoteTerminalStatus? {
        guard phase == .running, let terminalID, let model = owner?.model else { return nil }
        let current = generation
        let response = await model.response(to: .terminalStatus(taskID: taskID, terminalID: terminalID))
        guard current == generation, phase == .running, response.ok,
              let atPrompt = response.isAtPrompt, let runningProgram = response.isRunningProgram else {
            foreground = nil
            return nil
        }
        if let root = response.workspaceRoot, root.hasPrefix("/") { workspaceURL = URL(filePath: root) }
        let state = RemoteTerminalStatus(isAtPrompt: atPrompt, isRunningProgram: runningProgram, workspaceRoot: response.workspaceRoot)
        foreground = state
        return state
    }

    func resize(columns: Int, rows: Int) {
        let columns = max(2, min(columns, 500)), rows = max(2, min(rows, 300))
        guard self.columns != columns || self.rows != rows else { return }
        self.columns = columns; self.rows = rows
        sendSize()
    }

    private func sendSize() {
        guard phase == .running, let terminalID else { return }
        owner?.model?.requestInOrder(.terminalResize(taskID: taskID, terminalID: terminalID, columns: columns, rows: rows))
    }

    private func acknowledge(_ sequence: Int, terminalID: String) {
        acknowledgement?.cancel()
        acknowledgement = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.phase == .running, self.terminalID == terminalID,
                      self.sequence == sequence, let model = self.owner?.model else { return }
                let response: RemoteResponse = await withCheckedContinuation { continuation in
                    model.requestInOrder(.terminalOutputAck(taskID: self.taskID, terminalID: terminalID, sequence: sequence)) {
                        continuation.resume(returning: $0)
                    }
                }
                guard !Task.isCancelled, self.phase == .running, self.terminalID == terminalID else { return }
                if response.ok { return }
                guard response.error?.code == .rateLimited else { self.fail(response.error); return }
                // Older hosts share ACKs with their terminal input bucket. Retry only flow control, never input.
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() {
        let wasActive = phase == .opening || phase == .running
        generation += 1
        acknowledgement?.cancel()
        if let terminalID {
            if waitsForConnection { owner?.closeWhenConnected(taskID: taskID, terminalID: terminalID) }
            else { owner?.model?.requestInOrder(.closeTerminal(taskID: taskID, terminalID: terminalID)) }
        }
        waitsForConnection = false
        owner?.unregister(terminalID)
        owner?.release(self)
        terminalID = nil
        foreground = nil
        phase = .stopped
        if wasActive { onExit?(nil) }
    }

    /// The window closes and the host keeps the shell: nothing is sent, so the shell waits for this device's next window.
    func leave() {
        guard keepsRunning, phase == .opening || phase == .running || waitsForConnection else { return }
        generation += 1
        acknowledgement?.cancel()
        waitsForConnection = false
        owner?.unregister(terminalID)
        owner?.release(self)
        terminalID = nil
        foreground = nil
        phase = .stopped
    }

    /// With `waits`, a shell the host keeps stays this tab's and attaches again on the next connection, its screen repainted.
    func disconnected(waits: Bool) {
        guard phase == .opening || phase == .running || waitsForConnection else { return }
        generation += 1
        acknowledgement?.cancel()
        owner?.unregister(terminalID)
        foreground = nil
        if waits, keepsRunning {
            phase = .opening
            waitsForConnection = true
            // An open the connection took with it may have left a kept shell this tab never heard of.
            if terminalID == nil { resumes = true }
            return
        }
        waitsForConnection = false
        owner?.release(self)
        terminalID = nil
        phase = .failed(L10n.string("Connection lost"))
        onExit?(nil)
    }

    func reconnect() {
        guard waitsForConnection, let model = owner?.model, model.isConnected else { return }
        guard owner?.keepsTerminals == true else {
            waitsForConnection = false
            terminalID = nil
            fail(RemoteError(.unavailable))
            return
        }
        open(on: model)
    }

    fileprivate func receive(_ event: RemoteEvent) {
        guard phase == .running, let terminalID else { return }
        switch event.event {
        case .terminalOutput:
            guard let data = event.data, let next = event.sequence, next == sequence + 1,
                  data.count <= RemoteProtocol.maxTerminalChunkBytes else {
                stop(); fail(RemoteError(.unavailable)); return
            }
            sequence = next
            onOutput?(data)
            acknowledge(next, terminalID: terminalID)
        case .terminalClosed where event.reason == "outputTimeout" && keepsRunning:
            // The host kept the shell when an acknowledgement ran late: attach it again, its screen repainted.
            acknowledgement?.cancel()
            owner?.unregister(terminalID)
            foreground = nil
            if let model = owner?.model, model.isConnected { open(on: model) } else { waitsForConnection = true; phase = .opening }
        case .terminalClosed:
            acknowledgement?.cancel()
            closeReason = event.reason
            owner?.unregister(terminalID)
            owner?.release(self)
            self.terminalID = nil
            foreground = nil
            phase = event.reason == "exited" || event.reason == "closed" ? .ended
                : .failed(L10n.string("The remote terminal was closed."))
            onExit?(event.exitCode)
        default: break
        }
    }

    private func fail(_ error: RemoteError?) {
        acknowledgement?.cancel()
        if let terminalID { owner?.model?.requestInOrder(.closeTerminal(taskID: taskID, terminalID: terminalID)) }
        owner?.unregister(terminalID)
        owner?.release(self)
        terminalID = nil
        let message = error?.code == .notAllowed
            ? L10n.string("Allow Terminal for this device in the host's Remote Connections settings.")
            : error?.code == .rateLimited && phase == .opening
                ? L10n.string("The host's remote terminal limit has been reached. Close an unused terminal.")
                : L10n.string("The remote terminal is unavailable.")
        phase = .failed(message)
        onExit?(nil)
    }
}
