import Foundation
import XCTest
@testable import NativeHarnessClient

final class CodexAdapterTests: XCTestCase {
    /// Two requests that reach an adapter before its App Server has answered `initialize` share
    /// that one handshake: the second waits for the first instead of sending its own.
    func testConcurrentFirstRequestsShareOneInitialize() async throws {
        let modes = JSONValue.object(["data": .array([.object(["name": .string("Plan"), "mode": .string("plan")])])])
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "collaborationMode/list": [modes, modes]
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/fixture-codex"), transport: transport)
        await transport.suspendNextRequest("initialize")
        let first = Task { try await adapter.collaborationModes() }
        while await !transport.isRequestSuspended { await Task.yield() }
        let second = Task { try await adapter.collaborationModes() }
        // Give the second request every chance to send a handshake of its own.
        for _ in 0..<200 where await transport.requestMethods.filter({ $0 == "initialize" }).count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        await transport.releaseSuspendedRequest()
        let firstModes = try await first.value
        let secondModes = try await second.value
        XCTAssertEqual(firstModes.map(\.mode), ["plan"])
        XCTAssertEqual(secondModes.map(\.mode), ["plan"])
        let methods = await transport.requestMethods
        XCTAssertEqual(methods.filter { $0 == "initialize" }.count, 1, "\(methods)")
    }

    /// The runtime exits while `initialize` is unanswered: a late answer neither marks the adapter
    /// initialized nor lets the waiting request go on, and later requests report the ended connection.
    func testAnInitializeAnsweredAfterTheTransportEndedIsNotUsed() async throws {
        let modes = JSONValue.object(["data": .array([.object(["name": .string("Plan"), "mode": .string("plan")])])])
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "collaborationMode/list": [modes, modes]
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/fixture-codex"), transport: transport)
        let ended = "\(HarnessAdapterError.invalidProviderEvent(L10n.format("Connection to %@ ended.", "Codex")))"
        await transport.suspendNextRequest("initialize")
        let waiting = Task { try await adapter.collaborationModes() }
        while await !transport.isRequestSuspended { await Task.yield() }
        await transport.stop()
        // The adapter hears the end of the notification stream before the answer arrives. Each
        // probe runs on its own and only raises the flag, so one that finds the held handshake
        // and waits for it cannot keep the answer from being released.
        let observed = EndObservation()
        var probes: [Task<String, Never>] = []
        let deadline = ContinuousClock.now + testWaitLimit
        while await !observed.seen, ContinuousClock.now < deadline {
            probes.append(Task {
                do { _ = try await adapter.collaborationModes(); return "listed" } catch {
                    if "\(error)" == ended { await observed.see() }
                    return "\(error)"
                }
            })
            try await Task.sleep(for: .milliseconds(5))
        }
        let endObserved = await observed.seen
        XCTAssertTrue(endObserved, "The adapter reports the ended connection")
        await transport.releaseSuspendedRequest()
        do {
            _ = try await waiting.value
            XCTFail("A request whose handshake outlived the runtime does not go on")
        } catch {
            XCTAssertEqual("\(error)", ended)
        }
        for probe in probes {
            let outcome = await probe.value
            XCTAssertEqual(outcome, ended)
        }
        do {
            _ = try await adapter.collaborationModes()
            XCTFail("The ended connection is reported")
        } catch {
            XCTAssertEqual("\(error)", ended)
        }
        let methods = await transport.requestMethods
        XCTAssertEqual(methods, ["initialize"])
    }

