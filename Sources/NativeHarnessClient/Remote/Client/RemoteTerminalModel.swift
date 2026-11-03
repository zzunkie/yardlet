import Foundation
import Observation
import YardletRemote

/// Connection-owned shells. Reconnection never silently starts another shell or repeats input.
@MainActor @Observable
final class RemoteTerminalModel {
    @ObservationIgnored weak var model: RemoteHostModel?
    @ObservationIgnored private var streams: [UUID: RemoteTerminalStream] = [:]
    @ObservationIgnored private var byTerminalID: [String: RemoteTerminalStream] = [:]
    @ObservationIgnored var workspaces: [String: TaskWorkspaceState] = [:]

    func makeStream(taskID: String) -> RemoteTerminalStream {
        let stream = RemoteTerminalStream(owner: self, taskID: taskID)
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

    func disconnected() { for stream in Array(streams.values) { stream.disconnected() } }
    func removeTasks(_ ids: [String]) {
        for id in ids { workspaces.removeValue(forKey: id)?.endTerminal() }
    }
    func close() {
        for workspace in workspaces.values { workspace.endTerminal() }
        workspaces.removeAll()
        for stream in Array(streams.values) { stream.stop() }
        streams.removeAll()
        byTerminalID.removeAll()
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
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var columns = 80
    @ObservationIgnored private var rows = 24
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var acknowledgement: Task<Void, Never>?

    init(owner: RemoteTerminalModel?, taskID: String) { self.owner = owner; self.taskID = taskID }

    func start() {
        guard phase != .opening, phase != .running else { return }
        guard let model = owner?.model, model.isConnected else { fail(RemoteError(.unavailable)); return }
        owner?.track(self)
        generation += 1
        let current = generation
        let taskID = self.taskID
        phase = .opening
        model.requestInOrder(.openTerminal(taskID: taskID, columns: columns, rows: rows)) { [weak self, weak model] response in
            guard let self, current == self.generation else {
                if let id = response.terminalId { model?.requestInOrder(.closeTerminal(taskID: taskID, terminalID: id)) }
                return
            }
            guard response.ok, let id = response.terminalId else { self.fail(response.error); return }
            self.terminalID = id
            self.owner?.register(self, terminalID: id)
            self.sequence = 0
            self.phase = .running
            self.sendSize()
            self.onReady?()
            Task { [weak self] in _ = await self?.readForeground() }
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
        if let terminalID { owner?.model?.requestInOrder(.closeTerminal(taskID: taskID, terminalID: terminalID)) }
        owner?.unregister(terminalID)
        owner?.release(self)
        terminalID = nil
        foreground = nil
        phase = .stopped
        if wasActive { onExit?(nil) }
    }

    func disconnected() {
        guard phase == .opening || phase == .running else { return }
        generation += 1
        acknowledgement?.cancel()
        owner?.unregister(terminalID)
        owner?.release(self)
        terminalID = nil
        foreground = nil
        phase = .failed(L10n.string("Connection lost"))
        onExit?(nil)
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
