import Foundation
import YardletRemote

/// One bounded, cancellable setup per authenticated connection. Secrets never enter account projections or logs.
@MainActor
final class RemoteConnectorSetupCoordinator {
    @MainActor private final class Operation {
        let owner: String
        let exchange = RemoteConnectorSetupExchange()
        weak var center: ConnectorCenter?
        var state: RemoteConnectorSetupState
        var task: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var createdConnectorIDs: [UUID] = []
        var connectionID: UUID?
        var ownsConnection = false
        var discardCreated = false
        var settledAccountID: UUID?
        var accountService: LocalConnectorService?

        init(id: String, owner: String, center: ConnectorCenter) {
            self.owner = owner
            self.center = center
            state = .init(operationID: id)
        }

        var response: RemoteConnectorSetupState {
            var value = state
            value.step = state.status == .working ? exchange.step : nil
            return value
        }
    }

    private var operations: [String: Operation] = [:]
    private var completed: [String] = []
    private let timeout: Duration

    init(timeout: Duration = .seconds(300)) { self.timeout = timeout }

    func handle(_ request: RemoteConnectorSetupRequest, owner: String,
                center: ConnectorCenter) -> Result<RemoteConnectorSetupState, RemoteError> {
        if let error = request.validationError { return .failure(error) }
        guard UUID(uuidString: request.operationID) != nil, !owner.isEmpty else {
            return .failure(RemoteError(.badRequest))
        }
        if request.action == .start {
            guard operations[request.operationID] == nil else { return .failure(RemoteError(.notAllowed)) }
            guard !operations.values.contains(where: { $0.owner == owner && $0.state.status == .working }) else {
                return .failure(RemoteError(.busy))
            }
            guard request.draft != nil || request.connectorID != nil, request.reply == nil else {
                return .failure(RemoteError(.badRequest))
            }
            if let id = request.connectorID {
                guard let uuid = UUID(uuidString: id), let record = center.record(uuid) else {
                    return .failure(RemoteError(.notFound))
                }
                guard Self.supports(record) else { return .failure(RemoteError(.notAllowed)) }
                guard !center.isConnecting(uuid) else { return .failure(RemoteError(.busy)) }
                guard !operations.values.contains(where: { operation in
                    guard operation.state.status == .working, let value = operation.state.connectorID,
                          let other = UUID(uuidString: value) else { return false }
                    return center.record(other)?.credentialID == record.credentialID
                }) else { return .failure(RemoteError(.busy)) }
            }
            if let draft = request.draft, !Self.valid(draft, editing: request.connectorID != nil) {
                return .failure(RemoteError(.badRequest))
            }
            let operation = Operation(id: request.operationID, owner: owner, center: center)
            operation.state.connectorID = request.connectorID
            operation.accountService = request.connectorID.flatMap(UUID.init(uuidString:)).flatMap { center.record($0)?.localService }
                ?? request.draft?.presetID.flatMap(ConnectorPreset.preset(id:))?.localService
            operations[request.operationID] = operation
            operation.task = Task { [weak self] in
                guard let self else { return }
                await run(request, operation: operation, center: center)
            }
            operation.deadline = Task { [weak self] in
                do { try await Task.sleep(for: self?.timeout ?? .seconds(300)) } catch { return }
                self?.finish(operation, status: .failed, message: L10n.string("Sign-in timed out. Try again."), discardCreated: true)
            }
            return .success(operation.response)
        }
        guard let operation = operations[request.operationID], operation.owner == owner else {
            return .failure(RemoteError(.notFound))
        }
        guard request.draft == nil, request.connectorID == nil else { return .failure(RemoteError(.badRequest)) }
        switch request.action {
        case .start: return .failure(RemoteError(.badRequest))
        case .poll:
            guard request.reply == nil else { return .failure(RemoteError(.badRequest)) }
        case .answer:
            guard operation.state.status == .working, let reply = request.reply,
                  operation.exchange.answer(reply) else { return .failure(RemoteError(.badRequest)) }
        case .cancel:
            guard request.reply == nil else { return .failure(RemoteError(.badRequest)) }
            finish(operation, status: .cancelled)
        }
        return .success(operation.response)
    }

