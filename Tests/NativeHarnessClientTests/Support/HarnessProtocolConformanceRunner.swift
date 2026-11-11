import Foundation
@testable import NativeHarnessClient

struct HarnessProtocolExternalConformanceReport: Equatable, Sendable {
    let adapterID: String
    let negotiatedVersion: HarnessProtocolVersion
    let processID: Int32
    let createdSessionEventCount: Int
    let resumedSessionEventCount: Int
    let preservedExtensionValue: JSONValue
}

enum HarnessProtocolExternalConformanceError: Error, Equatable, Sendable {
    case missingCapability(HarnessCapabilityID)
    case unexpectedRuntime(HarnessKind)
    case unexpectedExtensionResult
    case unexpectedSessionDescriptor
    case eventDeadlineExceeded(localSessionID: UUID, expectedCount: Int)
    case missingEvent(localSessionID: UUID, kind: HarnessProtocolEventKind)
}

/// Drives the portable lifecycle against an independently launched adapter.
///
/// This runner deliberately uses only YHP requests and events. It does not import
/// or downcast an in-process `HarnessAdapter`, so passing it proves the same
/// process, JSONL, admission, schema, and cleanup boundary used by third parties.
struct HarnessProtocolExternalConformanceRunner: Sendable {
    private let requestTimeout: Duration
    private let eventTimeout: Duration

    init(
        requestTimeout: Duration = .seconds(2),
        eventTimeout: Duration = .seconds(2)
    ) {
        self.requestTimeout = requestTimeout
        self.eventTimeout = eventTimeout
    }

