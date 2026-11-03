import Foundation

struct RemoteTerminalInputAuditKey: Hashable {
    var device: String?
    var task: String?
    var result: String
}

struct RemoteTerminalInputAudit {
    var id = UUID()
    var began: Date
    var bytes: Int
    var timer: Task<Void, Never>?
}

struct RemoteServerTerminal {
    let connection: UUID
    let deviceID: String
    let taskID: String
    let permit: RemoteTerminalPermit
    var opened = false
    var output: [Data] = []
    var sentBytes: Int?
    var sequence = 0
    var exited = false
    var exitCode: Int32?
    var timeout: Task<Void, Never>?
}

extension RemoteServer {
    /// Acknowledging the single output chunk in flight cannot create more work than that chunk.
    /// Invalid, duplicate, foreign and future acknowledgements keep the normal traffic budget.
    func isExpectedTerminalAcknowledgement(_ request: RemoteRequest, on connection: UUID) -> Bool {
        guard case let .terminalOutputAck(taskID, terminalID, sequence) = request,
              let session = terminals[terminalID], session.connection == connection, session.taskID == taskID,
              session.permit.isValid, session.sequence == sequence, session.sentBytes != nil else { return false }
        return true
    }

    func handleTerminal(_ requestID: String, request: RemoteRequest, on connection: UUID) async {
        let deviceID = connections[connection]?.deviceID
        if let error = permissionError(.terminal, on: connection) {
            respond(.failure(requestID, error), to: connection)
            auditTerminal(request.type, device: deviceID, task: request.taskID, bytes: request.terminalInputBytes,
                          result: error.code.rawValue)
            return
        }
        guard let deviceID else { return }
        if case let .openTerminal(taskID, columns, rows) = request {
            guard terminals.count < RemoteProtocol.maxTerminalsTotal,
                  terminals.values.count(where: { $0.connection == connection }) < RemoteProtocol.maxTerminalsPerConnection else {
                respond(.failure(requestID, RemoteError(.rateLimited)), to: connection)
                auditTerminal(request.type, device: deviceID, task: taskID, result: "rateLimited")
                return
            }
            let terminalID = UUID().uuidString
            let permit = RemoteTerminalPermit()
            terminals[terminalID] = RemoteServerTerminal(connection: connection, deviceID: deviceID, taskID: taskID, permit: permit)
            let error = await bridge.openTerminal(taskID: taskID, terminalID: terminalID, columns: columns, rows: rows,
                                                  permit: permit) { [weak self] update in
                guard let self else { permit.revoke(); return }
                switch await permit.enqueue(update) {
                case .notify: await self.receiveTerminalUpdates(terminalID)
                case .overflow: await self.endTerminal(terminalID, reason: "outputOverflow")
                case .ended:
                    if !permit.isValid { await self.endTerminal(terminalID, reason: "closed") }
                case .queued: break
                }
            }
            let currentPermission = permissionError(.terminal, on: connection)
            let refusal = error ?? currentPermission ?? (permit.isValid ? nil : RemoteError(.notAllowed))
            guard refusal == nil, terminals[terminalID] != nil else {
                endTerminal(terminalID, reason: refusal?.code.rawValue ?? "notAllowed")
                // Covers a bridge returning after its connection's entry was removed while opening.
                permit.revoke()
                await bridge.closeTerminal(taskID: taskID, terminalID: terminalID)
                respond(.failure(requestID, refusal ?? RemoteError(.notAllowed)), to: connection)
                auditTerminal("openTerminal", device: deviceID, task: taskID, result: refusal?.code.rawValue ?? "notAllowed")
                return
            }
            terminals[terminalID]?.opened = true
            var response = RemoteResponse(re: requestID)
            response.taskId = taskID
            response.terminalId = terminalID
            respond(response, to: connection)
            auditTerminal("openTerminal", device: deviceID, task: taskID, result: "ok")
            flushTerminal(terminalID)
            return
        }
        guard let terminalID = request.terminalID, let session = terminals[terminalID],
              session.connection == connection, session.taskID == request.taskID, session.opened else {
            respond(.failure(requestID, RemoteError(.notAllowed)), to: connection)
            auditTerminal(request.type, device: deviceID, task: request.taskID, bytes: request.terminalInputBytes, result: "notAllowed")
            return
        }
        guard session.permit.isValid else {
            endTerminal(terminalID, reason: "closed")
            respond(.failure(requestID, RemoteError(.notFound)), to: connection)
            return
        }
        var error: RemoteError?
        var response = RemoteResponse(re: requestID)
        switch request {
        case let .terminalStatus(taskID, _):
            switch await bridge.terminalStatus(taskID: taskID, terminalID: terminalID, permit: session.permit) {
            case let .success(status):
                if session.permit.isValid {
                    response.isAtPrompt = status.isAtPrompt
                    response.isRunningProgram = status.isRunningProgram
                    response.workspaceRoot = status.workspaceRoot
                } else { error = RemoteError(.notAllowed) }
            case let .failure(failure): error = failure
            }
        case let .terminalInput(taskID, _, data):
            error = await bridge.terminalInput(taskID: taskID, terminalID: terminalID, data: data, permit: session.permit)
            auditTerminal("terminalInput", device: deviceID, task: taskID, bytes: data.count, result: error?.code.rawValue ?? "ok")
        case let .terminalResize(taskID, _, columns, rows):
            error = await bridge.terminalResize(taskID: taskID, terminalID: terminalID, columns: columns, rows: rows, permit: session.permit)
        case .closeTerminal:
            endTerminal(terminalID, reason: "closed")
        case let .terminalOutputAck(_, _, sequence):
            if sequence == session.sequence, let bytes = session.sentBytes {
                session.permit.release(bytes)
                terminals[terminalID]?.sentBytes = nil
                terminals[terminalID]?.timeout?.cancel()
                terminals[terminalID]?.timeout = nil
                flushTerminal(terminalID)
            } else {
                error = RemoteError(.badRequest)
            }
        default: error = RemoteError(.badRequest)
        }
        if !session.permit.isValid, terminals[terminalID] != nil {
            endTerminal(terminalID, reason: "closed")
            error = RemoteError(.notFound)
        }
        respond(error.map { .failure(requestID, $0) } ?? response, to: connection)
    }