    func cancel(owner: String) {
        for operation in Array(operations.values) where operation.owner == owner && operation.state.status == .working {
            finish(operation, status: .cancelled)
        }
        // A closed/revoked connection will never poll again. Drop its completed state too.
        let ids = operations.filter { $0.value.owner == owner }.map(\.key)
        for id in ids { operations[id] = nil }
        completed.removeAll { ids.contains($0) }
    }

    private func run(_ request: RemoteConnectorSetupRequest, operation: Operation, center: ConnectorCenter) async {
        let agent = RemoteConnectorSetupUserAgent(exchange: operation.exchange, deviceCode: { [weak operation, weak center] in
            guard let value = operation?.state.connectorID, let id = UUID(uuidString: value) else { return nil }
            return center?.deviceCodes[id]
        })
        do {
            try await ConnectorSignInContext.$userAgent.withValue(agent) {
                try await ConnectorSignInContext.$onCancel.withValue({ operation.exchange.markDeclined() }) {
                    try await ConnectorSignInContext.$onAccountSettled.withValue({ operation.settledAccountID = $0 }) {
                        try await connect(request, operation: operation, center: center)
                    }
                }
            }
        } catch is CancellationError {
            finish(operation, status: .cancelled)
        } catch let failure as SetupFailure {
            finish(operation, status: .failed, message: failure.message)
        } catch {
            // Provider errors can repeat request values. Keep credentials and URLs out of this response.
            finish(operation, status: .failed,
                   message: L10n.string("The service could not be connected. Check its setup and try again."))
        }
        await cleanUp(operation, center: center)
    }

    private func connect(_ request: RemoteConnectorSetupRequest, operation: Operation, center: ConnectorCenter) async throws {
        try Task.checkCancellation()
        let id: UUID
        if let value = request.connectorID, let existing = UUID(uuidString: value) {
            id = existing
            guard !center.isConnecting(id), center.record(id) != nil else { throw SetupFailure.busy }
            if let draft = request.draft { try await update(draft, id: id, in: center) }
            try Task.checkCancellation()
            guard !center.isConnecting(id), center.record(id) != nil else { throw SetupFailure.busy }
            center.reconnect(id)
        } else if let draft = request.draft {
            id = try await add(draft, in: center)
            operation.createdConnectorIDs.append(id)
            // Account creation starts the connection before returning, without an intervening await.
            if operation.accountService?.accountProvider != nil { operation.ownsConnection = true }
            operation.connectionID = id
            try Task.checkCancellation()
            guard operation.ownsConnection || !center.isConnecting(id) else { throw SetupFailure.busy }
            center.connect(id)
        } else { throw CancellationError() }
        operation.state.connectorID = id.uuidString
        operation.connectionID = id
        operation.ownsConnection = true
        await center.waitForConnection(id)
        operation.ownsConnection = false
        try Task.checkCancellation()
        let resultID: UUID
        if let target = operation.settledAccountID, let service = operation.accountService,
           let record = center.connectors.first(where: { $0.credentialID == target && $0.localService == service }) {
            resultID = record.id
            operation.state.connectorID = resultID.uuidString
        } else { resultID = id }
        if operation.exchange.declined {
            finish(operation, status: .cancelled)
        } else if center.record(resultID)?.status == .connected, center.failures[resultID] == nil {
            finish(operation, status: .connected)
        } else {
            if center.record(resultID) == nil { operation.state.connectorID = nil }
            finish(operation, status: .failed,
                   message: L10n.string("The service could not be connected. Check its setup and try again."))
        }
    }

    private func finish(_ operation: Operation, status: RemoteConnectorSetupState.Status, message: String? = nil,
                        discardCreated: Bool = false) {
        guard operation.state.status == .working else { return }
        operation.state.status = status
        operation.state.message = message
        if let value = operation.state.connectorID, let id = UUID(uuidString: value), operation.center?.record(id) == nil {
            operation.state.connectorID = nil
        }
        operation.discardCreated = discardCreated || status == .cancelled
        operation.exchange.stop()
        if status != .connected, operation.ownsConnection, let id = operation.connectionID {
            operation.center?.cancelConnect(id)
        }
        if operation.discardCreated, !operation.createdConnectorIDs.isEmpty { operation.state.connectorID = nil }
        operation.task?.cancel()
        operation.deadline?.cancel()
        operation.task = nil
        operation.deadline = nil
        completed.append(operation.state.operationID)
        while completed.count > 32 { operations[completed.removeFirst()] = nil }
    }

