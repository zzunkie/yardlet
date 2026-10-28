import Foundation

struct HarnessProtocolSessionDescriptor: Codable, Equatable, Sendable {
    let localSessionID: UUID
    let providerSessionID: String
    let workspacePath: String
}

struct HarnessProtocolTurnDescriptor: Codable, Equatable, Sendable {
    let id: String
    let localSessionID: UUID
}

enum HarnessProtocolMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

struct HarnessProtocolMessage: Codable, Equatable, Sendable {
    let id: String
    let role: HarnessProtocolMessageRole
    let content: [HarnessProtocolContentBlock]
}

enum HarnessProtocolToolCallStatus: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
}

struct HarnessProtocolToolCall: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let title: String
    let kind: String
    let status: HarnessProtocolToolCallStatus
    let input: JSONValue?
    let output: JSONValue?
    let extensionValues: [String: JSONValue]
}

enum HarnessProtocolPlanItemStatus: String, Codable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
}

struct HarnessProtocolPlanItem: Codable, Equatable, Sendable {
    let id: String
    let text: String
    let status: HarnessProtocolPlanItemStatus
}

struct HarnessProtocolPlan: Codable, Equatable, Sendable {
    let explanation: String?
    let items: [HarnessProtocolPlanItem]
}

struct HarnessProtocolPermissionResolution: Codable, Equatable, Sendable {
    let requestID: String
    let selectedActionID: String
    let behavior: HarnessProtocolPermissionBehavior
}

struct HarnessProtocolSubagent: Codable, Equatable, Sendable {
    let id: String
    let parentSessionID: UUID
    let providerSessionID: String?
    let title: String
    let status: SessionStatus
    let extensionValues: [String: JSONValue]
}

struct HarnessProtocolFailure: Codable, Equatable, Sendable {
    let code: String?
    let message: String
    let diagnostic: String?
    let recoverable: Bool
    /// The provider's error says the same request can succeed later (`HarnessEventPayload.error`).
    var transient: Bool? = nil
}

struct HarnessProtocolExtensionEvent: Codable, Equatable, Sendable {
    let namespace: String
    let name: String
    let payload: JSONValue
}

enum HarnessProtocolEventKind: String, Codable, Sendable {
    case sessionStarted = "session.started"
    case sessionStatusChanged = "session.status_changed"
    case turnStarted = "turn.started"
    case assistantDelta = "message.assistant_delta"
    case reasoningDelta = "message.reasoning_delta"
    case messageCompleted = "message.completed"
    case toolCallUpdated = "tool.updated"
    case permissionRequested = "permission.requested"
    case permissionResolved = "permission.resolved"
    case planUpdated = "plan.updated"
    case usageUpdated = "usage.updated"
    case subagentUpdated = "subagent.updated"
    case turnCompleted = "turn.completed"
    case turnFailed = "turn.failed"
    case turnCanceled = "turn.canceled"
    case `extension` = "extension"
}

/// Stable, tagged canonical event payload. Optional fields are validated by
/// `HarnessProtocolEventPayloadValidator` before dispatch.
struct HarnessProtocolEventPayload: Codable, Equatable, Sendable {
    let kind: HarnessProtocolEventKind
    let turnID: String?
    let turn: HarnessProtocolTurnDescriptor?
    let messageID: String?
    let text: String?
    let session: HarnessProtocolSessionDescriptor?
    let status: SessionStatus?
    let message: HarnessProtocolMessage?
    let toolCall: HarnessProtocolToolCall?
    let permission: HarnessProtocolPermissionRequest?
    let permissionResolution: HarnessProtocolPermissionResolution?
    let plan: HarnessProtocolPlan?
    let usage: HarnessProtocolUsage?
    let subagent: HarnessProtocolSubagent?
    let failure: HarnessProtocolFailure?
    let reason: String?
    let extensionEvent: HarnessProtocolExtensionEvent?

    static func sessionStarted(_ session: HarnessProtocolSessionDescriptor) -> Self {
        Self(kind: .sessionStarted, session: session)
    }

    static func sessionStatusChanged(_ status: SessionStatus) -> Self {
        Self(kind: .sessionStatusChanged, status: status)
    }

    static func turnStarted(_ turn: HarnessProtocolTurnDescriptor) -> Self {
        Self(kind: .turnStarted, turnID: turn.id, turn: turn)
    }

    static func assistantDelta(turnID: String?, messageID: String, text: String) -> Self {
        Self(kind: .assistantDelta, turnID: turnID, messageID: messageID, text: text)
    }

    static func reasoningDelta(turnID: String?, text: String) -> Self {
        Self(kind: .reasoningDelta, turnID: turnID, text: text)
    }

    static func messageCompleted(turnID: String?, message: HarnessProtocolMessage) -> Self {
        Self(kind: .messageCompleted, turnID: turnID, message: message)
    }

    static func toolCallUpdated(turnID: String?, toolCall: HarnessProtocolToolCall) -> Self {
        Self(kind: .toolCallUpdated, turnID: turnID, toolCall: toolCall)
    }

