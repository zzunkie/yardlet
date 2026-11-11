import Foundation
@testable import NativeHarnessClient

enum HarnessEventContractViolation: Error, Equatable, Sendable {
    case wrongSession(expected: UUID, actual: UUID)
    case sequenceMustStartAtZero(actual: UInt64)
    case sequenceGap(expected: UInt64, actual: UInt64)
    case firstEventMustStartSession
    case missingSessionStart
    case duplicateSessionStart
    case sessionHandleMismatch
}

/// Stateful validator shared by adapter conformance tests and future wire adapters.
/// It validates transport-independent identity and ordering without interpreting
/// provider-specific raw events.
struct HarnessEventContractValidator: Sendable {
    let session: HarnessSessionHandle
    private(set) var acceptedEventCount = 0
    private var nextSequence: UInt64 = 0
    private var observedSessionStart = false

    init(session: HarnessSessionHandle) {
        self.session = session
    }

    mutating func accept(_ event: HarnessEventEnvelope) throws {
        guard event.localSessionID == session.localSessionID else {
            throw HarnessEventContractViolation.wrongSession(
                expected: session.localSessionID,
                actual: event.localSessionID
            )
        }
        if acceptedEventCount == 0, event.sequence != 0 {
            throw HarnessEventContractViolation.sequenceMustStartAtZero(actual: event.sequence)
        }
        guard event.sequence == nextSequence else {
            throw HarnessEventContractViolation.sequenceGap(
                expected: nextSequence,
                actual: event.sequence
            )
        }

        if acceptedEventCount == 0 {
            guard case .sessionStarted = event.payload else {
                throw HarnessEventContractViolation.firstEventMustStartSession
            }
        }
        if case let .sessionStarted(handle) = event.payload {
            guard !observedSessionStart else {
                throw HarnessEventContractViolation.duplicateSessionStart
            }
            guard handle == session else {
                throw HarnessEventContractViolation.sessionHandleMismatch
            }
            observedSessionStart = true
        }

        acceptedEventCount += 1
        nextSequence += 1
    }

    func finish() throws {
        guard observedSessionStart else {
            throw HarnessEventContractViolation.missingSessionStart
        }
    }
}

struct HarnessAdapterConformanceReport: Equatable, Sendable {
    let negotiatedVersion: HarnessProtocolVersion
    let acceptedEventCount: Int
}

enum HarnessAdapterConformanceKit {
    static func validate(
        manifest: HarnessAdapterManifest,
        session: HarnessSessionHandle,
        events: [HarnessEventEnvelope]
    ) throws -> HarnessAdapterConformanceReport {
        try HarnessAdapterManifestValidator.validate(manifest)
        let version = try HarnessProtocolNegotiator.negotiate(adapter: manifest)
        var eventValidator = HarnessEventContractValidator(session: session)
        for event in events {
            try eventValidator.accept(event)
        }
        try eventValidator.finish()
        return HarnessAdapterConformanceReport(
            negotiatedVersion: version,
            acceptedEventCount: eventValidator.acceptedEventCount
        )
    }
}
