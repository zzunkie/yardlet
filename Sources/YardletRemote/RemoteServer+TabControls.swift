import Foundation

extension RemoteServer {
    /// Address and close actions share the watched task's revocable permit and bounded input queue.
    func tabControl(_ requestID: String, request: RemoteRequest, on id: UUID) {
        guard let watch = tabs.watches[id], watch.taskID == request.taskID else {
            respond(.failure(requestID, RemoteError(.notAllowed, "Watch the task's browser first")), to: id)
            audit?.record(device: connections[id]?.deviceID, type: request.type, task: request.taskID, result: "notAllowed", at: now())
            return
        }
        guard tabs.pendingInputs[id, default: 0] < RemoteProtocol.maxPendingTabInputs else {
            respond(.failure(requestID, RemoteError(.rateLimited)), to: id)
            audit?.record(device: connections[id]?.deviceID, type: request.type, task: request.taskID, result: "rateLimited", at: now())
            return
        }
        tabs.pendingInputs[id, default: 0] += 1
        let earlier = tabs.inputs[id]
        let permit = watch.permit
        let device = connections[id]?.deviceID
        tabs.inputs[id] = Task { [weak self] in
            await earlier?.value
            await self?.performTabControl(requestID, request: request, permit: permit, device: device, on: id)
        }
    }

    private func performTabControl(_ requestID: String, request: RemoteRequest, permit: RemoteTabPermit, device: String?, on id: UUID) async {
        defer { if let left = tabs.pendingInputs[id] { tabs.pendingInputs[id] = left > 1 ? left - 1 : nil } }
        var response = RemoteResponse(re: requestID)
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
            default: response = .failure(requestID, RemoteError(.badRequest))
            }
        }
        respond(response, to: id)
        audit?.record(device: device, type: request.type, task: request.taskID,
                      result: response.error?.code.rawValue ?? "ok", at: now())
    }
}