    static func permissionRequested(_ permission: HarnessProtocolPermissionRequest) -> Self {
        Self(
            kind: .permissionRequested,
            turnID: permission.turnID,
            permission: permission
        )
    }

    static func permissionResolved(
        turnID: String?,
        resolution: HarnessProtocolPermissionResolution
    ) -> Self {
        Self(kind: .permissionResolved, turnID: turnID, permissionResolution: resolution)
    }

    static func planUpdated(turnID: String?, plan: HarnessProtocolPlan) -> Self {
        Self(kind: .planUpdated, turnID: turnID, plan: plan)
    }

    static func usageUpdated(turnID: String?, usage: HarnessProtocolUsage) -> Self {
        Self(kind: .usageUpdated, turnID: turnID, usage: usage)
    }

    static func subagentUpdated(_ subagent: HarnessProtocolSubagent) -> Self {
        Self(kind: .subagentUpdated, subagent: subagent)
    }

    static func turnCompleted(turnID: String, usage: HarnessProtocolUsage?) -> Self {
        Self(kind: .turnCompleted, turnID: turnID, usage: usage)
    }

    static func turnFailed(turnID: String?, failure: HarnessProtocolFailure) -> Self {
        Self(kind: .turnFailed, turnID: turnID, failure: failure)
    }

    static func turnCanceled(turnID: String?, reason: String) -> Self {
        Self(kind: .turnCanceled, turnID: turnID, reason: reason)
    }

    static func extensionEvent(_ event: HarnessProtocolExtensionEvent) -> Self {
        Self(kind: .extension, extensionEvent: event)
    }

    private init(
        kind: HarnessProtocolEventKind,
        turnID: String? = nil,
        turn: HarnessProtocolTurnDescriptor? = nil,
        messageID: String? = nil,
        text: String? = nil,
        session: HarnessProtocolSessionDescriptor? = nil,
        status: SessionStatus? = nil,
        message: HarnessProtocolMessage? = nil,
        toolCall: HarnessProtocolToolCall? = nil,
        permission: HarnessProtocolPermissionRequest? = nil,
        permissionResolution: HarnessProtocolPermissionResolution? = nil,
        plan: HarnessProtocolPlan? = nil,
        usage: HarnessProtocolUsage? = nil,
        subagent: HarnessProtocolSubagent? = nil,
        failure: HarnessProtocolFailure? = nil,
        reason: String? = nil,
        extensionEvent: HarnessProtocolExtensionEvent? = nil
    ) {
        self.kind = kind
        self.turnID = turnID
        self.turn = turn
        self.messageID = messageID
        self.text = text
        self.session = session
        self.status = status
        self.message = message
        self.toolCall = toolCall
        self.permission = permission
        self.permissionResolution = permissionResolution
        self.plan = plan
        self.usage = usage
        self.subagent = subagent
        self.failure = failure
        self.reason = reason
        self.extensionEvent = extensionEvent
    }
}

struct HarnessProtocolEventEnvelope: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let localSessionID: UUID
    let timestamp: Date
    let sequence: UInt64
    let payload: HarnessProtocolEventPayload
    let rawProviderEvent: Data?

    init(
        id: UUID = UUID(),
        localSessionID: UUID,
        timestamp: Date = Date(),
        sequence: UInt64,
        payload: HarnessProtocolEventPayload,
        rawProviderEvent: Data? = nil
    ) {
        self.id = id
        self.localSessionID = localSessionID
        self.timestamp = timestamp
        self.sequence = sequence
        self.payload = payload
        self.rawProviderEvent = rawProviderEvent
    }
}

enum HarnessProtocolEventContractViolation: Error, Equatable, Sendable {
    case wrongSession(expected: UUID, actual: UUID)
    case sequenceMustStartAtZero(actual: UInt64)
    case sequenceGap(expected: UInt64, actual: UInt64)
    case firstEventMustStartSession
    case duplicateSessionStart
    case sessionDescriptorMismatch
    case invalidPayload(HarnessProtocolEventKind)
    case missingCapability(
        event: HarnessProtocolEventKind,
        capability: HarnessCapabilityID
    )
    case undeclaredExtensionNamespace(String)
    case undeclaredExtensionKey(String)
}

struct HarnessProtocolEventContractValidator: Sendable {
    let localSessionID: UUID
    let manifest: HarnessAdapterManifest
    private(set) var acceptedEventCount = 0
    private var nextSequence: UInt64 = 0
    private var observedSessionStart = false

    init(localSessionID: UUID, manifest: HarnessAdapterManifest) {
        self.localSessionID = localSessionID
        self.manifest = manifest
    }

