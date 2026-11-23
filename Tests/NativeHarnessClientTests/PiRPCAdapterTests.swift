import Foundation
import XCTest
@testable import NativeHarnessClient

final class PiRPCAdapterTests: XCTestCase {
    func testTwoProcessesStreamIndependentlyAndConfirmExtensionPermission() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let firstTransport = FakePiRPCTransport(sessionFile: "/tmp/pi-session-1.jsonl")
        let secondTransport = FakePiRPCTransport(sessionFile: "/tmp/pi-session-2.jsonl")
        let adapter = PiRPCAdapter(
            kind: .pi,
            executableURL: URL(filePath: "/tmp/fake-pi"),
            transportFactory: { localID in
                localID == firstID ? firstTransport : secondTransport
            }
        )

        let first = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: firstID,
                workspaceURL: URL(filePath: "/tmp/project-one"),
                initialPrompt: nil
            )
        )
        let second = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: secondID,
                workspaceURL: URL(filePath: "/tmp/project-two"),
                initialPrompt: nil
            )
        )
        XCTAssertNotEqual(first.providerSessionID, second.providerSessionID)
        let firstConfiguration = await firstTransport.configuration
        let secondConfiguration = await secondTransport.configuration
        XCTAssertEqual(firstConfiguration?.workspaceURL.path, "/tmp/project-one")
        XCTAssertEqual(secondConfiguration?.workspaceURL.path, "/tmp/project-two")

        let firstRecorder = PiPayloadRecorder()
        let secondRecorder = PiPayloadRecorder()
        let firstCollector = Task {
            for await event in await adapter.events(for: first) {
                await firstRecorder.append(event.payload)
            }
        }
        let secondCollector = Task {
            for await event in await adapter.events(for: second) {
                await secondRecorder.append(event.payload)
            }
        }

        try await adapter.send("first", to: first)
        try await adapter.send("second", to: second)
        await firstTransport.emit(textDelta("ONE"))
        await secondTransport.emit(textDelta("TWO"))
        await firstTransport.emit(.object([
            "type": .string("extension_ui_request"),
            "id": .string("confirm-1"),
            "method": .string("confirm"),
            "title": .string("Write file"),
            "message": .string("Continue?")
        ]))
        try await waitUntil {
            await firstRecorder.payloads.contains {
                if case .permissionRequested = $0 { return true }
                return false
            }
        }
        try await adapter.respond(
            to: "pi-permission-confirm-1",
            decision: .deny,
            in: first
        )
        let sentMessages = await firstTransport.sentMessages
        XCTAssertTrue(sentMessages.contains {
            $0["id"]?.stringValue == "confirm-1" && $0["confirmed"]?.boolValue == false
        })

        await firstTransport.emit(.object([
            "type": .string("agent_end"),
            "isTerminal": .bool(true)
        ]))
        await secondTransport.emit(.object([
            "type": .string("agent_end"),
            "isTerminal": .bool(true)
        ]))
        try await waitUntil {
            let firstValues = await firstRecorder.payloads
            let secondValues = await secondRecorder.payloads
            return firstValues.contains(.turnCompleted)
                && secondValues.contains(.turnCompleted)
        }

        let firstPayloads = await firstRecorder.payloads
        let secondPayloads = await secondRecorder.payloads
        XCTAssertTrue(firstPayloads.contains(.assistantDelta("ONE")))
        XCTAssertFalse(firstPayloads.contains(.assistantDelta("TWO")))
        XCTAssertTrue(secondPayloads.contains(.assistantDelta("TWO")))
        XCTAssertFalse(secondPayloads.contains(.assistantDelta("ONE")))

        let readyCountBeforeInterrupt = secondPayloads.filter {
            $0 == .sessionStatusChanged(.ready)
        }.count
        try await adapter.send("cancel", to: second)
        try await adapter.interrupt(second)
        try await waitUntil {
            let values = await secondRecorder.payloads
            return values.filter { $0 == .sessionStatusChanged(.ready) }.count
                > readyCountBeforeInterrupt
        }
        let secondRequestTypes = await secondTransport.requestTypes
        XCTAssertTrue(secondRequestTypes.contains("abort"))

        await adapter.close(first)
        await adapter.close(second)
        firstCollector.cancel()
        secondCollector.cancel()
    }

    func testResumeSwitchesToThePersistedSessionFile() async throws {
        let transport = FakePiRPCTransport(sessionFile: "/tmp/new-session.jsonl")
        let adapter = PiRPCAdapter(
            kind: .pi,
            executableURL: URL(filePath: "/tmp/fake-pi"),
            transportFactory: { _ in transport }
        )
        let resumed = try await adapter.resumeSession(
            providerSessionID: "/tmp/existing-session.jsonl",
            localSessionID: UUID(),
            workspaceURL: URL(filePath: "/tmp/project")
        )
        XCTAssertEqual(resumed.providerSessionID, "/tmp/existing-session.jsonl")
        let requestTypes = await transport.requestTypes
        XCTAssertTrue(requestTypes.contains("switch_session"))
        await adapter.close(resumed)
    }

    func testModelThinkingAndCompactionUsePiRPCCommands() async throws {
        let transport = FakePiRPCTransport(sessionFile: "/tmp/pi.jsonl")
        let adapter = PiRPCAdapter(kind: .pi, executableURL: URL(filePath: "/tmp/pi"), transportFactory: { _ in transport })
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/project"), initialPrompt: nil
        ))
        let state = try await adapter.providerCapabilities(for: handle)
        XCTAssertEqual(state.selectors.first { $0.id == "thinking" }?.currentValue, "medium")
        _ = try await adapter.setProviderOption(id: "thinking", value: "high", in: handle)
        _ = try await adapter.performProviderAction(id: ProviderCapabilityActionID.compact, in: handle)
        let types = await transport.requestTypes
        XCTAssertTrue(types.contains("get_available_models"))
        XCTAssertTrue(types.contains("set_thinking_level"))
        XCTAssertTrue(types.contains("compact"))
    }

    /// Pi's adapter sends images beside the prompt and projects no subagent activity. The probe
    /// says exactly that, so the adapter and the YHP route the app ships report the same thing.
    func testPiProbeClaimsOnlyWhatTheRPCRouteCarries() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-pi-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appending(path: "pi")
        try Data("#!/bin/sh\necho '0.84.1'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path(percentEncoded: false)
        )

        let runtime = try await PiRPCAdapter(kind: .pi, executableURL: executable)
            .probeRuntime()
        XCTAssertEqual(runtime.harness, .pi)
        XCTAssertTrue(runtime.capabilities.acceptsImages)
        XCTAssertFalse(runtime.capabilities.hasSubagents)
        XCTAssertFalse(runtime.capabilities.hasPlans)

        let routed = try await YHPProviderCompatibilityAdapter(
            adapter: PiRPCAdapter(kind: .pi, executableURL: executable),
            manifest: HarnessProtocolCompatibilityManifest.piRPC(.pi)
        ).probeRuntime()
        XCTAssertEqual(routed.capabilities, runtime.capabilities)
    }

    func testYHPProductRoutePreservesPiControlsPermissionsAndLifecycle() async throws {
        let directTransport = FakePiRPCTransport(sessionFile: "/tmp/pi-yhp-product.jsonl")
        let routedTransport = FakePiRPCTransport(sessionFile: "/tmp/pi-yhp-product.jsonl")
        let localSessionID = UUID()
        let direct = PiRPCAdapter(
            kind: .pi,
            executableURL: URL(filePath: "/tmp/fake-pi"),
            transportFactory: { _ in directTransport }
        )
        let routed = YHPProviderCompatibilityAdapter(
            adapter: PiRPCAdapter(
                kind: .pi,
                executableURL: URL(filePath: "/tmp/fake-pi"),
                transportFactory: { _ in routedTransport }
            ),
            manifest: HarnessProtocolCompatibilityManifest.piRPC(.pi)
        )
        let request = CreateHarnessSessionRequest(
            localSessionID: localSessionID,
            workspaceURL: URL(filePath: "/tmp/pi-yhp-product"),
            initialPrompt: nil
        )
        let directHandle = try await direct.createSession(request)
        let routedHandle = try await routed.createSession(request)
        XCTAssertEqual(routedHandle, directHandle)

        let routedCapabilities = try await routed.providerCapabilities(for: routedHandle)
        let directCapabilities = try await direct.providerCapabilities(for: directHandle)
        XCTAssertEqual(routedCapabilities, directCapabilities)
        let routedUpdated = try await routed.setProviderOption(
            id: "thinking",
            value: "high",
            in: routedHandle
        )
        let directUpdated = try await direct.setProviderOption(
            id: "thinking",
            value: "high",
            in: directHandle
        )
        XCTAssertEqual(routedUpdated, directUpdated)
        let routedCompacted = try await routed.performProviderAction(
            id: ProviderCapabilityActionID.compact,
            in: routedHandle
        )
        let directCompacted = try await direct.performProviderAction(
            id: ProviderCapabilityActionID.compact,
            in: directHandle
        )
        XCTAssertEqual(routedCompacted, directCompacted)

        let directRecorder = PiEventRecorder()
        let routedRecorder = PiEventRecorder()
        let directCollector = Task {
            for await event in await direct.events(for: directHandle) {
                await directRecorder.append(event)
            }
        }
        let routedCollector = Task {
            for await event in await routed.events(for: routedHandle) {
                await routedRecorder.append(event)
            }
        }
        try await direct.send("hello", to: directHandle)
        try await routed.send("hello", to: routedHandle)
        await directTransport.emit(textDelta("hello"))
        await routedTransport.emit(textDelta("hello"))
        let permission: JSONValue = .object([
            "type": .string("extension_ui_request"),
            "id": .string("confirm-yhp"),
            "method": .string("confirm"),
            "title": .string("Write file"),
            "message": .string("Continue?")
        ])
        await directTransport.emit(permission)
        await routedTransport.emit(permission)
        try await waitUntil {
            let directEvents = await directRecorder.events
            let routedEvents = await routedRecorder.events
            return directEvents.contains { event in
                if case .permissionRequested = event.payload { return true }
                return false
            } && routedEvents.contains { event in
                if case .permissionRequested = event.payload { return true }
                return false
            }
        }
        try await direct.respond(
            to: "pi-permission-confirm-yhp",
            decision: .deny,
            in: directHandle
        )
        try await routed.respond(
            to: "pi-permission-confirm-yhp",
            decision: .deny,
            in: routedHandle
        )
        let terminal: JSONValue = .object([
            "type": .string("agent_end"),
            "isTerminal": .bool(true)
        ])
        await directTransport.emit(terminal)
        await routedTransport.emit(terminal)
        // Session stats are requested after the turn completes, so the trailing ready/usage
        // events land asynchronously on both routes. Wait for them before comparing.
        try await waitUntil {
            let directEvents = await directRecorder.events
            let routedEvents = await routedRecorder.events
            return directEvents.contains { $0.payload == .turnCompleted }
                && routedEvents.contains { $0.payload == .turnCompleted }
                && directEvents.contains { if case .usageUpdated = $0.payload { return true } else { return false } }
                && routedEvents.contains { if case .usageUpdated = $0.payload { return true } else { return false } }
        }
        let directEvents = await directRecorder.events
        let routedEvents = await routedRecorder.events
        XCTAssertEqual(routedEvents.map(\.payload), directEvents.map(\.payload))
        XCTAssertEqual(
            routedEvents.map { $0.rawProviderEvent != nil },
            directEvents.map { $0.rawProviderEvent != nil }
        )

        try await direct.send("cancel", to: directHandle)
        try await routed.send("cancel", to: routedHandle)
        try await direct.interrupt(directHandle)
        try await routed.interrupt(routedHandle)
        try await waitUntil {
            let directEvents = await directRecorder.events
            let routedEvents = await routedRecorder.events
            func usageCount(_ events: [HarnessEventEnvelope]) -> Int {
                events.filter { if case .usageUpdated = $0.payload { return true } else { return false } }.count
            }
            return directEvents.filter { $0.payload == .turnCompleted }.count == 2
                && routedEvents.filter { $0.payload == .turnCompleted }.count == 2
                && usageCount(directEvents) == 2 && usageCount(routedEvents) == 2
        }
        let directFinal = await directRecorder.events.map(\.payload)
        let routedFinal = await routedRecorder.events.map(\.payload)
        XCTAssertEqual(routedFinal, directFinal)

        await direct.close(directHandle)
        await routed.close(routedHandle)
        directCollector.cancel()
        routedCollector.cancel()
    }

    func testEndedTransportFailsRunningTurnFinishesStreamsAndAllowsFreshSession() async throws {
        let activeID = UUID()
        let idleID = UUID()
        let activeTransport = FakePiRPCTransport(sessionFile: "/tmp/pi-crash-active.jsonl")
        let idleTransport = FakePiRPCTransport(sessionFile: "/tmp/pi-crash-idle.jsonl")
        let recoveredTransport = FakePiRPCTransport(sessionFile: "/tmp/pi-crash-recovered.jsonl")
        let recoveredID = UUID()
        let adapter = PiRPCAdapter(
            kind: .pi,
            executableURL: URL(filePath: "/tmp/fake-pi"),
            transportFactory: { localID in
                if localID == activeID { return activeTransport }
                if localID == idleID { return idleTransport }
                return recoveredTransport
            }
        )

        let active = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: activeID,
            workspaceURL: URL(filePath: "/tmp/pi-project"),
            initialPrompt: nil
        ))
        let idle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: idleID,
            workspaceURL: URL(filePath: "/tmp/pi-project"),
            initialPrompt: nil
        ))
        let activeRecorder = PiPayloadRecorder()
        let idleRecorder = PiPayloadRecorder()
        let activeCollector = Task {
            for await event in await adapter.events(for: active) {
                await activeRecorder.append(event.payload)
            }
            await activeRecorder.end()
        }
        let idleCollector = Task {
            for await event in await adapter.events(for: idle) {
                await idleRecorder.append(event.payload)
            }
            await idleRecorder.end()
        }
        defer {
            activeCollector.cancel()
            idleCollector.cancel()
        }

        try await adapter.send("crash me", to: active)
        await activeTransport.exit()
        await idleTransport.exit()
        try await waitUntil {
            let activeEnded = await activeRecorder.ended
            let idleEnded = await idleRecorder.ended
            return activeEnded && idleEnded
        }

        let activePayloads = await activeRecorder.payloads
        XCTAssertEqual(Array(activePayloads.suffix(2)), [
            .error(message: L10n.format("Connection to %@ ended.", HarnessKind.pi.displayName), recoverable: true),
            .sessionStatusChanged(.failed)
        ])
        XCTAssertFalse(activePayloads.contains(.turnCompleted))

        let idlePayloads = await idleRecorder.payloads
        XCTAssertFalse(idlePayloads.contains { payload in
            if case .error = payload { return true }
            return payload == .sessionStatusChanged(.failed)
        })

        do {
            try await adapter.send("after", to: active)
            XCTFail("Expected detached Pi session to reject prompts")
        } catch let error as HarnessAdapterError {
            XCTAssertEqual(error, .invalidProviderEvent(L10n.string("Pi RPC session is not attached")))
        }

        let recovered = try await adapter.resumeSession(
            providerSessionID: active.providerSessionID,
            localSessionID: recoveredID,
            workspaceURL: URL(filePath: "/tmp/pi-project")
        )
        XCTAssertEqual(recovered.providerSessionID, active.providerSessionID)
        await adapter.close(recovered)
    }

    func testMessageEndErrorPreventsTrailingAgentEndFromMaskingFailure() async throws {
        let directTransport = FakePiRPCTransport(sessionFile: "/tmp/pi-err-direct.jsonl")
        let routedTransport = FakePiRPCTransport(sessionFile: "/tmp/pi-err-routed.jsonl")
        let adapters: [(any HarnessAdapter, FakePiRPCTransport)] = [
            (
                PiRPCAdapter(
                    kind: .pi,
                    executableURL: URL(filePath: "/tmp/fake-pi"),
                    transportFactory: { _ in directTransport }
                ),
                directTransport
            ),
            (
                YHPProviderCompatibilityAdapter(
                    adapter: PiRPCAdapter(
                        kind: .pi,
                        executableURL: URL(filePath: "/tmp/fake-pi"),
                        transportFactory: { _ in routedTransport }
                    ),
                    manifest: HarnessProtocolCompatibilityManifest.piRPC(.pi)
                ),
                routedTransport
            )
        ]

        for (adapter, transport) in adapters {
            let handle = try await adapter.createSession(CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/pi-err"),
                initialPrompt: nil
            ))
            let recorder = PiPayloadRecorder()
            let collector = Task {
                for await event in await adapter.events(for: handle) {
                    await recorder.append(event.payload)
                }
            }
            defer { collector.cancel() }

            try await adapter.send("trigger error", to: handle)
            await transport.emit(.object(["type": .string("agent_start")]))
            await transport.emit(.object([
                "type": .string("message_end"),
                "message": .object([
                    "role": .string("assistant"),
                    "content": .array([]),
                    "stopReason": .string("error"),
                    "errorMessage": .string("429 rate limited")
                ])
            ]))
            await transport.emit(.object([
                "type": .string("agent_end"),
                "isTerminal": .bool(true)
            ]))
            try await waitUntil { await recorder.payloads.contains(.sessionStatusChanged(.failed)) }
            try await Task.sleep(for: .milliseconds(30))

            let payloads = await recorder.payloads
            XCTAssertTrue(payloads.contains(.error(message: "429 rate limited", recoverable: true)))
            XCTAssertFalse(payloads.contains(.turnCompleted))
            let running = try XCTUnwrap(payloads.firstIndex(of: .sessionStatusChanged(.running)))
            XCTAssertFalse(payloads[running...].contains(.sessionStatusChanged(.ready)))

            // The session is no longer stuck as running, so a follow-up turn succeeds.
            try await adapter.send("retry", to: handle)
            await transport.emit(.object(["type": .string("agent_end"), "isTerminal": .bool(true)]))
            try await waitUntil { await recorder.payloads.contains(.turnCompleted) }
            await adapter.close(handle)
        }
    }

    func testFinishedTurnPrunesCachedActivities() async throws {
        let transport = FakePiRPCTransport(sessionFile: "/tmp/pi-prune.jsonl")
        let adapter = PiRPCAdapter(
            kind: .pi,
            executableURL: URL(filePath: "/tmp/fake-pi"),
            transportFactory: { _ in transport }
        )
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: URL(filePath: "/tmp/pi-prune"),
            initialPrompt: nil
        ))
        let recorder = PiPayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }
        defer { collector.cancel() }

        try await adapter.send("turn 1", to: handle)
        await transport.emit(.object([
            "type": .string("tool_execution_start"),
            "toolCallId": .string("call-1"),
            "toolName": .string("bash"),
            "args": .object(["command": .string("pwd")])
        ]))
        await transport.emit(.object([
            "type": .string("tool_execution_end"),
            "toolCallId": .string("call-1"),
            "result": .object(["content": .array([.object(["type": .string("text"), "text": .string("/tmp")])])])
        ]))
        await transport.emit(.object(["type": .string("agent_end"), "isTerminal": .bool(true)]))
        try await waitUntil { await recorder.payloads.contains(.turnCompleted) }

        // Turn 2 reuses the same toolCallId without toolName/args: pruned state must not bleed through.
        try await adapter.send("turn 2", to: handle)
        await transport.emit(.object([
            "type": .string("tool_execution_update"),
            "toolCallId": .string("call-1"),
            "partialResult": .object(["content": .array([.object(["type": .string("text"), "text": .string("fresh")])])])
        ]))
        try await waitUntil {
            await recorder.payloads.contains { payload in
                if case let .activityUpdated(activity) = payload {
                    return activity.id == "call-1" && activity.output == "fresh"
                }
                return false
            }
        }
        let payloads = await recorder.payloads
        let updated = try XCTUnwrap(payloads.compactMap { payload -> HarnessActivity? in
            if case let .activityUpdated(activity) = payload, activity.id == "call-1" { return activity }
            return nil
        }.last)
        XCTAssertEqual(updated.title, L10n.string("Tool call"))
        XCTAssertNil(updated.input)
        await adapter.close(handle)
    }

    private func textDelta(_ text: String) -> JSONValue {
        .object([
            "type": .string("message_update"),
            "assistantMessageEvent": .object([
                "type": .string("text_delta"),
                "delta": .string(text)
            ])
        ])
    }
}

