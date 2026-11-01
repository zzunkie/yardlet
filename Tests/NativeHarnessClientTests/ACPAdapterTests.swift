import Foundation
import XCTest
@testable import NativeHarnessClient

final class ACPAdapterTests: XCTestCase {
    /// An ACP agent may document image prompts and subagents, but the ACP route implements
    /// neither as a family default: image input is the agent's own `initialize` answer, and no
    /// projection carries subagent activity. The probe claims only what the route carries, so the
    /// adapter and the YHP route the app ships report the same thing.
    func testACPProbeClaimsOnlyWhatTheACPRouteCarries() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-acp-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "hermes")
        try Data("#!/bin/sh\necho 'hermes 0.1.66'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path(percentEncoded: false)
        )

        let runtime = try await ACPAdapter(
            kind: .hermes,
            executableURL: executable
        ).probeRuntime()

        XCTAssertEqual(runtime.harness, .hermes)
        XCTAssertEqual(runtime.version, "hermes 0.1.66")
        XCTAssertFalse(runtime.capabilities.acceptsImages)
        XCTAssertFalse(runtime.capabilities.hasSubagents)
        XCTAssertTrue(runtime.capabilities.hasStructuredPermissions)
        XCTAssertTrue(runtime.capabilities.hasPlans)

        let routed = try await YHPProviderCompatibilityAdapter(
            adapter: ACPAdapter(kind: .hermes, executableURL: executable),
            manifest: HarnessProtocolCompatibilityManifest.acp(.hermes)
        ).probeRuntime()
        XCTAssertEqual(routed.capabilities, runtime.capabilities)

        // Once the agent answers, its own advertisement is what the probe reports.
        let advertising = ACPAdapter(
            kind: .hermes,
            executableURL: executable,
            transport: FakeACPTransport(advertisesImagePrompts: true)
        )
        let handle = try await advertising.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/acp-workspace"),
                initialPrompt: nil
            )
        )
        let answered = try await advertising.probeRuntime()
        XCTAssertTrue(answered.capabilities.acceptsImages)
        XCTAssertFalse(answered.capabilities.hasSubagents)
        await advertising.close(handle)
    }

    func testUnsupportedInitializationStopsTheTransport() async throws {
        let transport = FakeACPTransport(protocolVersion: 2)
        let adapter = ACPAdapter(
            kind: .grokBuild,
            executableURL: URL(filePath: "/tmp/fake-grok"),
            transport: transport
        )

        do {
            _ = try await adapter.createSession(
                CreateHarnessSessionRequest(
                    localSessionID: UUID(),
                    workspaceURL: URL(filePath: "/tmp/acp-workspace"),
                    initialPrompt: nil
                )
            )
            XCTFail("Expected the unsupported ACP version to fail")
        } catch let error as HarnessAdapterError {
            XCTAssertEqual(error, .unsupportedRuntime(version: "ACP 2"))
        }
        let stopCount = await transport.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testResumeFailsClosedWhenRuntimeDoesNotAdvertiseSessionLoading() async throws {
        let transport = FakeACPTransport(canLoadSession: false)
        let adapter = ACPAdapter(
            kind: .kimiCode,
            executableURL: URL(filePath: "/tmp/fake-kimi"),
            transport: transport
        )

        do {
            _ = try await adapter.resumeSession(
                providerSessionID: "existing-session",
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/acp-workspace")
            )
            XCTFail("Expected resume without negotiated loadSession support to fail")
        } catch let error as HarnessAdapterError {
            guard case let .capabilityUnavailable(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("Kimi Code"))
        }

        let methods = await transport.requestMethods
        let stopCount = await transport.stopCount
        XCTAssertEqual(methods, ["initialize"])
        XCTAssertEqual(stopCount, 1)
    }

    func testCreateStreamPermissionInterruptAndResumeUseSharedACPContract() async throws {
        let transport = FakeACPTransport()
        let adapter = ACPAdapter(
            kind: .hermes,
            executableURL: URL(filePath: "/tmp/fake-hermes"),
            launchArguments: ["acp"],
            transport: transport
        )
        let localID = UUID()
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: localID,
                workspaceURL: URL(filePath: "/tmp/acp-workspace"),
                initialPrompt: nil
            )
        )
        XCTAssertEqual(handle.providerSessionID, "acp-session-1")
        let configuration = await transport.configuration
        XCTAssertEqual(configuration?.arguments, ["acp"])
        XCTAssertEqual(configuration?.environmentOverrides, [:])

        let recorder = ACPPayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }
        try await adapter.send("hello", to: handle)
        try await waitUntil { await transport.requestMethods.contains("session/prompt") }
        let requestsWithoutTimeout = await transport.requestMethodsWithoutTimeout
        XCTAssertEqual(requestsWithoutTimeout, ["session/prompt"])

        await transport.emit(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/update"),
            "params": .object([
                "sessionId": .string(handle.providerSessionID),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string("world")
                    ])
                ])
            ])
        ]))
        await transport.emit(.object([
            "jsonrpc": .string("2.0"),
            "id": .string("permission-rpc-1"),
            "method": .string("session/request_permission"),
            "params": .object([
                "sessionId": .string(handle.providerSessionID),
                "toolCall": .object([
                    "toolCallId": .string("tool-1"),
                    "title": .string("Run command"),
                    "kind": .string("execute"),
                    "rawInput": .object(["command": .string("git status")])
                ]),
                "options": .array([
                    .object([
                        "optionId": .string("allow-once"),
                        "name": .string("Allow once"),
                        "kind": .string("allow_once")
                    ]),
                    .object([
                        "optionId": .string("reject-once"),
                        "name": .string("Reject once"),
                        "kind": .string("reject_once")
                    ])
                ])
            ])
        ]))
        try await waitUntil {
            await recorder.payloads.contains {
                if case .permissionRequested = $0 { return true }
                return false
            }
        }

        try await adapter.respond(
            to: "acp-permission-permission-rpc-1",
            decision: .allow,
            in: handle
        )
        let sent = await transport.sentMessages
        XCTAssertTrue(sent.contains { message in
            message["result"]?["outcome"]?["optionId"]?.stringValue == "allow-once"
        })

        await transport.completePrompt()
        try await waitUntil { await recorder.payloads.contains(.turnCompleted) }
        let payloads = await recorder.payloads
        XCTAssertTrue(payloads.contains(.assistantDelta("world")))
        XCTAssertTrue(payloads.contains(.sessionStatusChanged(.waitingForApproval)))

        try await adapter.send("cancel me", to: handle)
        try await waitUntil { await transport.pendingPromptCount == 1 }
        try await adapter.interrupt(handle)
        let afterCancel = await transport.sentMessages
        XCTAssertTrue(afterCancel.contains { $0["method"]?.stringValue == "session/cancel" })
        await transport.completePrompt()

        await adapter.close(handle)

        let resumedAdapter = ACPAdapter(
            kind: .openCode,
            executableURL: URL(filePath: "/tmp/fake-opencode"),
            launchArguments: ["acp"],
            transport: FakeACPTransport()
        )
        let resumed = try await resumedAdapter.resumeSession(
            providerSessionID: "existing-session",
            localSessionID: UUID(),
            workspaceURL: URL(filePath: "/tmp/acp-workspace")
        )
        XCTAssertEqual(resumed.providerSessionID, "existing-session")
        await resumedAdapter.close(resumed)
        collector.cancel()
    }

    func testSessionConfigOptionRoundTripsThroughAdapter() async throws {
        let transport = FakeACPTransport(exposesConfig: true)
        let adapter = ACPAdapter(kind: .openCode, executableURL: URL(filePath: "/tmp/opencode"), transport: transport)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/project"), initialPrompt: nil
        ))
        let initial = try await adapter.providerCapabilities(for: handle)
        XCTAssertEqual(initial.selectors.first?.currentValue, "ask")
        let updated = try await adapter.setProviderOption(id: "mode", value: "code", in: handle)
        XCTAssertEqual(updated.selectors.first?.currentValue, "code")
        let methods = await transport.requestMethods
        XCTAssertTrue(methods.contains("session/set_config_option"))
    }

    /// Antigravity over ACP keeps the option names its print mode saved, and its permission mode is
    /// how Yardlet answers what the agent asks: Default shows the request, Bypass permissions
    /// answers yes and Plan answers no.
    func testAntigravityKeepsItsOptionNamesAndAnswersApprovalsByItsPermissionMode() async throws {
        let transport = FakeACPTransport(exposesAntigravity: true)
        let adapter = ACPAdapter(kind: .antigravityCLI, executableURL: URL(filePath: "/tmp/agy"),
                                 launchArguments: ["acp"], transport: transport)
        let localID = UUID()
        // A print-mode task that never ran a turn kept its local ID; it starts a conversation.
        let handle = try await adapter.resumeSession(providerSessionID: localID.uuidString.lowercased(),
                                                     localSessionID: localID, workspaceURL: URL(filePath: "/tmp/project"))
        XCTAssertEqual(handle.providerSessionID, "acp-session-1")
        let afterAttach = await transport.requestMethods
        XCTAssertEqual(afterAttach, ["initialize", "session/new"])

        let initial = try await adapter.providerCapabilities(for: handle)
        XCTAssertEqual(initial.selectors.map(\.id), ["model", StructuredHeadlessOptionID.reasoningEffort,
                                                     AntigravityPermissionMode.optionID])
        XCTAssertEqual(initial.selectors.last?.choices.map(\.value),
                       [AntigravityPermissionMode.standard, AntigravityPermissionMode.bypass])
        let models = await adapter.advertisedModels(for: localID)
        XCTAssertEqual(models?.map(\.value), ["gemini-3.8-flash"])
        XCTAssertEqual(models?.first?.effortLevels, ["low", "medium", "high"])

        // A variant saved in print mode is its model with that effort.
        let chosen = try await adapter.setProviderOption(id: "model", value: "gemini-3.8-flash-low", in: handle)
        let sentOptions = await transport.requestValues.filter { $0["method"]?.stringValue == "session/set_config_option" }
        XCTAssertEqual(sentOptions.compactMap { $0["params"]?["configId"]?.stringValue }, ["model", "thought_level"])
        XCTAssertEqual(chosen.selectors.first { $0.id == StructuredHeadlessOptionID.reasoningEffort }?.currentValue, "low")
        // Print mode's own choices, and a default, change nothing; a model it does not offer is said.
        for (id, value) in [(StructuredHeadlessOptionID.reasoningEffort, "default"), (StructuredHeadlessOptionID.agent, "x")] {
            _ = try await adapter.setProviderOption(id: id, value: value, in: handle)
        }
        let requestCount = await transport.requestMethods.count
        XCTAssertEqual(requestCount, 4)
        do {
            _ = try await adapter.setProviderOption(id: "model", value: "claude-sonnet-4-6", in: handle)
            XCTFail("A model the session does not offer was accepted")
        } catch HarnessAdapterError.capabilityUnavailable {}
        let accepting = try await adapter.setProviderOption(id: AntigravityPermissionMode.optionID,
                                                            value: AntigravityPermissionMode.acceptEdits, in: handle)
        XCTAssertEqual(accepting.selectors.last?.currentValue, AntigravityPermissionMode.standard)

        let recorder = ACPPayloadRecorder()
        let collector = Task { for await event in await adapter.events(for: handle) { await recorder.append(event.payload) } }
        func ask(_ rpcID: String) async {
            await transport.emit(.object([
                "jsonrpc": .string("2.0"), "id": .string(rpcID), "method": .string("session/request_permission"),
                "params": .object([
                    "sessionId": .string(handle.providerSessionID),
                    "toolCall": .object(["toolCallId": .string(rpcID), "title": .string("hello.txt")]),
                    "options": .array([
                        .object(["optionId": .string("allow-once"), "name": .string("Allow"), "kind": .string("allow_once")]),
                        .object(["optionId": .string("reject-once"), "name": .string("Reject"), "kind": .string("reject_once")])
                    ])
                ])
            ]))
        }
        func answer(_ rpcID: String) async -> String? {
            await transport.sentMessages.first { $0["id"]?.stringValue == rpcID }?["result"]?["outcome"]?["optionId"]?.stringValue
        }
        _ = try await adapter.setProviderOption(id: AntigravityPermissionMode.optionID, value: AntigravityPermissionMode.bypass, in: handle)
        await ask("bypass-1")
        try await waitUntil { await answer("bypass-1") != nil }
        let bypassAnswer = await answer("bypass-1")
        XCTAssertEqual(bypassAnswer, "allow-once")
        _ = try await adapter.setProviderOption(id: AntigravityPermissionMode.optionID, value: AntigravityPermissionMode.plan, in: handle)
        await ask("plan-1")
        try await waitUntil { await answer("plan-1") != nil }
        let planAnswer = await answer("plan-1")
        XCTAssertEqual(planAnswer, "reject-once")
        _ = try await adapter.setProviderOption(id: AntigravityPermissionMode.optionID, value: AntigravityPermissionMode.standard, in: handle)
        await ask("ask-1")
        try await waitUntil {
            await recorder.payloads.contains { if case .permissionRequested = $0 { return true }; return false }
        }
        let payloads = await recorder.payloads
        XCTAssertEqual(payloads.filter { if case .permissionRequested = $0 { return true }; return false }.count, 1)
        let askAnswer = await answer("ask-1")
        XCTAssertNil(askAnswer)
        collector.cancel()
        await adapter.close(handle)
    }


    func testGrokSeparatesWorkMessagesFromFinalAnswerAndRoutesLiveControls() async throws {
        let transport = FakeACPTransport(exposesGrokModels: true)
        let adapter = ACPAdapter(
            kind: .grokBuild,
            executableURL: URL(filePath: "/tmp/fake-grok"),
            transport: transport
        )
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: URL(filePath: "/tmp/grok-project"),
            initialPrompt: nil
        ))
        let capabilities = try await adapter.providerCapabilities(for: handle)
        XCTAssertEqual(capabilities.selectors.map(\.id), ["model", "reasoning_effort"])

        let recorder = ACPPayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }
        try await adapter.send("check", to: handle)
        try await waitUntil { await transport.pendingPromptCount == 1 }
        await transport.emit(acpUpdate(
            providerSessionID: handle.providerSessionID,
            update: .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("Inspecting.")])
            ])
        ))
        await transport.emit(acpUpdate(
            providerSessionID: handle.providerSessionID,
            update: .object([
                "sessionUpdate": .string("tool_call"),
                "toolCallId": .string("tool-1"),
                "kind": .string("read"),
                "title": .string("Read file")
            ])
        ))
        await transport.emit(acpUpdate(
            providerSessionID: handle.providerSessionID,
            update: .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("Final answer.")])
            ])
        ))
        try await waitUntil {
            await recorder.payloads.contains(.assistantDelta("Final answer."))
        }
        await transport.completePrompt()
        try await waitUntil { await recorder.payloads.contains(.turnCompleted) }

        let payloads = await recorder.payloads
        guard let workCompleted = payloads.firstIndex(of: .assistantMessageCompleted("Inspecting.")),
              let toolStarted = payloads.firstIndex(where: {
                  if case .activityStarted = $0 { return true }
                  return false
              }),
              let finalCompleted = payloads.firstIndex(of: .assistantMessageCompleted("Final answer.")),
              let turnCompleted = payloads.firstIndex(of: .turnCompleted) else {
            return XCTFail("Expected bounded Grok assistant messages and turn completion: \(payloads)")
        }
        XCTAssertLessThan(workCompleted, toolStarted)
        XCTAssertLessThan(toolStarted, finalCompleted)
        XCTAssertLessThan(finalCompleted, turnCompleted)

        let switched = try await adapter.setProviderOption(
            id: "model",
            value: "grok-4.5",
            in: handle
        )
        XCTAssertEqual(
            switched.selectors.first(where: { $0.id == "model" })?.currentValue,
            "grok-4.5"
        )
        XCTAssertEqual(
            switched.selectors.first(where: { $0.id == "reasoning_effort" })?.choices.map(\.value),
            ["high", "low"]
        )
        _ = try await adapter.setProviderOption(
            id: "reasoning_effort",
            value: "low",
            in: handle
        )
        let methods = await transport.requestMethods
        XCTAssertEqual(methods.filter { $0 == "session/set_model" }.count, 2)

        await adapter.close(handle)
        collector.cancel()
    }

    func testGrokPublishesExtensionTurnUsageThroughYHPRoute() async throws {
        let transport = FakeACPTransport(exposesGrokModels: true)
        let adapter = YHPProviderCompatibilityAdapter(
            adapter: ACPAdapter(
                kind: .grokBuild,
                executableURL: URL(filePath: "/tmp/fake-grok"),
                transport: transport
            ),
            manifest: HarnessProtocolCompatibilityManifest.acp(.grokBuild)
        )
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: URL(filePath: "/tmp/grok-usage"),
            initialPrompt: nil
        ))
        let recorder = ACPPayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }

        await transport.emit(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("_x.ai/session/update"),
            "params": .object([
                "sessionId": .string(handle.providerSessionID),
                "update": .object([
                    "sessionUpdate": .string("turn_completed"),
                    "usage": .object([
                        "inputTokens": .integer(1_200),
                        "cachedReadTokens": .integer(800),
                        "outputTokens": .integer(50)
                    ])
                ])
            ])
        ]))
        try await waitUntil {
            await recorder.payloads.contains { payload in
                if case .usageUpdated = payload { return true }
                return false
            }
        }
        let payloads = await recorder.payloads
        guard case let .usageUpdated(usage)? = payloads.first(where: {
            if case .usageUpdated = $0 { return true }
            return false
        }) else {
            return XCTFail("Expected Grok usage event")
        }
        XCTAssertEqual(usage.inputTokens, 1_200)
        XCTAssertEqual(usage.cachedInputTokens, 800)
        XCTAssertEqual(usage.outputTokens, 50)

        await adapter.close(handle)
        collector.cancel()
    }

    /// ACP's `usage_update` (OpenCode, Kimi Code, Hermes) fills the composer's context
    /// ring: `used` of `size`, and the session's cost in USD.
    func testUsageUpdateReportsTheContextWindow() async throws {
        let transport = FakeACPTransport()
        let adapter = ACPAdapter(kind: .openCode, executableURL: URL(filePath: "/tmp/fake-opencode"),
                                 transport: transport)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/acp-usage"), initialPrompt: nil))
        let recorder = ACPPayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) { await recorder.append(event.payload) }
        }
        await transport.emit(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/update"),
            "params": .object([
                "sessionId": .string(handle.providerSessionID),
                "update": .object([
                    "sessionUpdate": .string("usage_update"),
                    "used": .integer(53_000),
                    "size": .integer(200_000),
                    "cost": .object(["amount": .number(0.42), "currency": .string("USD")])
                ])
            ])
        ]))
        try await waitUntil {
            await recorder.payloads.contains { if case .usageUpdated = $0 { true } else { false } }
        }
        guard case let .usageUpdated(usage)? = await recorder.payloads.first(where: {
            if case .usageUpdated = $0 { true } else { false }
        }) else { return XCTFail("Expected the usage update") }
        XCTAssertEqual(usage.contextUsedTokens, 53_000)
        XCTAssertEqual(usage.contextWindowTokens, 200_000)
        XCTAssertEqual(usage.totalCostUSD, 0.42)
        XCTAssertEqual(ComposerContextSummary.make(usage: usage, reportsContextWindow: false)?.summaryText,
                       "53k / 200k (27%)")
        await adapter.close(handle)
        collector.cancel()
    }

    func testYHPProductRoutePreservesACPControlsPermissionsAndLifecycle() async throws {
        let directTransport = FakeACPTransport(exposesConfig: true)
        let routedTransport = FakeACPTransport(exposesConfig: true)
        let executable = URL(filePath: "/tmp/fake-yhp-acp")
        let direct = ACPAdapter(
            kind: .openCode,
            executableURL: executable,
            transport: directTransport
        )
        let routed = YHPProviderCompatibilityAdapter(
            adapter: ACPAdapter(
                kind: .openCode,
                executableURL: executable,
                transport: routedTransport
            ),
            manifest: HarnessProtocolCompatibilityManifest.acp(.openCode)
        )
        let localSessionID = UUID()
        let request = CreateHarnessSessionRequest(
            localSessionID: localSessionID,
            workspaceURL: URL(filePath: "/tmp/acp-yhp-product"),
            initialPrompt: nil
        )
        let directHandle = try await direct.createSession(request)
        let routedHandle = try await routed.createSession(request)
        XCTAssertEqual(routedHandle, directHandle)

        let directCapabilities = try await direct.providerCapabilities(for: directHandle)
        let routedCapabilities = try await routed.providerCapabilities(for: routedHandle)
        XCTAssertEqual(routedCapabilities, directCapabilities)
        let directUpdated = try await direct.setProviderOption(
            id: "mode",
            value: "code",
            in: directHandle
        )
        let routedUpdated = try await routed.setProviderOption(
            id: "mode",
            value: "code",
            in: routedHandle
        )
        XCTAssertEqual(routedUpdated, directUpdated)

        let directRecorder = ACPEventRecorder()
        let routedRecorder = ACPEventRecorder()
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
        try await waitUntil {
            let directPending = await directTransport.pendingPromptCount
            let routedPending = await routedTransport.pendingPromptCount
            return directPending == 1 && routedPending == 1
        }
        let assistant = acpUpdate(
            providerSessionID: directHandle.providerSessionID,
            update: .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("same")])
            ])
        )
        let permission = acpPermissionRequest(providerSessionID: directHandle.providerSessionID)
        await directTransport.emit(assistant)
        await routedTransport.emit(assistant)
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
            to: "acp-permission-permission-rpc-yhp",
            selectedActionID: "allow-always",
            in: directHandle
        )
        try await routed.respond(
            to: "acp-permission-permission-rpc-yhp",
            selectedActionID: "allow-always",
            in: routedHandle
        )
        let directSent = await directTransport.sentMessages
        let routedSent = await routedTransport.sentMessages
        XCTAssertTrue(directSent.contains {
            $0["result"]?["outcome"]?["optionId"]?.stringValue == "allow-always"
        })
        XCTAssertTrue(routedSent.contains {
            $0["result"]?["outcome"]?["optionId"]?.stringValue == "allow-always"
        })

        await directTransport.completePrompt()
        await routedTransport.completePrompt()
        try await waitUntil {
            let directEvents = await directRecorder.events
            let routedEvents = await routedRecorder.events
            return directEvents.contains { $0.payload == .turnCompleted }
                && routedEvents.contains { $0.payload == .turnCompleted }
        }
        let directEvents = await directRecorder.events
        let routedEvents = await routedRecorder.events
        XCTAssertEqual(routedEvents.map(\.payload), directEvents.map(\.payload))
        XCTAssertEqual(
            routedEvents.map { $0.rawProviderEvent != nil },
            directEvents.map { $0.rawProviderEvent != nil }
        )
        XCTAssertEqual(routedEvents.map(\.sequence), Array(0..<UInt64(routedEvents.count)))

        try await direct.send("cancel", to: directHandle)
        try await routed.send("cancel", to: routedHandle)
        try await waitUntil {
            let directPending = await directTransport.pendingPromptCount
            let routedPending = await routedTransport.pendingPromptCount
            return directPending == 1 && routedPending == 1
        }
        try await direct.interrupt(directHandle)
        try await routed.interrupt(routedHandle)
        await directTransport.completePrompt()
        await routedTransport.completePrompt()
        try await waitUntil {
            let directEvents = await directRecorder.events
            let routedEvents = await routedRecorder.events
            return directEvents.filter { $0.payload == .turnCompleted }.count == 2
                && routedEvents.filter { $0.payload == .turnCompleted }.count == 2
        }
        let directFinalPayloads = await directRecorder.events.map(\.payload)
        let routedFinalPayloads = await routedRecorder.events.map(\.payload)
        XCTAssertEqual(routedFinalPayloads, directFinalPayloads)

        await direct.close(directHandle)
        await routed.close(routedHandle)
        directCollector.cancel()
        routedCollector.cancel()
    }

    private func acpUpdate(providerSessionID: String, update: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/update"),
            "params": .object([
                "sessionId": .string(providerSessionID),
                "update": update
            ])
        ])
    }

    private func acpPermissionRequest(providerSessionID: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": .string("permission-rpc-yhp"),
            "method": .string("session/request_permission"),
            "params": .object([
                "sessionId": .string(providerSessionID),
                "toolCall": .object([
                    "toolCallId": .string("tool-yhp"),
                    "title": .string("Run command"),
                    "kind": .string("execute"),
                    "rawInput": .object(["command": .string("git status")])
                ]),
                "options": .array([
                    permissionOption("allow-once", "Allow once", "allow_once"),
                    permissionOption("allow-always", "Allow always", "allow_always"),
                    permissionOption("reject-once", "Reject once", "reject_once"),
                    permissionOption("reject-always", "Reject always", "reject_always")
                ])
            ])
        ])
    }

    private func permissionOption(_ id: String, _ name: String, _ kind: String) -> JSONValue {
        .object([
            "optionId": .string(id),
            "name": .string(name),
            "kind": .string(kind)
        ])
    }
}

