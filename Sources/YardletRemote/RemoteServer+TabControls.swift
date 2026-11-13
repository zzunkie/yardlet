import Foundation

extension RemoteServer {
    /// Address and close actions, and answers to a site's permission prompt, share the watched task's revocable permit
    /// and bounded input queue. A permission prompt is answered only on the tab whose page the connection watches.
    func tabControl(_ requestID: String, request: RemoteRequest, on id: UUID) {
        let device = connections[id]?.deviceID
        guard let watch = tabs.watches[id], watch.taskID == request.taskID else {
            respond(.failure(requestID, RemoteError(.notAllowed, "Watch the task's browser first")), to: id)
            auditTabControl(request, device: device, result: RemoteErrorCode.notAllowed.rawValue)
            return
        }
        if case let .answerTabPermission(_, tabID, _, _) = request, watch.tabID != tabID {
            respond(.failure(requestID, RemoteError(.notAllowed, "Watch the tab first")), to: id)
            auditTabControl(request, device: device, result: RemoteErrorCode.notAllowed.rawValue)
            return
        }
        guard tabs.pendingInputs[id, default: 0] < RemoteProtocol.maxPendingTabInputs else {
            respond(.failure(requestID, RemoteError(.rateLimited)), to: id)
            auditTabControl(request, device: device, result: RemoteErrorCode.rateLimited.rawValue)
            return
        }
        tabs.pendingInputs[id, default: 0] += 1
        let earlier = tabs.inputs[id]
        let permit = watch.permit
        tabs.inputs[id] = Task { [weak self] in
            await earlier?.value
            await self?.performTabControl(requestID, request: request, permit: permit, device: device, on: id)
        }
    }

    private func performTabControl(_ requestID: String, request: RemoteRequest, permit: RemoteTabPermit, device: String?, on id: UUID) async {
        defer { if let left = tabs.pendingInputs[id] { tabs.pendingInputs[id] = left > 1 ? left - 1 : nil } }
        var response = RemoteResponse(re: requestID)
        var answered: RemoteTabPermission?
        if !permit.isValid {
            response = .failure(requestID, RemoteError(.notAllowed))
        } else {
            switch request {
            case let .openTab(taskID, tabID, address):
                switch await bridge.openTab(taskID: taskID, tabID: tabID, address: address, permit: permit) {
                case let .success(tab): response.tabId = tab; response.taskId = taskID
                case let .failure(error): response = .failure(requestID, error)
                }
            case let .closeTab(taskID, tabID):
                if let error = await bridge.closeTab(taskID: taskID, tabID: tabID, permit: permit) {
                    response = .failure(requestID, error)
                }
            case let .answerTabPermission(taskID, tabID, prompt, answer):
                switch await bridge.answerTabPermission(taskID: taskID, tabID: tabID, prompt: prompt, answer: answer,
                                                        permit: permit) {
                case let .success(prompt): answered = prompt
                case let .failure(error): response = .failure(requestID, error)
                }
            default: response = .failure(requestID, RemoteError(.badRequest))
            }
        }
        respond(response, to: id)
        auditTabControl(request, device: device, result: response.error?.code.rawValue ?? "ok", answered: answered)
    }

    /// The request's type, task and result; for a permission answer also the answer and the prompt's origin and
    /// permissions, never the address or the page. A refusal a client can repeat at will is written at most once a
    /// minute per device, request, task and result (§4.4).
    private func auditTabControl(_ request: RemoteRequest, device: String?, result: String,
                                 answered: RemoteTabPermission? = nil) {
        let time = now()
        if result != "ok" {
            tabs.auditedInputs = tabs.auditedInputs.filter { time.timeIntervalSince($0.value) < Self.inputAuditWindow }
            let key = [device ?? "", request.type, request.taskID ?? "", result].joined(separator: "\u{0}")
            guard tabs.auditedInputs[key] == nil else { return }
            tabs.auditedInputs[key] = time
        }
        var answer: String?
        if case let .answerTabPermission(_, _, _, given) = request { answer = given.rawValue }
        audit?.record(device: device, type: request.type, task: request.taskID, input: answer, result: result,
                      origin: answered?.origin, permissions: answered?.permissions, at: time)
    }
}