    /// A cancelled keychain/network call may finish later. Its new record is removed only after the connection
    /// has unwound, so a late credential save cannot recreate a secret after removal.
    private func cleanUp(_ operation: Operation, center: ConnectorCenter) async {
        guard operation.discardCreated else { return }
        if operation.ownsConnection, let id = operation.connectionID {
            center.cancelConnect(id)
            await center.waitForConnection(id)
            operation.ownsConnection = false
        }
        for id in operation.createdConnectorIDs where center.record(id) != nil { center.remove(id) }
        if !operation.createdConnectorIDs.isEmpty {
            operation.state.connectorID = nil
            await center.waitForPendingDeletions()
        }
    }

    private enum SetupFailure: Error {
        case accountApp
        case busy
        var message: String {
            switch self {
            case .accountApp: L10n.string("This service needs an OAuth app. Enter its client ID and try again.")
            case .busy: L10n.string("This connector is already connecting. Try again when it finishes.")
            }
        }
    }

    private func add(_ draft: RemoteConnectorDraft, in center: ConnectorCenter) async throws -> UUID {
        let preset = draft.presetID.flatMap(ConnectorPreset.preset(id:))
        if let service = preset?.localService, let provider = service.accountProvider {
            if let clientID = Self.trimmed(draft.clientID) {
                switch provider {
                case .google: try await center.saveGoogleApp(clientID: clientID, secret: draft.clientSecret)
                case .microsoft: center.saveMicrosoftApp(clientID: clientID, tenant: draft.tenant)
                }
            }
            try Task.checkCancellation()
            guard center.canSignIn(with: provider), center.signInServices(provider).contains(service),
                  let account = center.addAccount(services: [service]) else { throw SetupFailure.accountApp }
            return account.id
        }
        guard let url = preset?.serverURL ?? draft.serverURL.flatMap(URL.init(string:)) else {
            throw CancellationError()
        }
        let client = Self.trimmed(draft.clientID).map { (id: $0, secret: Self.trimmed(draft.clientSecret)) }
        return try await center.add(name: Self.trimmed(draft.name) ?? preset?.name ?? url.host() ?? "Connector",
                                    serverURL: url, token: Self.trimmed(draft.token), tokenHeader: Self.trimmed(draft.tokenHeader),
                                    client: client, preset: preset).id
    }

    private func update(_ draft: RemoteConnectorDraft, id: UUID, in center: ConnectorCenter) async throws {
        guard let record = center.record(id) else { throw CancellationError() }
        if let provider = record.localService?.accountProvider {
            guard Self.trimmed(draft.token) == nil, draft.tokenHeader == nil else { throw SetupFailure.accountApp }
            if let clientID = Self.trimmed(draft.clientID) {
                switch provider {
                case .google: try await center.saveGoogleApp(clientID: clientID, secret: draft.clientSecret)
                case .microsoft: center.saveMicrosoftApp(clientID: clientID, tenant: draft.tenant)
                }
            }
        } else {
            try await center.setAuthentication(id, token: draft.token, tokenHeader: draft.tokenHeader,
                                               clientID: draft.clientID, clientSecret: draft.clientSecret)
        }
    }

    private static func supports(_ record: ConnectorRecord) -> Bool {
        record.program == nil && (record.localService == nil || record.localService?.accountProvider != nil)
    }

    private static func valid(_ draft: RemoteConnectorDraft, editing: Bool) -> Bool {
        if trimmed(draft.token) != nil && trimmed(draft.clientID) != nil { return false }
        if trimmed(draft.clientSecret) != nil && trimmed(draft.clientID) == nil { return false }
        if let header = trimmed(draft.tokenHeader) {
            guard trimmed(draft.token) != nil, header.utf8.allSatisfy({ byte in
                (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45
            }) else { return false }
        }
        if editing {
            return draft.presetID == nil && draft.name == nil && draft.serverURL == nil
                && (trimmed(draft.token) != nil || trimmed(draft.clientID) != nil)
        }
        if let id = draft.presetID {
            guard let preset = ConnectorPreset.preset(id: id), draft.serverURL == nil else { return false }
            if let service = preset.localService {
                return service.accountProvider != nil && trimmed(draft.token) == nil && draft.tokenHeader == nil
            }
            return true
        }
        guard let text = draft.serverURL, let parts = URLComponents(string: text),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)),
              parts.url != nil else { return false }
        return true
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