    /// A handshake that fails leaves the next request free to try again.
    func testAFailedInitializeIsRetriedByTheNextRequest() async throws {
        let modes = JSONValue.object(["data": .array([.object(["name": .string("Plan"), "mode": .string("plan")])])])
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object([:]), .object(["platformOs": .string("macos")])],
            "collaborationMode/list": [modes]
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/fixture-codex"), transport: transport)
        do {
            _ = try await adapter.collaborationModes()
            XCTFail("An initialize answer without platformOs is refused")
        } catch {}
        let listed = try await adapter.collaborationModes()
        XCTAssertEqual(listed.map(\.mode), ["plan"])
        let methods = await transport.requestMethods
        XCTAssertEqual(methods, ["initialize", "initialize", "collaborationMode/list"])
    }

    func testSlowPresentationConsumerReceivesLatestSnapshotAndLosslessEvents() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [threadResult("slow-reader")]
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
        let snapshots = try await adapter.presentationStates(for: handle)
        let events = await adapter.events(for: handle)
        for delta in ["one\n", "two\n", "three"] {
            await transport.emit(method: "item/agentMessage/delta", params: .object([
                "threadId": .string("slow-reader"), "turnId": .string("turn"),
                "itemId": .string("answer"), "delta": .string(delta)
            ]))
        }
        await transport.emit(method: "turn/completed", params: .object([
            "threadId": .string("slow-reader"),
            "turn": .object(["id": .string("turn"), "status": .string("completed")])
        ]))
        await transport.stop()
        var payloads: [HarnessEventPayload] = []
        for await event in events { payloads.append(event.payload) }
        // Read only after the producer finished, as if the main thread was busy laying out text.
        var received: [CodexTaskState] = []
        for await state in snapshots { received.append(state) }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.last?.thread?.turns.last?.status, .completed)
        guard case let .agentMessage(message) = received.last?.thread?.turns.last?.items.last?.content else {
            return XCTFail("The newest snapshot must contain the complete answer")
        }
        XCTAssertEqual(message.text, "one\ntwo\nthree")
        XCTAssertEqual(payloads.compactMap { payload -> String? in
            if case let .assistantDelta(text) = payload { return text }; return nil
        }, ["one\n", "two\n", "three"])
        XCTAssertTrue(payloads.contains(.turnCompleted))
        await adapter.close(handle)
    }

    func testTransportEndPublishesPartialTurnAndExpiresApprovalBeforeFinishingEvents() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [threadResult("thread-eof")],
            "turn/start": [.object(["turn": .object(["id": .string("turn-eof")])])]
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/eof"), initialPrompt: nil))
        try await adapter.send("Inspect local fixture", to: handle)
        await transport.emit(method: "item/agentMessage/delta", params: .object([
            "threadId": .string("thread-eof"), "turnId": .string("turn-eof"),
            "itemId": .string("answer-eof"), "delta": .string("Partial before disconnect")
        ]))
        await transport.emitServerRequest(id: .string("approval-eof"), method: "item/commandExecution/requestApproval", params: .object([
            "threadId": .string("thread-eof"), "turnId": .string("turn-eof"), "command": .string("swift test")
        ]))
        await transport.stop()
        let ended = expectation(description: "late subscriber observes runtime EOF")
        let collector = Task {
            for await _ in await adapter.events(for: handle) {}
            ended.fulfill()
        }
        await fulfillment(of: [ended], timeout: 2)
        collector.cancel()
        let state = try await adapter.presentationState(for: handle)
        XCTAssertNil(state.activeTurnID)
        XCTAssertEqual(state.thread?.turns.last?.status, .failed)
        guard case .rejected = state.serverRequestsByID["s:approval-eof"]?.resolution else {
            await adapter.close(handle)
            return XCTFail("Disconnected approval must expire")
        }
        XCTAssertTrue(state.thread?.turns.last?.items.contains {
            if case let .agentMessage(message) = $0.content { return message.text == "Partial before disconnect" }
            return false
        } == true)
        await adapter.close(handle)
    }

    func testCreateStreamInterruptAndResumeUseProviderThreadIdentity() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [threadResult("thread-1")],
            "turn/start": [.object(["turn": .object(["id": .string("turn-1")])])],
            "turn/interrupt": [.object([:])],
            "thread/resume": [threadResult("thread-1")],
            "thread/items/list": [.object(["data": .array([])])]
        ])
        let adapter = CodexAdapter(
            executableURL: URL(filePath: "/tmp/fake-codex"),
            transport: transport
        )
        let localSessionID = UUID()
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: localSessionID,
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )
        let recorder = PayloadRecorder()
        let received = expectation(description: "normalized Codex events")
        let collector = Task {
            let stream = await adapter.events(for: handle)
            for await event in stream {
                let count = await recorder.append(event.payload)
                if count == 6 {
                    received.fulfill()
                    break
                }
            }
        }

        try await adapter.send("hello", to: handle)
        await transport.emit(
            method: "item/agentMessage/delta",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "delta": .string("world")
            ])
        )
        await transport.emit(
            method: "turn/completed",
            params: .object([
                "threadId": .string("thread-1"),
                "turn": .object(["id": .string("turn-1")])
            ])
        )
        await fulfillment(of: [received], timeout: 2)
        collector.cancel()

        let payloads = await recorder.payloads
        XCTAssertTrue(payloads.contains(.assistantDelta("world")))
        XCTAssertTrue(payloads.contains(.turnCompleted))
        XCTAssertEqual(payloads.last, .sessionStatusChanged(.ready))

        // Exercise interrupt against a second active turn so completion above can
        // still prove the ready transition independently.
        await transport.enqueue(
            method: "turn/start",
            result: .object(["turn": .object(["id": .string("turn-2")])])
        )
        try await adapter.send("keep going", to: handle)
        try await adapter.interrupt(handle)

        let resumedLocalID = UUID()
        let resumed = try await adapter.resumeSession(
            providerSessionID: "thread-1",
            localSessionID: resumedLocalID,
            workspaceURL: URL(filePath: "/tmp/workspace")
        )
        XCTAssertEqual(resumed.providerSessionID, "thread-1")
        XCTAssertEqual(resumed.localSessionID, resumedLocalID)

        let methods = await transport.requestMethods
        XCTAssertEqual(methods, [
            "initialize",
            "thread/start",
            "turn/start",
            "turn/start",
            "turn/interrupt",
            "thread/resume",
            "thread/items/list"
        ])
    }

    func testStructuredSubmissionSteersTheActiveTurnWithoutFlatteningInputs() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [threadResult("thread-structured")],
            "turn/start": [.object(["turn": .object(["id": .string("turn-1")])])],
            "turn/steer": [.object([:])]
        ])
        let adapter = CodexAdapter(
            executableURL: URL(filePath: "/tmp/fake-codex"),
            transport: transport
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )
        let draft = CodexComposerDraft(inputs: [
            .text("Inspect this context"),
            .localImage(URL(filePath: "/tmp/context.png"), detail: .high),
            .skill(name: "openai-docs", path: URL(filePath: "/tmp/skill/SKILL.md"))
        ])

        try await adapter.selectRunLocation(.readOnly, for: handle)
        try await adapter.submit(draft, submission: .start, to: handle)
        try await adapter.submit(
            CodexComposerDraft(inputs: [.text("Continue")]),
            submission: .steer(expectedTurnID: "turn-1"),
            to: handle
        )

        let activeTurnID = await adapter.activeTurnID(for: handle)
        XCTAssertEqual(activeTurnID, "turn-1")
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["initialize", "thread/start", "turn/start", "turn/steer"])
        let startInputs = requests[2].params["input"]?.arrayValue ?? []
        XCTAssertEqual(startInputs[1]["type"]?.stringValue, "localImage")
        XCTAssertEqual(
            requests[2].params["sandboxPolicy"]?["type"]?.stringValue,
            "readOnly"
        )
        XCTAssertEqual(requests[3].params["expectedTurnId"]?.stringValue, "turn-1")
    }

    func testRetryingStreamErrorShowsReconnectAndOnlyTheFinalErrorFailsTheTask() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [threadResult("thread-retry")],
            "turn/start": [.object(["turn": .object(["id": .string("turn-retry")])])]
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/retry"), initialPrompt: nil))
        let events = await adapter.events(for: handle)
        try await adapter.send("Inspect the project", to: handle)
        await transport.emit(method: "turn/started", params: .object([
            "threadId": .string("thread-retry"),
            "turn": .object(["id": .string("turn-retry"), "status": .string("inProgress")])
        ]))
        await transport.emit(method: "error", params: .object([
            "threadId": .string("thread-retry"), "turnId": .string("turn-retry"), "willRetry": .bool(true),
            "error": .object([
                "message": .string("Reconnecting... 2/5"),
                "codexErrorInfo": .object(["responseStreamDisconnected": .object(["httpStatusCode": .null])])
            ])
        ]))
        var reconnecting: String?
        for _ in 0..<50 {
            let state = try await adapter.presentationState(for: handle)
            reconnecting = CodexTurnErrorPresentation.reconnectStatus(state.thread?.turns.last?.retryingError)
            if reconnecting != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(reconnecting, L10n.format("Reconnecting %@", "2/5"))
        let stillRunning = await adapter.activeTurnID(for: handle)
        XCTAssertEqual(stillRunning, "turn-retry")

        let usageLimit: JSONValue = .object([
            "message": .string("Your limit resets at 3:05 PM."),
            "codexErrorInfo": .string("usageLimitExceeded")
        ])
        await transport.emit(method: "error", params: .object([
            "threadId": .string("thread-retry"), "turnId": .string("turn-retry"),
            "willRetry": .bool(false), "error": usageLimit
        ]))
        await transport.emit(method: "turn/completed", params: .object([
            "threadId": .string("thread-retry"),
            "turn": .object(["id": .string("turn-retry"), "status": .string("failed"), "error": usageLimit])
        ]))
        await transport.stop()
        var payloads: [HarnessEventPayload] = []
        for await event in events { payloads.append(event.payload) }

        let errors = payloads.compactMap { payload -> String? in
            if case let .error(message, _, _) = payload { return message }; return nil
        }
        XCTAssertEqual(errors, [CodexTurnErrorPresentation(usageLimit)?.text])
        XCTAssertTrue(errors.first?.hasPrefix(L10n.string("You've hit your usage limit.")) == true)
        let turn = try await adapter.presentationState(for: handle).thread?.turns.last
        XCTAssertEqual(turn?.status, .failed)
        XCTAssertNil(turn?.retryingError)
        XCTAssertEqual(turn?.error?["codexErrorInfo"]?.stringValue, "usageLimitExceeded")
        await adapter.close(handle)
    }

    func testThreadActionsUseTypedNameArchiveAndDeleteRequests() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [threadResult("thread-actions")],
            "thread/name/set": [.object([:])],
            "thread/archive": [.object([:])],
            "thread/delete": [.object([:])]
        ])
        let adapter = CodexAdapter(
            executableURL: URL(filePath: "/tmp/fake-codex"),
            transport: transport
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )

        try await adapter.setThreadName("  Renamed task  ", for: handle)
        try await adapter.archiveThread(handle)
        try await adapter.deleteThread(handle)

        let requests = await transport.requests
        XCTAssertEqual(
            requests.map(\.method),
            ["initialize", "thread/start", "thread/name/set", "thread/archive", "thread/delete"]
        )
        XCTAssertEqual(requests[2].params["threadId"]?.stringValue, "thread-actions")
        XCTAssertEqual(requests[2].params["name"]?.stringValue, "Renamed task")
        XCTAssertEqual(requests[3].params["threadId"]?.stringValue, "thread-actions")
        XCTAssertEqual(requests[4].params["threadId"]?.stringValue, "thread-actions")
    }

    func testPersistedPendingServerRequestCannotInventProviderRPCContext() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [threadResult("thread-restore-approval")]
        ])
        let adapter = CodexAdapter(
            executableURL: URL(filePath: "/tmp/fake-codex"),
            transport: transport
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )
        let pending = CodexPendingServerRequest(
            CodexServerRequestState(
                id: "approval-restarted",
                method: "item/commandExecution/requestApproval",
                kind: .commandExecutionApproval,
                threadID: "thread-restore-approval",
                turnID: "turn-1",
                itemID: "item-1",
                params: .object(["command": .string("git status")]),
                resolution: .pending
            )
        )

        let answerableIDs = await adapter.answerablePendingServerRequestIDs([pending], for: handle)
        XCTAssertEqual(answerableIDs, [])
        do {
            try await adapter.respond(
                to: pending.id,
                response: .command(.acceptForSession),
                in: handle
            )
            XCTFail("persisted request should not become answerable without a live RPC context")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                HarnessAdapterError.invalidProviderEvent(
                    "Unknown or already-resolved Codex server request"
                ).localizedDescription
            )
        }

        let sent = await transport.sentResponses
        XCTAssertTrue(sent.isEmpty)
    }

    func testPresentationStateLoadsAuthoritativeSnapshotAndPagination() async throws {
        let snapshot = presentationThread("thread-presentation")
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [threadResult("thread-presentation")],
            "thread/read": [.object(["thread": snapshot])],
            "thread/turns/list": [.object([
                "data": .array([.object([
                    "id": .string("turn-2"),
                    "status": .string("completed"),
                    "itemsView": .string("full"),
                    "items": .array([])
                ])]),
                "nextCursor": .string("turn-next")
            ])],
            "thread/items/list": [.object([
                "data": .array([.object([
                    "turnId": .string("turn-2"),
                    "item": .object([
                        "id": .string("item-2"),
                        "type": .string("contextCompaction")
                    ])
                ])]),
                "nextCursor": .string("item-next")
            ])]
        ])
        let adapter = CodexAdapter(
            executableURL: URL(filePath: "/tmp/fake-codex"),
            transport: transport
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )

        let restored = try await adapter.refreshPresentationState(for: handle)
        XCTAssertEqual(restored.thread?.id, "thread-presentation")
        XCTAssertEqual(restored.thread?.turns.first?.items.first?.id, "item-1")

        let turns = try await adapter.loadTurns(for: handle, cursor: nil, limit: 20)
        XCTAssertEqual(turns.nextCursor, "turn-next")
        let items = try await adapter.loadItems(
            for: handle,
            turnID: "turn-2",
            cursor: nil,
            limit: 20
        )
        XCTAssertEqual(items.nextCursor, "item-next")

        let loaded = try await adapter.presentationState(for: handle)
        XCTAssertEqual(loaded.thread?.turns.map(\.id), ["turn-1", "turn-2"])
        XCTAssertEqual(loaded.thread?.turns.last?.items.first?.id, "item-2")
        let requestMethods = await transport.requestMethods
        XCTAssertEqual(requestMethods, [
            "initialize", "thread/start", "thread/read", "thread/turns/list", "thread/items/list"
        ])
        let requests = await transport.requests
        XCTAssertEqual(requests[3].params["sortDirection"]?.stringValue, "desc")
    }

    func testResumeReconstructsPresentationFromAuthoritativeProviderSnapshot() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/resume": [.object([
                "thread": presentationThread("thread-resume"),
                "initialTurnsPage": .object([
                    "data": .array([
                        .object([
                            "id": .string("turn-bootstrap"),
                            "status": .string("completed"),
                            "itemsView": .string("full"),
                            "items": .array([.object([
                                "id": .string("item-bootstrap"),
                                "type": .string("contextCompaction")
                            ])])
                        ]),
                        .object([
                            "id": .string("turn-1"),
                            "status": .string("completed"),
                            "itemsView": .string("full"),
                            "items": .array([.object([
                                "id": .string("item-1"),
                                "type": .string("agentMessage"),
                                "text": .string("history")
                            ])])
                        ])
                    ]),
                    "nextCursor": .string("turn-next"),
                    "backwardsCursor": .string("turn-head")
                ]),
                "turnsBackwardsCursor": .string("turn-head"),
                "itemsBackwardsCursor": .string("item-head")
            ])],
            "thread/items/list": [.object([
                "data": .array([.object([
                    "turnId": .string("turn-1"),
                    "item": .object([
                        "id": .string("command-restored"),
                        "type": .string("commandExecution"),
                        "command": .string("swift test"),
                        "cwd": .string("/tmp/workspace"),
                        "status": .string("completed")
                    ])
                ])])
            ])]
        ])
        let adapter = CodexAdapter(
            executableURL: URL(filePath: "/tmp/fake-codex"),
            transport: transport
        )
        let handle = try await adapter.resumeSession(
            providerSessionID: "thread-resume",
            localSessionID: UUID(),
            workspaceURL: URL(filePath: "/tmp/workspace")
        )
        let state = try await adapter.presentationState(for: handle)
        XCTAssertEqual(state.thread?.id, "thread-resume")
        XCTAssertEqual(state.thread?.turns.first?.id, "turn-1")
        XCTAssertEqual(state.thread?.turns.first?.items.first?.id, "item-1")
        XCTAssertTrue(state.thread?.turns.first?.items.contains { item in
            guard case .commandExecution = item.content else { return false }
            return item.id == "command-restored"
        } == true)
        XCTAssertEqual(state.thread?.turns.last?.id, "turn-bootstrap")
        XCTAssertEqual(state.thread?.turns.last?.items.first?.id, "item-bootstrap")
        XCTAssertEqual(state.thread?.turnsNextCursor, "turn-next")
        XCTAssertEqual(state.thread?.turnsBackwardsCursor, "turn-head")
        XCTAssertEqual(state.thread?.itemsBackwardsCursor, "item-head")
        let requests = await transport.requests
        XCTAssertNil(requests.last?.params["turnId"])
        XCTAssertEqual(requests.last?.params["limit"]?.integerValue, 100)
    }

    func testResumeDropsInProgressSnapshotTurnOlderThanLatestCompletedPage() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/resume": [.object([
                "thread": .object([
                    "id": .string("thread-idle"),
                    "turns": .array([.object([
                        "id": .string("stale"),
                        "status": .string("inProgress"),
                        "startedAt": .integer(100),
                        "itemsView": .string("full"),
                        "items": .array([])
                    ])])
                ]),
                "initialTurnsPage": .object([
                    "data": .array([
                        .object([
                            "id": .string("latest"),
                            "status": .string("completed"),
                            "startedAt": .integer(200),
                            "completedAt": .integer(201),
                            "itemsView": .string("full"),
                            "items": .array([])
                        ]),
                        .object([
                            "id": .string("orphaned"),
                            "status": .string("inProgress"),
                            "itemsView": .string("full"),
                            "items": .array([])
                        ])
                    ])
                ])
            ])],
            "thread/items/list": [.object(["data": .array([])])]
        ])
        let adapter = CodexAdapter(
            executableURL: URL(filePath: "/tmp/fake-codex"),
            transport: transport
        )

        let handle = try await adapter.resumeSession(
            providerSessionID: "thread-idle",
            localSessionID: UUID(),
            workspaceURL: URL(filePath: "/tmp/workspace")
        )
        let state = try await adapter.presentationState(for: handle)

        XCTAssertEqual(state.thread?.turns.map(\.id), ["latest"])
        XCTAssertNil(state.activeTurnID)
    }

    func testResumeDropsUntimestampedInProgressSnapshotTurnWhenCompletedPageIsNewerTruth() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/resume": [.object([
                "thread": .object([
                    "id": .string("thread-idle"),
                    "turns": .array([.object([
                        "id": .string("orphaned"),
                        "status": .string("inProgress"),
                        "itemsView": .string("full"),
                        "items": .array([])
                    ])])
                ]),
                "initialTurnsPage": .object([
                    "data": .array([.object([
                        "id": .string("latest"),
                        "status": .string("completed"),
                        "startedAt": .integer(200),
                        "completedAt": .integer(201),
                        "itemsView": .string("full"),
                        "items": .array([])
                    ])])
                ])
            ])],
            "thread/items/list": [.object([
                "data": .array([.object([
                    "turnId": .string("orphaned"),
                    "item": .object([
                        "id": .string("orphaned-item"),
                        "type": .string("commandExecution"),
                        "command": .string("swift test"),
                        "cwd": .string("/tmp/workspace"),
                        "status": .string("completed")
                    ])
                ])])
            ])]
        ])
        let adapter = CodexAdapter(
            executableURL: URL(filePath: "/tmp/fake-codex"),
            transport: transport
        )

        let handle = try await adapter.resumeSession(
            providerSessionID: "thread-idle",
            localSessionID: UUID(),
            workspaceURL: URL(filePath: "/tmp/workspace")
        )
        let state = try await adapter.presentationState(for: handle)

        XCTAssertEqual(state.thread?.turns.map(\.id), ["latest"])
        XCTAssertNil(state.activeTurnID)
    }

    func testResumeRetriesLegacyEnvelopeWhenBootstrapFieldsAreRejected() async throws {
        let transport = FakeCodexTransport(
            responses: [
                "initialize": [.object(["platformOs": .string("macos")])],
                "thread/resume": [threadResult("thread-legacy")]
            ],
            errorResponses: ["thread/resume": [.object([
                "code": .integer(-32602), "message": .string("Invalid params: unknown field `initialTurnsPage`")
            ])]]
        )
        let adapter = CodexAdapter(
            executableURL: URL(filePath: "/tmp/fake-codex"),
            transport: transport
        )

        let handle = try await adapter.resumeSession(
            providerSessionID: "thread-legacy",
            localSessionID: UUID(),
            workspaceURL: URL(filePath: "/tmp/workspace")
        )

        XCTAssertEqual(handle.providerSessionID, "thread-legacy")
        let methods = await transport.requestMethods
        XCTAssertEqual(methods, ["initialize", "thread/resume", "thread/resume", "thread/items/list"])
        let requests = await transport.requests
        XCTAssertEqual(requests[1].params["excludeTurns"]?.boolValue, true)
        XCTAssertNotNil(requests[1].params["initialTurnsPage"])
        XCTAssertNil(requests[2].params["excludeTurns"])
        XCTAssertNil(requests[2].params["initialTurnsPage"])
    }

    /// Another App Server writing the thread (the ChatGPT app's, 2026-10-16) refuses the resume
    /// with `-32600 thread <id> already has an active writer` on 0.157.1 and 0.163.0 alike. Yardlet
    /// says so in words the person can act on, keeps the provider's words, and does not ask again
    /// for the whole history, which a long thread makes very large.
    func testResumeOfAThreadAnotherAppServerWritesSaysWhyAndIsNotRetried() async throws {
        let transport = FakeCodexTransport(
            responses: ["initialize": [.object(["platformOs": .string("macos")])]],
            errorResponses: ["thread/resume": [.object([
                "code": .integer(-32600),
                "message": .string("thread 0000aaaa-0000-0000-0000-000000000001 already has an active writer")
            ])]]
        )
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport)

        do {
            _ = try await adapter.resumeSession(
                providerSessionID: "0000aaaa-0000-0000-0000-000000000001",
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace")
            )
            XCTFail("A thread another App Server writes must not resume")
        } catch let error as CodexThreadHeldElsewhere {
            let text = error.localizedDescription
            XCTAssertTrue(text.hasPrefix(L10n.string(
                "This conversation is open in another Codex app, such as ChatGPT, so it cannot continue here. Quit that app, then send again."
            )), text)
            XCTAssertTrue(text.contains("already has an active writer"), "The provider's words stay in the details")
            XCTAssertEqual(TranscriptRecoveryProjection.errorSummary(text), L10n.string(
                "This conversation is open in another Codex app, such as ChatGPT, so it cannot continue here. Quit that app, then send again."
            ), "The card's one line is the notice")
        }
        let methods = await transport.requestMethods
        XCTAssertEqual(methods, ["initialize", "thread/resume"])
    }

    /// A resume that ends without an answer (no reply in time, or the App Server gone) fails with
    /// that reason at once; asking again without the bootstrap page would only fail the same way.
    func testResumeThatGetsNoAnswerFailsWithItsReasonAndIsNotRetried() async throws {
        let transport = FakeCodexTransport(
            responses: [
                "initialize": [.object(["platformOs": .string("macos")])],
                "thread/resume": [threadResult("thread-slow")]
            ],
            failures: ["thread/resume": 1]
        )
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport)

        do {
            _ = try await adapter.resumeSession(
                providerSessionID: "thread-slow", localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/workspace")
            )
            XCTFail("A resume without an answer must not report success")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Fake runtime rejected optional resume fields")
        }
        let methods = await transport.requestMethods
        XCTAssertEqual(methods, ["initialize", "thread/resume"])
    }

    func testResumeRestoresActiveTurnIdentityForSteerAndInterrupt() async throws {
        let activeThread = JSONValue.object([
            "id": .string("thread-active-resume"),
            "status": .object([
                "type": .string("active"),
                "activeFlags": .array([.string("turn")])
            ]),
            "turns": .array([.object([
                "id": .string("turn-active"),
                "status": .string("inProgress"),
                "itemsView": .string("full"),
                "items": .array([])
            ])])
        ])
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/resume": [.object(["thread": activeThread])],
            "turn/steer": [.object([:])],
            "turn/interrupt": [.object([:])]
        ])
        let adapter = CodexAdapter(
            executableURL: URL(filePath: "/tmp/fake-codex"),
            transport: transport
        )
        let handle = try await adapter.resumeSession(
            providerSessionID: "thread-active-resume",
            localSessionID: UUID(),
            workspaceURL: URL(filePath: "/tmp/workspace")
        )

        let activeTurnID = await adapter.activeTurnID(for: handle)
        XCTAssertEqual(activeTurnID, "turn-active")
        try await adapter.submit(
            CodexComposerDraft(inputs: [.text("Continue the active turn")]),
            submission: .steer(expectedTurnID: "turn-active"),
            to: handle
        )
        try await adapter.interrupt(handle)

        let methods = await transport.requestMethods
        XCTAssertEqual(methods, [
            "initialize", "thread/resume", "thread/items/list", "turn/steer", "turn/interrupt"
        ])
    }

    func testPresentationStatePublishesNotificationProjection() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [threadResult("thread-notifications")]
        ])
        let adapter = CodexAdapter(
            executableURL: URL(filePath: "/tmp/fake-codex"),
            transport: transport
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )
        let received = expectation(description: "typed presentation notification")
        let stream = try await adapter.presentationStates(for: handle)
        let collector = Task {
            for await state in stream {
                if state.thread?.turns.contains(where: { turn in
                    turn.items.contains(where: { $0.id == "item-1" })
                }) == true {
                    received.fulfill()
                    break
                }
            }
        }

        await transport.emit(
            method: "item/started",
            params: .object([
                "threadId": .string("thread-notifications"),
                "turnId": .string("turn-1"),
                "item": .object([
                    "id": .string("item-1"),
                    "type": .string("contextCompaction")
                ]),
                "startedAtMs": .integer(10)
            ])
        )
        await fulfillment(of: [received], timeout: 2)
        collector.cancel()

        let state = try await adapter.presentationState(for: handle)
        XCTAssertEqual(state.thread?.turns.first?.items.first?.id, "item-1")
        XCTAssertEqual(state.thread?.turns.first?.items.first?.lifecycle, .inProgress)
    }

    /// `configWarning` names no thread. The attached task keeps it for its next turn, beside the
    /// turn's own `model/rerouted` notice.
    func testRuntimeNoticesReachTheAttachedTaskInItsNextTurn() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [threadResult("thread-notices")]
        ])
        let adapter = CodexAdapter(
            executableURL: URL(filePath: "/tmp/fake-codex"),
            transport: transport
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )
        func notices(_ state: CodexTaskState) -> [CodexNoticeItem] {
            (state.thread?.turns.last?.items ?? []).compactMap { item in
                if case let .notice(notice) = item.content { return notice }
                return nil
            }
        }
        let received = expectation(description: "notices in the next turn")
        let stream = try await adapter.presentationStates(for: handle)
        let collector = Task {
            for await state in stream where notices(state).count == 2 {
                received.fulfill()
                break
            }
        }

        await transport.emit(method: "configWarning", params: .object([
            "summary": .string("Unknown key `foo` in config.toml"), "details": .null
        ]))
        await transport.emit(method: "turn/started", params: .object([
            "threadId": .string("thread-notices"),
            "turn": .object(["id": .string("turn-1"), "status": .string("inProgress"), "items": .array([])])
        ]))
        await transport.emit(method: "model/rerouted", params: .object([
            "threadId": .string("thread-notices"), "turnId": .string("turn-1"),
            "fromModel": .string("gpt-5.5"), "toModel": .string("gpt-5.5-mini"),
            "reason": .string("highRiskCyberActivity")
        ]))
        await fulfillment(of: [received], timeout: 2)
        collector.cancel()

        let state = try await adapter.presentationState(for: handle)
        XCTAssertEqual(notices(state).map(\.kind), [.configWarning, .modelRerouted])
        XCTAssertEqual(notices(state).map(\.message), ["Unknown key `foo` in config.toml", "gpt-5.5-mini"])
        XCTAssertEqual(state.pendingNotices, [])
    }

    func testAgentDeltasCoalescePresentationPublicationButKeepFinalState() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [threadResult("thread-coalesce")]
        ])
        let adapter = CodexAdapter(
            executableURL: URL(filePath: "/tmp/fake-codex"),
            transport: transport
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )
        let recorder = PresentationRecorder()
        let received = expectation(description: "coalesced final presentation")
        let stream = try await adapter.presentationStates(for: handle)
        let collector = Task {
            for await state in stream {
                let count = await recorder.append(state)
                if count >= 2,
                   state.thread?.turns.first?.items.first?.id == "assistant-1" {
                    received.fulfill()
                    break
                }
            }
        }

        for delta in ["a", "b", "c"] {
            await transport.emit(
                method: "item/agentMessage/delta",
                params: .object([
                    "threadId": .string(handle.providerSessionID),
                    "turnId": .string("turn-1"),
                    "itemId": .string("assistant-1"),
                    "delta": .string(delta)
                ])
            )
        }
        await fulfillment(of: [received], timeout: 2)
        try await Task.sleep(for: .milliseconds(40))
        collector.cancel()

        let states = await recorder.states
        XCTAssertGreaterThanOrEqual(states.count, 2)
        let final = try XCTUnwrap(states.last)
        guard case let .agentMessage(message) = final.thread?.turns.first?.items.first?.content else {
            return XCTFail("coalesced state should retain agent message")
        }
        XCTAssertEqual(message.text, "abc")
    }

    func testPermissionRequestWaitsForExplicitDenial() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [threadResult("thread-permission")]
        ])
        let adapter = CodexAdapter(
            executableURL: URL(filePath: "/tmp/fake-codex"),
            transport: transport
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )
        let recorder = PayloadRecorder()
        let received = expectation(description: "permission event")
        let collector = Task {
            let stream = await adapter.events(for: handle)
            for await event in stream {
                let count = await recorder.append(event.payload)
                if count == 4 {
                    received.fulfill()
                    break
                }
            }
        }

        await transport.emitServerRequest(
            id: .string("permission-1"),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("thread-permission"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "startedAtMs": .integer(1),
                "command": .string("git status"),
                "reason": .string("Inspect the worktree")
            ])
        )
        await fulfillment(of: [received], timeout: 2)
        collector.cancel()

        let payloads = await recorder.payloads
        XCTAssertTrue(payloads.contains { payload in
            guard case let .permissionRequested(request) = payload else { return false }
            return request.id == "s:permission-1" && request.command == "git status"
        })
        XCTAssertEqual(payloads.last, .sessionStatusChanged(.waitingForApproval))

        let answerableIDs = await adapter.answerablePendingServerRequestIDs([
            CodexPendingServerRequest(
                CodexServerRequestState(
                    id: "s:permission-1",
                    method: "item/commandExecution/requestApproval",
                    kind: .commandExecutionApproval,
                    threadID: "thread-permission",
                    turnID: "turn-1",
                    itemID: "item-1",
                    params: .object(["command": .string("git status")]),
                    resolution: .pending
                )
            )
        ], for: handle)
        XCTAssertEqual(answerableIDs, ["s:permission-1"])
        let mismatchedIDs = await adapter.answerablePendingServerRequestIDs([
            CodexPendingServerRequest(
                CodexServerRequestState(
                    id: "s:permission-1",
                    method: "item/commandExecution/requestApproval",
                    kind: .commandExecutionApproval,
                    threadID: "thread-permission",
                    turnID: "turn-1",
                    itemID: "stale-item",
                    params: .object(["command": .string("git status")]),
                    resolution: .pending
                )
            )
        ], for: handle)
        XCTAssertEqual(mismatchedIDs, [])

        try await adapter.respond(
            to: "s:permission-1",
            decision: .deny,
            in: handle
        )
        let responses = await transport.sentResponses
        XCTAssertEqual(responses.last?.id, .string("permission-1"))
        XCTAssertEqual(responses.last?.result["decision"]?.stringValue, "decline")
    }

    func testUnsupportedServerRequestFailsClosedAndCurrentTimeIsAnswered() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [threadResult("thread-server-request")]
        ])
        let adapter = CodexAdapter(
            executableURL: URL(filePath: "/tmp/fake-codex"),
            transport: transport
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )

        await transport.emitServerRequest(
            id: .string("future-1"),
            method: "future/serverRequest",
            params: .object(["threadId": .string(handle.providerSessionID)])
        )
        await transport.emitServerRequest(
            id: .string("time-1"),
            method: "currentTime/read",
            params: .object([:])
        )

        try await waitUntil {
            let errors = await transport.sentErrorResponses.count
            let responses = await transport.sentResponses.count
            return errors == 1 && responses == 1
        }
        let errors = await transport.sentErrorResponses
        let responses = await transport.sentResponses
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.id, .string("future-1"))
        XCTAssertEqual(errors.first?.error["code"]?.integerValue, -32001)
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.id, .string("time-1"))
        XCTAssertNotNil(responses.first?.result["currentTimeAt"]?.integerValue)

        let state = try await adapter.presentationState(for: handle)
        XCTAssertEqual(
            state.serverRequestsByID["s:future-1"]?.resolution,
            .rejected(code: -32001, message: "Unsupported Codex server request future/serverRequest: No native response implementation is registered")
        )
    }

    func testTypedToolInputServerRequestRemainsPendingUntilExactResponse() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [threadResult("thread-tool-input")]
        ])
        let adapter = CodexAdapter(
            executableURL: URL(filePath: "/tmp/fake-codex"),
            transport: transport
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )
        await transport.emitServerRequest(
            id: .string("input-1"),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string(handle.providerSessionID),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "isBlocking": .bool(true),
                "questions": .array([])
            ])
        )
        for _ in 0..<20 {
            if try await adapter.presentationState(for: handle)
                .serverRequestsByID["s:input-1"]?.resolution == .pending {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await adapter.respond(
            to: "s:input-1",
            response: .toolUserInput(answers: ["question-1": ["yes"]]),
            in: handle
        )
        let response = await transport.sentResponses.last
        XCTAssertEqual(response?.id, .string("input-1"))
        XCTAssertEqual(
            response?.result["answers"]?["question-1"]?["answers"]?.arrayValue,
            [.string("yes")]
        )
        let finalState = try await adapter.presentationState(for: handle)
        XCTAssertEqual(
            finalState.serverRequestsByID["s:input-1"]?.resolution,
            .resolved(response?.result)
        )
    }

    func testCodexCapabilitiesUseSameRegisteredThreadAndSelectedMode() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [threadResult("thread-capabilities")],
            "collaborationMode/list": [.object([
                "data": .array([.object([
                    "name": .string("Plan"),
                    "mode": .string("plan"),
                    "model": .string("gpt-5.6-codex"),
                    "reasoning_effort": .string("high")
                ])])
            ])],
            "skills/list": [.object(["data": .array([])])],
            "plugin/list": [.object(["marketplaces": .array([])])],
            "thread/list": [
                .object([
                    "data": .array([]),
                    "nextCursor": .string("recent-cursor")
                ]),
                .object([
                    "data": .array([.object([
                        "id": .string("thread-recent-2"),
                        "cwd": .string("/tmp/workspace"),
                        "updatedAt": .integer(1_700_000_002),
                        "name": .string("Recent page"),
                        "preview": .string("paged history")
                    ])]),
                    "nextCursor": .null
                ])
            ],
            "thread/search": [.object([
                "data": .array([
                    .object([
                        "thread": .object([
                            "id": .string("thread-search"),
                            "cwd": .string("/tmp/workspace"),
                            "updatedAt": .integer(1_700_000_000),
                            "name": .string("Approval task"),
                            "preview": .string("Need approval")
                        ]),
                        "snippet": .string("approval required")
                    ]),
                    .object([
                        "thread": .object([
                            "id": .string("thread-other-workspace"),
                            "cwd": .string("/tmp/other"),
                            "updatedAt": .integer(1_700_000_000),
                            "preview": .string("other")
                        ]),
                        "snippet": .string("other")
                    ])
                ]),
                "nextCursor": .string("cursor-2")
            ])],
            "thread/searchOccurrences": [.object([
                "data": .array([.object([
                    "turnId": .string("turn-search"),
                    "itemId": .string("item-search"),
                    "snippet": .string("approval required"),
                    "snippetMatchRange": .object([
                        "start": .integer(0),
                        "end": .integer(8)
                    ]),
                    "turnCursor": .string("turn-cursor")
                ])]),
                "nextCursor": .string("occurrence-cursor")
            ])],
            "turn/start": [
                .object(["turn": .object(["id": .string("turn-mode")])]),
                .object(["turn": .object(["id": .string("turn-forked")])])
            ],
            "thread/fork": [.object([
                "thread": .object([
                    "id": .string("thread-forked"),
                    "cwd": .string("/tmp/workspace"),
                    "forkedFromId": .string("thread-capabilities"),
                    "status": .object(["type": .string("idle")])
                ])
            ])],
            "review/start": [.object(["turn": .object(["id": .string("turn-review")])])]
        ])
        let adapter = CodexAdapter(
            executableURL: URL(filePath: "/tmp/fake-codex"),
            transport: transport
        )
        let workspace = URL(filePath: "/tmp/workspace")
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: workspace,
                initialPrompt: nil
            )
        )

        let modes = try await adapter.collaborationModes()
        let skills = try await adapter.skills(in: workspace)
        let plugins = try await adapter.plugins(in: workspace)
        let threads = try await adapter.recentThreads(in: workspace)
        let recentPage = try await adapter.recentThreadsPage(
            in: workspace,
            cursor: "recent-cursor",
            limit: 30
        )
        let searchPage = try await adapter.searchThreads(
            in: workspace,
            searchTerm: "approval",
            cursor: nil,
            limit: 30
        )
        XCTAssertEqual(modes.map(\.name), ["Plan"])
        XCTAssertEqual(skills, [])
        XCTAssertEqual(plugins, [])
        XCTAssertEqual(threads, [])
        XCTAssertEqual(recentPage.threads.map(\.id), ["thread-recent-2"])
        XCTAssertNil(recentPage.nextCursor)
        XCTAssertEqual(searchPage.matches.map(\.thread.id), ["thread-search"])
        XCTAssertEqual(searchPage.matches.first?.snippet, "approval required")
        XCTAssertEqual(searchPage.nextCursor, "cursor-2")
        let occurrences = try await adapter.searchOccurrences(
            threadID: "thread-search",
            searchTerm: "approval",
            cursor: nil,
            limit: 30
        )
        XCTAssertEqual(occurrences.occurrences.first?.turnID, "turn-search")
        XCTAssertEqual(occurrences.occurrences.first?.itemID, "item-search")
        XCTAssertEqual(occurrences.nextCursor, "occurrence-cursor")

        try await adapter.selectCollaborationMode(try XCTUnwrap(modes.first), for: handle)
        try await adapter.selectRunLocation(.workspaceWrite, for: handle)
        try await adapter.send("use plan", to: handle)
        let forked = try await adapter.fork(handle, newLocalSessionID: UUID())
        XCTAssertEqual(forked.providerSessionID, "thread-forked")
        let forkedState = try await adapter.presentationState(for: forked)
        XCTAssertEqual(forkedState.thread?.id, "thread-forked")
        XCTAssertEqual(forkedState.thread?.forkedFromID, "thread-capabilities")
        try await adapter.send("continue fork", to: forked)
        // A review starts only on an idle thread, so the plan turn finishes first.
        await transport.emit(method: "turn/completed", params: .object([
            "threadId": .string("thread-capabilities"),
            "turn": .object(["id": .string("turn-mode"), "status": .string("completed")])
        ]))
        // Wait on what the review guard reads, not on the presentation state, which can already be
        // idle while the adapter has yet to process the completion.
        try await waitUntil { await adapter.activeTurnID(for: handle) == nil }
        try await adapter.startWorkingTreeReview(in: handle)

        let requests = await transport.requests
        let turnRequest = try XCTUnwrap(requests.first(where: { $0.method == "turn/start" }))
        let reviewRequest = try XCTUnwrap(requests.first(where: { $0.method == "review/start" }))
        XCTAssertEqual(turnRequest.params["threadId"]?.stringValue, "thread-capabilities")
        XCTAssertEqual(turnRequest.params["collaborationMode"]?["mode"]?.stringValue, "plan")
        let forkTurnRequest = try XCTUnwrap(
            requests.last(where: { $0.method == "turn/start" && $0.params["threadId"]?.stringValue == "thread-forked" })
        )
        XCTAssertEqual(forkTurnRequest.params["collaborationMode"]?["mode"]?.stringValue, "plan")
        XCTAssertEqual(
            forkTurnRequest.params["sandboxPolicy"]?["type"]?.stringValue,
            "workspaceWrite"
        )
        XCTAssertEqual(
            reviewRequest.params["threadId"]?.stringValue,
            "thread-capabilities"
        )
        let searchRequest = try XCTUnwrap(requests.first(where: { $0.method == "thread/search" }))
        XCTAssertEqual(searchRequest.params["searchTerm"]?.stringValue, "approval")
        XCTAssertEqual(searchRequest.params["archived"]?.boolValue, false)
        let occurrenceRequest = try XCTUnwrap(
            requests.first(where: { $0.method == "thread/searchOccurrences" })
        )
        XCTAssertEqual(occurrenceRequest.params["threadId"]?.stringValue, "thread-search")
        XCTAssertEqual(occurrenceRequest.params["searchTerm"]?.stringValue, "approval")
    }

    /// Every thread frame takes a number, so one that projects to no event leaves a gap. A late
    /// subscriber reads the newest 500 events. Closing finishes the session's stream but, unlike
    /// the other adapters, keeps its events and numbering; the shared channel kept both.
    func testEventNumbersCountFramesWithoutAnEventAndAClosedSessionKeepsItsReplay() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [threadResult("thread-replay"), threadResult("thread-open")]
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/replay"), initialPrompt: nil))
        // A second session keeps the transport running after the first one closes.
        let open = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/open"), initialPrompt: nil))
        func delta(_ text: String) -> JSONValue {
            .object([
                "threadId": .string("thread-replay"), "turnId": .string("turn-replay"),
                "itemId": .string("answer-replay"), "delta": .string(text)
            ])
        }

        var live = await adapter.events(for: handle).makeAsyncIterator()
        await transport.emit(method: "item/agentMessage/delta", params: delta("first"))
        await transport.emit(method: "item/reasoning/summaryTextDelta", params: .object([
            "threadId": .string("thread-replay"), "turnId": .string("turn-replay"),
            "itemId": .string("reasoning-replay"), "delta": .string("thinking"), "summaryIndex": .integer(0)
        ]))
        for index in 0..<600 {
            await transport.emit(method: "item/agentMessage/delta", params: delta("\(index)"))
        }
        var liveEvents: [HarnessEventEnvelope] = []
        while let event = await live.next() {
            liveEvents.append(event)
            if event.payload == .assistantDelta("599") { break }
        }
        XCTAssertEqual(liveEvents.prefix(4).map(\.payload), [
            .sessionStarted(handle), .sessionStatusChanged(.ready), .assistantDelta("first"), .assistantDelta("0")
        ])
        XCTAssertEqual(liveEvents.prefix(4).map(\.sequence), [0, 1, 2, 4])
        XCTAssertEqual(liveEvents.last?.sequence, 603)

        var late = await adapter.events(for: handle).makeAsyncIterator()
        let replacedEnd = await live.next()
        XCTAssertNil(replacedEnd)
        var lateEvents: [HarnessEventEnvelope] = []
        for _ in 0..<500 { if let event = await late.next() { lateEvents.append(event) } }
        XCTAssertEqual(lateEvents, Array(liveEvents.suffix(500)))

        await adapter.close(handle)
        let closedEnd = await late.next()
        XCTAssertNil(closedEnd)
        var reopened = await adapter.events(for: handle).makeAsyncIterator()
        var replayed: [HarnessEventEnvelope] = []
        for _ in 0..<500 { if let event = await reopened.next() { replayed.append(event) } }
        XCTAssertEqual(replayed, lateEvents)
        await adapter.close(open)
    }

    private func threadResult(_ id: String) -> JSONValue {
        .object(["thread": .object(["id": .string(id)])])
    }

    private func presentationThread(_ id: String) -> JSONValue {
        .object([
            "id": .string(id),
            "sessionId": .string("session-1"),
            "preview": .string("Restore presentation"),
            "cwd": .string("/tmp/workspace"),
            "cliVersion": .string("0.148.0-alpha.9"),
            "modelProvider": .string("openai"),
            "createdAt": .integer(1_700_000_000),
            "updatedAt": .integer(1_700_000_010),
            "ephemeral": .bool(false),
            "status": .object(["type": .string("idle")]),
            "turns": .array([.object([
                "id": .string("turn-1"),
                "status": .string("completed"),
                "itemsView": .string("full"),
                "items": .array([.object([
                    "id": .string("item-1"),
                    "type": .string("agentMessage"),
                    "text": .string("history")
                ])])
            ])])
        ])
    }
}

