import Foundation
import XCTest
@testable import NativeHarnessClient

/// Claude Code's queued user messages in the shapes 2.1.291 reads and writes: a `user` message
/// carrying `uuid` and `priority`, the `cancel_async_message` control request, and the
/// `command_lifecycle` frames that say when the CLI took a message into a turn.
final class ClaudeFollowUpQueueTests: XCTestCase {
    private let sessionID = "8d0c6b8e-3c9f-4d5e-9a63-0f3b8f1f2a10"
    private let codec = ClaudeWireCodec()

    func testAFollowUpCarriesItsUUIDAndPriorityWhileAnOrdinaryTurnIsUnchanged() throws {
        XCTAssertEqual(
            try line(ClaudeProtocol.userMessage("Run the tests", sessionID: sessionID)),
            #"{"message":{"content":"Run the tests","role":"user"},"parent_tool_use_id":null,"#
                + #""session_id":"8d0c6b8e-3c9f-4d5e-9a63-0f3b8f1f2a10","type":"user"}"#
        )
        let id = "1f0e7a52-6a8c-4d7e-b1c4-0d4f7c2a9e31"
        // Typed by the user, so stamped as a person's message, which the CLI's Send now requires.
        XCTAssertEqual(
            try line(ClaudeProtocol.userMessage(text: "Use Python instead", images: [], sessionID: sessionID,
                                                uuid: id, priority: .next)),
            #"{"message":{"content":"Use Python instead","role":"user"},"origin":{"kind":"human"},"#
                + #""parent_tool_use_id":null,"priority":"next","#
                + #""session_id":"8d0c6b8e-3c9f-4d5e-9a63-0f3b8f1f2a10","type":"user","#
                + #""uuid":"1f0e7a52-6a8c-4d7e-b1c4-0d4f7c2a9e31"}"#
        )
        let withImage = ClaudeProtocol.userMessage(
            text: "Like this", images: [.init(mimeType: "image/png", base64Data: "iVBORw0KGgo=")],
            sessionID: sessionID, uuid: id, priority: .now
        )
        XCTAssertEqual(withImage["message"]?["content"]?.arrayValue?.count, 2)
        XCTAssertEqual(withImage["uuid"]?.stringValue, id)
        XCTAssertEqual(withImage["priority"]?.stringValue, "now")
        XCTAssertEqual(withImage["origin"]?["kind"]?.stringValue, "human")
        XCTAssertNil(withImage["isSynthetic"])
        // Another task's message is relayed text: marked synthetic with no origin, so Claude Code 2.1.332
        // does not count it as the person's in the running turn.
        let relayed = TaskMessage(senderID: "9A3E0C55-7B21-4D2F-8E6A-1C4B5D6E7F80", senderName: "Coordinator",
                                  body: "Merge it.").text(in: .yardlet)
        let relay = ClaudeProtocol.userMessage(text: relayed, images: [], sessionID: sessionID, uuid: id, priority: .next)
        XCTAssertEqual(relay["isSynthetic"]?.boolValue, true)
        XCTAssertNil(relay["origin"])
        XCTAssertEqual(relay["message"]?["content"]?.stringValue, relayed)
        XCTAssertEqual(relay["priority"]?.stringValue, "next")

        let cancel = ClaudeProtocol.cancelAsyncMessage(id: "nhc-cancel-message-7", messageUUID: id)
        XCTAssertEqual(
            try line(cancel),
            #"{"request":{"message_uuid":"1f0e7a52-6a8c-4d7e-b1c4-0d4f7c2a9e31","subtype":"cancel_async_message"},"#
                + #""request_id":"nhc-cancel-message-7","type":"control_request"}"#
        )
        // Send now is an interrupt that is not a Stop.
        XCTAssertEqual(
            try line(ClaudeProtocol.sendNow(id: "nhc-send-now-8", messageUUID: id)),
            #"{"request":{"message_uuid":"1f0e7a52-6a8c-4d7e-b1c4-0d4f7c2a9e31","send_now":true,"subtype":"interrupt"},"#
                + #""request_id":"nhc-send-now-8","type":"control_request"}"#
        )

        let lifecycle = try json(lifecycleFrame(id, "started"))
        XCTAssertEqual(ClaudeProtocol.commandLifecycle(in: lifecycle)?.messageID, id)
        XCTAssertEqual(ClaudeProtocol.commandLifecycle(in: lifecycle)?.state, "started")
        XCTAssertNil(ClaudeProtocol.commandLifecycle(in: try json(#"{"type":"system","subtype":"status"}"#)))
        // The projection has nothing to say about a lifecycle frame.
        var projection = ClaudeSessionProjection()
        XCTAssertTrue(projection.payloads(from: lifecycle).isEmpty)
    }

    func testTheCLIsLifecycleSaysWhenAFollowUpIsReadAndOneItStillHoldsStartsTheNextTurn() async throws {
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport })
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/workspace"), initialPrompt: nil))
        let log = FollowUpPayloadLog()
        let collector = Task { for await event in await adapter.events(for: handle) { await log.append(event.payload) } }
        defer { collector.cancel() }

        try await adapter.send("Run the tests", to: handle)
        let steered = UUID().uuidString.lowercased(), waiting = UUID().uuidString.lowercased()
        try await adapter.sendFollowUp(HarnessUserInput(text: "Use Python instead"), messageID: steered,
                                       priority: .next, to: handle)
        try await adapter.sendFollowUp(HarnessUserInput(text: "Then update the README"), messageID: waiting,
                                       priority: .next, to: handle)
        let written = await transport.sentValues
        XCTAssertEqual(written.map { $0["uuid"]?.stringValue }, [nil, steered, waiting])
        XCTAssertEqual(written.map { $0["priority"]?.stringValue }, [nil, "next", "next"])
        try await waitFor(log) { $0.filter { $0 == .sessionStatusChanged(.running) }.count == 1 }

        for frame in [lifecycleFrame(steered, "queued"), lifecycleFrame(waiting, "queued"), toolUse, toolResult,
                      lifecycleFrame(steered, "started"), lifecycleFrame(UUID().uuidString, "started"),
                      assistantText("Switching to Python."), lifecycleFrame(steered, "completed"), result] {
            await transport.emit(try json(frame))
        }
        try await waitForTurnEnd(log)
        var payloads = await log.payloads
        // Read between the tool result and the text it changed, while the turn kept running: into
        // that turn (D13).
        let read = try XCTUnwrap(payloads.firstIndex(of: .followUpDelivery(.init(
            messageID: steered, state: .read, joinsRunningTurn: true
        ))))
        let toolDone = try XCTUnwrap(payloads.firstIndex { if case .activityCompleted = $0 { true } else { false } })
        let answer = try XCTUnwrap(payloads.firstIndex(of: .assistantMessageCompleted("Switching to Python.")))
        XCTAssertLessThan(toolDone, read)
        XCTAssertLessThan(read, answer)
        XCTAssertEqual(payloads.filter { if case .followUpDelivery = $0 { true } else { false } }.count, 1,
                       "Its completion and a command that is not Yardlet's say nothing more")
        XCTAssertEqual(payloads.filter { $0 == .sessionStatusChanged(.running) }.count, 1)

        // The one still held starts the next turn on its own, which is running again.
        await transport.emit(try json(lifecycleFrame(waiting, "started")))
        try await waitFor(log) { $0.last == .sessionStatusChanged(.running) }
        payloads = await log.payloads
        XCTAssertEqual(Array(payloads.suffix(2)), [
            .followUpDelivery(.init(messageID: waiting, state: .read, joinsRunningTurn: false)),
            .sessionStatusChanged(.running)
        ])
        await adapter.close(handle)
    }

    /// Send now is asked of a CLI only once its `system/init` advertises `interrupt_send_now_v1`, and
    /// only for a message in its queue: one just written is pressed when the CLI reports it
    /// `queued`, and one it already took is not pressed at all. The answer's `send_now` says what
    /// the CLI did. The product route carries the same.
    func testSendNowWaitsForTheCapabilityAndTheQueueAndReportsTheCLIsAnswer() async throws {
        let directTransport = FakeClaudeTransport(), routedTransport = FakeClaudeTransport()
        let direct = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in directTransport })
        let routed = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in routedTransport }),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let workspace = URL(filePath: "/tmp/claude-send-now")
        for (adapter, transport) in [(direct as any HarnessFollowUpQueueing & HarnessAdapter, directTransport),
                                     (routed as any HarnessFollowUpQueueing & HarnessAdapter, routedTransport)] {
            let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: workspace, initialPrompt: nil))
            let log = FollowUpPayloadLog()
            let collector = Task { for await event in await adapter.events(for: handle) { await log.append(event.payload) } }
            defer { collector.cancel() }
            try await adapter.send("Run the tests", to: handle)
            let id = UUID().uuidString.lowercased()
            try await adapter.sendFollowUp(HarnessUserInput(text: "Use Python instead"), messageID: id, priority: .next, to: handle)

            // Before the CLI said it reads Send now, it is not asked.
            let early = await adapter.canSendFollowUpNow(in: handle)
            XCTAssertFalse(early)
            do {
                _ = try await adapter.sendFollowUpNow(messageID: id, in: handle)
                XCTFail("Asked a CLI that did not advertise Send now")
            } catch HarnessAdapterError.capabilityUnavailable {}
            await transport.emit(try json(SendNowFrames.initFrame))
            try await waitUntil { await adapter.canSendFollowUpNow(in: handle) }

            // Pressed before the CLI reported it queued: the request waits for that report.
            await transport.setInterruptResponse(try json(SendNowFrames.receipt(id)))
            let press = Task { try await adapter.sendFollowUpNow(messageID: id, in: handle) }
            try await Task.sleep(for: .milliseconds(100))
            let waiting = await transport.requestSubtypes.filter { $0 == "interrupt" }
            XCTAssertTrue(waiting.isEmpty)
            await transport.emit(try json(SendNowFrames.lifecycle(id, "queued")))
            let outcome = try await press.value
            XCTAssertEqual(outcome, .delivering)
            let request = await transport.requestedValues.last { $0["request"]?["subtype"]?.stringValue == "interrupt" }
            XCTAssertEqual(request?["request"], .object([
                "subtype": .string("interrupt"), "send_now": .bool(true), "message_uuid": .string(id)
            ]))

            // The CLI's other answers come back as they are.
            await transport.setInterruptResponse(.object(["still_queued": .array([]), "send_now": .string("stopped")]))
            let stopped = try await adapter.sendFollowUpNow(messageID: id, in: handle)
            XCTAssertEqual(stopped, .stopped)
            await transport.setInterruptResponse(.object(["still_queued": .array([])]))
            let unreported = try await adapter.sendFollowUpNow(messageID: id, in: handle)
            XCTAssertNil(unreported)

            // Once it took the message, there is nothing to press.
            await transport.emit(try json(SendNowFrames.lifecycle(id, "started")))
            try await waitFor(log) {
                $0.contains(.followUpDelivery(.init(messageID: id, state: .read, joinsRunningTurn: true)))
            }
            let taken = try await adapter.sendFollowUpNow(messageID: id, in: handle)
            XCTAssertEqual(taken, .nothingWaiting)
            let presses = await transport.requestSubtypes.filter { $0 == "interrupt" }
            XCTAssertEqual(presses.count, 3)
            await adapter.close(handle)
        }
    }

    func testWithdrawingAFollowUpAsksTheCLIAndItsOwnCancelledFrameIsNotADrop() async throws {
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport })
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/workspace"), initialPrompt: nil))
        let log = FollowUpPayloadLog()
        let collector = Task { for await event in await adapter.events(for: handle) { await log.append(event.payload) } }
        defer { collector.cancel() }
        try await adapter.send("Run the tests", to: handle)

        let id = UUID().uuidString.lowercased()
        try await adapter.sendFollowUp(HarnessUserInput(text: "Never mind"), messageID: id, priority: .next, to: handle)
        await transport.emit(try json(lifecycleFrame(id, "queued")))
        // The CLI reports the cancellation before it answers the request.
        await transport.holdCancelAsyncMessage()
        let cancel = Task { try await adapter.cancelFollowUp(messageID: id, in: handle) }
        try await waitUntil { await transport.hasHeldCancel }
        await transport.emit(try json(lifecycleFrame(id, "cancelled")))
        await transport.emit(try json(assistantText("Still working")))
        try await waitFor(log) { $0.contains(.assistantMessageCompleted("Still working")) }
        await transport.answerHeldCancel()
        let cancelled = try await cancel.value
        XCTAssertTrue(cancelled)
        let request = await transport.requestedValues.last { $0["request"]?["subtype"]?.stringValue == "cancel_async_message" }
        XCTAssertEqual(request?["request"]?["message_uuid"]?.stringValue, id)
        let afterCancel = await log.payloads
        XCTAssertFalse(afterCancel.contains { if case .followUpDelivery = $0 { true } else { false } })

        // Withdrawn, it is no longer the CLI's to cancel.
        let again = try await adapter.cancelFollowUp(messageID: id, in: handle)
        XCTAssertFalse(again)
        let cancelRequests = await transport.requestSubtypes.filter { $0 == "cancel_async_message" }
        XCTAssertEqual(cancelRequests.count, 1)

        // One the CLI already took cannot be withdrawn; one it refuses is let go.
        await transport.setCancelsAsyncMessage(false)
        let taken = UUID().uuidString.lowercased()
        try await adapter.sendFollowUp(HarnessUserInput(text: "Also lint"), messageID: taken, priority: .next, to: handle)
        let withdrawn = try await adapter.cancelFollowUp(messageID: taken, in: handle)
        XCTAssertFalse(withdrawn)
        await transport.emit(try json(lifecycleFrame(taken, "refused")))
        try await waitFor(log) { $0.contains(.followUpDelivery(.init(messageID: taken, state: .dropped))) }
        await adapter.close(handle)
    }

    func testACLIThatReportsNoLifecycleHasReadItsFollowUpsByTheTurnsEnd() async throws {
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport })
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/workspace"), initialPrompt: nil))
        let log = FollowUpPayloadLog()
        let collector = Task { for await event in await adapter.events(for: handle) { await log.append(event.payload) } }
        defer { collector.cancel() }
        try await adapter.send("Run the tests", to: handle)
        let first = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased()
        for id in [first, second] {
            try await adapter.sendFollowUp(HarnessUserInput(text: id), messageID: id, priority: .next, to: handle)
        }
        await transport.emit(try json(result))
        try await waitForTurnEnd(log)
        let payloads = await log.payloads
        let reads = payloads.enumerated().filter { if case .followUpDelivery = $0.element { true } else { false } }
        XCTAssertEqual(reads.map(\.element), [
            .followUpDelivery(.init(messageID: first, state: .read)),
            .followUpDelivery(.init(messageID: second, state: .read))
        ])
        XCTAssertLessThan(try XCTUnwrap(reads.last?.offset),
                          try XCTUnwrap(payloads.lastIndex(of: .sessionStatusChanged(.ready))),
                          "Read before the task is idle, so the queue's next send does not wait for them")

        // The turn such a CLI then starts by itself may be theirs, which they already opened; the next
        // one it starts by itself, its answer to a background task's notice, opens a turn of its own.
        for frame in [assistantText("Both done."), result, assistantText("The build finished."), result] {
            await transport.emit(try json(frame))
        }
        try await waitFor(log) { $0.filter { $0 == .sessionStatusChanged(.ready) }.count == 4 }
        let later = Array(await log.payloads.dropFirst(payloads.count))
        XCTAssertEqual(later.filter { $0 == .providerStartedTurn(messageID: nil) }.count, 1, "\(later)")
        let opened = try XCTUnwrap(later.firstIndex(of: .providerStartedTurn(messageID: nil)))
        XCTAssertLessThan(try XCTUnwrap(later.firstIndex(of: .assistantMessageCompleted("Both done."))), opened)
        XCTAssertLessThan(opened, try XCTUnwrap(later.firstIndex(of: .assistantMessageCompleted("The build finished."))))
        await adapter.close(handle)
    }

    func testTheProductRouteCarriesFollowUpsAndWhatBecameOfThemUnchanged() async throws {
        let directTransport = FakeClaudeTransport(), routedTransport = FakeClaudeTransport()
        let localID = UUID()
        let direct = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in directTransport })
        let routed = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in routedTransport }),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let workspace = URL(filePath: "/tmp/claude-yhp-follow-ups")
        let directHandle = try await direct.createSession(.init(localSessionID: localID, workspaceURL: workspace, initialPrompt: nil))
        let routedHandle = try await routed.createSession(.init(localSessionID: localID, workspaceURL: workspace, initialPrompt: nil))
        let directLog = FollowUpPayloadLog(), routedLog = FollowUpPayloadLog()
        let collectors = [
            Task { for await event in await direct.events(for: directHandle) { await directLog.append(event.payload) } },
            Task { for await event in await routed.events(for: routedHandle) { await routedLog.append(event.payload) } }
        ]
        defer { collectors.forEach { $0.cancel() } }
        try await direct.send("go", to: directHandle)
        try await routed.send("go", to: routedHandle)
        let read = UUID().uuidString.lowercased(), refused = UUID().uuidString.lowercased()
        let withdrawn = UUID().uuidString.lowercased()
        for (adapter, handle) in [(direct as any HarnessFollowUpQueueing, directHandle),
                                  (routed as any HarnessFollowUpQueueing, routedHandle)] {
            for id in [read, refused, withdrawn] {
                try await adapter.sendFollowUp(HarnessUserInput(text: id), messageID: id, priority: .next, to: handle)
            }
            let cancelled = try await adapter.cancelFollowUp(messageID: withdrawn, in: handle)
            XCTAssertTrue(cancelled)
        }
        for frame in [lifecycleFrame(read, "started"), lifecycleFrame(refused, "discarded"), result] {
            await directTransport.emit(try json(frame))
            await routedTransport.emit(try json(frame))
        }
        for log in [directLog, routedLog] {
            try await waitForTurnEnd(log)
        }
        let deliveries = { (payloads: [HarnessEventPayload]) in
            payloads.filter { if case .followUpDelivery = $0 { true } else { false } }
        }
        let directDeliveries = deliveries(await directLog.payloads)
        let routedDeliveries = deliveries(await routedLog.payloads)
        XCTAssertEqual(directDeliveries, [
            .followUpDelivery(.init(messageID: read, state: .read, joinsRunningTurn: true)),
            .followUpDelivery(.init(messageID: refused, state: .dropped))
        ])
        XCTAssertEqual(routedDeliveries, directDeliveries)
        for transport in [directTransport, routedTransport] {
            let written = await transport.sentValues.dropFirst()
            XCTAssertEqual(written.map { $0["message"]?["content"]?.stringValue }, [read, refused, withdrawn])
            XCTAssertEqual(written.map { $0["uuid"]?.stringValue }, [read, refused, withdrawn])
            XCTAssertEqual(written.map { $0["priority"]?.stringValue }, ["next", "next", "next"])
            let cancels = await transport.requestedValues.filter {
                $0["request"]?["subtype"]?.stringValue == "cancel_async_message"
            }
            XCTAssertEqual(cancels.map { $0["request"]?["message_uuid"]?.stringValue }, [withdrawn])
        }
        await direct.close(directHandle)
        await routed.close(routedHandle)
    }

    // MARK: - Frames

    private func lifecycleFrame(_ id: String, _ state: String) -> String {
        #"{"type":"command_lifecycle","command_uuid":"\#(id)","state":"\#(state)","#
            + #""uuid":"\#(UUID().uuidString.lowercased())","session_id":"\#(sessionID)"}"#
    }

    private var toolUse: String {
        #"""
        {"type":"assistant","parent_tool_use_id":null,"session_id":"8d0c6b8e-3c9f-4d5e-9a63-0f3b8f1f2a10",
          "message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"Bash",
            "input":{"command":"npm test"}}]}}
        """#
    }

    private var toolResult: String {
        #"""
        {"type":"user","parent_tool_use_id":null,"session_id":"8d0c6b8e-3c9f-4d5e-9a63-0f3b8f1f2a10",
          "message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01","content":"2 failing"}]}}
        """#
    }

    private func assistantText(_ text: String) -> String {
        #"{"type":"assistant","parent_tool_use_id":null,"session_id":"\#(sessionID)","#
            + #""message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private var result: String {
        #"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"8d0c6b8e-3c9f-4d5e-9a63-0f3b8f1f2a10"}"#
    }

    // MARK: - Helpers

    private func line(_ value: JSONValue) throws -> String {
        String(decoding: try codec.encodeLine(value).dropLast(), as: UTF8.self)
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// The ready status a result sets, after the one attaching set.
    private func waitForTurnEnd(_ log: FollowUpPayloadLog) async throws {
        try await waitFor(log) { $0.filter { $0 == .sessionStatusChanged(.ready) }.count == 2 }
    }

    private func waitFor(
        _ log: FollowUpPayloadLog,
        _ condition: @escaping ([HarnessEventPayload]) -> Bool
    ) async throws {
        try await waitUntil { condition(await log.payloads) }
    }
}

private actor FollowUpPayloadLog {
    private(set) var payloads: [HarnessEventPayload] = []
    func append(_ payload: HarnessEventPayload) { payloads.append(payload) }
}