    func run(
        configuration: HarnessProtocolAdapterLaunchConfiguration
    ) async throws -> HarnessProtocolExternalConformanceReport {
        let host = HarnessProtocolProcessHost(
            handshakeTimeout: 2,
            requestTimeout: requestTimeout
        )
        let eventStore = HarnessProtocolConformanceEventStore()
        let stream = await host.events()
        let collector = Task {
            for await event in stream {
                await eventStore.append(event)
            }
        }

        do {
            let processSession = try await host.start(configuration)
            let manifest = processSession.manifest
            for capability in [
                HarnessCapabilityID.sessionResume,
                .turnInterrupt
            ] where !manifest.supports(capability) {
                throw HarnessProtocolExternalConformanceError.missingCapability(capability)
            }

            let runtimeValue = try await host.request(
                try HarnessProtocolRequest(
                    id: "conformance-runtime",
                    method: .runtimeProbe,
                    typedParams: HarnessProtocolEmptyParams()
                )
            )
            let codec = HarnessProtocolPayloadCodec()
            let runtime = try codec.decode(HarnessProtocolRuntimeInfo.self, from: runtimeValue)
            guard runtime.harness == manifest.harness else {
                throw HarnessProtocolExternalConformanceError.unexpectedRuntime(runtime.harness)
            }

            let extensionValue: JSONValue = .object([
                "sample.fixture.trace": .string("preserved")
            ])
            let echoed = try await host.request(
                HarnessProtocolRequest(
                    id: "conformance-extension",
                    method: HarnessProtocolMethodID(rawValue: "sample.fixture.echo"),
                    params: extensionValue
                )
            )
            guard echoed == extensionValue else {
                throw HarnessProtocolExternalConformanceError.unexpectedExtensionResult
            }

            let createdLocalSessionID = UUID()
            let config = HarnessProtocolSessionConfig(
                workspacePath: configuration.workspaceURL.path(percentEncoded: false),
                modelID: nil,
                modeID: nil,
                featureValues: [:],
                extensionValues: ["sample.fixture.mode": .string("conformance")]
            )
            let createdValue = try await host.request(
                try HarnessProtocolRequest(
                    id: "conformance-create",
                    method: .sessionCreate,
                    typedParams: HarnessProtocolCreateSessionParams(
                        localSessionID: createdLocalSessionID,
                        config: config,
                        initialPrompt: []
                    )
                )
            )
            let created = try codec.decode(
                HarnessProtocolSessionDescriptor.self,
                from: createdValue
            )
            guard created.localSessionID == createdLocalSessionID,
                  created.workspacePath == config.workspacePath else {
                throw HarnessProtocolExternalConformanceError.unexpectedSessionDescriptor
            }
            try await waitForEvents(
                2,
                localSessionID: createdLocalSessionID,
                in: eventStore
            )

            _ = try await host.request(
                try HarnessProtocolRequest(
                    id: "conformance-send-complete",
                    method: .sessionSend,
                    typedParams: HarnessProtocolTurnSubmitParams(
                        localSessionID: createdLocalSessionID,
                        clientMessageID: "complete",
                        content: [.text("hello")]
                    )
                )
            )
            try await waitForEvents(
                5,
                localSessionID: createdLocalSessionID,
                in: eventStore
            )

            _ = try await host.request(
                try HarnessProtocolRequest(
                    id: "conformance-send-interrupt",
                    method: .sessionSend,
                    typedParams: HarnessProtocolTurnSubmitParams(
                        localSessionID: createdLocalSessionID,
                        clientMessageID: "interrupt",
                        content: [.text("hold")]
                    )
                )
            )
            try await waitForEvents(
                6,
                localSessionID: createdLocalSessionID,
                in: eventStore
            )
            _ = try await host.request(
                try HarnessProtocolRequest(
                    id: "conformance-interrupt",
                    method: .sessionInterrupt,
                    typedParams: HarnessProtocolSessionReference(
                        localSessionID: createdLocalSessionID
                    )
                )
            )
            try await waitForEvents(
                7,
                localSessionID: createdLocalSessionID,
                in: eventStore
            )

            _ = try await host.request(
                try HarnessProtocolRequest(
                    id: "conformance-close-created",
                    method: .sessionClose,
                    typedParams: HarnessProtocolSessionReference(
                        localSessionID: createdLocalSessionID
                    )
                )
            )

            let resumedLocalSessionID = UUID()
            let resumedValue = try await host.request(
                try HarnessProtocolRequest(
                    id: "conformance-resume",
                    method: .sessionResume,
                    typedParams: HarnessProtocolResumeSessionParams(
                        localSessionID: resumedLocalSessionID,
                        providerSessionID: created.providerSessionID,
                        config: config
                    )
                )
            )
            let resumed = try codec.decode(
                HarnessProtocolSessionDescriptor.self,
                from: resumedValue
            )
            guard resumed.localSessionID == resumedLocalSessionID,
                  resumed.providerSessionID == created.providerSessionID else {
                throw HarnessProtocolExternalConformanceError.unexpectedSessionDescriptor
            }
            try await waitForEvents(
                2,
                localSessionID: resumedLocalSessionID,
                in: eventStore
            )

            _ = try await host.request(
                try HarnessProtocolRequest(
                    id: "conformance-resumed-send",
                    method: .sessionSend,
                    typedParams: HarnessProtocolTurnSubmitParams(
                        localSessionID: resumedLocalSessionID,
                        clientMessageID: "resumed",
                        content: [.text("resumed")]
                    )
                )
            )
            try await waitForEvents(
                5,
                localSessionID: resumedLocalSessionID,
                in: eventStore
            )
            _ = try await host.request(
                try HarnessProtocolRequest(
                    id: "conformance-close-resumed",
                    method: .sessionClose,
                    typedParams: HarnessProtocolSessionReference(
                        localSessionID: resumedLocalSessionID
                    )
                )
            )

            let createdEvents = await eventStore.events(for: createdLocalSessionID)
            let resumedEvents = await eventStore.events(for: resumedLocalSessionID)
            let createdReport = try HarnessProtocolConformanceKit.validate(
                manifest: manifest,
                localSessionID: createdLocalSessionID,
                events: createdEvents
            )
            let resumedReport = try HarnessProtocolConformanceKit.validate(
                manifest: manifest,
                localSessionID: resumedLocalSessionID,
                events: resumedEvents
            )
            try requireEvent(
                .turnCanceled,
                localSessionID: createdLocalSessionID,
                events: createdEvents
            )
            try requireEvent(
                .turnCompleted,
                localSessionID: resumedLocalSessionID,
                events: resumedEvents
            )
            let preserved = createdEvents.compactMap(\.payload.extensionEvent).first?
                .payload["sample.fixture.mode"] ?? .null
            guard preserved == .string("conformance") else {
                throw HarnessProtocolExternalConformanceError.unexpectedExtensionResult
            }

            await host.stop()
            _ = await collector.result
            return HarnessProtocolExternalConformanceReport(
                adapterID: manifest.adapterID,
                negotiatedVersion: processSession.version,
                processID: processSession.processID,
                createdSessionEventCount: createdReport.acceptedEventCount,
                resumedSessionEventCount: resumedReport.acceptedEventCount,
                preservedExtensionValue: preserved
            )
        } catch {
            await host.stop()
            collector.cancel()
            _ = await collector.result
            throw error
        }
    }

    private func waitForEvents(
        _ count: Int,
        localSessionID: UUID,
        in store: HarnessProtocolConformanceEventStore
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: eventTimeout)
        while clock.now < deadline {
            if await store.count(for: localSessionID) >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HarnessProtocolExternalConformanceError.eventDeadlineExceeded(
            localSessionID: localSessionID,
            expectedCount: count
        )
    }

    private func requireEvent(
        _ kind: HarnessProtocolEventKind,
        localSessionID: UUID,
        events: [HarnessProtocolEventEnvelope]
    ) throws {
        guard events.contains(where: { $0.payload.kind == kind }) else {
            throw HarnessProtocolExternalConformanceError.missingEvent(
                localSessionID: localSessionID,
                kind: kind
            )
        }
    }
}

private actor HarnessProtocolConformanceEventStore {
    private var eventsBySessionID: [UUID: [HarnessProtocolEventEnvelope]] = [:]

    func append(_ event: HarnessProtocolEventEnvelope) {
        eventsBySessionID[event.localSessionID, default: []].append(event)
    }

    func count(for localSessionID: UUID) -> Int {
        eventsBySessionID[localSessionID]?.count ?? 0
    }

    func events(for localSessionID: UUID) -> [HarnessProtocolEventEnvelope] {
        eventsBySessionID[localSessionID] ?? []
    }
}
