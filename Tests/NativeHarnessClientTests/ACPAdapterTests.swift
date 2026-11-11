import Foundation
import os
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
            transportFactory: { FakeACPTransport(advertisesImagePrompts: true) }
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

    /// A copy `agy` wrote stays while its process runs, goes once the process has ended, and is gone
    /// before the next process starts; `mcp/yardlet/` stays.
    func testAnEndedProcessTakesItsSchemaCopiesBeforeTheNextOneStarts() async throws {
        let mcp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: mcp) }
        let copy = mcp.appending(path: "yardlet_963b6c4b", directoryHint: .isDirectory)
        let first = mcp.appending(path: "yardlet", directoryHint: .isDirectory)
        for folder in [copy, first] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: folder.appending(path: "list_tasks.json"))
        }
        let table = FakeProcessTable()
        let own = ProcessInfo.processInfo.processIdentifier
        table.set(own, parent: 1, name: "Yardlet")
        table.set(own &+ 1, parent: 1, start: Int64((Date().timeIntervalSince1970 - 60) * 1_000_000), name: "agy")
        let adapter = ACPAdapter(
            kind: .antigravityCLI,
            executableURL: URL(filePath: "/tmp/agy"),
            schemaCopies: AntigravitySchemaCopies(directory: mcp, table: table, executableNames: ["agy"]),
            transportFactory: transportSequence(FakeACPTransport(onStop: { table.remove(own &+ 1) }), FakeACPTransport())
        )
        func newSession() async throws -> HarnessSessionHandle {
            try await adapter.createSession(CreateHarnessSessionRequest(
                localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/acp-workspace"), initialPrompt: nil))
        }
        func exists(_ folder: URL) -> Bool {
            FileManager.default.fileExists(atPath: folder.path(percentEncoded: false))
        }

        let session = try await newSession()
        XCTAssertEqual(AntigravitySchemaCopies(directory: mcp, table: table, executableNames: ["agy"]).removeUnused(), [])
        await adapter.close(session)
        _ = try await newSession()
        XCTAssertFalse(exists(copy))
        XCTAssertTrue(exists(first))
    }

    /// A failed `initialize` stops its process and leaves the adapter able to try again: the
    /// registry keeps the adapter, so the next attempt starts a process of its own. A process that
    /// ends on its own, killed mid-turn, ends every session it served, the turn with an error, and
    /// the next session or prompt starts a new process at once.
    func testAFailedOrEndedProcessIsReplacedByTheNextSessionsOwn() async throws {
        let transport = FakeACPTransport(protocolVersion: 2)
        let next = FakeACPTransport()
        let third = FakeACPTransport()
        let adapter = ACPAdapter(
            kind: .grokBuild,
            executableURL: URL(filePath: "/tmp/fake-grok"),
            transportFactory: transportSequence(transport, next, third)
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

        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/acp-workspace"),
                initialPrompt: nil
            )
        )
        XCTAssertEqual(handle.providerSessionID, "acp-session-1")
        let methods = await next.requestMethods
        XCTAssertEqual(methods, ["initialize", "session/new"])

        let idle = try await adapter.resumeSession(
            providerSessionID: "existing-session",
            localSessionID: UUID(),
            workspaceURL: URL(filePath: "/tmp/acp-workspace")
        )
        let running = ACPPayloadRecorder()
        let waiting = ACPPayloadRecorder()
        let collectors = [(handle, running), (idle, waiting)].map { session, recorder in
            Task {
                for await event in await adapter.events(for: session) {
                    await recorder.append(event.payload)
                }
                await recorder.end()
            }
        }
        defer { collectors.forEach { $0.cancel() } }
        try await adapter.send("hello", to: handle)
        try await waitUntil { await next.pendingPromptCount == 1 }
        await next.exit()
        try await waitUntil {
            let ran = await running.ended
            let waited = await waiting.ended
            return ran && waited
        }
        let runningPayloads = await running.payloads
        XCTAssertEqual(Array(runningPayloads.suffix(2)), [
            .error(message: L10n.format("Connection to %@ ended.", HarnessKind.grokBuild.displayName), recoverable: true),
            .sessionStatusChanged(.failed)
        ])
        XCTAssertEqual(runningPayloads.filter { if case .error = $0 { true } else { false } }.count, 1)
        let waitingPayloads = await waiting.payloads
        XCTAssertFalse(waitingPayloads.contains { if case .error = $0 { true } else { false } },
                       "A session with no turn running ends without an error")
        do {
            try await adapter.send("after", to: handle)
            XCTFail("A session ends with its process")
        } catch let error as HarnessAdapterError {
            XCTAssertEqual(error, .invalidProviderEvent(L10n.string("ACP session is not attached")))
        }

        // A new task starts a new process at once, and closing the ended sessions leaves it alone.
        let fresh = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/acp-workspace"),
                initialPrompt: nil
            )
        )
        await adapter.close(handle)
        let nextStops = await next.stopCount
        let thirdStops = await third.stopCount
        XCTAssertEqual(nextStops, 1)
        XCTAssertEqual(thirdStops, 0)
        // The waiting task's next prompt loads its conversation on the new process.
        let resumed = try await adapter.resumeSession(
            providerSessionID: idle.providerSessionID,
            localSessionID: idle.localSessionID,
            workspaceURL: URL(filePath: "/tmp/acp-workspace")
        )
        try await adapter.send("again", to: resumed)
        try await waitUntil { await third.pendingPromptCount == 1 }
        let thirdMethods = await third.requestMethods
        XCTAssertEqual(thirdMethods, ["initialize", "session/new", "session/load", "session/prompt"])
        await third.completePrompt()
        await adapter.close(fresh)
        await adapter.close(resumed)
        let thirdStopsAfterClose = await third.stopCount
        XCTAssertEqual(thirdStopsAfterClose, 1)
    }

    func testResumeFailsClosedWhenRuntimeDoesNotAdvertiseSessionLoading() async throws {
        let transport = FakeACPTransport(canLoadSession: false)
        let adapter = ACPAdapter(
            kind: .kimiCode,
            executableURL: URL(filePath: "/tmp/fake-kimi"),
            transportFactory: { transport }
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

    /// A turn Yardlet's quit cut off continues with the Claude app's words as the next prompt, on the
    /// session as it is (`RestartResumePolicy`): once, not while a prompt runs, and again after it ends.
    func testAContinuationAfterARestartIsAPromptOfTheClaudeAppsWordsWhileNoPromptRuns() async throws {
        let transport = FakeACPTransport()
        let adapter = ACPAdapter(kind: .openCode, executableURL: URL(filePath: "/tmp/fake-opencode"),
                                 transportFactory: { transport })
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/acp-workspace"), initialPrompt: nil))
        let started = try await adapter.continueInterruptedTurn(in: handle, after: .quit)
        XCTAssertTrue(started)
        let startedAgain = try await adapter.continueInterruptedTurn(in: handle, after: .quit)
        XCTAssertFalse(startedAgain, "A prompt is running")
        try await waitUntil { await transport.pendingPromptCount == 1 }
        var prompts = await transport.requestValues.filter { $0["method"]?.stringValue == "session/prompt" }
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts.first?["params"]?["sessionId"]?.stringValue, handle.providerSessionID)
        XCTAssertEqual(prompts.first?["params"]?["prompt"]?.arrayValue?.map { $0["text"]?.stringValue },
                       [RestartContinuation.claudeText])
        await transport.completePrompt()
        try await waitUntil { await transport.pendingPromptCount == 0 }
        try await waitUntil { try await adapter.continueInterruptedTurn(in: handle, after: .quit) }
        try await waitUntil { await transport.pendingPromptCount == 1 }
        prompts = await transport.requestValues.filter { $0["method"]?.stringValue == "session/prompt" }
        XCTAssertEqual(prompts.count, 2)
        await adapter.close(handle)
    }

    func testCreateStreamPermissionInterruptAndResumeUseSharedACPContract() async throws {
        let transport = FakeACPTransport()
        let next = FakeACPTransport()
        let adapter = ACPAdapter(
            kind: .hermes,
            executableURL: URL(filePath: "/tmp/fake-hermes"),
            launchArguments: ["acp"],
            transportFactory: transportSequence(transport, next)
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
        // A request for a session no task holds is answered too, so the agent does not wait on it.
        await transport.emit(.object([
            "jsonrpc": .string("2.0"),
            "id": .string("permission-rpc-orphan"),
            "method": .string("session/request_permission"),
            "params": .object([
                "sessionId": .string("acp-session-closed"),
                "toolCall": .object(["toolCallId": .string("tool-2"), "title": .string("Run command")]),
                "options": .array([
                    .object(["optionId": .string("allow-once"), "name": .string("Allow once"), "kind": .string("allow_once")])
                ])
            ])
        ]))
        try await waitUntil {
            await transport.sentMessages.contains { $0["id"]?.stringValue == "permission-rpc-orphan" }
        }
        let orphanAnswer = await transport.sentMessages.first { $0["id"]?.stringValue == "permission-rpc-orphan" }
        XCTAssertEqual(orphanAnswer?["result"]?["outcome"]?["outcome"]?.stringValue, "cancelled")

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
        collector.cancel()
        let stopCount = await transport.stopCount
        XCTAssertEqual(stopCount, 1)

        // Closing the last session ended its process, and the registry keeps the adapter: the next
        // session starts a new process and reads that one's updates.
        let resumed = try await adapter.resumeSession(
            providerSessionID: "existing-session",
            localSessionID: UUID(),
            workspaceURL: URL(filePath: "/tmp/acp-workspace")
        )
        XCTAssertEqual(resumed.providerSessionID, "existing-session")
        let restarted = await next.configuration
        XCTAssertEqual(restarted?.arguments, ["acp"])
        let resumedRecorder = ACPPayloadRecorder()
        let resumedCollector = Task {
            for await event in await adapter.events(for: resumed) {
                await resumedRecorder.append(event.payload)
            }
        }
        try await adapter.send("again", to: resumed)
        try await waitUntil { await next.pendingPromptCount == 1 }
        await next.emit(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/update"),
            "params": .object([
                "sessionId": .string(resumed.providerSessionID),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string("back")])
                ])
            ])
        ]))
        await next.completePrompt()
        try await waitUntil { await resumedRecorder.payloads.contains(.turnCompleted) }
        let resumedPayloads = await resumedRecorder.payloads
        XCTAssertTrue(resumedPayloads.contains(.assistantDelta("back")))
        await adapter.close(resumed)
        resumedCollector.cancel()
    }

    func testSessionConfigOptionRoundTripsThroughAdapter() async throws {
        let transport = FakeACPTransport(exposesConfig: true)
        let adapter = ACPAdapter(kind: .openCode, executableURL: URL(filePath: "/tmp/opencode"), transportFactory: { transport })
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

    /// Antigravity over ACP keeps the option names its print mode saved, and its permission mode is the
    /// one menu for approvals: the CLI's own session modes (Default, Accept edits, Auto), set in the
    /// session as they are chosen, and Plan, where Yardlet answers no. Bypass permissions runs the
    /// session on `agy acp --dangerously-skip-permissions`, which approves for itself even in the turns
    /// the agent starts between prompts: the conversation is loaded there with the task's model and
    /// effort, and closed on the process it leaves, between prompts.
    func testAntigravityKeepsItsOptionNamesAndAnswersApprovalsByItsPermissionMode() async throws {
        let transport = FakeACPTransport(exposesAntigravity: true)
        let bypassing = FakeACPTransport(exposesAntigravity: true)
        let restarted = FakeACPTransport(exposesAntigravity: true)
        let savedInBypass = FakeACPTransport(exposesAntigravity: true)
        let savedAccepting = FakeACPTransport(exposesAntigravity: true)
        let adapter = ACPAdapter(kind: .antigravityCLI, executableURL: URL(filePath: "/tmp/agy"), launchArguments: ["acp"],
                                 transportFactory: transportSequence(transport, bypassing, restarted, savedInBypass,
                                                                     savedAccepting))
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
        // The CLI's own `plan` is a way of working, not of approving, and is not offered.
        XCTAssertEqual(initial.selectors.last?.choices.map(\.value),
                       ["default", "accept-edits", "auto", AntigravityPermissionMode.bypass])
        let models = await adapter.advertisedModels(for: localID)
        XCTAssertEqual(models?.map(\.value), ["gemini-3.8-flash"])
        XCTAssertEqual(models?.first?.effortLevels, ["low", "medium", "high"])

        // A variant saved in print mode is its model with that effort.
        let chosen = try await adapter.setProviderOption(id: "model", value: "gemini-3.8-flash-low", in: handle)
        let sentOptions = await transport.requestValues.filter { $0["method"]?.stringValue == "session/set_config_option" }
        XCTAssertEqual(sentOptions.compactMap { $0["params"]?["configId"]?.stringValue }, ["model", "thought_level"])
        XCTAssertEqual(chosen.selectors.first { $0.id == StructuredHeadlessOptionID.reasoningEffort }?.currentValue, "low")
        // Print mode's own choices, a default and the CLI's own session mode, kept by a task that chose it
        // before the permission menu was the only one, change nothing; a model it does not offer is said.
        for (id, value) in [(StructuredHeadlessOptionID.reasoningEffort, "default"), (StructuredHeadlessOptionID.agent, "x"),
                            ("mode", "plan")] {
            _ = try await adapter.setProviderOption(id: id, value: value, in: handle)
        }
        let requestCount = await transport.requestMethods.count
        XCTAssertEqual(requestCount, 4)
        do {
            _ = try await adapter.setProviderOption(id: "model", value: "claude-sonnet-4-6", in: handle)
            XCTFail("A model the session does not offer was accepted")
        } catch HarnessAdapterError.capabilityUnavailable {}

        let recorder = ACPPayloadRecorder()
        let collector = Task { for await event in await adapter.events(for: handle) { await recorder.append(event.payload) } }
        func ask(_ rpcID: String, on transport: FakeACPTransport) async {
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
        func answer(_ rpcID: String, on transport: FakeACPTransport) async -> String? {
            await transport.sentMessages.first { $0["id"]?.stringValue == rpcID }?["result"]?["outcome"]?["optionId"]?.stringValue
        }
        func configSent(_ transport: FakeACPTransport) async -> [String] {
            let values = await transport.requestValues
            return values.filter { $0["method"]?.stringValue == "session/set_config_option" }.map {
                "\($0["params"]?["configId"]?.stringValue ?? "")=\($0["params"]?["value"]?.stringValue ?? "")"
            }
        }

        // Accept edits is the session's own mode, set at once on the process it is on.
        let accepting = try await adapter.setProviderOption(id: AntigravityPermissionMode.optionID,
                                                            value: AntigravityPermissionMode.acceptEdits, in: handle)
        XCTAssertEqual(accepting.selectors.last?.currentValue, AntigravityPermissionMode.acceptEdits)
        let acceptSent = await configSent(transport)
        XCTAssertEqual(acceptSent.last, "mode=accept-edits")

        // Bypass permissions moves the idle session to a process that approves for itself, on the
        // default mode.
        let bypass = try await adapter.setProviderOption(id: AntigravityPermissionMode.optionID,
                                                         value: AntigravityPermissionMode.bypass, in: handle)
        XCTAssertEqual(bypass.selectors.first { $0.id == StructuredHeadlessOptionID.reasoningEffort }?.currentValue, "low")
        let bypassArguments = await bypassing.configuration?.arguments
        XCTAssertEqual(bypassArguments, ["acp", "--dangerously-skip-permissions"])
        let bypassMethods = await bypassing.requestMethods
        XCTAssertEqual(bypassMethods, ["initialize", "session/load", "session/set_config_option"])
        let restored = await configSent(bypassing)
        XCTAssertEqual(restored, ["thought_level=low"])
        let left = await transport.requestMethods.last
        let leftStops = await transport.stopCount
        XCTAssertEqual(left, "session/close")
        XCTAssertEqual(leftStops, 1, "A process no session uses ends")
        await ask("bypass-1", on: bypassing)
        try await waitUntil { await answer("bypass-1", on: bypassing) != nil }
        let bypassAnswer = await answer("bypass-1", on: bypassing)
        XCTAssertEqual(bypassAnswer, "allow-once")

        // A mode chosen while a prompt runs moves the session once the prompt ends, before its turn does.
        try await adapter.send("Go on", to: handle)
        try await waitUntil { await bypassing.pendingPromptCount == 1 }
        _ = try await adapter.setProviderOption(id: AntigravityPermissionMode.optionID, value: AntigravityPermissionMode.plan, in: handle)
        let startedEarly = await restarted.configuration
        XCTAssertNil(startedEarly)
        await bypassing.completePrompt()
        try await waitUntil { await recorder.payloads.contains(.turnCompleted) }
        let planArguments = await restarted.configuration?.arguments
        XCTAssertEqual(planArguments, ["acp"])
        let planMethods = await restarted.requestMethods
        XCTAssertEqual(planMethods, ["initialize", "session/load", "session/set_config_option"])
        let bypassStops = await bypassing.stopCount
        XCTAssertEqual(bypassStops, 1)
        await ask("plan-1", on: restarted)
        try await waitUntil { await answer("plan-1", on: restarted) != nil }
        let planAnswer = await answer("plan-1", on: restarted)
        XCTAssertEqual(planAnswer, "reject-once")

        // Plan and Default share a process.
        _ = try await adapter.setProviderOption(id: AntigravityPermissionMode.optionID, value: AntigravityPermissionMode.standard, in: handle)
        let afterDefault = await restarted.requestMethods
        XCTAssertEqual(afterDefault, planMethods)
        await ask("ask-1", on: restarted)
        try await waitUntil {
            await recorder.payloads.contains { if case .permissionRequested = $0 { return true }; return false }
        }
        let payloads = await recorder.payloads
        XCTAssertEqual(payloads.filter { if case .permissionRequested = $0 { return true }; return false }.count, 1)
        let askAnswer = await answer("ask-1", on: restarted)
        XCTAssertNil(askAnswer)
        // Auto is set in the session on the same process; what the CLI still asks is shown as before.
        let auto = try await adapter.setProviderOption(id: AntigravityPermissionMode.optionID,
                                                       value: AntigravityPermissionMode.auto, in: handle)
        XCTAssertEqual(auto.selectors.last?.currentValue, AntigravityPermissionMode.auto)
        let autoSent = await configSent(restarted)
        XCTAssertEqual(autoSent.last, "mode=auto")
        collector.cancel()
        await adapter.close(handle)

        // A task saved in Bypass permissions starts there.
        let saved = UUID()
        await adapter.setLaunchOptions([AntigravityPermissionMode.optionID: AntigravityPermissionMode.bypass], for: saved)
        let savedHandle = try await adapter.resumeSession(providerSessionID: "saved-conversation", localSessionID: saved,
                                                          workspaceURL: URL(filePath: "/tmp/project"))
        let savedArguments = await savedInBypass.configuration?.arguments
        XCTAssertEqual(savedArguments, ["acp", "--dangerously-skip-permissions"])
        await adapter.close(savedHandle)

        // A task that kept Accept edits sets it in the session as it attaches, and only while the
        // session is on another mode.
        let keptAccepting = UUID()
        await adapter.setLaunchOptions([AntigravityPermissionMode.optionID: AntigravityPermissionMode.acceptEdits],
                                       for: keptAccepting)
        let keptHandle = try await adapter.resumeSession(providerSessionID: "accepting-conversation",
                                                         localSessionID: keptAccepting, workspaceURL: URL(filePath: "/tmp/project"))
        for _ in 0..<2 {
            _ = try await adapter.setProviderOption(id: AntigravityPermissionMode.optionID,
                                                    value: AntigravityPermissionMode.acceptEdits, in: keptHandle)
        }
        let keptSent = await configSent(savedAccepting)
        XCTAssertEqual(keptSent, ["mode=accept-edits"])
        await adapter.close(keptHandle)
    }


    func testGrokSeparatesWorkMessagesFromFinalAnswerAndRoutesLiveControls() async throws {
        let transport = FakeACPTransport(exposesGrokModels: true)
        let adapter = ACPAdapter(
            kind: .grokBuild,
            executableURL: URL(filePath: "/tmp/fake-grok"),
            transportFactory: { transport }
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
                transportFactory: { transport }
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
                                 transportFactory: { transport })
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

    /// `session/load` replays the conversation, and what of it reaches the adapter after the load's
    /// answer is history the task already shows: no turn of the task until it sends the next prompt.
    func testReplayedHistoryAfterALoadIsNotATurn() async throws {
        let transport = FakeACPTransport()
        let adapter = ACPAdapter(kind: .kimiCode, executableURL: URL(filePath: "/tmp/fake-kimi"),
                                 launchArguments: ["acp"], transportFactory: { transport })
        let handle = try await adapter.resumeSession(providerSessionID: "saved", localSessionID: UUID(),
                                                     workspaceURL: URL(filePath: "/tmp/acp-workspace"))
        let recorder = ACPPayloadRecorder()
        let events = await adapter.events(for: handle)
        let collector = Task { for await event in events { await recorder.append(event.payload) } }
        defer { collector.cancel() }
        func update(_ fields: [String: JSONValue]) -> JSONValue {
            .object(["jsonrpc": .string("2.0"), "method": .string("session/update"),
                     "params": .object(["sessionId": .string("saved"), "update": .object(fields)])])
        }
        func answer(_ text: String) -> JSONValue {
            update(["sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string(text)])])
        }
        await transport.emit(answer("Earlier answer"))
        await transport.emit(update(["sessionUpdate": .string("tool_call"), "toolCallId": .string("earlier-tool"),
                                     "title": .string("Earlier tool"), "status": .string("completed")]))
        // The session's state still arrives: frames are taken in order, so the replay came before it.
        await transport.emit(update(["sessionUpdate": .string("usage_update"), "used": .integer(1), "size": .integer(10)]))
        try await waitUntil { await recorder.payloads.contains { if case .usageUpdated = $0 { true } else { false } } }

        try await adapter.send("Next", to: handle)
        try await waitUntil { await transport.requestMethods.contains("session/prompt") }
        await transport.emit(answer("New answer"))
        await transport.completePrompt()
        try await waitUntil { await recorder.payloads.contains(.turnCompleted) }
        let payloads = await recorder.payloads
        XCTAssertFalse(payloads.contains(.assistantDelta("Earlier answer")))
        XCTAssertFalse(payloads.contains { if case .activityCompleted = $0 { true } else { false } })
        XCTAssertTrue(payloads.contains(.assistantDelta("New answer")))
        await adapter.close(handle)
    }

    func testYHPProductRoutePreservesACPControlsPermissionsAndLifecycle() async throws {
        let directTransport = FakeACPTransport(exposesConfig: true)
        let routedTransport = FakeACPTransport(exposesConfig: true)
        let executable = URL(filePath: "/tmp/fake-yhp-acp")
        let direct = ACPAdapter(
            kind: .openCode,
            executableURL: executable,
            transportFactory: { directTransport }
        )
        let routed = YHPProviderCompatibilityAdapter(
            adapter: ACPAdapter(
                kind: .openCode,
                executableURL: executable,
                transportFactory: { routedTransport }
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

    /// Gives the adapter `transports` in order, one for each process it starts, then fresh ones.
    private func transportSequence(_ transports: FakeACPTransport...) -> @Sendable () -> any ACPTransport {
        let queue = OSAllocatedUnfairLock(initialState: transports)
        return { queue.withLock { $0.isEmpty ? FakeACPTransport() : $0.removeFirst() } }
    }

    /// `agy acp` streams a conversation only while a prompt runs. When a subagent finished after the
    /// prompt's answer, the CLI woke the agent with a system message and it answered with no client
    /// hearing of it, and sent that answer ahead of the next prompt's own steps. Those are the real
    /// session's records and order, with other words. On the route the app ships, the agent's turn
    /// runs, answers and ends from the log with nothing sent, and the repeat shows nothing twice.
    func testAntigravityTurnTheAgentStartsBetweenPromptsIsShownFromItsLogAndNotAgainOnTheNextPrompt() async throws {
        let log = try AntigravityLogFixture()
        defer { log.remove() }
        let transport = FakeACPTransport(exposesAntigravity: true)
        let adapter = YHPProviderCompatibilityAdapter(
            adapter: log.adapter(transport: transport),
            manifest: HarnessProtocolCompatibilityManifest.acp(.antigravityCLI)
        )
        let handle = try await adapter.createSession(log.sessionRequest)
        let recorder = ACPPayloadRecorder()
        let collector = Task { for await event in await adapter.events(for: handle) { await recorder.append(event.payload) } }
        defer { collector.cancel() }
        func ready() async -> Int { await recorder.payloads.filter { $0 == .sessionStatusChanged(.ready) }.count }
        try await waitUntil { await ready() == 1 }

        try await adapter.send("Make an image", to: handle)
        try await waitUntil { await transport.pendingPromptCount == 1 }
        try log.append(.response(158, tools: ["invoke_subagent"]), .tool(159), .response(160, answer: "A subagent is on it."))
        await transport.emit(log.answer("A subagent is on it."))
        try await waitUntil { await recorder.payloads.contains(.assistantDelta("A subagent is on it.")) }
        await transport.completePrompt()
        try await waitUntil { await ready() == 2 }

        // Nothing is the agent's own until it wakes, and a late line of the turn that ended is not.
        try log.append(.tool(161))
        try await Task.sleep(for: .milliseconds(100))
        let beforeWake = await recorder.payloads
        XCTAssertEqual(beforeWake.last, .sessionStatusChanged(.ready))

        try log.append(.systemMessage(162))
        try await waitUntil { await recorder.payloads.last == .sessionStatusChanged(.running) }
        try log.append(.response(163, answer: "The image is ready."))
        try await waitUntil { await ready() == 3 }
        let afterWake = await recorder.payloads.dropFirst(beforeWake.count)
        XCTAssertEqual(Array(afterWake), [.sessionStatusChanged(.running), .assistantMessageCompleted("The image is ready."),
                                          .turnCompleted, .sessionStatusChanged(.ready)])
        let prompts = await transport.requestMethodsWithoutTimeout
        XCTAssertEqual(prompts, ["session/prompt"])

        try await adapter.send("Still working?", to: handle)
        try await waitUntil { await transport.pendingPromptCount == 1 }
        await transport.emit(log.answer("The image is ready."))
        await transport.emit(log.answer("No, it is done."))
        try await waitUntil { await recorder.payloads.contains(.assistantDelta("No, it is done.")) }
        await transport.completePrompt()
        try await waitUntil { await ready() == 4 }
        let payloads = await recorder.payloads
        XCTAssertFalse(payloads.contains(.assistantDelta("The image is ready.")))
        XCTAssertEqual(payloads.filter { $0 == .assistantMessageCompleted("The image is ready.") }.count, 1)
        await adapter.close(handle)
    }

    /// A prompt that arrives while the agent's own turn runs takes the conversation over: no ready in
    /// between, its stream repeats what the log showed, tool calls under IDs the log does not have,
    /// and goes on with what the log had not shown, which the log does not show as well.
    func testAPromptDuringAnAgentsOwnTurnTakesOverFromTheLog() async throws {
        let log = try AntigravityLogFixture()
        defer { log.remove() }
        let transport = FakeACPTransport(exposesAntigravity: true)
        let adapter = log.adapter(transport: transport)
        let handle = try await adapter.createSession(log.sessionRequest)
        let recorder = ACPPayloadRecorder()
        let collector = Task { for await event in await adapter.events(for: handle) { await recorder.append(event.payload) } }
        defer { collector.cancel() }
        try await adapter.send("Start", to: handle)
        try await waitUntil { await transport.pendingPromptCount == 1 }
        await transport.completePrompt()
        try await waitUntil { await recorder.payloads.contains(.turnCompleted) }

        try log.append(.systemMessage(10), .response(11, thinking: "Reading it.", tools: ["read_file"]), .tool(12))
        try await waitUntil { await recorder.payloads.contains(.reasoningCompleted("Reading it.")) }
        let shown = await recorder.payloads.count
        let toolCalls = await recorder.payloads.filter { if case .activityCompleted = $0 { true } else { false } }.count
        XCTAssertEqual(toolCalls, 1)

        try await adapter.send("And now?", to: handle)
        try await waitUntil { await transport.pendingPromptCount == 1 }
        try log.append(.response(13, answer: "Not from the log."))
        await transport.emit(log.update(["sessionUpdate": .string("agent_thought_chunk"),
                                         "content": .object(["type": .string("text"), "text": .string("Reading it.")])]))
        await transport.emit(log.update(["sessionUpdate": .string("tool_call"), "toolCallId": .string("call_1"),
                                         "kind": .string("read"), "title": .string("File")]))
        await transport.emit(log.update(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("call_1"),
                                         "status": .string("completed")]))
        await transport.emit(log.answer("Not from the log."))
        try await waitUntil { await recorder.payloads.contains(.assistantDelta("Not from the log.")) }
        await transport.completePrompt()
        try await waitUntil { await recorder.payloads.last == .sessionStatusChanged(.ready) }
        let payloads = await recorder.payloads.dropFirst(shown)
        XCTAssertEqual(Array(payloads), [.sessionStatusChanged(.running), .assistantDelta("Not from the log."),
                                         .assistantMessageCompleted("Not from the log."), .turnCompleted,
                                         .sessionStatusChanged(.ready)])
        await adapter.close(handle)
    }

    /// Stopping the agent's own turn cancels it as any turn, with no prompt to answer for it, and a
    /// turn that adds nothing to the log for too long leaves the task ready, not stuck behind a step
    /// no client can answer between prompts. One stopped on a tool call with no result ends, with a
    /// row saying a step may wait for approval and no failure, unless its process approves for itself.
    func testAnAgentsOwnTurnEndsWhenStoppedOrWhenItsLogGoesQuiet() async throws {
        let log = try AntigravityLogFixture()
        defer { log.remove() }
        let transport = FakeACPTransport(exposesAntigravity: true)
        let adapter = log.adapter(transport: transport)
        let handle = try await adapter.createSession(log.sessionRequest)
        let recorder = ACPPayloadRecorder()
        let collector = Task { for await event in await adapter.events(for: handle) { await recorder.append(event.payload) } }
        defer { collector.cancel() }
        try await adapter.send("Start", to: handle)
        try await waitUntil { await transport.pendingPromptCount == 1 }
        await transport.completePrompt()
        try await waitUntil { await recorder.payloads.contains(.turnCompleted) }
        try log.append(.systemMessage(10))
        try await waitUntil { await recorder.payloads.last == .sessionStatusChanged(.running) }
        try await adapter.interrupt(handle)
        let cancels = await transport.sentMessages.filter { $0["method"]?.stringValue == "session/cancel" }.count
        XCTAssertEqual(cancels, 1)
        try await waitUntil { await recorder.payloads.last == .sessionStatusChanged(.ready) }
        await adapter.close(handle)

        var follower = AntigravityAgentTurnFollower(store: log.store, conversationID: log.conversationID,
                                                    quietLimit: .seconds(60))
        try log.append(.systemMessage(20), .response(21, tools: ["run_command"]))
        let start = ContinuousClock.now
        XCTAssertEqual(follower.read(at: start), [.sessionStatusChanged(.running), .activityCompleted(HarnessActivity(
            id: "\(log.conversationID)-21-0", kind: "run_command", title: "run command"))])
        XCTAssertEqual(follower.read(at: start + .seconds(59)), [])
        XCTAssertEqual(follower.read(at: start + .seconds(60)), [
            .activityCompleted(HarnessActivity(
                id: "\(log.conversationID)-21-waiting", kind: "wait", title: L10n.string("Waiting for approval or still running"),
                detail: "run command", outcome: .stopped, output: AntigravityAgentTurnFollower.waitingStepNotice)),
            .turnCompleted, .sessionStatusChanged(.ready)
        ])
        XCTAssertEqual(follower.read(at: start + .seconds(120)), [])
        // The step ran after all: the turn goes on, and a quiet one whose calls all have results only
        // leaves the task ready.
        try log.append(.tool(22), .response(23, tools: ["read_file"]), .tool(24))
        XCTAssertEqual(follower.read(at: start + .seconds(130)).first, .sessionStatusChanged(.running))
        XCTAssertEqual(follower.read(at: start + .seconds(190)), [.sessionStatusChanged(.ready)])

        var approving = AntigravityAgentTurnFollower(store: log.store, conversationID: log.conversationID,
                                                     quietLimit: .seconds(60), stepsWaitForApproval: false)
        try log.append(.systemMessage(30), .response(31, tools: ["run_command"]))
        _ = approving.read(at: start)
        XCTAssertEqual(approving.read(at: start + .seconds(60)), [.sessionStatusChanged(.ready)])
    }

    private func permissionOption(_ id: String, _ name: String, _ kind: String) -> JSONValue {
        .object([
            "optionId": .string(id),
            "name": .string(name),
            "kind": .string(kind)
        ])
    }
}

/// A conversation's log in a folder of its own, written as `agy` writes it, line by line.
private struct AntigravityLogFixture {
    enum Record {
        case response(Int, thinking: String? = nil, tools: [String] = [], answer: String? = nil)
        case tool(Int)
        case systemMessage(Int)

        var json: JSONValue {
            switch self {
            case let .response(step, thinking, tools, answer):
                var record = Self.record(step, source: "MODEL", type: "PLANNER_RESPONSE")
                if let thinking { record["thinking"] = .string(thinking) }
                if !tools.isEmpty {
                    record["tool_calls"] = .array(tools.map { .object(["name": .string($0), "args": .object([:])]) })
                }
                if let answer { record["content"] = .string(answer) }
                return .object(record)
            case let .tool(step):
                return .object(Self.record(step, source: "MODEL", type: "GENERIC"))
            case let .systemMessage(step):
                var record = Self.record(step, source: "SYSTEM", type: "SYSTEM_MESSAGE")
                record["content"] = .string("<SYSTEM_MESSAGE>\n[Message] content=Done.\n</SYSTEM_MESSAGE>")
                return .object(record)
            }
        }

        private static func record(_ step: Int, source: String, type: String) -> [String: JSONValue] {
            ["step_index": .integer(Int64(step)), "source": .string(source), "type": .string(type),
             "status": .string("DONE"), "created_at": .string("2026-11-07T13:33:14Z")]
        }
    }

    let root = FileManager.default.temporaryDirectory
        .appending(path: "nhc-agy-log-\(UUID().uuidString)", directoryHint: .isDirectory)
    let conversationID = "acp-session-1"
    private let logURL: URL

    init() throws {
        let logs = root.appending(path: "brain/\(conversationID)/.system_generated/logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        logURL = logs.appending(path: "transcript_full.jsonl")
        try Data().write(to: logURL)
    }

    var store: AntigravityConversationStore { AntigravityConversationStore(root: root) }

    var sessionRequest: CreateHarnessSessionRequest {
        CreateHarnessSessionRequest(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/project"), initialPrompt: nil)
    }

    func adapter(transport: FakeACPTransport) -> ACPAdapter {
        ACPAdapter(kind: .antigravityCLI, executableURL: URL(filePath: "/tmp/agy"), launchArguments: ["acp"],
                   conversationStore: store, agentTurnReadInterval: .milliseconds(5), transportFactory: { transport })
    }

    func append(_ records: Record...) throws {
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for record in records {
            try handle.write(contentsOf: JSONEncoder().encode(record.json) + Data([0x0A]))
        }
    }

    func update(_ update: [String: JSONValue]) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "method": .string("session/update"),
                 "params": .object(["sessionId": .string(conversationID), "update": .object(update)])])
    }

    func answer(_ text: String) -> JSONValue {
        update(["sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string(text)])])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor ACPPayloadRecorder {
    private(set) var payloads: [HarnessEventPayload] = []
    private(set) var ended = false
    func append(_ payload: HarnessEventPayload) { payloads.append(payload) }
    func end() { ended = true }
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
    /// Answers as `agy acp` 1.5.5 does: a model, thinking level and session mode in
    /// `configOptions`, the model variants in `models.availableModels` and the modes in `modes`. A
    /// session it loads starts on the default mode.
    private let exposesAntigravity: Bool
    /// Runs while the transport stops, as a process's end changes what the process table shows.
    private let onStop: (@Sendable () -> Void)?
    private var antigravityModel = "gemini-3.8-flash"
    private var antigravityEffort = "high"
    private var antigravityMode = "default"
    private(set) var configuration: ACPLaunchConfiguration?
    private(set) var requestMethods: [String] = []
    private(set) var requestValues: [JSONValue] = []
    private(set) var requestMethodsWithoutTimeout: [String] = []
    private(set) var sentMessages: [JSONValue] = []
    private(set) var stopCount = 0
    private var exited = false

    init(
        protocolVersion: Int64 = 1,
        exposesConfig: Bool = false,
        exposesGrokModels: Bool = false,
        canLoadSession: Bool = true,
        advertisesImagePrompts: Bool = false,
        exposesAntigravity: Bool = false,
        onStop: (@Sendable () -> Void)? = nil
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
        self.onStop = onStop
    }

    var pendingPromptCount: Int { promptContinuations.count }

    func start(_ configuration: ACPLaunchConfiguration) async throws {
        // Single-use, as `ACPProcessTransport` is.
        guard stopCount == 0 else {
            throw HarnessAdapterError.processExited(code: -1, message: "ACP transport cannot restart after being stopped")
        }
        self.configuration = configuration
    }

    func request(_ value: JSONValue, id: Int64) async throws -> JSONValue {
        let method = value["method"]?.stringValue ?? "unknown"
        guard !exited else { throw HarnessAdapterError.processExited(code: -1, message: "ACP agent is not running") }
        requestMethods.append(method)
        requestValues.append(value)
        switch method {
        case "initialize":
            var capabilities: [String: JSONValue] = [
                "loadSession": .bool(canLoadSession),
                "promptCapabilities": .object(["image": .bool(advertisesImagePrompts)])
            ]
            if exposesAntigravity { capabilities["sessionCapabilities"] = .object(["close": .object([:])]) }
            return .object([
                "protocolVersion": .integer(protocolVersion),
                "agentCapabilities": .object(capabilities)
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
            if value["params"]?["configId"]?.stringValue == "mode" { antigravityMode = configValue }
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
                               "availableModels": .array(["high", "medium", "low"].map(variant))]),
            "modes": .object(["currentModeId": .string(antigravityMode), "availableModes": .array(antigravityModes.map {
                .object(["id": .string($0), "name": .string($0)])
            })])
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
                     })]),
            .object(["id": .string("mode"), "name": .string("Mode"), "category": .string("mode"),
                     "type": .string("select"), "currentValue": .string(antigravityMode),
                     "options": .array(antigravityModes.map { .object(["value": .string($0), "name": .string($0)]) })])
        ])
    }

    private let antigravityModes = ["default", "accept-edits", "auto", "plan"]

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

    func send(_ value: JSONValue) async throws {
        guard !exited else { throw HarnessAdapterError.processExited(code: -1, message: "ACP agent is not running") }
        sentMessages.append(value)
    }
    func messages() async -> AsyncStream<ACPRawFrame> { stream }
    func stop() async {
        stopCount += 1
        onStop?()
        continuation.finish()
    }

    /// Ends as `ACPProcessTransport` does when its process is killed: the requests waiting on it
    /// fail, its messages end, and later requests find it not running.
    func exit() {
        exited = true
        let prompts = promptContinuations
        promptContinuations.removeAll()
        for prompt in prompts {
            prompt.resume(throwing: HarnessAdapterError.processExited(code: SIGKILL, message: ""))
        }
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