private actor ACPPayloadRecorder {
    private(set) var payloads: [HarnessEventPayload] = []
    func append(_ payload: HarnessEventPayload) { payloads.append(payload) }
}

private actor ACPEventRecorder {
    private(set) var events: [HarnessEventEnvelope] = []
    func append(_ event: HarnessEventEnvelope) { events.append(event) }
}

actor FakeACPTransport: ACPTransport {
    private let stream: AsyncStream<ACPRawFrame>
    private let continuation: AsyncStream<ACPRawFrame>.Continuation
    private var promptContinuations: [CheckedContinuation<JSONValue, Error>] = []
    private let protocolVersion: Int64
    private let exposesConfig: Bool
    private let exposesGrokModels: Bool
    private let canLoadSession: Bool
    private let advertisesImagePrompts: Bool
    /// Answers as `agy acp` does: a model and thinking level in `configOptions` and the model
    /// variants in `models.availableModels`.
    private let exposesAntigravity: Bool
    private var antigravityModel = "gemini-3.8-flash"
    private var antigravityEffort = "high"
    private(set) var configuration: ACPLaunchConfiguration?
    private(set) var requestMethods: [String] = []
    private(set) var requestValues: [JSONValue] = []
    private(set) var requestMethodsWithoutTimeout: [String] = []
    private(set) var sentMessages: [JSONValue] = []
    private(set) var stopCount = 0

    init(
        protocolVersion: Int64 = 1,
        exposesConfig: Bool = false,
        exposesGrokModels: Bool = false,
        canLoadSession: Bool = true,
        advertisesImagePrompts: Bool = false,
        exposesAntigravity: Bool = false
    ) {
        let pair = AsyncStream<ACPRawFrame>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        self.protocolVersion = protocolVersion
        self.exposesConfig = exposesConfig
        self.exposesGrokModels = exposesGrokModels
        self.canLoadSession = canLoadSession
        self.advertisesImagePrompts = advertisesImagePrompts
        self.exposesAntigravity = exposesAntigravity
    }

    var pendingPromptCount: Int { promptContinuations.count }

    func start(_ configuration: ACPLaunchConfiguration) async throws {
        self.configuration = configuration
    }

    func request(_ value: JSONValue, id: Int64) async throws -> JSONValue {
        let method = value["method"]?.stringValue ?? "unknown"
        requestMethods.append(method)
        requestValues.append(value)
        switch method {
        case "initialize":
            return .object([
                "protocolVersion": .integer(protocolVersion),
                "agentCapabilities": .object([
                    "loadSession": .bool(canLoadSession),
                    "promptCapabilities": .object(["image": .bool(advertisesImagePrompts)])
                ])
            ])
        case "session/new":
            var result: [String: JSONValue] = ["sessionId": .string("acp-session-1")]
            if exposesConfig { result["configOptions"] = configOptions(current: "ask") }
            if exposesGrokModels { result["models"] = grokModels(current: "grok-4.6") }
            if exposesAntigravity { result.merge(antigravitySession()) { _, new in new } }
            return .object(result)
        case "session/set_config_option" where exposesAntigravity:
            let configValue = value["params"]?["value"]?.stringValue ?? ""
            if value["params"]?["configId"]?.stringValue == "model" { antigravityModel = configValue }
            if value["params"]?["configId"]?.stringValue == "thought_level" { antigravityEffort = configValue }
            return .object(["configOptions": antigravityConfigOptions()])
        case "session/set_config_option":
            return .object(["configOptions": configOptions(current: value["params"]?["value"]?.stringValue ?? "ask")])
        case "session/set_model":
            return .object(["_meta": .object(["model": .string(
                value["params"]?["modelId"]?.stringValue ?? "grok-4.6"
            )])])
        case "session/load":
            return exposesAntigravity ? .object(antigravitySession()) : .object([:])
        case "session/prompt":
            return try await withCheckedThrowingContinuation { continuation in
                promptContinuations.append(continuation)
            }
        default:
            return .object([:])
        }
    }

    func requestWithoutTimeout(_ value: JSONValue, id: Int64) async throws -> JSONValue {
        requestMethodsWithoutTimeout.append(value["method"]?.stringValue ?? "unknown")
        return try await request(value, id: id)
    }

    private func configOptions(current: String) -> JSONValue {
        .array([.object([
            "id": .string("mode"), "name": .string("Mode"), "type": .string("select"),
            "currentValue": .string(current),
            "options": .array([
                .object(["value": .string("ask"), "name": .string("Ask")]),
                .object(["value": .string("code"), "name": .string("Code")])
            ])
        ])])
    }

    private func antigravitySession() -> [String: JSONValue] {
        let variant = { (effort: String) -> JSONValue in
            .object(["modelId": .string("gemini-3.8-flash-\(effort)"),
                     "name": .string("Gemini 3.8 Flash (\(effort.capitalized))")])
        }
        return [
            "configOptions": antigravityConfigOptions(),
            "models": .object(["currentModelId": .string("gemini-3.8-flash-high"),
                               "availableModels": .array(["high", "medium", "low"].map(variant))])
        ]
    }

    private func antigravityConfigOptions() -> JSONValue {
        .array([
            .object(["id": .string("model"), "name": .string("Model"), "category": .string("model"),
                     "type": .string("select"), "currentValue": .string(antigravityModel),
                     "options": .array([.object(["value": .string("gemini-3.8-flash"), "name": .string("Gemini 3.8 Flash")])])]),
            .object(["id": .string("thought_level"), "name": .string("Thinking Level"), "category": .string("thought_level"),
                     "type": .string("select"), "currentValue": .string(antigravityEffort),
                     "options": .array(["low", "medium", "high"].map {
                         .object(["value": .string($0), "name": .string($0.capitalized)])
                     })])
        ])
    }

    private func grokModels(current: String) -> JSONValue {
        .object([
            "currentModelId": .string(current),
            "availableModels": .array([
                grokModel("grok-4.6", efforts: ["xhigh", "high", "low"]),
                grokModel("grok-4.5", efforts: ["high", "low"])
            ])
        ])
    }

    private func grokModel(_ id: String, efforts: [String]) -> JSONValue {
        .object([
            "modelId": .string(id),
            "name": .string(id == "grok-4.6" ? "Grok 4.6" : "Grok 4.5"),
            "_meta": .object([
                "supportsReasoningEffort": .bool(true),
                "reasoningEffort": .string("high"),
                "reasoningEfforts": .array(efforts.map { effort in
                    .object([
                        "id": .string(effort),
                        "value": .string(effort),
                        "label": .string(effort.capitalized),
                        "default": .bool(effort == "high")
                    ])
                })
            ])
        ])
    }

    func send(_ value: JSONValue) async throws { sentMessages.append(value) }
    func messages() async -> AsyncStream<ACPRawFrame> { stream }
    func stop() async {
        stopCount += 1
        continuation.finish()
    }

    func emit(_ value: JSONValue) {
        let data = (try? ACPWireCodec().encodeLine(value)) ?? Data()
        continuation.yield(ACPRawFrame(value: value, data: data))
    }

    func completePrompt() {
        guard !promptContinuations.isEmpty else { return }
        promptContinuations.removeFirst().resume(
            returning: .object(["stopReason": .string("end_turn")])
        )
    }
}