private actor PayloadRecorder {
    private(set) var payloads: [HarnessEventPayload] = []

    @discardableResult
    func append(_ payload: HarnessEventPayload) -> Int {
        payloads.append(payload)
        return payloads.count
    }
}

private actor PresentationRecorder {
    private(set) var states: [CodexTaskState] = []

    @discardableResult
    func append(_ state: CodexTaskState) -> Int {
        states.append(state)
        return states.count
    }
}

private actor EndObservation {
    private(set) var seen = false
    func see() { seen = true }
}

actor FakeCodexTransport: CodexTransport {
    private var responses: [String: [JSONValue]]
    private var failures: [String: Int]
    private var errorResponses: [String: [JSONValue]]
    private let stream: AsyncStream<CodexRawFrame>
    private let continuation: AsyncStream<CodexRawFrame>.Continuation
    private(set) var requestMethods: [String] = []
    private(set) var requests: [CodexRPCRequest] = []
    private(set) var sentResponses: [CodexRPCResponse] = []
    private(set) var sentErrorResponses: [CodexRPCErrorResponse] = []
    private(set) var stopCount = 0
    private var suspendedRequestMethod: String?
    private var requestContinuation: CheckedContinuation<Void, Never>?
    var isRequestSuspended: Bool { requestContinuation != nil }

    init(responses: [String: [JSONValue]], failures: [String: Int] = [:], errorResponses: [String: [JSONValue]] = [:]) {
        self.responses = responses
        self.failures = failures
        self.errorResponses = errorResponses
        let pair = AsyncStream<CodexRawFrame>.makeStream()
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func start() async throws {}

    func request(_ request: CodexRPCRequest) async throws -> CodexRPCIncomingMessage {
        requestMethods.append(request.method)
        requests.append(request)
        if suspendedRequestMethod == request.method {
            suspendedRequestMethod = nil
            await withCheckedContinuation { requestContinuation = $0 }
        }
        if var errors = errorResponses[request.method], !errors.isEmpty {
            let payload = errors.removeFirst()
            errorResponses[request.method] = errors
            guard case let .integer(id) = request.id else { throw HarnessAdapterError.invalidProviderEvent("Invalid fake request ID") }
            throw CodexRPCRequestFailure(requestID: id, payload: payload)
        }
        if let remaining = failures[request.method], remaining > 0 {
            failures[request.method] = remaining - 1
            throw HarnessAdapterError.invalidProviderEvent(
                "Fake runtime rejected optional resume fields"
            )
        }
        guard var queue = responses[request.method], !queue.isEmpty else {
            throw HarnessAdapterError.invalidProviderEvent(
                "Missing fake response for \(request.method)"
            )
        }
        let result = queue.removeFirst()
        responses[request.method] = queue
        return CodexRPCIncomingMessage(
            id: request.id,
            method: nil,
            params: nil,
            result: result,
            error: nil,
            emittedAtMs: nil
        )
    }

    func sendResponse(_ response: CodexRPCResponse) async throws {
        sentResponses.append(response)
    }

    func sendErrorResponse(_ response: CodexRPCErrorResponse) async throws {
        sentErrorResponses.append(response)
    }

    func notifications() async -> AsyncStream<CodexRawFrame> {
        stream
    }

    func stop() async {
        stopCount += 1
        continuation.finish()
    }

    func enqueue(method: String, result: JSONValue) {
        responses[method, default: []].append(result)
    }

    func suspendNextRequest(_ method: String) { suspendedRequestMethod = method }

    func releaseSuspendedRequest() {
        requestContinuation?.resume()
        requestContinuation = nil
    }

    func emit(method: String, params: JSONValue) {
        continuation.yield(
            CodexRawFrame(
                message: CodexRPCIncomingMessage(
                    id: nil,
                    method: method,
                    params: params,
                    result: nil,
                    error: nil,
                    emittedAtMs: nil
                ),
                data: Data("{\"method\":\"\(method)\"}".utf8)
            )
        )
    }

    func emitServerRequest(id: CodexRPCID, method: String, params: JSONValue) {
        continuation.yield(
            CodexRawFrame(
                message: CodexRPCIncomingMessage(
                    id: id,
                    method: method,
                    params: params,
                    result: nil,
                    error: nil,
                    emittedAtMs: nil
                ),
                data: Data("{\"method\":\"\(method)\"}".utf8)
            )
        )
    }
}
