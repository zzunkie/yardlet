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
    /// The connection it belongs to; nil while a kept shell waits for its device to attach again.
    var connection: UUID?
    let deviceID: String
    let taskID: String
    var permit: RemoteTerminalPermit
    /// Opened with `keepRunning` on a host whose bridge keeps shells: the end of its connection detaches it.
    var keepsRunning = false
    /// Its place among the server's opens, so kept shells attach again in the order they were opened.
    var order = 0
    /// Answered for this connection: open, or attached again.
    var opened = false
    /// The bridge started its shell; it stays started while kept and while attaching again.
    var hasShell = false
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
        if case let .openTerminal(taskID, columns, rows, keepRunning, keptID, resume) = request {
            let keeps = (keepRunning || keptID != nil || resume) && bridgeKeepsTerminals
            if keeps, keptID != nil || resume {
                if let kept = keptTerminal(keptID, deviceID: deviceID, taskID: taskID) {
                    await attachKeptTerminal(kept, requestID: requestID, on: connection, deviceID: deviceID,
                                             columns: columns, rows: rows, counts: resume)
                    return
                }
                if keptID != nil {
                    respond(.failure(requestID, RemoteError(.notFound)), to: connection)
                    auditTerminal("attachTerminal", device: deviceID, task: taskID, result: "notFound")
                    return
                }
            } else if keptID != nil {
                respond(.failure(requestID, RemoteError(.notFound)), to: connection)
                return
            }
            guard terminals.count < RemoteProtocol.maxTerminalsTotal,
                  terminals.values.count(where: { $0.connection == connection }) < RemoteProtocol.maxTerminalsPerConnection else {
                respond(.failure(requestID, RemoteError(.rateLimited)), to: connection)
                auditTerminal(request.type, device: deviceID, task: taskID, result: "rateLimited")
                return
            }
            let terminalID = UUID().uuidString
            let permit = RemoteTerminalPermit()
            terminalOpens += 1
            terminals[terminalID] = RemoteServerTerminal(connection: connection, deviceID: deviceID, taskID: taskID, permit: permit,
                                                         keepsRunning: keeps, order: terminalOpens)
            let error = await bridge.openTerminal(taskID: taskID, terminalID: terminalID, columns: columns, rows: rows,
                                                  permit: permit, output: terminalSink(terminalID, permit: permit))
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
            terminals[terminalID]?.hasShell = true
            var response = RemoteResponse(re: requestID)
            response.taskId = taskID
            response.terminalId = terminalID
            if keeps, resume { response.detachedTerminals = keptCount(deviceID: deviceID, taskID: taskID) }
            respond(response, to: connection)
            auditTerminal("openTerminal", device: deviceID, task: taskID, result: "ok")
            flushTerminal(terminalID)
            return
        }
        if case let .closeTerminal(taskID, terminalID) = request, let kept = terminals[terminalID], kept.connection == nil,
           kept.keepsRunning, kept.deviceID == deviceID, kept.taskID == taskID {
            // A tab closed while its connection was away: its device ends the shell it kept.
            endTerminal(terminalID, reason: "closed")
            respond(RemoteResponse(re: requestID), to: connection)
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
            // Ends it only while this permit still holds it: a connection that ended meanwhile detached a kept shell.
            endTerminal(terminalID, reason: "closed", permit: session.permit)
            error = RemoteError(.notFound)
        }
        respond(error.map { .failure(requestID, $0) } ?? response, to: connection)
    }

    /// What the bridge calls with a shell's output for one connection. A permit replaced by a later attach, or revoked
    /// when its connection ended, no longer speaks for the shell.
    private func terminalSink(_ terminalID: String, permit: RemoteTerminalPermit) -> @Sendable (RemoteTerminalUpdate) async -> Void {
        { [weak self] update in
            guard let self else { permit.revoke(); return }
            switch await permit.enqueue(update) {
            case .notify: await self.receiveTerminalUpdates(terminalID, permit: permit)
            case .overflow: await self.endTerminal(terminalID, reason: "outputOverflow", permit: permit)
            case .ended:
                if !permit.isValid { await self.endTerminal(terminalID, reason: "closed", permit: permit) }
            case .queued: break
            }
        }
    }

    /// `id` when this device kept it for `taskID`, or with no `id` the device's earliest shell kept there.
    private func keptTerminal(_ id: String?, deviceID: String, taskID: String) -> String? {
        if let id {
            guard let session = terminals[id], session.deviceID == deviceID, session.taskID == taskID,
                  session.keepsRunning else { return nil }
            return id
        }
        return terminals.filter { $0.value.deviceID == deviceID && $0.value.taskID == taskID && $0.value.keepsRunning
            && $0.value.connection == nil }.min { $0.value.order < $1.value.order }?.key
    }

    private func keptCount(deviceID: String, taskID: String) -> Int {
        terminals.values.count { $0.deviceID == deviceID && $0.taskID == taskID && $0.keepsRunning && $0.connection == nil }
    }

    /// A kept shell goes to `connection`; the bridge's first output repaints its screen. Another connection of the same
    /// device that still holds it (one whose end the transport has not noticed yet) is told it was detached.
    private func attachKeptTerminal(_ terminalID: String, requestID: String, on connection: UUID, deviceID: String,
                                    columns: Int, rows: Int, counts: Bool) async {
        guard var session = terminals[terminalID] else { return }
        let taskID = session.taskID
        func refuse(_ code: RemoteErrorCode) {
            respond(.failure(requestID, RemoteError(code)), to: connection)
            auditTerminal("attachTerminal", device: deviceID, task: taskID, result: code.rawValue)
        }
        if let holder = session.connection {
            // An open or attach still in progress elsewhere, or this connection attaching what it already shows.
            guard session.opened, holder != connection else { return refuse(holder == connection ? .badRequest : .unavailable) }
        }
        guard terminals.values.count(where: { $0.connection == connection }) < RemoteProtocol.maxTerminalsPerConnection else {
            return refuse(.rateLimited)
        }
        if session.connection != nil { detachTerminal(terminalID, telling: "detached") }
        guard let detached = terminals[terminalID] else { return refuse(.notFound) }
        session = detached
        let permit = RemoteTerminalPermit()
        session.connection = connection
        session.permit = permit
        session.opened = false
        session.output = []
        session.sentBytes = nil
        session.sequence = 0
        session.exited = false
        session.exitCode = nil
        terminals[terminalID] = session
        let error = await bridge.attachTerminal(taskID: taskID, terminalID: terminalID, columns: columns, rows: rows,
                                                permit: permit, output: terminalSink(terminalID, permit: permit))
        let current = terminals[terminalID]
        let refusal = error ?? permissionError(.terminal, on: connection)
            ?? (current == nil ? RemoteError(.notFound) : permit.isValid && current?.permit === permit ? nil : RemoteError(.unavailable))
        guard refusal == nil else {
            permit.revoke()
            if current?.permit === permit {
                // The shell ended meanwhile; otherwise it stays kept for a later attach.
                if refusal?.code == .notFound { endTerminal(terminalID, reason: "closed") } else { detachTerminal(terminalID) }
            }
            return refuse(refusal?.code ?? .notAllowed)
        }
        terminals[terminalID]?.opened = true
        var response = RemoteResponse(re: requestID)
        response.taskId = taskID
        response.terminalId = terminalID
        response.resumed = true
        if counts { response.detachedTerminals = keptCount(deviceID: deviceID, taskID: taskID) }
        respond(response, to: connection)
        auditTerminal("attachTerminal", device: deviceID, task: taskID, result: "ok")
        flushTerminal(terminalID)
    }

    /// The shell goes on without this connection; output meanwhile reaches only the host's screen. Its own device
    /// may attach it again (`openTerminal` with its `terminalId`, or `resume`).
    /// `telling`: the reason the connection is sent in `terminalClosed`, when it may still be listening.
    private func detachTerminal(_ terminalID: String, telling: String? = nil) {
        guard var session = terminals[terminalID], let connection = session.connection else { return }
        let permit = session.permit
        permit.revoke()
        flushTerminalInputAudits(deviceID: session.deviceID, taskID: session.taskID)
        session.timeout?.cancel()
        if let telling, session.opened {
            var event = RemoteEvent(.terminalClosed)
            event.taskId = session.taskID
            event.terminalId = terminalID
            event.reason = telling
            send(event, to: connection)
        }
        session.connection = nil
        session.timeout = nil
        session.output = []
        session.sentBytes = nil
        terminals[terminalID] = session
        auditTerminal("detachTerminal", device: session.deviceID, task: session.taskID, result: "ok")
        let taskID = session.taskID
        let ended: @Sendable () async -> Void = { [weak self] in await self?.keptTerminalEnded(terminalID) }
        Task { [bridge] in await bridge.detachTerminal(taskID: taskID, terminalID: terminalID, permit: permit, ended: ended) }
    }

    /// The bridge saw a kept shell end while no connection showed it.
    private func keptTerminalEnded(_ terminalID: String) {
        guard let session = terminals[terminalID], session.connection == nil else { return }
        endTerminal(terminalID, reason: "exited")
    }

    private func receiveTerminalUpdates(_ terminalID: String, permit: RemoteTerminalPermit) {
        guard let session = terminals[terminalID], session.permit === permit else { return }
        guard session.permit.isValid else { endTerminal(terminalID, reason: "closed", permit: permit); return }
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
        guard var session = terminals[terminalID], session.opened, let connection = session.connection, session.permit.isValid,
              session.sentBytes == nil else { return }
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
        send(event, to: connection)
    }

    private func terminalTimedOut(_ terminalID: String, sequence: Int) {
        guard let session = terminals[terminalID], session.sequence == sequence, session.sentBytes != nil else { return }
        // A client that went quiet (asleep, or a network that dropped without a word) finds a kept shell still running.
        if session.keepsRunning, session.hasShell {
            detachTerminal(terminalID, telling: "outputTimeout")
        } else {
            endTerminal(terminalID, reason: "outputTimeout")
        }
    }

    func endTerminals(deviceID: String, reason: String) {
        let owned = terminals.keys.filter { terminals[$0]?.deviceID == deviceID }
        for id in owned { terminals[id]?.permit.revoke() }
        flushTerminalInputAudits(deviceID: deviceID)
        for id in owned { endTerminal(id, reason: reason) }
    }

    /// The connection ended. Its kept shells wait for their device; the others end.
    func endTerminals(on connection: UUID, reason: String) {
        let owned = terminals.keys.filter { terminals[$0]?.connection == connection }
        for id in owned { terminals[id]?.permit.revoke() }
        flushTerminalInputAudits()
        for id in owned {
            if let session = terminals[id], session.keepsRunning, session.hasShell { detachTerminal(id) } else { endTerminal(id, reason: reason) }
        }
    }

    /// With `permit`, only while that permit still speaks for the shell: a later attach replaced it, or its connection ended.
    func endTerminal(_ terminalID: String, reason: String, exitCode: Int32? = nil, permit: RemoteTerminalPermit? = nil) {
        if let permit {
            guard let session = terminals[terminalID], session.permit === permit, session.connection != nil else { return }
        }
        guard let session = terminals.removeValue(forKey: terminalID) else { return }
        session.permit.revoke()
        flushTerminalInputAudits(deviceID: session.deviceID, taskID: session.taskID)
        session.timeout?.cancel()
        if session.opened, let connection = session.connection {
            var event = RemoteEvent(.terminalClosed)
            event.taskId = session.taskID
            event.terminalId = terminalID
            event.reason = reason
            event.exitCode = exitCode
            send(event, to: connection)
        }
        auditTerminal("closeTerminal", device: session.deviceID, task: session.taskID, result: reason)
        Task { await bridge.closeTerminal(taskID: session.taskID, terminalID: terminalID) }
    }

    /// Keystrokes and paste chunks are one short audit batch, never one line per byte or packet.
    func auditTerminal(_ type: String, device: String?, task: String?, bytes: Int? = nil, result: String) {
        guard let audit, ["openTerminal", "attachTerminal", "detachTerminal", "closeTerminal", "terminalInput"].contains(type) else { return }
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
