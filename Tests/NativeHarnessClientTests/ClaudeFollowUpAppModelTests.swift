import Foundation
import XCTest
@testable import NativeHarnessClient

/// Messages sent while a Claude turn runs, through the app model on the product route: they show
/// as queued until Claude Code reads them, follow the shared follow-up setting, can be sent at
/// once, removed or edited, and an interrupt holds them until Resume. The CLI is a fake transport
/// speaking 2.1.291's frames; no model is asked anything.
@MainActor final class ClaudeFollowUpAppModelTests: XCTestCase {
    func testTheReadyReportFromAttachingDoesNotEndTheFirstTurn() async throws {
        let fixture = try await makeFixture()
        // Both the attach report and the turn's running report have been applied by now.
        try await waitUntil {
            fixture.model.eventsBySessionID[fixture.task.id]?.contains { $0.payload == .sessionStatusChanged(.ready) } == true
        }
        XCTAssertEqual(fixture.model.store.sessions.first?.status, .running)
    }

    /// Return while Claude runs writes the message to read at the turn's next step; Claude Code
    /// holds it until then and the turn goes on.
    func testAMessageSentWhileClaudeRunsStaysQueuedUntilClaudeReadsItAtItsNextStep() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model, task = fixture.task, transport = fixture.transport
        await transport.emit(try json(toolUse))
        try await waitUntil { self.lines(model, task).count == 2 }

        await model.send(HarnessUserInput(text: "Use Python instead"), to: task)
        let queued = model.followUps.queue(for: task.id)
        XCTAssertEqual(queued.map(\.state), [.sent])
        XCTAssertEqual(lines(model, task), ["user: Run the tests", "activity: toolu_01"], "Not a sent bubble yet")
        let written = try await lastSent(transport)
        XCTAssertEqual(written["message"]?["content"]?.stringValue, "Use Python instead")
        XCTAssertEqual(written["priority"]?.stringValue, "next", "Read at the turn's next step")
        let messageID = try XCTUnwrap(written["uuid"]?.stringValue)
        XCTAssertEqual(queued.first?.providerMessageID, messageID)
        XCTAssertEqual(model.store.sessions.first?.status, .running)

