import Foundation
import os
import XCTest
@testable import NativeHarnessClient

final class MuseAdapterTests: XCTestCase {
    func testRecordedLifecycleStreamsApprovalsInterruptsAndResumesTruthfully() async throws {
        let transport = FakeMuseTransport()
        let adapter = MuseAdapter(
            executableURL: URL(filePath: "/tmp/fake-muse"),
            transport: transport
        )
        let localID = UUID()
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: localID,
                workspaceURL: URL(filePath: "/home/me/src/proj"),
                initialPrompt: nil
            )
        )
        XCTAssertEqual(handle.providerSessionID, Self.sessionID)
        let configuration = await transport.configuration
        XCTAssertEqual(configuration?.arguments, ["serve"])
        let sentAfterHandshake = await transport.sentMessages
        XCTAssertTrue(sentAfterHandshake.contains { $0["method"]?.stringValue == "initialized" })

        let recorder = MusePayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }

        try await adapter.send("Run the agent test suite and summarize failures", to: handle)
        await transport.emit(Self.turnStartedFrame())
        await transport.emit(Self.agentStartedFrame())
        await transport.emit(Self.agentDeltaFrame())
        await transport.emit(Self.agentCompletedFrame())
        await transport.emit(Self.toolStartedFrame())
        await transport.emit(try decode(MuseProtocolTests.recordedApprovalRequest))
        try await waitUntil {
            await recorder.payloads.contains { payload in
                if case .permissionRequested = payload { return true }
                return false
            }
        }

        try await adapter.respond(
            to: Self.approvalID,
            selectedActionID: "allow_session",
            in: handle
        )
        await transport.emit(Self.toolCompletedFrame())
        await transport.emit(Self.turnCompletedFrame())
        try await waitUntil { await recorder.payloads.contains(.turnCompleted) }

        let payloads = await recorder.payloads
        XCTAssertTrue(payloads.contains(.assistantDelta("All 214 tests pass")))
        XCTAssertTrue(payloads.contains(
            .assistantMessageCompleted("All 214 tests pass and no failures were found.")
        ))
        XCTAssertTrue(payloads.contains { payload in
            if case let .activityStarted(activity) = payload {
                return activity.id == Self.toolItemID && activity.kind == "toolCall"
            }
            return false
        })
        XCTAssertTrue(payloads.contains { payload in
            if case let .activityCompleted(activity) = payload {
                return activity.id == Self.toolItemID && activity.detail == "Cargo.toml updated\n"
            }
            return false
        })
        XCTAssertTrue(payloads.contains(.sessionStatusChanged(.waitingForApproval)))

        let sent = await transport.sentMessages
        XCTAssertTrue(sent.contains { message in
            message["id"]?.integerValue == 1 && message["result"] == .object([:])
        })
        let requests = await transport.requests
        let approvalDecision = try XCTUnwrap(
            requests.last(where: { $0["method"]?.stringValue == "approval/decide" })
        )
        XCTAssertEqual(approvalDecision["params"]?["choiceId"]?.stringValue, "allow_session")
        XCTAssertEqual(
            approvalDecision["params"]?["requirementId"]?["sourceIndex"]?.integerValue,
            0
        )

        try await waitUntil {
            await recorder.payloads.filter { $0 == .sessionStatusChanged(.ready) }.count >= 2
        }
        try await adapter.send("Keep running until stopped", to: handle)
        try await adapter.interrupt(handle)
        let afterInterrupt = await transport.requests
        let interrupt = try XCTUnwrap(
            afterInterrupt.last(where: { $0["method"]?.stringValue == "turn/interrupt" })
        )
        XCTAssertEqual(interrupt["params"]?["turnId"]?.stringValue, Self.turnID)
        let preTerminalPayloads = await recorder.payloads
        let readyCountBeforeTerminal = preTerminalPayloads.filter {
            $0 == .sessionStatusChanged(.ready)
        }.count
        try await Task.sleep(for: .milliseconds(20))
        let readyCountAfterInterruptAck = await recorder.payloads.filter {
            $0 == .sessionStatusChanged(.ready)
        }.count
        XCTAssertEqual(readyCountAfterInterruptAck, readyCountBeforeTerminal)
        await transport.emit(Self.turnCancelledFrame())
        try await waitUntil {
            // Require a new ready event from cancellation, independent of later event ordering.
            await recorder.payloads.filter { $0 == .sessionStatusChanged(.ready) }.count > readyCountAfterInterruptAck
        }

        await adapter.close(handle)
        collector.cancel()

        let resumeTransport = FakeMuseTransport(resumeRunning: true)
        let resumedAdapter = MuseAdapter(
            executableURL: URL(filePath: "/tmp/fake-muse"),
            transport: resumeTransport
        )
        let resumed = try await resumedAdapter.resumeSession(
            providerSessionID: Self.sessionID,
            localSessionID: UUID(),
            workspaceURL: URL(filePath: "/home/me/src/proj")
        )
        XCTAssertEqual(resumed.providerSessionID, Self.sessionID)
        let resumeRequests = await resumeTransport.requests
        let resumeRequest = try XCTUnwrap(resumeRequests.last(where: {
            $0["method"]?.stringValue == "session/resume"
        }))
        XCTAssertEqual(resumeRequest["params"]?["sessionId"]?.stringValue, Self.sessionID)
        await resumedAdapter.close(resumed)
    }

    func testFailedTurnUsesServerTerminalReasonAndRetryability() async throws {
        let transport = FakeMuseTransport()
        let adapter = MuseAdapter(
            executableURL: URL(filePath: "/tmp/fake-muse"),
            transport: transport
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/home/me/src/proj"),
                initialPrompt: nil
            )
        )
        let recorder = MusePayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }
        try await adapter.send("summarize the failing tests", to: handle)
        await transport.emit(Self.failedTurnFrame())
        try await waitUntil { await recorder.payloads.contains(.sessionStatusChanged(.failed)) }
        let payloads = await recorder.payloads
        XCTAssertTrue(payloads.contains(
            .error(
                message: "model failed after 3 attempts: provider returned 503 service_unavailable",
                recoverable: true
            )
        ))
        XCTAssertFalse(payloads.contains(.turnCompleted))
        let running = try XCTUnwrap(payloads.firstIndex(of: .sessionStatusChanged(.running)))
        XCTAssertFalse(payloads[running...].contains(.sessionStatusChanged(.ready)))
        await adapter.close(handle)
        collector.cancel()
    }

    func testUnknownTerminalStateFailsTurnWithoutCompletingIt() async throws {
        let transport = FakeMuseTransport()
        let adapter = MuseAdapter(
            executableURL: URL(filePath: "/tmp/fake-muse"),
            transport: transport
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/home/me/src/proj"),
                initialPrompt: nil
            )
        )
        let recorder = MusePayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }
        defer { collector.cancel() }

        try await adapter.send("run", to: handle)
        await transport.emit(Self.notification("turn/completed", [
            "sessionId": .string(Self.sessionID),
            "viewCursor": .string("v:\(Self.sessionID):10"),
            "turnId": .string(Self.turnID),
            "terminal": .string("timedOut")
        ]))
        try await waitUntil { await recorder.payloads.contains(.sessionStatusChanged(.failed)) }

        let payloads = await recorder.payloads
        XCTAssertTrue(payloads.contains(
            .error(message: "Muse turn ended with terminal state timedOut", recoverable: true)
        ))
        XCTAssertFalse(payloads.contains(.turnCompleted))
        let running = try XCTUnwrap(payloads.firstIndex(of: .sessionStatusChanged(.running)))
        XCTAssertFalse(payloads[running...].contains(.sessionStatusChanged(.ready)))
        await adapter.close(handle)
    }

    func testEndedTransportFailsActiveTurnFinishesStreamsAndReplacesDeadHost() async throws {
        let first = FakeMuseTransport()
        let second = FakeMuseTransport()
        let third = FakeMuseTransport()
        let queue = OSAllocatedUnfairLock(initialState: [first, second, third])
        let adapter = MuseAdapter(
            executableURL: URL(filePath: "/tmp/fake-muse"),
            transportFactory: { queue.withLock { $0.removeFirst() } }
        )

        // Active turn crashes mid-flight: emits error + failed, finishes event stream, detaches handle.
        let active = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: URL(filePath: "/home/me/src/proj"),
            initialPrompt: nil
        ))
        let activeRecorder = MusePayloadRecorder()
        let activeCollector = Task {
            for await event in await adapter.events(for: active) {
                await activeRecorder.append(event.payload)
            }
            await activeRecorder.end()
        }
        defer { activeCollector.cancel() }

        try await adapter.send("crash mid-turn", to: active)
        await first.exit()
        try await waitUntil { await activeRecorder.ended }

        let activePayloads = await activeRecorder.payloads
        XCTAssertEqual(Array(activePayloads.suffix(2)), [
            .error(message: L10n.format("Connection to %@ ended.", HarnessKind.museCode.displayName), recoverable: true),
            .sessionStatusChanged(.failed)
        ])
        XCTAssertFalse(activePayloads.contains(.turnCompleted))
        do {
            try await adapter.send("after crash", to: active)
            XCTFail("Expected ended session to reject further prompts")
        } catch let error as HarnessAdapterError {
            XCTAssertEqual(error, .invalidProviderEvent("Muse session is not attached"))
        }

        // Next session spawns a fresh host, and closing the dead handle leaves the new host alone.
        let idle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: URL(filePath: "/home/me/src/proj"),
            initialPrompt: nil
        ))
        await adapter.close(active)
        let firstStops = await first.stopCount
        let secondStops = await second.stopCount
        XCTAssertEqual(firstStops, 1)
        XCTAssertEqual(secondStops, 0)

        // An idle session whose host exits ends cleanly without an error.
        let idleRecorder = MusePayloadRecorder()
        let idleCollector = Task {
            for await event in await adapter.events(for: idle) {
                await idleRecorder.append(event.payload)
            }
            await idleRecorder.end()
        }
        defer { idleCollector.cancel() }

        await second.exit()
        try await waitUntil { await idleRecorder.ended }
        let idlePayloads = await idleRecorder.payloads
        XCTAssertFalse(idlePayloads.contains { payload in
            if case .error = payload { return true }
            return payload == .sessionStatusChanged(.failed)
        })

        // Another fresh session starts on the third transport.
        let recovered = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: URL(filePath: "/home/me/src/proj"),
            initialPrompt: nil
        ))
        let thirdMethods = await third.requestMethods
        XCTAssertEqual(thirdMethods.filter { $0 != "usage/read" }, ["initialize", "session/start"])
        await adapter.close(recovered)
        let thirdStops = await third.stopCount
        XCTAssertEqual(thirdStops, 1)
    }

    /// The host a failed start stopped is not the next session's: that one starts a new host, as
    /// the session after the last closed one does.
    func testUnsupportedSchemaStopsTransportWithoutCreatingSession() async throws {
        let transport = FakeMuseTransport(schemaVersion: 2)
        let next = FakeMuseTransport()
        let unstarted = OSAllocatedUnfairLock(initialState: [transport, next])
        let adapter = MuseAdapter(
            executableURL: URL(filePath: "/tmp/fake-muse"),
            transportFactory: { unstarted.withLock { $0.removeFirst() } }
        )
        do {
            _ = try await adapter.createSession(
                CreateHarnessSessionRequest(
                    localSessionID: UUID(),
                    workspaceURL: URL(filePath: "/tmp/project"),
                    initialPrompt: nil
                )
            )
            XCTFail("Expected unsupported MSP version to fail")
        } catch let error as HarnessAdapterError {
            XCTAssertEqual(error, .unsupportedRuntime(version: "MSP 2"))
        }
        let requestMethods = await transport.requestMethods
        let stopCount = await transport.stopCount
        XCTAssertEqual(requestMethods, ["initialize"])
        XCTAssertEqual(stopCount, 1)

        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/project"),
                                        initialPrompt: nil))
        XCTAssertEqual(handle.providerSessionID, Self.sessionID)
        let nextMethods = await next.requestMethods
        XCTAssertEqual(nextMethods.filter { $0 != "usage/read" }, ["initialize", "session/start"])
        await adapter.close(handle)
    }

    func testFailedInitialPromptClosesRegisteredSessionAndTransport() async throws {
        let transport = FakeMuseTransport(failTurnStart: true)
        let adapter = MuseAdapter(
            executableURL: URL(filePath: "/tmp/fake-muse"),
            transport: transport
        )
        do {
            _ = try await adapter.createSession(
                CreateHarnessSessionRequest(
                    localSessionID: UUID(),
                    workspaceURL: URL(filePath: "/tmp/project"),
                    initialPrompt: "start immediately"
                )
            )
            XCTFail("Expected the initial MSP turn to fail")
        } catch let error as HarnessAdapterError {
            XCTAssertEqual(
                error,
                .processExited(code: 1, message: "fixture turn/start failure")
            )
        }
        let stopCount = await transport.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testReasoningSummaryPartsStreamIntoOneThoughtThatMatchesTheCompletedItem() async throws {
        let transport = FakeMuseTransport()
        let adapter = MuseAdapter(
            executableURL: URL(filePath: "/tmp/fake-muse"),
            transport: transport
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/home/me/src/proj"),
                initialPrompt: nil
            )
        )
        let recorder = MusePayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }

        try await adapter.send("Why does the parser test fail?", to: handle)
        await transport.emit(Self.turnStartedFrame())
        await transport.emit(Self.reasoningStartedFrame())
        // MSP v1 streams a reasoning summary on `summary.<n>`, never on `text`.
        await transport.emit(Self.reasoningDeltaFrame(field: "summary.0", "Reading the parser"))
        await transport.emit(Self.reasoningDeltaFrame(field: "summary.0", " test output."))
        await transport.emit(Self.reasoningDeltaFrame(field: "summary.1", "The fixture lost a newline."))
        await transport.emit(Self.reasoningCompletedFrame(summary: [
            "Reading the parser test output.",
            "The fixture lost a newline."
        ]))
        await transport.emit(Self.agentStartedFrame())
        await transport.emit(Self.agentDeltaFrame())
        await transport.emit(Self.agentCompletedFrame())
        await transport.emit(Self.turnCompletedFrame())
        try await waitUntil { await recorder.payloads.contains(.turnCompleted) }

        let payloads = await recorder.payloads
        let thought = "Reading the parser test output.\n\nThe fixture lost a newline."
        XCTAssertEqual(
            payloads.filter {
                if case .reasoningDelta = $0 { return true }
                if case .reasoningCompleted = $0 { return true }
                return false
            },
            [
                .reasoningDelta("Reading the parser"),
                .reasoningDelta(" test output."),
                .reasoningDelta("\n\nThe fixture lost a newline."),
                .reasoningCompleted(thought)
            ]
        )
        // The thought is neither answer text nor an activity card.
        XCTAssertFalse(payloads.contains(.assistantDelta("Reading the parser")))
        XCTAssertFalse(payloads.contains { payload in
            if case let .activityStarted(activity) = payload { return activity.kind == "reasoning" }
            if case let .activityCompleted(activity) = payload { return activity.kind == "reasoning" }
            return false
        })

        var transcript = TranscriptBuilder()
        payloads.forEach { transcript.apply($0) }
        XCTAssertTrue(transcript.entries.contains { entry in
            if case let .reasoning(text, isStreaming) = entry.content {
                return text == thought && !isStreaming
            }
            return false
        })
        await adapter.close(handle)
        collector.cancel()
    }

    func testSessionTokenAndContextUsageReachTheSessionThroughTheYHPRoute() async throws {
        let transport = FakeMuseTransport()
        let adapter = YHPProviderCompatibilityAdapter(
            adapter: MuseAdapter(
                executableURL: URL(filePath: "/tmp/fake-muse"),
                transport: transport
            ),
            manifest: HarnessProtocolCompatibilityManifest.msp(.museCode)
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/home/me/src/proj"),
                initialPrompt: nil
            )
        )
        let recorder = MusePayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }

        try await adapter.send("Summarize the diff", to: handle)
        await transport.emit(Self.turnStartedFrame())
        await transport.emit(Self.tokenUsageFrame())
        await transport.emit(Self.contextUsageFrame())
        await transport.emit(Self.turnCompletedFrame())
        try await waitUntil { await recorder.payloads.contains(.turnCompleted) }

        let usages = await recorder.payloads.compactMap { payload -> HarnessProtocolUsage? in
            guard case let .usageUpdated(usage) = payload else { return nil }
            return usage
        }
        XCTAssertEqual(usages.count, 2)
        // The session's counted-once totals, not the single call's raw counters.
        XCTAssertEqual(usages.first?.inputTokens, 5_400)
        XCTAssertEqual(usages.first?.outputTokens, 610)
        XCTAssertNil(usages.first?.cachedInputTokens)
        XCTAssertNil(usages.first?.reasoningTokens)
        XCTAssertNil(usages.first?.totalCostUSD)
        XCTAssertEqual(
            ConversationSessionStatusProjection.totalUsageTokens(usages.first),
            6_010
        )
        XCTAssertEqual(usages.last?.contextUsedTokens, 6_010)
        XCTAssertEqual(usages.last?.contextWindowTokens, 262_144)
        XCTAssertNil(usages.last?.inputTokens)

        await adapter.close(handle)
        collector.cancel()
    }

    func testComposerImageReachesMuseAsAnImagePartThroughTheYHPRoute() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "nhc-muse-image-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appending(path: "pixel.png")
        try XCTUnwrap(Data(base64Encoded: Self.onePixelPNG)).write(to: imageURL)

        let transport = FakeMuseTransport()
        let adapter = YHPProviderCompatibilityAdapter(
            adapter: MuseAdapter(
                executableURL: URL(filePath: "/tmp/fake-muse"),
                transport: transport
            ),
            manifest: HarnessProtocolCompatibilityManifest.msp(.museCode)
        )
        XCTAssertTrue(adapter.protocolManifest.supports(.images))
        XCTAssertEqual(HarnessComposerInputPolicy(harness: .museCode).imageSupport, .always)
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/home/me/src/proj"),
                initialPrompt: nil
            )
        )
        let recorder = MusePayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }

        try await adapter.send(
            HarnessUserInput(
                text: "Describe the attached image.",
                images: [HarnessUserInput.ImageAttachment(url: imageURL, mimeType: "image/png")]
            ),
            to: handle
        )
        let imageRequests = await transport.requests
        let imageTurn = try XCTUnwrap(imageRequests.last(where: {
            $0["method"]?.stringValue == "turn/start"
        }))
        XCTAssertEqual(
            imageTurn["params"]?["input"],
            .array([
                .object([
                    "type": .string("text"),
                    "text": .string("Describe the attached image.")
                ]),
                .object([
                    "type": .string("image"),
                    "base64Data": .string(Self.onePixelPNG),
                    "mediaType": .string("image/png")
                ])
            ])
        )

        // Muse 1.4.0 echoes the submission as a `userMessage` carrying attachment metadata only;
        // Yardlet already shows the user's own bubble, so it is neither text nor a card.
        await transport.emit(Self.turnStartedFrame())
        await transport.emit(try decode(Self.recordedImageUserMessage))
        await transport.emit(Self.turnCompletedFrame())
        try await waitUntil { await recorder.payloads.contains(.turnCompleted) }
        let payloads = await recorder.payloads
        XCTAssertFalse(payloads.contains { payload in
            switch payload {
            case .activityStarted, .activityUpdated, .activityCompleted,
                 .assistantDelta, .assistantMessageCompleted:
                return true
            default:
                return false
            }
        })

        // A text-only turn is the single text part it always was.
        try await waitUntil {
            await recorder.payloads.filter { $0 == .sessionStatusChanged(.ready) }.count >= 2
        }
        try await adapter.send("hello", to: handle)
        let textRequests = await transport.requests
        let textTurn = try XCTUnwrap(textRequests.last(where: {
            $0["method"]?.stringValue == "turn/start"
        }))
        XCTAssertEqual(
            textTurn["params"]?["input"],
            .array([.object(["type": .string("text"), "text": .string("hello")])])
        )

        await adapter.close(handle)
        collector.cancel()
    }

    func testStableMSPSettingsRoundTripAndReasoningAppliesToNextTurn() async throws {
        let transport = FakeMuseTransport()
        let adapter = MuseAdapter(
            executableURL: URL(filePath: "/tmp/fake-muse"),
            transport: transport
        )
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: URL(filePath: "/home/me/src/proj"),
            initialPrompt: nil
        ))

        let capabilities = try await adapter.providerCapabilities(for: handle)
        XCTAssertEqual(
            Set(capabilities.selectors.map(\.id)),
            ["model", "approvalMode", "reasoningEffort"]
        )
        XCTAssertEqual(capabilities.actions.map(\.id), [ProviderCapabilityActionID.compact])
        XCTAssertEqual(
            capabilities.selectors.first(where: { $0.id == "model" })?.choices.count,
            3
        )
        let modelValue = try XCTUnwrap(
            capabilities.selectors.first(where: { $0.id == "model" })?.choices
                .first(where: { $0.name == "Muse Large 3" })?.value
        )

        _ = try await adapter.setProviderOption(
            id: "model", value: modelValue, in: handle
        )
        _ = try await adapter.setProviderOption(
            id: "approvalMode", value: "denyUnmatched", in: handle
        )
        _ = try await adapter.setProviderOption(
            id: "reasoningEffort", value: "xhigh", in: handle
        )
        _ = try await adapter.performProviderAction(
            id: ProviderCapabilityActionID.compact,
            in: handle
        )
        try await adapter.send("Use the selected settings", to: handle)

        let requests = await transport.requests
        XCTAssertTrue(requests.contains {
            $0["method"]?.stringValue == "session/setModel"
                && $0["params"]?["model"]?["modelId"]?.stringValue == "muse-large-3"
                && $0["params"]?["model"]?["providerId"]?.stringValue == "meta"
        })
        XCTAssertTrue(requests.contains {
            $0["method"]?.stringValue == "session/setApprovalMode"
                && $0["params"]?["mode"]?.stringValue == "denyUnmatched"
        })
        XCTAssertTrue(requests.contains { $0["method"]?.stringValue == "session/compact" })
        let turn = try XCTUnwrap(requests.last(where: {
            $0["method"]?.stringValue == "turn/start"
        }))
        XCTAssertEqual(turn["params"]?["reasoningEffort"]?.stringValue, "xhigh")
        await adapter.close(handle)
    }

    /// Muse 1.4.0 lists each model's selectable reasoning tiers, in order, as its `model/list`
    /// row's `variants`. The effort selector offers the current model's own tiers, and a tier
    /// chosen under another model reaches a turn only while the current model offers it. A row
    /// that answers `unknown`, or a host that sends no `variants`, keeps the fixed list.
    func testReasoningEffortChoicesAreTheCurrentModelsCatalogVariants() async throws {
        func efforts(_ tiers: [String]) -> JSONValue { .array(tiers.map(JSONValue.string)) }
        let variants: [String: JSONValue] = [
            "Muse Large 2": efforts(["low", "medium", "high", "max"]),
            "Muse Large 3": efforts(["high", "xhigh", "max", "ultra"]),
            "Partner Muse Large 3": .string("unknown")
        ]
        let fixedList = ["default", "none", "minimal", "low", "medium", "high", "xhigh", "ultra"]
        func effort(in state: ProviderCapabilityState) -> ProviderCapabilitySelector? {
            state.selectors.first { $0.id == "reasoningEffort" }
        }
        func model(named name: String, in state: ProviderCapabilityState) throws -> String {
            try XCTUnwrap(
                state.selectors.first { $0.id == "model" }?.choices.first { $0.name == name }?.value
            )
        }
        func lastTurn(_ transport: FakeMuseTransport) async throws -> JSONValue {
            let requests = await transport.requests
            return try XCTUnwrap(requests.last { $0["method"]?.stringValue == "turn/start" })
        }

        let transport = FakeMuseTransport(modelVariants: variants)
        let adapter = MuseAdapter(executableURL: URL(filePath: "/tmp/fake-muse"), transport: transport)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: URL(filePath: "/home/me/src/proj"),
            initialPrompt: nil
        ))
        let initial = try await adapter.providerCapabilities(for: handle)
        XCTAssertEqual(
            effort(in: initial)?.choices.map(\.value),
            ["default", "low", "medium", "high", "max"]
        )
        XCTAssertEqual(effort(in: initial)?.currentValue, "default")

        let chosen = try await adapter.setProviderOption(
            id: "reasoningEffort", value: "max", in: handle
        )
        XCTAssertEqual(effort(in: chosen)?.currentValue, "max")
        let newer = try await adapter.setProviderOption(
            id: "model", value: try model(named: "Muse Large 3", in: chosen), in: handle
        )
        XCTAssertEqual(
            effort(in: newer)?.choices.map(\.value),
            ["default", "high", "xhigh", "max", "ultra"]
        )
        XCTAssertEqual(effort(in: newer)?.currentValue, "max")
        try await adapter.send("Think hard", to: handle)
        let offered = try await lastTurn(transport)
        XCTAssertEqual(offered["params"]?["reasoningEffort"]?.stringValue, "max")
        await adapter.close(handle)

        // A model whose tiers are unknown offers the fixed list, which has no `max`, so the
        // choice stays kept for a model that offers it but no turn carries it here.
        let unknownTransport = FakeMuseTransport(modelVariants: variants)
        let unknownAdapter = MuseAdapter(
            executableURL: URL(filePath: "/tmp/fake-muse"),
            transport: unknownTransport
        )
        let unknownHandle = try await unknownAdapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: URL(filePath: "/home/me/src/proj"),
            initialPrompt: nil
        ))
        let catalog = try await unknownAdapter.setProviderOption(
            id: "reasoningEffort", value: "max", in: unknownHandle
        )
        let partner = try await unknownAdapter.setProviderOption(
            id: "model", value: try model(named: "Partner Muse Large 3", in: catalog),
            in: unknownHandle
        )
        XCTAssertEqual(effort(in: partner)?.choices.map(\.value), fixedList)
        XCTAssertEqual(effort(in: partner)?.currentValue, "default")
        try await unknownAdapter.send("Use the host default", to: unknownHandle)
        let unoffered = try await lastTurn(unknownTransport)
        XCTAssertNil(unoffered["params"]?["reasoningEffort"])
        let back = try await unknownAdapter.setProviderOption(
            id: "model", value: try model(named: "Muse Large 2", in: partner), in: unknownHandle
        )
        XCTAssertEqual(effort(in: back)?.currentValue, "max")
        await unknownAdapter.close(unknownHandle)

        // A host that sends no `variants` keeps the fixed list, and a tier outside MSP's
        // vocabulary is refused as before.
        let olderTransport = FakeMuseTransport()
        let olderAdapter = MuseAdapter(
            executableURL: URL(filePath: "/tmp/fake-muse"),
            transport: olderTransport
        )
        let olderHandle = try await olderAdapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: URL(filePath: "/home/me/src/proj"),
            initialPrompt: nil
        ))
        let older = try await olderAdapter.providerCapabilities(for: olderHandle)
        XCTAssertEqual(effort(in: older)?.choices.map(\.value), fixedList)
        do {
            _ = try await olderAdapter.setProviderOption(
                id: "reasoningEffort", value: "extreme", in: olderHandle
            )
            XCTFail("an effort outside the MSP vocabulary was accepted")
        } catch HarnessAdapterError.capabilityUnavailable {}
        await olderAdapter.close(olderHandle)
    }

    // MARK: - Subscription usage

    func testTheLiveHostsSubscriptionUsageReachesTheAccountStore() async throws {
        let transport = FakeMuseTransport()
        let observed = try decode(ProviderUsageTests.museUsageRead)
        await transport.answerUsageRead(with: observed)
        let store = MuseSubscriptionUsageStore()
        let adapter = MuseAdapter(
            executableURL: URL(filePath: "/tmp/fake-muse"),
            transport: transport,
            subscriptionUsageStore: store
        )
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/home/me/src/proj"), initialPrompt: nil
        ))
        let recorder = MusePayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) { await recorder.append(event.payload) }
        }
        defer { collector.cancel() }

        // The connection reads once it is up; the read carries no params and makes no model call.
        try await waitUntil { await store.latest(for: .museCode) != nil }
        let first = await store.latest(for: .museCode)
        XCTAssertEqual(first, MuseSubscriptionUsage(observed["usage"]))
        let read = try await lastRequest("usage/read", in: transport)
        XCTAssertNil(read["params"])
        let readsAfterStart = await transport.usageReadCount
        XCTAssertEqual(readsAfterStart, 1)

        // Each finished turn reads again, since its model calls are where the host observes usage.
        try await adapter.send("Summarize the diff", to: handle)
        await transport.emit(Self.turnStartedFrame())
        await transport.emit(Self.turnCompletedFrame())
        try await waitUntil { await transport.usageReadCount == 2 }

        // A host-wide push replaces an older observation and never a newer one.
        await transport.emit(Self.usageChangedFrame(usedPercent: 61, observedAtMs: 1_790_430_600_000))
        try await waitUntil { await store.latest(for: .museCode)?.window?.usedPercent == 61 }
        await transport.emit(Self.usageChangedFrame(usedPercent: 12, observedAtMs: 1_790_420_000_000))
        await transport.emit(Self.turnStartedFrame())
        await transport.emit(Self.turnCompletedFrame())
        try await waitUntil { await transport.usageReadCount == 3 }
        let latest = await store.latest(for: .museCode)
        XCTAssertEqual(latest?.window?.usedPercent, 61)
        await adapter.close(handle)
    }

    func testAHostThatRefusesUsageReadIsNotAskedAgainOnThatConnection() async throws {
        let transport = FakeMuseTransport()
        await transport.failUsageRead(with: HarnessAdapterError.invalidProviderEvent("Method not found"))
        let store = MuseSubscriptionUsageStore()
        let adapter = MuseAdapter(
            executableURL: URL(filePath: "/tmp/fake-muse"),
            transport: transport,
            subscriptionUsageStore: store
        )
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/home/me/src/proj"), initialPrompt: nil
        ))
        let recorder = MusePayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) { await recorder.append(event.payload) }
        }
        defer { collector.cancel() }
        try await waitUntil { await transport.usageReadCount == 1 }
        try await adapter.send("Summarize the diff", to: handle)
        await transport.emit(Self.turnStartedFrame())
        await transport.emit(Self.turnCompletedFrame())
        try await waitUntil { await recorder.payloads.contains(.turnCompleted) }
        try await Task.sleep(for: .milliseconds(50))
        let reads = await transport.usageReadCount
        XCTAssertEqual(reads, 1)
        let stored = await store.latest(for: .museCode)
        XCTAssertNil(stored)
        // The session itself is unaffected by the refused read.
        let payloads = await recorder.payloads
        XCTAssertFalse(payloads.contains {
            if case .error = $0 { return true }
            return false
        })
        await adapter.close(handle)
    }

    private static func usageChangedFrame(usedPercent: Int64, observedAtMs: Int64) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "method": .string("usage/changed"),
            "params": .object([
                "window": .object([
                    "usedPercent": .integer(usedPercent),
                    "windowDurationMins": .integer(300),
                    "resetsAtMs": .integer(1_790_440_000_000)
                ]),
                "observedAtMs": .integer(observedAtMs)
            ])
        ])
    }

    // MARK: - User input

    func testUserInputRequestIsAnsweredThroughTheQuestionCard() async throws {
        let transport = FakeMuseTransport()
        let adapter = MuseAdapter(executableURL: URL(filePath: "/tmp/fake-muse"), transport: transport)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/home/me/src/proj"), initialPrompt: nil
        ))
        let recorder = MusePayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) { await recorder.append(event.payload) }
        }
        defer { collector.cancel() }

        try await adapter.send("Pick a verification target", to: handle)
        await transport.emit(Self.turnStartedFrame())
        await transport.emit(try userInputFrame(rpcID: 7, userInputID: MuseProtocolTests.userInputID))
        let request = try await waitForPermission(MuseProtocolTests.userInputID, in: recorder)
        guard case let .questions(questions)? = request.structured else {
            return XCTFail("the prompt did not open a question card")
        }
        XCTAssertEqual(questions.map(\.question), [
            "Which verification target should run?", "Which platforms should it cover?"
        ])
        XCTAssertEqual(questions.map(\.allowsMultipleSelections), [false, true])
        // The server request only asks for a presentation receipt, sent as soon as it is shown.
        let receipts = await transport.sentMessages.filter { $0["id"] == .integer(7) }
        XCTAssertEqual(receipts, [.object([
            "jsonrpc": .string("2.0"), "id": .integer(7), "result": .object([:])
        ])])
        let waiting = await recorder.payloads
        XCTAssertTrue(waiting.contains(.sessionStatusChanged(.waitingForApproval)))

        // The host re-issues an open prompt on a new subscription; it gets a receipt, not a card.
        await transport.emit(try userInputFrame(rpcID: 8, userInputID: MuseProtocolTests.userInputID))
        try await waitUntil { await transport.sentMessages.contains { $0["id"] == .integer(8) } }
        let cards = await recorder.payloads.filter {
            if case .permissionRequested = $0 { return true }
            return false
        }
        XCTAssertEqual(cards.count, 1)

        // MSP answers every question, so an incomplete answer is refused before anything is sent.
        do {
            try await adapter.respond(
                to: MuseProtocolTests.userInputID,
                answer: .questions([PermissionQuestionAnswer(
                    question: "Which verification target should run?", selectedLabels: ["Unit tests"]
                )]),
                in: handle
            )
            XCTFail("an answer that leaves a question out was sent")
        } catch HarnessAdapterError.capabilityUnavailable {}
        let beforeAnswer = await transport.requestMethods
        XCTAssertFalse(beforeAnswer.contains("userInput/answer"))

        let runningBefore = await recorder.payloads.filter { $0 == .sessionStatusChanged(.running) }.count
        try await adapter.respond(
            to: MuseProtocolTests.userInputID,
            answer: .questions([
                PermissionQuestionAnswer(
                    question: "Which verification target should run?", selectedLabels: ["Unit tests"]
                ),
                PermissionQuestionAnswer(
                    question: "Which platforms should it cover?", selectedLabels: ["macOS", "Linux"]
                )
            ]),
            in: handle
        )
        let requests = await transport.requests
        let answer = try XCTUnwrap(requests.last { $0["method"]?.stringValue == "userInput/answer" })
        XCTAssertEqual(answer["params"]?["sessionId"]?.stringValue, Self.sessionID)
        XCTAssertEqual(answer["params"]?["userInputId"]?.stringValue, MuseProtocolTests.userInputID)
        XCTAssertNotNil(answer["params"]?["commandId"]?.stringValue)
        XCTAssertEqual(answer["params"]?["answers"], .array([
            .object(["questionId": .string("q-target"), "selectedLabel": .string("Unit tests")]),
            .object([
                "questionId": .string("q-platforms"),
                "selectedLabels": .array([.string("macOS"), .string("Linux")])
            ])
        ]))
        // A response acknowledgement does not await the separate event-stream consumer.
        try await waitUntil {
            await recorder.payloads.filter { $0 == .sessionStatusChanged(.running) }.count == runningBefore + 1
        }
        let runningAfter = await recorder.payloads.filter { $0 == .sessionStatusChanged(.running) }.count
        XCTAssertEqual(runningAfter, runningBefore + 1)

        // The prompt is settled; a second answer has nothing to settle.
        do {
            try await adapter.respond(to: MuseProtocolTests.userInputID, decision: .deny, in: handle)
            XCTFail("a settled prompt was answered again")
        } catch HarnessAdapterError.invalidProviderEvent {}
        await adapter.close(handle)
    }

    func testDeclinedSettledEndedAndClosedPromptsLeaveNothingPending() async throws {
        let transport = FakeMuseTransport()
        let adapter = MuseAdapter(executableURL: URL(filePath: "/tmp/fake-muse"), transport: transport)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/home/me/src/proj"), initialPrompt: nil
        ))
        let recorder = MusePayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) { await recorder.append(event.payload) }
        }
        defer { collector.cancel() }
        try await adapter.send("Ask before choosing", to: handle)
        await transport.emit(Self.turnStartedFrame())

        // A plain allow has no answers to send; a deny declines through `userInput/cancel`.
        await transport.emit(try userInputFrame(rpcID: 21, userInputID: "prompt-declined"))
        _ = try await waitForPermission("prompt-declined", in: recorder)
        do {
            try await adapter.respond(to: "prompt-declined", decision: .allow, in: handle)
            XCTFail("a prompt was allowed without answers")
        } catch HarnessAdapterError.capabilityUnavailable {}
        try await adapter.respond(to: "prompt-declined", decision: .deny, in: handle)
        let cancel = try await lastRequest("userInput/cancel", in: transport)
        XCTAssertEqual(cancel["params"]?["userInputId"]?.stringValue, "prompt-declined")
        XCTAssertEqual(cancel["params"]?["sessionId"]?.stringValue, Self.sessionID)
        XCTAssertEqual(cancel["params"]?["reason"]?.stringValue, "The user declined to answer.")

        // The YHP route declines with the plain deny id its fallback actions carry.
        await transport.emit(try userInputFrame(rpcID: 22, userInputID: "prompt-route-deny"))
        _ = try await waitForPermission("prompt-route-deny", in: recorder)
        try await adapter.respond(to: "prompt-route-deny", selectedActionID: "deny", in: handle)
        let routeCancel = try await lastRequest("userInput/cancel", in: transport)
        XCTAssertEqual(routeCancel["params"]?["userInputId"]?.stringValue, "prompt-route-deny")

        // A prompt settled on the host, by timeout or another client, is no longer answerable.
        await transport.emit(try userInputFrame(rpcID: 23, userInputID: "prompt-timed-out"))
        _ = try await waitForPermission("prompt-timed-out", in: recorder)
        let runningBefore = await recorder.payloads.filter { $0 == .sessionStatusChanged(.running) }.count
        await transport.emit(Self.notification("userInput/settled", [
            "sessionId": .string(Self.sessionID),
            "viewCursor": .string("v:\(Self.sessionID):14"),
            "userInputId": .string("prompt-timed-out"),
            "outcome": .string("timedOut")
        ]))
        try await waitUntil {
            await recorder.payloads.filter { $0 == .sessionStatusChanged(.running) }.count > runningBefore
        }
        await assertUnanswerable("prompt-timed-out", adapter: adapter, handle: handle)

        // A prompt belongs to its turn, so the turn's end drops it.
        await transport.emit(try userInputFrame(rpcID: 24, userInputID: "prompt-turn-ended"))
        _ = try await waitForPermission("prompt-turn-ended", in: recorder)
        await transport.emit(Self.turnCancelledFrame())
        try await waitUntil { await recorder.payloads.contains(.turnCompleted) }
        await assertUnanswerable("prompt-turn-ended", adapter: adapter, handle: handle)

        // Closing the task is not an answer: nothing is sent, and the host keeps the prompt for
        // the session's resume.
        await transport.emit(try userInputFrame(rpcID: 25, userInputID: "prompt-at-close"))
        _ = try await waitForPermission("prompt-at-close", in: recorder)
        let beforeClose = await transport.requests.count
        await adapter.close(handle)
        let afterClose = await transport.requests
        XCTAssertEqual(afterClose.count, beforeClose)
        XCTAssertFalse(afterClose.contains {
            $0["params"]?["userInputId"]?.stringValue == "prompt-at-close"
        })
    }

    func testAPromptTheCardCannotShowGetsAnErrorReceiptAndOneNotice() async throws {
        let transport = FakeMuseTransport()
        let adapter = MuseAdapter(executableURL: URL(filePath: "/tmp/fake-muse"), transport: transport)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/home/me/src/proj"), initialPrompt: nil
        ))
        let recorder = MusePayloadRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) { await recorder.append(event.payload) }
        }
        defer { collector.cancel() }
        try await adapter.send("Ask something open-ended", to: handle)
        await transport.emit(Self.turnStartedFrame())

        // A free-text question offers no options for the card to show.
        let freeText = try userInputFrame(rpcID: 31, userInputID: "prompt-free-text") { question in
            question["options"] = .array([])
        }
        await transport.emit(freeText)
        try await waitUntil { await transport.sentMessages.contains { $0["id"] == .integer(31) } }
        let sent = await transport.sentMessages
        let receipt = try XCTUnwrap(sent.first { $0["id"] == .integer(31) })
        XCTAssertNil(receipt["result"])
        XCTAssertEqual(receipt["error"]?["code"]?.integerValue, -32602)
        let notice = HarnessEventPayload.error(
            message: L10n.string(
                "Muse Code asked a question Yardlet cannot show. Stop the turn to continue."
            ),
            recoverable: true
        )
        try await waitUntil { await recorder.payloads.contains(notice) }

        // The host re-issues the pending prompt; it gets the same receipt and no second notice.
        let reissued = try userInputFrame(rpcID: 32, userInputID: "prompt-free-text") { question in
            question["options"] = .array([])
        }
        await transport.emit(reissued)
        try await waitUntil { await transport.sentMessages.contains { $0["id"] == .integer(32) } }

        // A prompt for a session this adapter does not own is refused without a notice.
        var foreign = try userInputFrame(rpcID: 33, userInputID: "prompt-foreign").objectValue ?? [:]
        var foreignParams = foreign["params"]?.objectValue ?? [:]
        foreignParams["sessionId"] = .string("0198f0aa-9999-7000-8000-0000000000ff")
        foreign["params"] = .object(foreignParams)
        await transport.emit(.object(foreign))
        try await waitUntil { await transport.sentMessages.contains { $0["id"] == .integer(33) } }

        let payloads = await recorder.payloads
        XCTAssertEqual(payloads.filter { $0 == notice }.count, 1)
        XCTAssertFalse(payloads.contains {
            if case .permissionRequested = $0 { return true }
            return false
        })
        let foreignReceipt = await transport.sentMessages.first { $0["id"] == .integer(33) }
        XCTAssertNotNil(foreignReceipt?["error"])
        await adapter.close(handle)
    }

    func testUserInputAnswerAndDeclineCrossTheYHPRoute() async throws {
        let transport = FakeMuseTransport()
        let routed = YHPProviderCompatibilityAdapter(
            adapter: MuseAdapter(executableURL: URL(filePath: "/tmp/fake-muse"), transport: transport),
            manifest: HarnessProtocolCompatibilityManifest.msp(.museCode)
        )
        let handle = try await routed.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/home/me/src/proj"), initialPrompt: nil
        ))
        let recorder = MusePayloadRecorder()
        let collector = Task {
            for await event in await routed.events(for: handle) { await recorder.append(event.payload) }
        }
        defer { collector.cancel() }
        try await routed.send("Pick a verification target", to: handle)
        await transport.emit(Self.turnStartedFrame())

        await transport.emit(try userInputFrame(rpcID: 41, userInputID: MuseProtocolTests.userInputID))
        let request = try await waitForPermission(MuseProtocolTests.userInputID, in: recorder)
        guard case let .questions(questions)? = request.structured else {
            return XCTFail("the question form did not survive the YHP route")
        }
        XCTAssertEqual(questions.count, 2)
        // The route's own allow and deny stand-ins stay off the card.
        XCTAssertEqual(request.actions, [])
        try await routed.respond(
            to: MuseProtocolTests.userInputID,
            answer: .questions([
                PermissionQuestionAnswer(
                    question: "Which verification target should run?", selectedLabels: ["Full suite"]
                ),
                PermissionQuestionAnswer(
                    question: "Which platforms should it cover?", selectedLabels: ["Linux"]
                )
            ]),
            in: handle
        )
        let answer = try await lastRequest("userInput/answer", in: transport)
        XCTAssertEqual(answer["params"]?["answers"], .array([
            .object(["questionId": .string("q-target"), "selectedLabel": .string("Full suite")]),
            .object(["questionId": .string("q-platforms"), "selectedLabels": .array([.string("Linux")])])
        ]))

        await transport.emit(try userInputFrame(rpcID: 42, userInputID: "prompt-declined"))
        _ = try await waitForPermission("prompt-declined", in: recorder)
        try await routed.respond(to: "prompt-declined", decision: .deny, in: handle)
        let cancel = try await lastRequest("userInput/cancel", in: transport)
        XCTAssertEqual(cancel["params"]?["userInputId"]?.stringValue, "prompt-declined")
        await routed.close(handle)
    }

    private func userInputFrame(
        rpcID: Int64,
        userInputID: String,
        editingFirstQuestion edit: ((inout [String: JSONValue]) -> Void)? = nil
    ) throws -> JSONValue {
        var frame = try decode(MuseProtocolTests.userInputRequest).objectValue ?? [:]
        var params = frame["params"]?.objectValue ?? [:]
        frame["id"] = .integer(rpcID)
        params["userInputId"] = .string(userInputID)
        if let edit, var questions = params["questions"]?.arrayValue,
           var first = questions.first?.objectValue {
            edit(&first)
            questions[0] = .object(first)
            params["questions"] = .array(questions)
        }
        frame["params"] = .object(params)
        return .object(frame)
    }

    private func waitForPermission(
        _ id: String,
        in recorder: MusePayloadRecorder
    ) async throws -> PermissionRequest {
        try await waitUntil {
            await recorder.payloads.contains {
                if case let .permissionRequested(request) = $0 { return request.id == id }
                return false
            }
        }
        let request = await recorder.payloads.lazy.compactMap { payload -> PermissionRequest? in
            if case let .permissionRequested(request) = payload, request.id == id { return request }
            return nil
        }.first
        return try XCTUnwrap(request)
    }

    private func lastRequest(_ method: String, in transport: FakeMuseTransport) async throws -> JSONValue {
        let requests = await transport.requests
        return try XCTUnwrap(requests.last { $0["method"]?.stringValue == method })
    }

    private func assertUnanswerable(
        _ id: String,
        adapter: MuseAdapter,
        handle: HarnessSessionHandle,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await adapter.respond(to: id, decision: .deny, in: handle)
            XCTFail("\(id) was still answerable", file: file, line: line)
        } catch {}
    }

    private func decode(_ raw: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
    }


    fileprivate static let sessionID = "0198f0aa-1111-7000-8000-0000000000aa"
    fileprivate static let turnID = "018f6a1e-9b3c-7c21-a54a-2f30bd3c9f10"
    fileprivate static let approvalID = "0198f0ac-7777-7000-8000-0000000000e1"
    fileprivate static let toolItemID = "0198f0ac-4242-7000-8000-000000000042"

    private static func notification(_ method: String, _ params: [String: JSONValue]) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": .object(params),
            "emittedAtMs": .integer(1_754_590_941_000)
        ])
    }

    private static func turnStartedFrame() -> JSONValue {
        notification("turn/started", [
            "sessionId": .string(sessionID),
            "viewCursor": .string("v:\(sessionID):4"),
            "turnId": .string(turnID),
            "commandId": .string(turnID)
        ])
    }

    private static func agentStartedFrame() -> JSONValue {
        notification("item/started", [
            "sessionId": .string(sessionID),
            "viewCursor": .string("v:\(sessionID):6"),
            "item": .object([
                "itemId": .string("0198f0ac-5151-7000-8000-000000000051"),
                "kind": .string("agentMessage"),
                "turnId": .string(turnID),
                "revision": .integer(1),
                "status": .string("inProgress"),
                "text": .string("")
            ])
        ])
    }

    private static func agentDeltaFrame() -> JSONValue {
        notification("item/delta", [
            "sessionId": .string(sessionID),
            "viewCursor": .string("v:\(sessionID):7"),
            "itemId": .string("0198f0ac-5151-7000-8000-000000000051"),
            "field": .string("text"),
            "delta": .string("All 214 tests pass")
        ])
    }

    private static func agentCompletedFrame() -> JSONValue {
        notification("item/completed", [
            "sessionId": .string(sessionID),
            "viewCursor": .string("v:\(sessionID):8"),
            "item": .object([
                "itemId": .string("0198f0ac-5151-7000-8000-000000000051"),
                "kind": .string("agentMessage"),
                "turnId": .string(turnID),
                "revision": .integer(2),
                "status": .string("completed"),
                "text": .string("All 214 tests pass and no failures were found.")
            ])
        ])
    }

    private static let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    /// Recorded from `muse serve` 1.4.0-R4161.1 after a `turn/start` with a text part and a
    /// 1×1 PNG image part (isolated home, no network). Session and turn IDs are the fixture's.
    private static let recordedImageUserMessage = #"{"jsonrpc":"2.0","method":"item/completed","params":{"sessionId":"0198f0aa-1111-7000-8000-0000000000aa","viewCursor":"v:0198f0aa-1111-7000-8000-0000000000aa:5","sourceRange":{"stream":{"kind":"session","id":"0198f0aa-1111-7000-8000-0000000000aa"},"first":{"id":"c7ba21d7-0048-44e7-be42-a678758a3950","sequence":29},"last":{"id":"c7ba21d7-0048-44e7-be42-a678758a3950","sequence":29}},"item":{"itemId":"fc2e637f-9797-4bf5-9f41-a43195bca74b","kind":"userMessage","turnId":"018f6a1e-9b3c-7c21-a54a-2f30bd3c9f10","revision":1,"status":"completed","recordedAt":"2026-09-26T12:25:55.528128Z","text":"Describe the attached image.[Image #1]","commandId":"018f6a1e-9b3c-7c21-a54a-2f30bd3c9f10","attachments":[{"type":"image","mediaType":"image/png","width":1,"height":1}]}},"emittedAtMs":1790425555540}"#

    /// Shape of `session/tokenUsage` in the MSP v1 schema exported by Muse Code 1.4.0.
    private static func tokenUsageFrame() -> JSONValue {
        notification("session/tokenUsage", [
            "sessionId": .string(sessionID),
            "viewCursor": .string("v:\(sessionID):10"),
            "turnId": .string(turnID),
            "modelId": .string("muse-large-2"),
            "usage": .object([
                "inputTokens": .integer(1_800),
                "cachedTokens": .integer(1_200),
                "outputTokens": .integer(240),
                "reasoningTokens": .integer(96)
            ]),
            "promptTokens": .integer(1_800),
            "totalTokens": .integer(2_040),
            "cumulative": .object([
                "promptTokens": .integer(5_400),
                "outputTokens": .integer(610),
                "totalTokens": .integer(6_010)
            ]),
            "durationMs": .integer(2_100)
        ])
    }

    private static func contextUsageFrame() -> JSONValue {
        notification("session/contextUsage", [
            "sessionId": .string(sessionID),
            "viewCursor": .string("v:\(sessionID):10"),
            "usedTokens": .integer(6_010),
            "windowTokens": .integer(262_144),
            "pressure": .string("normal")
        ])
    }

    private static let reasoningItemID = "0198f0ac-6161-7000-8000-000000000061"

    private static func reasoningStartedFrame() -> JSONValue {
        notification("item/started", [
            "sessionId": .string(sessionID),
            "viewCursor": .string("v:\(sessionID):5"),
            "item": .object([
                "itemId": .string(reasoningItemID),
                "kind": .string("reasoning"),
                "turnId": .string(turnID),
                "revision": .integer(1),
                "status": .string("inProgress"),
                "summary": .array([]),
                "providerItemId": .string("rs_0198f0ac")
            ])
        ])
    }

    private static func reasoningDeltaFrame(field: String, _ delta: String) -> JSONValue {
        notification("item/delta", [
            "sessionId": .string(sessionID),
            "viewCursor": .string("v:\(sessionID):5"),
            "itemId": .string(reasoningItemID),
            "field": .string(field),
            "delta": .string(delta)
        ])
    }

    private static func reasoningCompletedFrame(summary: [String]) -> JSONValue {
        notification("item/completed", [
            "sessionId": .string(sessionID),
            "viewCursor": .string("v:\(sessionID):5"),
            "item": .object([
                "itemId": .string(reasoningItemID),
                "kind": .string("reasoning"),
                "turnId": .string(turnID),
                "revision": .integer(2),
                "status": .string("completed"),
                "summary": .array(summary.map(JSONValue.string)),
                "providerItemId": .string("rs_0198f0ac")
            ])
        ])
    }

    private static func toolStartedFrame() -> JSONValue {
        notification("item/started", [
            "sessionId": .string(sessionID),
            "viewCursor": .string("v:\(sessionID):9"),
            "item": .object([
                "itemId": .string(toolItemID),
                "kind": .string("toolCall"),
                "turnId": .string(turnID),
                "revision": .integer(1),
                "status": .string("inProgress"),
                "tool": .string("write_file"),
                "callId": .string("call_9f21"),
                "args": .string(#"{"path":"Cargo.toml"}"#),
                "approvalId": .string(approvalID)
            ])
        ])
    }

    private static func toolCompletedFrame() -> JSONValue {
        notification("item/completed", [
            "sessionId": .string(sessionID),
            "viewCursor": .string("v:\(sessionID):10"),
            "item": .object([
                "itemId": .string(toolItemID),
                "kind": .string("toolCall"),
                "turnId": .string(turnID),
                "revision": .integer(2),
                "status": .string("completed"),
                "tool": .string("write_file"),
                "visibleOutput": .string("Cargo.toml updated\n")
            ])
        ])
    }

    private static func turnCompletedFrame() -> JSONValue {
        notification("turn/completed", [
            "sessionId": .string(sessionID),
            "viewCursor": .string("v:\(sessionID):11"),
            "turnId": .string(turnID),
            "terminal": .string("completed")
        ])
    }

    private static func turnCancelledFrame() -> JSONValue {
        notification("turn/completed", [
            "sessionId": .string(sessionID),
            "viewCursor": .string("v:\(sessionID):12"),
            "turnId": .string(turnID),
            "terminal": .string("cancelled")
        ])
    }

    private static func failedTurnFrame() -> JSONValue {
        notification("turn/completed", [
            "sessionId": .string(sessionID),
            "viewCursor": .string("v:\(sessionID):10"),
            "turnId": .string(turnID),
            "terminal": .string("failed"),
            "reason": .string("model failed after 3 attempts: provider returned 503 service_unavailable"),
            "error": .object([
                "kind": .string("modelError"),
                "message": .string("model failed after 3 attempts: provider returned 503 service_unavailable"),
                "retryable": .bool(true)
            ])
        ])
    }
}