    private func receiveTerminalUpdates(_ terminalID: String) {
        guard let session = terminals[terminalID] else { return }
        guard session.permit.isValid else { endTerminal(terminalID, reason: "closed"); return }
        for update in session.permit.takeUpdates() {
            switch update {
            case let .output(data): terminals[terminalID]?.output.append(data)
            case let .exited(code):
                terminals[terminalID]?.exited = true
                terminals[terminalID]?.exitCode = code
            }
        }
        flushTerminal(terminalID)
    }

    private func flushTerminal(_ terminalID: String) {
        guard var session = terminals[terminalID], session.opened, session.permit.isValid, session.sentBytes == nil else { return }
        guard !session.output.isEmpty else {
            if session.exited { endTerminal(terminalID, reason: "exited", exitCode: session.exitCode) }
            return
        }
        let data = session.output.removeFirst()
        session.sequence += 1
        session.sentBytes = data.count
        let sequence = session.sequence
        session.timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.terminalTimedOut(terminalID, sequence: sequence)
        }
        terminals[terminalID] = session
        var event = RemoteEvent(.terminalOutput)
        event.taskId = session.taskID
        event.terminalId = terminalID
        event.data = data
        event.sequence = sequence
        send(event, to: session.connection)
    }

    private func terminalTimedOut(_ terminalID: String, sequence: Int) {
        guard let session = terminals[terminalID], session.sequence == sequence, session.sentBytes != nil else { return }
        endTerminal(terminalID, reason: "outputTimeout")
    }

    func endTerminals(deviceID: String, reason: String) {
        let owned = terminals.keys.filter { terminals[$0]?.deviceID == deviceID }
        for id in owned { terminals[id]?.permit.revoke() }
        flushTerminalInputAudits(deviceID: deviceID)
        for id in owned { endTerminal(id, reason: reason) }
    }

    func endTerminals(on connection: UUID, reason: String) {
        let owned = terminals.keys.filter { terminals[$0]?.connection == connection }
        for id in owned { terminals[id]?.permit.revoke() }
        flushTerminalInputAudits()
        for id in owned { endTerminal(id, reason: reason) }
    }

    func endTerminal(_ terminalID: String, reason: String, exitCode: Int32? = nil) {
        guard let session = terminals.removeValue(forKey: terminalID) else { return }
        session.permit.revoke()
        flushTerminalInputAudits(deviceID: session.deviceID, taskID: session.taskID)
        session.timeout?.cancel()
        if session.opened {
            var event = RemoteEvent(.terminalClosed)
            event.taskId = session.taskID
            event.terminalId = terminalID
            event.reason = reason
            event.exitCode = exitCode
            send(event, to: session.connection)
        }
        auditTerminal("closeTerminal", device: session.deviceID, task: session.taskID, result: reason)
        Task { await bridge.closeTerminal(taskID: session.taskID, terminalID: terminalID) }
    }

    /// Keystrokes and paste chunks are one short audit batch, never one line per byte or packet.
    func auditTerminal(_ type: String, device: String?, task: String?, bytes: Int? = nil, result: String) {
        guard let audit, ["openTerminal", "closeTerminal", "terminalInput"].contains(type) else { return }
        guard type == "terminalInput", let bytes else {
            audit.record(device: device, type: type, task: task, byteCount: bytes, result: result, at: now())
            return
        }
        let key = RemoteTerminalInputAuditKey(device: device, task: task, result: result)
        if terminalInputAudits[key] != nil {
            terminalInputAudits[key]?.bytes += bytes
            return
        }
        // Valid sessions need few keys; arbitrary rejected task IDs cannot grow this buffer without a bound.
        if terminalInputAudits.count >= 128, let oldest = terminalInputAudits.min(by: { $0.value.began < $1.value.began }) {
            flushTerminalInputAudit(oldest.key, generation: oldest.value.id)
        }
        var batch = RemoteTerminalInputAudit(began: now(), bytes: bytes)
        let generation = batch.id
        batch.timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.flushTerminalInputAudit(key, generation: generation)
        }
        terminalInputAudits[key] = batch
    }

    func flushTerminalInputAudits(deviceID: String? = nil, taskID: String? = nil) {
        let selected = terminalInputAudits.filter {
            (deviceID == nil || $0.key.device == deviceID) && (taskID == nil || $0.key.task == taskID)
        }
        for (key, batch) in selected { flushTerminalInputAudit(key, generation: batch.id) }
    }

    private func flushTerminalInputAudit(_ key: RemoteTerminalInputAuditKey, generation: UUID) {
        guard let batch = terminalInputAudits[key], batch.id == generation else { return }
        terminalInputAudits[key] = nil
        batch.timer?.cancel()
        audit?.record(device: key.device, type: "terminalInput", task: key.task, byteCount: batch.bytes,
                      result: key.result, at: batch.began)
    }

}

private extension RemoteRequest {
    var terminalID: String? {
        switch self {
        case let .terminalInput(_, id, _), let .terminalResize(_, id, _, _), let .closeTerminal(_, id),
             let .terminalOutputAck(_, id, _), let .terminalStatus(_, id): id
        default: nil
        }
    }
    var terminalInputBytes: Int? {
        if case let .terminalInput(_, _, data) = self { data.count } else { nil }
    }
}