        for frame in [lifecycle(messageID, "queued"), toolResult, lifecycle(messageID, "started"),
                      assistantText("Switching to Python."), lifecycle(messageID, "completed"), result] {
            await transport.emit(try json(frame))
        }
        try await waitUntil { model.store.sessions.first?.status == .ready }
        XCTAssertEqual(lines(model, task), [
            "user: Run the tests", "activity: toolu_01", "user: Use Python instead", "assistant: Switching to Python."
        ])
        // Read into the running turn, which the conversation keeps it in (D13).
        let entries = model.transcriptBySessionID[task.id] ?? []
        XCTAssertEqual(entries.filter { if case .user = $0.content { true } else { false } }.map(\.joinsRunningTurn),
                       [nil, true])
        XCTAssertTrue(model.followUps.queue(for: task.id).isEmpty)
        XCTAssertTrue(fixture.queueRepository.load(for: task.id).isEmpty)
    }

    func testQueuedMessagesWaitInYardletAndEachStartsTheNextTurnInOrder() async throws {
        let fixture = try await makeFixture(followUps: .queue)
        let model = fixture.model, task = fixture.task, transport = fixture.transport
        await model.send(HarnessUserInput(text: "Then update the README"), to: task)
        await model.send(HarnessUserInput(text: "And bump the version"), to: task)
        let queued = model.followUps.queue(for: task.id)
        XCTAssertEqual(queued.map(\.state), [.pending, .pending])
        let sentBefore = await transport.sentValues.count
        XCTAssertEqual(sentBefore, 1, "Nothing reaches Claude Code while the turn runs")
        XCTAssertEqual(fixture.queueRepository.load(for: task.id).map(\.draft.text),
                       ["Then update the README", "And bump the version"])

        model.moveQueued(queued[1].id, in: task, to: 0)
        await transport.emit(try json(result))
        try await waitUntil { await transport.sentValues.count == 2 }
        let next = try await lastSent(transport)
        XCTAssertEqual(next["message"]?["content"]?.stringValue, "And bump the version")
        XCTAssertNil(next["uuid"], "A turn of its own, sent as any message to an idle task")
        XCTAssertNil(next["priority"])
        try await waitUntil { self.lines(model, task).last == "user: And bump the version" }
        XCTAssertEqual(model.followUps.queue(for: task.id).map(\.draft.text), ["Then update the README"])
        XCTAssertEqual(model.store.sessions.first?.status, .running)

        await transport.emit(try json(result))
        try await waitUntil { await transport.sentValues.count == 3 }
        try await waitUntil { model.followUps.queue(for: task.id).isEmpty }
        XCTAssertEqual(lines(model, task).filter { $0.hasPrefix("user: ") }, [
            "user: Run the tests", "user: And bump the version", "user: Then update the README"
        ])
    }

    func testASentMessageCanBeSentAtOnceRemovedOrEditedBeforeClaudeReadsIt() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model, task = fixture.task, transport = fixture.transport

        // Stop and send: out of the CLI's queue, then again to stop the turn and be read now.
        await model.send(HarnessUserInput(text: "Use Python instead"), to: task)
        let first = try XCTUnwrap(model.followUps.queue(for: task.id).first)
        let firstID = try XCTUnwrap(first.providerMessageID)
        await model.stopAndSendQueued(first.id, for: task)
        let cancelledFirst = await cancelledIDs(transport)
        XCTAssertEqual(cancelledFirst, [firstID])
        let resent = try await lastSent(transport)
        XCTAssertEqual(resent["message"]?["content"]?.stringValue, "Use Python instead")
        XCTAssertEqual(resent["priority"]?.stringValue, "now")
        let nowID = try XCTUnwrap(resent["uuid"]?.stringValue)
        XCTAssertNotEqual(nowID, firstID, "The CLI drops a second message with an ID it has seen")
        XCTAssertEqual(model.followUps.queue(for: task.id).map(\.providerMessageID), [nowID])

        // Remove from queue: withdrawn from the CLI and gone.
        await model.send(HarnessUserInput(text: "Also add a test"), to: task)
        let second = try XCTUnwrap(model.followUps.queue(for: task.id).last)
        await model.removeQueued(second.id, for: task)
        let cancelledSecond = await cancelledIDs(transport)
        XCTAssertEqual(cancelledSecond, [firstID, try XCTUnwrap(second.providerMessageID)])
        XCTAssertEqual(model.followUps.queue(for: task.id).map(\.id), [first.id])

        // One the CLI already took stays until its bubble appears.
        await transport.setCancelsAsyncMessage(false)
        await model.removeQueued(first.id, for: task)
        XCTAssertEqual(model.followUps.queue(for: task.id).map(\.state), [.sent])
        await transport.emit(try json(lifecycle(nowID, "started")))
        try await waitUntil { model.followUps.queue(for: task.id).isEmpty }
        XCTAssertEqual(lines(model, task).last, "user: Use Python instead")

        // Edit: back in the composer once withdrawn.
        await transport.setCancelsAsyncMessage(true)
        await model.send(HarnessUserInput(text: "Rename the module"), to: task)
        let third = try XCTUnwrap(model.followUps.queue(for: task.id).first)
        XCTAssertNil(model.editQueued(third.id, for: task), "It arrives once the CLI lets it go")
        let composer = model.composerDrafts.tasks.draft(for: task.id)
        try await waitUntil { composer.text == "Rename the module" }
        XCTAssertTrue(model.followUps.queue(for: task.id).isEmpty)
        let cancelledThird = await cancelledIDs(transport)
        XCTAssertEqual(cancelledThird.last, third.providerMessageID)

        // A held message never replaces a draft already in the composer.
        await model.submitFollowUp(HarnessUserInput(text: "Later"), action: .queue, to: task)
        let held = try XCTUnwrap(model.followUps.queue(for: task.id).first)
        XCTAssertNil(model.editQueued(held.id, for: task))
        XCTAssertEqual(composer.text, "Rename the module")
        XCTAssertEqual(model.followUps.queue(for: task.id).map(\.id), [held.id])
        composer.clear()
        XCTAssertEqual(model.editQueued(held.id, for: task)?.text, "Later")
        XCTAssertEqual(composer.text, "Later")
    }

    /// Send now with a CLI that does not advertise `interrupt_send_now_v1` (this fixture's sends no
    /// `system/init`): the message is withdrawn and written again with `priority: "now"`. The frames
    /// are a real 2.1.291 run of that path (before Yardlet used Send now and stamped `origin`): the
    /// CLI let the command finish, ended that turn without answering it (`terminal_reason:
    /// "aborted_tools"`, before the message's `started`), then answered the message. The turn's end
    /// does not send anything else meanwhile, and the bubble lands before the answer.
    func testStopAndSendWhileAToolRunsEndsThatTurnAtTheToolResultInTheRecordedOrder() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model, task = fixture.task, transport = fixture.transport
        await transport.emit(try json(toolUse))
        try await waitUntil { self.lines(model, task).count == 2 }
        await model.send(HarnessUserInput(text: "Stop what you are doing and reply with exactly NOW_OK."), to: task)
        let item = try XCTUnwrap(model.followUps.queue(for: task.id).first)
        let heldID = try XCTUnwrap(item.providerMessageID)
        await model.stopAndSendQueued(item.id, for: task)
        let nowID = try XCTUnwrap(model.followUps.queue(for: task.id).first?.providerMessageID)
        XCTAssertNotEqual(nowID, heldID)

        for frame in [lifecycle(heldID, "queued"), lifecycle(heldID, "cancelled"), lifecycle(nowID, "queued"), toolResult,
                      #"{"type":"result","subtype":"success","is_error":false,"result":"","stop_reason":"tool_use","terminal_reason":"aborted_tools","num_turns":2,"result_index":0,"session_id":"s"}"#] {
            await transport.emit(try json(frame))
        }
        try await waitUntil { model.store.sessions.first?.status == .ready }
        XCTAssertEqual(model.followUps.queue(for: task.id).map(\.state), [.sent], "Still Claude Code's until it is read")
        for frame in [lifecycle(nowID, "started"), assistantText("NOW_OK"),
                      #"{"type":"result","subtype":"success","is_error":false,"result":"NOW_OK","stop_reason":"end_turn","terminal_reason":"completed","num_turns":1,"result_index":1,"user_message_uuid":"\#(nowID)","session_id":"s"}"#,
                      lifecycle(nowID, "completed")] {
            await transport.emit(try json(frame))
        }
        try await waitUntil { self.lines(model, task).last == "assistant: NOW_OK" && model.store.sessions.first?.status == .ready }
        XCTAssertEqual(lines(model, task), [
            "user: Run the tests", "activity: toolu_01", "user: Stop what you are doing and reply with exactly NOW_OK.",
            "assistant: NOW_OK"
        ])
        // The stopped turn ended before Claude read it, so it starts a turn of its own (D13).
        XCTAssertEqual((model.transcriptBySessionID[task.id] ?? []).compactMap { entry -> Bool? in
            if case .user = entry.content { return entry.joinsRunningTurn ?? false }
            return nil
        }, [false, false])
        XCTAssertTrue(model.followUps.queue(for: task.id).isEmpty)
        XCTAssertNil(model.errorBySessionID[task.id])
        let sent = await transport.sentValues
        XCTAssertEqual(sent.map { $0["priority"]?.stringValue }, [nil, "next", "now"], "The turn's end sent nothing else")
    }

    /// Return while Claude runs never stops the turn (2026-10-16: a message sent while Claude wrote
    /// its answer cut the answer off), even with a CLI that advertises `interrupt_send_now_v1` (the
    /// recorded 2.1.291 run's frames, `SendNowFrames`): the message is written for the next step
    /// (`next`, a person's message) and nothing is pressed; the chip's send leaves it so too. Only
    /// Stop and send presses `interrupt{send_now:true,message_uuid}`, keeping its uuid; nothing is
    /// withdrawn or written again. The CLI moves the running command to the background, the turn
    /// reads the message after the command's "moved to the background" result and answers it. The
    /// command's card stays running in the background through the turn's end, not stopped, and its
    /// later completion, with the turn the CLI starts for it, reaches the same card.
    func testReturnWhileACommandRunsWritesTheMessageForTheNextStepAndOnlyStopAndSendPressesIt() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model, task = fixture.task, transport = fixture.transport
        for frame in [SendNowFrames.initFrame, SendNowFrames.toolUse, SendNowFrames.taskStarted] {
            await transport.emit(try json(frame))
        }
        try await waitUntil { self.lines(model, task).count == 2 }
        await model.send(HarnessUserInput(text: SendNowFrames.text), to: task)
        let written = try await lastSent(transport)
        XCTAssertEqual(written["priority"]?.stringValue, "next")
        XCTAssertEqual(written["origin"]?["kind"]?.stringValue, "human", "A person's message, which the CLI may deliver early")
        let messageID = try XCTUnwrap(written["uuid"]?.stringValue)
        await transport.setInterruptResponse(try json(SendNowFrames.receipt(messageID)))
        await transport.emit(try json(SendNowFrames.lifecycle(messageID, "queued")))
        let item = try XCTUnwrap(model.followUps.queue(for: task.id).first)
        XCTAssertEqual(item.providerMessageID, messageID)
        XCTAssertEqual(item.state, .sent)
        try await Task.sleep(for: .milliseconds(150))
        var pressed = await transport.requestedValues.filter { $0["request"]?["subtype"]?.stringValue == "interrupt" }
        XCTAssertTrue(pressed.isEmpty, "Return does not stop the turn")
        await model.sendQueuedNow(item.id, for: task)
        pressed = await transport.requestedValues.filter { $0["request"]?["subtype"]?.stringValue == "interrupt" }
        XCTAssertTrue(pressed.isEmpty, "Nor does the chip's send of a message Claude already reads at its next step")

        let pressNow = JSONValue.object([
            "subtype": .string("interrupt"), "send_now": .bool(true), "message_uuid": .string(messageID)
        ])
        await model.stopAndSendQueued(item.id, for: task)
        pressed = await transport.requestedValues.filter { $0["request"]?["subtype"]?.stringValue == "interrupt" }
        XCTAssertEqual(pressed.map { $0["request"] ?? .null }, [pressNow], "Stop and send, and only it")
        let cancelled = await cancelledIDs(transport)
        XCTAssertTrue(cancelled.isEmpty, "Not withdrawn")
        let sent = await transport.sentValues
        XCTAssertEqual(sent.count, 2, "Not written again")
        XCTAssertEqual(model.followUps.queue(for: task.id).map(\.providerMessageID), [messageID], "Claude's until it reads it")

        for frame in [SendNowFrames.backgroundTasksChanged, SendNowFrames.backgrounded, SendNowFrames.movedResult,
                      SendNowFrames.lifecycle(messageID, "started"), SendNowFrames.answer,
                      SendNowFrames.lifecycle(messageID, "completed"), SendNowFrames.turnResult(messageID)] {
            await transport.emit(try json(frame))
        }
        let card = "activity: \(SendNowFrames.toolUseID)"
        try await waitUntil { self.lines(model, task).last == "assistant: NOW_OK" && model.store.sessions.first?.status == .ready }
        XCTAssertEqual(lines(model, task), ["user: Run the tests", card, "user: \(SendNowFrames.text)", "assistant: NOW_OK"])
        XCTAssertEqual(bashCard(model, task)?.state, .running, "In the background, not stopped")
        XCTAssertEqual(bashCard(model, task)?.activity.isBackground, true)
        XCTAssertEqual(bashCard(model, task)?.activity.output, SendNowFrames.movedOutput)
        XCTAssertTrue(model.followUps.queue(for: task.id).isEmpty)

        for frame in [SendNowFrames.backgroundTasksEmptied, SendNowFrames.taskCompleted, SendNowFrames.notification,
                      SendNowFrames.initFrame, SendNowFrames.notificationAnswer] {
            await transport.emit(try json(frame))
        }
        // The CLI answers the finished command in a turn of its own, which runs like any other. It sends
        // no lifecycle frame and no request for it, so the turn opens with the answer, and NOW_OK stays
        // the answer of the turn before (2026-10-24).
        try await waitUntil { model.store.sessions.first?.status == .running }
        await transport.emit(try json(SendNowFrames.notificationTurnResult))
        let notified = "assistant: \(SendNowFrames.notificationAnswerText)"
        try await waitUntil { self.lines(model, task).last == notified && model.store.sessions.first?.status == .ready }
        XCTAssertEqual(lines(model, task), ["user: Run the tests", card, "user: \(SendNowFrames.text)", "assistant: NOW_OK",
                                            "turn Claude Code started: ", notified])
        XCTAssertEqual(bashCard(model, task)?.state, .completed, "The same card, completed")
        XCTAssertEqual(bashCard(model, task)?.activity.output, SendNowFrames.notificationSummary)
        XCTAssertNil(model.errorBySessionID[task.id])
    }

    /// Send now on a message Yardlet still holds while the turn runs: it is written to Claude Code
    /// (`next`, a person's message) and pressed only once the CLI reports it queued, since a Send now
    /// on a message the CLI is still admitting finds nothing to deliver.
    func testStopAndSendOnAMessageYardletHoldsWritesItAndPressesItOnceClaudeQueuedIt() async throws {
        let fixture = try await makeFixture(followUps: .queue)
        let model = fixture.model, task = fixture.task, transport = fixture.transport
        for frame in [SendNowFrames.initFrame, SendNowFrames.toolUse, SendNowFrames.taskStarted] {
            await transport.emit(try json(frame))
        }
        try await waitUntil { self.lines(model, task).count == 2 }
        await model.send(HarnessUserInput(text: SendNowFrames.text), to: task)
        let item = try XCTUnwrap(model.followUps.queue(for: task.id).first)
        XCTAssertEqual(item.state, .pending)

        let press = Task { await model.stopAndSendQueued(item.id, for: task) }
        try await waitUntil { await transport.sentValues.count == 2 }
        let written = try await lastSent(transport)
        XCTAssertEqual(written["priority"]?.stringValue, "next")
        XCTAssertEqual(written["origin"]?["kind"]?.stringValue, "human")
        let messageID = try XCTUnwrap(written["uuid"]?.stringValue)
        await transport.setInterruptResponse(try json(SendNowFrames.receipt(messageID)))
        try await Task.sleep(for: .milliseconds(150))
        var interrupts = await transport.requestSubtypes.filter { $0 == "interrupt" }
        XCTAssertTrue(interrupts.isEmpty, "Not before the CLI has it in its queue")
        await transport.emit(try json(SendNowFrames.lifecycle(messageID, "queued")))
        await press.value
        interrupts = await transport.requestSubtypes.filter { $0 == "interrupt" }
        XCTAssertEqual(interrupts.count, 1)
        let request = await transport.requestedValues.last { $0["request"]?["subtype"]?.stringValue == "interrupt" }
        XCTAssertEqual(request?["request"]?["message_uuid"]?.stringValue, messageID)
        XCTAssertEqual(request?["request"]?["send_now"], .bool(true))
        XCTAssertEqual(model.followUps.queue(for: task.id).map(\.state), [.sent])

        for frame in [SendNowFrames.backgroundTasksChanged, SendNowFrames.backgrounded, SendNowFrames.movedResult,
                      SendNowFrames.lifecycle(messageID, "started"), SendNowFrames.answer,
                      SendNowFrames.lifecycle(messageID, "completed"), SendNowFrames.turnResult(messageID)] {
            await transport.emit(try json(frame))
        }
        try await waitUntil { self.lines(model, task).last == "assistant: NOW_OK" && model.store.sessions.first?.status == .ready }
        XCTAssertEqual(lines(model, task), [
            "user: Run the tests", "activity: \(SendNowFrames.toolUseID)", "user: \(SendNowFrames.text)", "assistant: NOW_OK"
        ])
        XCTAssertEqual(bashCard(model, task)?.state, .running)
        XCTAssertTrue(model.followUps.queue(for: task.id).isEmpty)
    }

    /// Return while Claude writes its final answer (2026-10-16: the answer stopped mid-stream): the
    /// message is written for the next step and nothing is pressed, so the answer streams to its
    /// end; the CLI then reads the message in a turn of its own and the answer stays whole.
    func testReturnWhileClaudeWritesItsAnswerLeavesTheAnswerWhole() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model, task = fixture.task, transport = fixture.transport
        func delta(_ text: String) -> String {
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}}"#
        }
        for frame in [SendNowFrames.initFrame,
                      #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_final","role":"assistant","content":[]}}}"#,
                      delta("All three checks "), delta("passed, and ")] {
            await transport.emit(try json(frame))
        }
        try await waitUntil { self.lines(model, task).last == "assistant: All three checks passed, and " }

        await model.send(HarnessUserInput(text: "Also update the changelog"), to: task)
        let written = try await lastSent(transport)
        XCTAssertEqual(written["priority"]?.stringValue, "next", "Read once the answer ends, not now")
        let messageID = try XCTUnwrap(written["uuid"]?.stringValue)
        await transport.setInterruptResponse(try json(SendNowFrames.receipt(messageID)))
        await transport.emit(try json(lifecycle(messageID, "queued")))
        try await Task.sleep(for: .milliseconds(150))
        let interrupts = await transport.requestSubtypes.filter { $0 == "interrupt" }
        XCTAssertTrue(interrupts.isEmpty, "Nothing stops the turn")

        for frame in [delta("the build is green."), assistantText("All three checks passed, and the build is green."),
                      result, lifecycle(messageID, "started"), assistantText("Updated the changelog."),
                      lifecycle(messageID, "completed"), result] {
            await transport.emit(try json(frame))
        }
        try await waitUntil { self.lines(model, task).last == "assistant: Updated the changelog." }
        XCTAssertEqual(lines(model, task), [
            "user: Run the tests", "assistant: All three checks passed, and the build is green.",
            "user: Also update the changelog", "assistant: Updated the changelog."
        ])
        XCTAssertNil(model.errorBySessionID[task.id])
    }

    func testInterruptingTakesBackWhatClaudeHoldsAndPausesTheQueueUntilResume() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model, task = fixture.task, transport = fixture.transport
        await model.send(HarnessUserInput(text: "Use Python instead"), to: task)
        await model.submitFollowUp(HarnessUserInput(text: "Then update the README"), action: .queue, to: task)
        let steeredID = try XCTUnwrap(model.followUps.queue(for: task.id).first?.providerMessageID)
        XCTAssertEqual(model.followUps.queue(for: task.id).map(\.state), [.sent, .pending])

        await model.interrupt(task)
        let subtypes = await transport.requestSubtypes.filter { $0 == "cancel_async_message" || $0 == "interrupt" }
        XCTAssertEqual(subtypes, ["cancel_async_message", "interrupt"], "Taken back before the turn stops")
        let cancelledOnInterrupt = await cancelledIDs(transport)
        XCTAssertEqual(cancelledOnInterrupt, [steeredID])
        XCTAssertEqual(model.followUps.queue(for: task.id).map(\.state), [.pending, .pending])
        XCTAssertTrue(model.followUps.queue(for: task.id).allSatisfy { $0.providerMessageID == nil })
        XCTAssertTrue(model.followUps.isPaused(task.id))
        XCTAssertTrue(fixture.queueRepository.isPaused(for: task.id))

        await transport.emit(try json(interruptedResult))
        try await waitUntil { model.store.sessions.first?.status == .ready }
        try await Task.sleep(for: .milliseconds(150))
        let whilePaused = await transport.sentValues.count
        XCTAssertEqual(whilePaused, 2, "The paused queue sends nothing when the turn ends")

        model.resumeQueue(for: task)
        XCTAssertFalse(model.followUps.isPaused(task.id))
        try await waitUntil { await transport.sentValues.count == 3 }
        let resumed = try await lastSent(transport)
        XCTAssertEqual(resumed["message"]?["content"]?.stringValue, "Use Python instead")
        XCTAssertNil(resumed["uuid"])
        try await waitUntil { self.lines(model, task).last == "user: Use Python instead" }
        XCTAssertEqual(model.followUps.queue(for: task.id).map(\.draft.text), ["Then update the README"])

        await transport.emit(try json(result))
        try await waitUntil { model.followUps.queue(for: task.id).isEmpty }
        let last = try await lastSent(transport)
        XCTAssertEqual(last["message"]?["content"]?.stringValue, "Then update the README")
        XCTAssertFalse(fixture.queueRepository.isPaused(for: task.id))
    }

    func testAMessageClaudeCodeLetsGoUnreadStaysQueuedAsFailed() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model, task = fixture.task, transport = fixture.transport
        await model.send(HarnessUserInput(text: "Use Python instead"), to: task)
        let messageID = try XCTUnwrap(model.followUps.queue(for: task.id).first?.providerMessageID)
        await transport.emit(try json(lifecycle(messageID, "refused")))
        try await waitUntil { model.followUps.queue(for: task.id).first?.state == .failed }
        let item = try XCTUnwrap(model.followUps.queue(for: task.id).first)
        XCTAssertEqual(item.failureMessage, L10n.string("Claude Code did not take this message."))
        XCTAssertNil(item.providerMessageID)
        XCTAssertFalse(lines(model, task).contains("user: Use Python instead"))

        model.retryQueued(item.id, for: task)
        XCTAssertEqual(model.followUps.queue(for: task.id).map(\.state), [.pending], "Waits for the running turn")
    }

    func testWithoutARunningTurnAMessageIsSentAsAlwaysAndARestoredQueueIsHeldByYardlet() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model, task = fixture.task, transport = fixture.transport
        await transport.emit(try json(result))
        try await waitUntil { model.store.sessions.first?.status == .ready }
        await model.send(HarnessUserInput(text: "Next request"), to: task)
        let written = try await lastSent(transport)
        XCTAssertNil(written["uuid"])
        XCTAssertNil(written["priority"])
        XCTAssertEqual(lines(model, task).last, "user: Next request")
        XCTAssertTrue(model.followUps.queue(for: task.id).isEmpty)

        // What the CLI held when Yardlet quit went with it unread; the next launch holds it again.
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("ClaudeFollowUps.Restore")))
        let repository = UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue.")
        let saved = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/claude-follow-up-restore"),
                                  runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Restored")
        repository.save([
            CodexQueuedSubmission(draft: CodexComposerDraft(inputs: [.text("held by the CLI")]), state: .sent,
                                  providerMessageID: UUID().uuidString.lowercased()),
            CodexQueuedSubmission(draft: CodexComposerDraft(inputs: [.text("held by Yardlet")]))
        ], for: saved.id)
        repository.setPaused(true, for: saved.id)
        let restored = AppModel(
            store: SessionStore(repository: InMemorySessionRepository(sessions: [saved])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            codexQueueRepository: repository,
            preferences: defaults
        )
        await restored.restoreIndex()
        let session = try XCTUnwrap(restored.store.sessions.first)
        XCTAssertEqual(restored.followUps.queue(for: session.id).map(\.state), [.pending, .pending])
        XCTAssertTrue(restored.followUps.queue(for: session.id).allSatisfy { $0.providerMessageID == nil })
        XCTAssertTrue(restored.followUps.isPaused(session.id))
        XCTAssertEqual(restored.followUps.queue(for: session.id).map(\.draft.text), ["held by the CLI", "held by Yardlet"],
                       "One queue per task, in its saved order")
        await restored.shutdown()
    }

    /// A message another task sent waits in the queue too, out of the person's rows. An interrupt's
    /// pause holds it only while one of the person's messages waits with it: once the person has
    /// sent or removed each of theirs, it goes as after Resume, and no Resume row is left over an
    /// empty list (2026-11-02).
    func testThePausePassesWithThePersonsLastMessageAndWhatAnotherTaskSentGoesNext() async throws {
        for ending in ["send", "remove"] {
            let fixture = try await makeFixture()
            let model = fixture.model, task = fixture.task, transport = fixture.transport
            await model.send(HarnessUserInput(text: "Use Python instead"), to: task)
            _ = await model.deliverTaskMessage(
                TaskMessage(senderID: UUID().uuidString, senderName: "Child", body: "Tests pass"), to: task)
            await model.send(HarnessUserInput(text: "Then update the README"), to: task)
            await model.interrupt(task)
            await transport.emit(try json(interruptedResult))
            try await waitUntil { model.store.sessions.first?.status == .ready }
            let persons = model.followUps.queue(for: task.id).filter { !$0.isFromAnotherTask }
            XCTAssertEqual(persons.map(\.draft.text), ["Use Python instead", "Then update the README"])
            XCTAssertEqual(model.followUps.queue(for: task.id).count, 3)
            XCTAssertTrue(model.followUps.isPaused(task.id))
            let sentAtStop = await transport.sentValues.count

            await model.sendQueuedNow(persons[0].id, for: try XCTUnwrap(model.store.sessions.first))
            await transport.emit(try json(result))
            try await waitUntil { model.store.sessions.first?.status == .ready }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(model.followUps.isPaused(task.id), "One of the person's still waits: \(ending)")
            let sentWhilePaused = await transport.sentValues.count
            XCTAssertEqual(sentWhilePaused, sentAtStop + 1, "Only the person's message went")

            let current = try XCTUnwrap(model.store.sessions.first)
            if ending == "send" {
                await model.sendQueuedNow(persons[1].id, for: current)
            } else {
                await model.removeQueued(persons[1].id, for: current)
            }
            XCTAssertFalse(model.followUps.isPaused(task.id), ending)
            XCTAssertFalse(fixture.queueRepository.isPaused(for: task.id), ending)
            XCTAssertEqual(model.followUps.queue(for: task.id).map(\.isFromAnotherTask), [true], ending)
            if ending == "send" {
                // The person's message runs first; the other task's goes when that turn ends.
                let sent = try await lastSent(transport)
                XCTAssertEqual(sent["message"]?["content"]?.stringValue, "Then update the README")
                await transport.emit(try json(result))
            }
            try await waitUntil { model.followUps.queue(for: task.id).isEmpty }
            let last = try await lastSent(transport)
            XCTAssertNotNil(TaskMessage.parse(last["message"]?["content"]?.stringValue ?? ""), ending)
        }
    }

    /// A message another task sends while the person's own message is still starting the task's
    /// runtime waits for that runtime and goes into it. It neither starts a second one for the same
    /// conversation nor fails with "already attached" (2026-11-11).
    func testAMessageArrivingWhileTheRuntimeStartsWaitsForThatRuntime() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model, task = fixture.task
        await fixture.transport.emit(try json(result))
        try await waitUntil { model.store.sessions.first?.status == .ready }
        await model.closeIdleRuntime(of: task.id)
        XCTAssertNil(model.handlesBySessionID[task.id])

        fixture.transports.holdNextHandshakes()
        let persons = Task { await model.send(HarnessUserInput(text: "Next request"), to: task) }
        try await waitUntil {
            guard fixture.transports.all.count == 2 else { return false }
            return await fixture.transports.all[1].hasHeldInitialize
        }
        let current = try XCTUnwrap(model.store.sessions.first)
        let delivery = Task {
            await model.deliverTaskMessage(
                TaskMessage(senderID: UUID().uuidString, senderName: "Schedule", body: "Reddit answered 403"),
                to: current)
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fixture.transports.all.count, 2, "No second runtime while the first starts")
        XCTAssertNil(model.errorBySessionID[task.id])

        let restarted = fixture.transports.all[1]
        await restarted.answerHeldInitialize()
        await persons.value
        let outcome = await delivery.value
        XCTAssertEqual(fixture.transports.all.count, 2)
        XCTAssertNil(model.errorBySessionID[task.id], "No error card")
        if case let .undelivered(reason) = outcome { XCTFail(reason) }
        let sent = await restarted.sentValues.compactMap { $0["message"]?["content"]?.stringValue }
        XCTAssertEqual(sent.count, 2, "Both messages reach the one runtime: \(sent)")
        XCTAssertTrue(sent.contains("Next request"), "\(sent)")
        XCTAssertTrue(sent.contains { TaskMessage.parse($0) != nil }, "\(sent)")
    }

    // MARK: - Fixture

    private struct Fixture {
        let model: AppModel
        let task: SessionRecord
        let transport: FakeClaudeTransport
        let transports: TransportLog
        let queueRepository: UserDefaultsCodexQueueRepository
    }

    private final class TransportLog: @unchecked Sendable {
        private let lock = NSLock()
        private var transports: [FakeClaudeTransport] = []
        private var holdsInitialize = false
        func make() -> FakeClaudeTransport {
            lock.withLock {
                let transport = FakeClaudeTransport(holdsInitialize: holdsInitialize)
                transports.append(transport)
                return transport
            }
        }
        var all: [FakeClaudeTransport] { lock.withLock { transports } }
        /// Runtimes started from now on wait in their handshake until it is answered.
        func holdNextHandshakes() { lock.withLock { holdsInitialize = true } }
    }

    /// A Claude task on the product route whose first turn is running.
    private func makeFixture(followUps mode: CodexFollowUpMode? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "claude-follow-ups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cli = root.appending(path: "claude-fixture")
        try Data("""
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo '2.1.291 (Claude Code)'; exit 0; fi

        """.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("ClaudeFollowUps")))
        if let mode { defaults.set(mode.rawValue, forKey: CodexFollowUpMode.preferenceKey) }
        let queueRepository = UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue.")
        let transports = TransportLog()
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, url in
                YHPProviderCompatibilityAdapter(
                    adapter: ClaudeAdapter(executableURL: url, transportFactory: { _ in transports.make() }),
                    manifest: HarnessProtocolCompatibilityManifest.claude()
                )
            },
            codexQueueRepository: queueRepository,
            preferences: defaults,
            restoresIndexOnLaunch: false
        )
        addTeardownBlock { await model.shutdown() }
        let created = await model.createSession(harness: .claudeCode, workspaceURL: root,
                                                runtimeExecutableURL: cli, title: "Follow-ups")
        let task = try XCTUnwrap(created, model.errorBySessionID.values.first ?? "Missing task")
        let transport = try XCTUnwrap(transports.all.first)
        await model.send(HarnessUserInput(text: "Run the tests"), to: task)
        // Attaching reported the task ready; that report can land after the send marked it running,
        // so wait for the turn's own running report.
        try await waitUntil {
            model.eventsBySessionID[task.id]?.contains { $0.payload == .sessionStatusChanged(.running) } == true
                && model.store.sessions.first?.status == .running
        }
        return Fixture(model: model, task: try XCTUnwrap(model.store.sessions.first), transport: transport,
                       transports: transports, queueRepository: queueRepository)
    }

    private func lines(_ model: AppModel, _ task: SessionRecord) -> [String] {
        (model.transcriptBySessionID[task.id] ?? []).compactMap { entry in
            switch entry.content {
            case let .user(text, _) where entry.origin == .provider: "turn Claude Code started: \(text)"
            case let .user(text, _): "user: \(text)"
            case let .assistant(text, _): "assistant: \(text)"
            case let .activity(activity, _): "activity: \(activity.id)"
            default: nil
            }
        }
    }

    private func bashCard(_ model: AppModel, _ task: SessionRecord) -> (activity: HarnessActivity, state: TranscriptActivityState)? {
        (model.transcriptBySessionID[task.id] ?? []).lazy.compactMap { entry -> (HarnessActivity, TranscriptActivityState)? in
            if case let .activity(activity, state) = entry.content, activity.id == SendNowFrames.toolUseID { (activity, state) } else { nil }
        }.first
    }

    private func lastSent(_ transport: FakeClaudeTransport) async throws -> JSONValue {
        let values = await transport.sentValues
        return try XCTUnwrap(values.last)
    }

    private func cancelledIDs(_ transport: FakeClaudeTransport) async -> [String] {
        await transport.requestedValues
            .filter { $0["request"]?["subtype"]?.stringValue == "cancel_async_message" }
            .compactMap { $0["request"]?["message_uuid"]?.stringValue }
    }

    // MARK: - Frames (2.1.291)

    private func lifecycle(_ id: String, _ state: String) -> String {
        #"{"type":"command_lifecycle","command_uuid":"\#(id)","state":"\#(state)","uuid":"\#(UUID().uuidString)","session_id":"s"}"#
    }

    private var toolUse: String {
        #"""
        {"type":"assistant","parent_tool_use_id":null,"session_id":"s","message":{"role":"assistant",
          "content":[{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"npm test"}}]}}
        """#
    }

    private var toolResult: String {
        #"""
        {"type":"user","parent_tool_use_id":null,"session_id":"s","message":{"role":"user",
          "content":[{"type":"tool_result","tool_use_id":"toolu_01","content":"2 failing"}]}}
        """#
    }

    private func assistantText(_ text: String) -> String {
        #"{"type":"assistant","parent_tool_use_id":null,"session_id":"s","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private var result: String {
        #"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s"}"#
    }

    private var interruptedResult: String {
        #"{"type":"result","subtype":"success","is_error":false,"result":"","terminal_reason":"aborted_streaming","session_id":"s"}"#
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}