private actor MusePayloadRecorder {
    private(set) var payloads: [HarnessEventPayload] = []
    private(set) var ended = false
    func append(_ payload: HarnessEventPayload) { payloads.append(payload) }
    func end() { ended = true }
}

private actor FakeMuseTransport: MuseTransport {
    private let stream: AsyncStream<MuseRawFrame>
    private let continuation: AsyncStream<MuseRawFrame>.Continuation
    private let schemaVersion: Int64
    private let resumeRunning: Bool
    private let failTurnStart: Bool
    /// `model/list` `variants` by display label; a row with no entry sends none.
    private let modelVariants: [String: JSONValue]
    /// The row `model/list` marks active, which `session/setModel` moves as the host does.
    private var activeModel = ["meta", "", "muse-large-2"]
    private(set) var configuration: MuseLaunchConfiguration?
    private(set) var requests: [JSONValue] = []
    private(set) var sentMessages: [JSONValue] = []
    private(set) var stopCount = 0
    /// What `usage/read` answers: `{}` is MSP's "nothing observed yet".
    var usageReadResult: JSONValue = .object([:])
    var usageReadError: (any Error)?
    private(set) var usageReadCount = 0

    func answerUsageRead(with result: JSONValue) { usageReadResult = result }
    func failUsageRead(with error: any Error) { usageReadError = error }

    init(
        schemaVersion: Int64 = 1,
        resumeRunning: Bool = false,
        failTurnStart: Bool = false,
        modelVariants: [String: JSONValue] = [:]
    ) {
        let pair = AsyncStream<MuseRawFrame>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        self.schemaVersion = schemaVersion
        self.resumeRunning = resumeRunning
        self.failTurnStart = failTurnStart
        self.modelVariants = modelVariants
    }

    var requestMethods: [String] { requests.compactMap { $0["method"]?.stringValue } }

    func start(_ configuration: MuseLaunchConfiguration) async throws {
        self.configuration = configuration
    }

    func request(_ value: JSONValue, id: Int64) async throws -> JSONValue {
        requests.append(value)
        switch value["method"]?.stringValue {
        case "initialize":
            return .object([
                "serverInfo": .object([
                    "name": .string("muse-session-server"),
                    "version": .string("0.0.0-fixture")
                ]),
                "schema": .object([
                    "version": .integer(schemaVersion),
                    "fingerprint": .string("sha256:c8d1a2a1866814e220fd396d382a9a75861412feee884b5021b2ee359bd3dc59")
                ]),
                "grantedCapabilities": .array([]),
                "experimentalApi": .bool(false),
                "sessionDurability": .string("durable")
            ])
        case "session/start":
            return .object([
                "session": session(status: "idle", activeTurnID: nil),
                "viewCursor": .string("v:\(MuseAdapterTests.sessionID):3")
            ])
        case "session/resume":
            return .object([
                "session": session(
                    status: resumeRunning ? "running" : "idle",
                    activeTurnID: resumeRunning ? MuseAdapterTests.turnID : nil
                ),
                "viewCursor": .string("v:\(MuseAdapterTests.sessionID):412"),
                "history": .object([
                    "mode": .string("none"),
                    "items": .null,
                    "snapshot": .null,
                    "noneReason": .string("cursorSuffix")
                ]),
                "pendingRequests": .array([])
            ])
        case "model/list":
            return .object([
                "providerId": .string("meta"),
                "profileId": .null,
                "source": .string("bundled"),
                "models": .array([
                    modelRow(
                        providerID: "meta",
                        profileID: nil,
                        modelID: "muse-large-2",
                        label: "Muse Large 2",
                        description: "Stable"
                    ),
                    modelRow(
                        providerID: "meta",
                        profileID: nil,
                        modelID: "muse-large-3",
                        label: "Muse Large 3",
                        description: "Newest"
                    ),
                    modelRow(
                        providerID: "partner",
                        profileID: "team",
                        modelID: "muse-large-3",
                        label: "Partner Muse Large 3",
                        description: "Same model ID, different provider"
                    )
                ])
            ])
        case "session/setModel":
            let model = value["params"]?["model"]
            activeModel = [
                model?["providerId"]?.stringValue ?? "",
                model?["profileId"]?.stringValue ?? "",
                model?["modelId"]?.stringValue ?? ""
            ]
            return .object([
                "commandId": value["params"]?["commandId"] ?? .null,
                "status": .string("accepted")
            ])
        case "session/setApprovalMode":
            return .object([
                "commandId": value["params"]?["commandId"] ?? .null,
                "status": .string("accepted"),
                "applyOutcome": .string("applied"),
                "effectiveMode": .object([
                    "mode": value["params"]?["mode"] ?? .string("onRequest"),
                    "source": .string("session"),
                    "lastCommandId": value["params"]?["commandId"] ?? .null
                ])
            ])
        case "session/compact":
            return .object([
                "commandId": value["params"]?["commandId"] ?? .null,
                "status": .string("accepted")
            ])
        case "turn/start":
            if failTurnStart {
                throw HarnessAdapterError.processExited(
                    code: 1,
                    message: "fixture turn/start failure"
                )
            }
            return .object([
                "commandId": value["params"]?["commandId"] ?? .null,
                "status": .string("accepted"),
                "turnId": .string(MuseAdapterTests.turnID),
                "startedNewTurn": .bool(true),
                "disposition": .string("started")
            ])
        case "turn/interrupt":
            return .object([
                "commandId": value["params"]?["commandId"] ?? .null,
                "status": .string("accepted"),
                "turnId": .string(MuseAdapterTests.turnID)
            ])
        case "approval/decide":
            return .object([
                "commandId": value["params"]?["commandId"] ?? .null,
                "status": .string("accepted"),
                "approvalId": .string(MuseAdapterTests.approvalID),
                "terminal": .bool(true)
            ])
        case "userInput/answer", "userInput/cancel":
            return .object([
                "commandId": value["params"]?["commandId"] ?? .null,
                "status": .string("accepted"),
                "userInputId": value["params"]?["userInputId"] ?? .null
            ])
        case "usage/read":
            usageReadCount += 1
            if let usageReadError { throw usageReadError }
            return usageReadResult
        default:
            return .object([:])
        }
    }

    func send(_ value: JSONValue) async throws {
        sentMessages.append(value)
    }

    func messages() async -> AsyncStream<MuseRawFrame> { stream }

    func stop() async {
        stopCount += 1
        continuation.finish()
    }

    func exit() {
        continuation.finish()
    }

    func emit(_ value: JSONValue) {
        let data = (try? ACPWireCodec().encodeLine(value)) ?? Data()
        continuation.yield(MuseRawFrame(value: value, data: data))
    }

    private func modelRow(
        providerID: String,
        profileID: String?,
        modelID: String,
        label: String,
        description: String
    ) -> JSONValue {
        var row: [String: JSONValue] = [
            "providerId": .string(providerID),
            "profileId": profileID.map(JSONValue.string) ?? .null,
            "modelId": .string(modelID),
            "displayLabel": .string(label),
            "description": .string(description),
            "isActive": .bool(activeModel == [providerID, profileID ?? "", modelID])
        ]
        if let variants = modelVariants[label] { row["variants"] = variants }
        return .object(row)
    }

    private func session(status: String, activeTurnID: String?) -> JSONValue {
        var session: [String: JSONValue] = [
            "sessionId": .string(MuseAdapterTests.sessionID),
            "status": .string(status),
            "turnCount": .integer(0),
            "workspaceRoot": .string("/home/me/src/proj"),
            "providerId": .string("muse"),
            "modelId": .string("muse-large-2"),
            "approvalMode": .object([
                "mode": .string("onRequest"),
                "source": .string("default"),
                "lastCommandId": .null
            ])
        ]
        session["activeTurnId"] = activeTurnID.map(JSONValue.string) ?? .null
        return .object(session)
    }
}