private actor PiPayloadRecorder {
    private(set) var payloads: [HarnessEventPayload] = []
    private(set) var ended = false
    func append(_ payload: HarnessEventPayload) { payloads.append(payload) }
    func end() { ended = true }
}

private actor PiEventRecorder {
    private(set) var events: [HarnessEventEnvelope] = []
    func append(_ event: HarnessEventEnvelope) { events.append(event) }
}

actor FakePiRPCTransport: PiRPCTransport {
    private let stream: AsyncStream<PiRPCRawFrame>
    private let continuation: AsyncStream<PiRPCRawFrame>.Continuation
    private var sessionFile: String
    private var modelProvider = "anthropic"
    private var modelID = "sonnet"
    private var thinkingLevel = "medium"
    private var autoCompactionEnabled = true
    private(set) var configuration: PiRPCLaunchConfiguration?
    private(set) var requestTypes: [String] = []
    private(set) var requestValues: [JSONValue] = []
    private(set) var sentMessages: [JSONValue] = []
    private(set) var stopCount = 0
    /// `get_state` names no session file, as a session kept in memory may.
    private var omitsSessionFile = false

    func forgetSessionFile() { omitsSessionFile = true }

    init(sessionFile: String) {
        self.sessionFile = sessionFile
        let pair = AsyncStream<PiRPCRawFrame>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func start(_ configuration: PiRPCLaunchConfiguration) async throws {
        self.configuration = configuration
    }

    func request(_ value: JSONValue, id: String) async throws -> JSONValue {
        let type = value["type"]?.stringValue ?? "unknown"
        requestTypes.append(type)
        requestValues.append(value)
        if type == "switch_session", let path = value["sessionPath"]?.stringValue {
            sessionFile = path
            return response(id: id, command: type, data: .object(["cancelled": .bool(false)]))
        }
        if type == "get_state" {
            var data: [String: JSONValue] = [
                "sessionFile": .string(sessionFile),
                "sessionId": .string(URL(filePath: sessionFile).deletingPathExtension().lastPathComponent),
                "model": .object([
                    "provider": .string(modelProvider),
                    "id": .string(modelID)
                ]),
                "thinkingLevel": .string(thinkingLevel),
                "autoCompactionEnabled": .bool(autoCompactionEnabled)
            ]
            if omitsSessionFile { data.removeValue(forKey: "sessionFile") }
            return response(id: id, command: type, data: .object(data))
        }
        if type == "get_available_models" {
            return response(id: id, command: type, data: .object(["models": .array([
                .object(["provider": .string("anthropic"), "id": .string("sonnet"), "name": .string("Sonnet")])
            ])]))
        }
        if type == "get_available_thinking_levels" {
            return response(id: id, command: type, data: .object(["levels": .array([.string("off"), .string("medium"), .string("high")])]))
        }
        if type == "prompt" {
            return response(
                id: id,
                command: type,
                data: .object(["agentInvoked": .bool(true)])
            )
        }
        if type == "get_session_stats" {
            return response(id: id, command: type, data: .object([
                "tokens": .object([
                    "input": .integer(1_200),
                    "output": .integer(300),
                    "cacheRead": .integer(50)
                ]),
                "cost": .number(0.0421),
                "contextUsage": .object([
                    "usedTokens": .integer(1_550),
                    "maxTokens": .integer(200_000)
                ])
            ]))
        }
        if type == "set_model" {
            modelProvider = value["provider"]?.stringValue ?? modelProvider
            modelID = value["modelId"]?.stringValue ?? modelID
        }
        if type == "set_thinking_level" {
            thinkingLevel = value["level"]?.stringValue ?? thinkingLevel
        }
        if type == "set_auto_compaction" {
            autoCompactionEnabled = value["enabled"]?.boolValue ?? autoCompactionEnabled
        }
        return response(id: id, command: type, data: nil)
    }

    func send(_ value: JSONValue) async throws { sentMessages.append(value) }
    func messages() async -> AsyncStream<PiRPCRawFrame> { stream }
    func stop() async {
        stopCount += 1
        continuation.finish()
    }

    func exit() {
        continuation.finish()
    }

    func emit(_ value: JSONValue) {
        let data = (try? PiRPCWireCodec().encodeLine(value)) ?? Data()
        continuation.yield(PiRPCRawFrame(value: value, data: data))
    }

    private func response(id: String, command: String, data: JSONValue?) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "type": .string("response"),
            "command": .string(command),
            "success": .bool(true)
        ]
        object["data"] = data
        return .object(object)
    }
}