    mutating func accept(_ event: HarnessProtocolEventEnvelope) throws {
        guard event.localSessionID == localSessionID else {
            throw HarnessProtocolEventContractViolation.wrongSession(
                expected: localSessionID,
                actual: event.localSessionID
            )
        }
        if acceptedEventCount == 0, event.sequence != 0 {
            throw HarnessProtocolEventContractViolation.sequenceMustStartAtZero(
                actual: event.sequence
            )
        }
        guard event.sequence == nextSequence else {
            throw HarnessProtocolEventContractViolation.sequenceGap(
                expected: nextSequence,
                actual: event.sequence
            )
        }
        if acceptedEventCount == 0, event.payload.kind != .sessionStarted {
            throw HarnessProtocolEventContractViolation.firstEventMustStartSession
        }

        try validatePayload(event.payload)
        if event.payload.kind == .sessionStarted {
            guard !observedSessionStart else {
                throw HarnessProtocolEventContractViolation.duplicateSessionStart
            }
            guard event.payload.session?.localSessionID == localSessionID else {
                throw HarnessProtocolEventContractViolation.sessionDescriptorMismatch
            }
            observedSessionStart = true
        }

        acceptedEventCount += 1
        nextSequence += 1
    }

    private func validatePayload(_ payload: HarnessProtocolEventPayload) throws {
        if let capability = Self.capabilityRequirements[payload.kind],
           !manifest.supports(capability) {
            throw HarnessProtocolEventContractViolation.missingCapability(
                event: payload.kind,
                capability: capability
            )
        }

        let valid: Bool
        switch payload.kind {
        case .sessionStarted:
            valid = payload.session != nil
        case .sessionStatusChanged:
            valid = payload.status != nil
        case .turnStarted:
            valid = payload.turn?.id == payload.turnID
                && payload.turn?.localSessionID == localSessionID
        case .turnCompleted:
            valid = payload.turnID != nil
        case .assistantDelta:
            valid = payload.messageID != nil && payload.text != nil
        case .reasoningDelta:
            valid = payload.text != nil
        case .messageCompleted:
            valid = payload.message != nil
        case .toolCallUpdated:
            valid = payload.toolCall != nil
        case .permissionRequested:
            valid = payload.permission?.localSessionID == localSessionID
        case .permissionResolved:
            valid = payload.permissionResolution != nil
        case .planUpdated:
            valid = payload.plan != nil
        case .usageUpdated:
            valid = payload.usage != nil
        case .subagentUpdated:
            valid = payload.subagent?.parentSessionID == localSessionID
        case .turnFailed:
            valid = payload.failure != nil
        case .turnCanceled:
            valid = payload.reason != nil
        case .extension:
            guard let event = payload.extensionEvent else {
                throw HarnessProtocolEventContractViolation.invalidPayload(payload.kind)
            }
            guard manifest.extensionNamespaces.contains(event.namespace) else {
                throw HarnessProtocolEventContractViolation.undeclaredExtensionNamespace(
                    event.namespace
                )
            }
            valid = !event.name.isEmpty
        }
        guard valid else {
            throw HarnessProtocolEventContractViolation.invalidPayload(payload.kind)
        }

        let extensionValues: [[String: JSONValue]] = [
            payload.toolCall?.extensionValues,
            payload.permission?.extensionValues,
            payload.usage?.extensionValues,
            payload.subagent?.extensionValues
        ].compactMap { $0 }
        for values in extensionValues {
            do {
                try HarnessProtocolExtensionValidator.validate(values, manifest: manifest)
            } catch let error as HarnessProtocolExtensionViolation {
                switch error {
                case let .undeclaredKey(key):
                    throw HarnessProtocolEventContractViolation.undeclaredExtensionKey(key)
                }
            }
        }
    }

    private static let capabilityRequirements: [
        HarnessProtocolEventKind: HarnessCapabilityID
    ] = [
        .assistantDelta: .streaming,
        .reasoningDelta: .reasoning,
        .toolCallUpdated: .structuredActivities,
        .permissionRequested: .structuredPermissions,
        .permissionResolved: .structuredPermissions,
        .planUpdated: .plans,
        .usageUpdated: .usage,
        .subagentUpdated: .subagents
    ]
}

struct HarnessProtocolConformanceReport: Equatable, Sendable {
    let negotiatedVersion: HarnessProtocolVersion
    let acceptedEventCount: Int
}

enum HarnessProtocolConformanceKit {
    static func validate(
        manifest: HarnessAdapterManifest,
        localSessionID: UUID,
        events: [HarnessProtocolEventEnvelope]
    ) throws -> HarnessProtocolConformanceReport {
        try HarnessAdapterManifestValidator.validate(manifest)
        let version = try HarnessProtocolNegotiator.negotiate(adapter: manifest)
        var validator = HarnessProtocolEventContractValidator(
            localSessionID: localSessionID,
            manifest: manifest
        )
        for event in events {
            try validator.accept(event)
        }
        guard validator.acceptedEventCount > 0 else {
            throw HarnessProtocolEventContractViolation.firstEventMustStartSession
        }
        return HarnessProtocolConformanceReport(
            negotiatedVersion: version,
            acceptedEventCount: validator.acceptedEventCount
        )
    }
}
