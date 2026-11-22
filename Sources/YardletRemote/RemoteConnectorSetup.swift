import Foundation

/// New credentials travel only in an authenticated, encrypted setup request, never in account snapshots.
public struct RemoteConnectorDraft: Codable, Equatable, Sendable {
    public var presetID: String?
    public var name: String?
    public var serverURL: String?
    public var token: String?
    public var tokenHeader: String?
    public var clientID: String?
    public var clientSecret: String?
    public var tenant: String?

    public init(presetID: String? = nil, name: String? = nil, serverURL: String? = nil,
                token: String? = nil, tokenHeader: String? = nil, clientID: String? = nil,
                clientSecret: String? = nil, tenant: String? = nil) {
        self.presetID = presetID
        self.name = name
        self.serverURL = serverURL
        self.token = token
        self.tokenHeader = tokenHeader
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.tenant = tenant
    }
}

/// One setup is owned by its authenticated connection. The owner is never a wire field.
public struct RemoteConnectorSetupRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case start, poll, answer, cancel }
    public var action: Action
    public var operationID: String
    public var draft: RemoteConnectorDraft?
    public var connectorID: String?
    public var reply: RemoteConnectorSetupReply?

    public init(action: Action, operationID: String, draft: RemoteConnectorDraft? = nil,
                connectorID: String? = nil, reply: RemoteConnectorSetupReply? = nil) {
        self.action = action
        self.operationID = operationID
        self.draft = draft
        self.connectorID = connectorID
        self.reply = reply
    }
}

public struct RemoteConnectorSetupReply: Codable, Equatable, Sendable {
    public var stepID: String
    public var value: String?
    public var accepted: Bool?

    public init(stepID: String, value: String? = nil, accepted: Bool? = nil) {
        self.stepID = stepID
        self.value = value
        self.accepted = accepted
    }
}

/// A browser operation for the initiating device alone. OAuth tokens and PKCE verifiers stay on the host.
public struct RemoteConnectorSetupStep: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case listen, open, confirm, callback }
    public var id: String
    public var kind: Kind
    public var url: String?
    public var port: UInt16?
    public var state: String?
    public var connector: String?
    public var serverHost: String?
    public var signInHost: String?
    public var deviceCode: String?

    public init(id: String, kind: Kind, url: String? = nil, port: UInt16? = nil, state: String? = nil,
                connector: String? = nil, serverHost: String? = nil, signInHost: String? = nil,
                deviceCode: String? = nil) {
        self.id = id
        self.kind = kind
        self.url = url
        self.port = port
        self.state = state
        self.connector = connector
        self.serverHost = serverHost
        self.signInHost = signInHost
        self.deviceCode = deviceCode
    }
}

public struct RemoteConnectorSetupState: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case working, connected, failed, cancelled }
    public var operationID: String
    public var connectorID: String?
    public var status: Status
    public var step: RemoteConnectorSetupStep?
    public var message: String?

    public init(operationID: String, connectorID: String? = nil, status: Status = .working,
                step: RemoteConnectorSetupStep? = nil, message: String? = nil) {
        self.operationID = operationID
        self.connectorID = connectorID
        self.status = status
        self.step = step
        self.message = message
    }
}

extension RemoteConnectorSetupRequest {
    /// Validate before a request reaches storage, a lookup, or the audit log. Errors never quote input secrets.
    public var validationError: RemoteError? {
        guard UUID(uuidString: operationID) != nil,
              connectorID.map({ UUID(uuidString: $0) != nil }) ?? true else {
            return RemoteError(.badRequest, "Invalid connector setup identifier")
        }
        switch action {
        case .start:
            guard draft != nil || connectorID != nil, reply == nil else {
                return RemoteError(.badRequest, "Choose a new or existing connector")
            }
            if let draft, connectorID != nil,
               draft.presetID != nil || draft.name != nil || draft.serverURL != nil {
                return RemoteError(.badRequest, "An existing connector's address and name cannot change during sign-in")
            }
        case .poll, .cancel:
            guard draft == nil, connectorID == nil, reply == nil else {
                return RemoteError(.badRequest, "Unexpected connector setup fields")
            }
        case .answer:
            guard draft == nil, connectorID == nil, let reply, UUID(uuidString: reply.stepID) != nil,
                  (reply.value != nil) != (reply.accepted != nil) else {
                return RemoteError(.badRequest, "Invalid connector setup answer")
            }
        }
        if let draft {
            guard connectorID != nil || draft.presetID?.isEmpty == false || draft.serverURL?.isEmpty == false else {
                return RemoteError(.badRequest, "Missing connector address or preset")
            }
            let fields: [(String?, Int)] = [
                (draft.presetID, 256), (draft.name, 512), (draft.serverURL, 8_192),
                (draft.token, 16_384), (draft.tokenHeader, 256), (draft.clientID, 4_096),
                (draft.clientSecret, 16_384), (draft.tenant, 256)
            ]
            guard fields.allSatisfy({ ($0.0?.utf8.count ?? 0) <= $0.1 }) else {
                return RemoteError(.tooLarge, "Connector setup field is too long")
            }
        }
        guard (reply?.value?.utf8.count ?? 0) <= 16_384 else {
            return RemoteError(.tooLarge, "Connector setup answer is too long")
        }
        return nil
    }
}
