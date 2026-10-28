import Foundation
import XCTest
@testable import NativeHarnessClient

/// Explicit opt-in: real Claude Code and Codex turns through the product model, for the features
/// that were first checked only against fake transports (Claude follow-ups and bash mode, the
/// context ring and the kept permission mode, Codex steer, queue pause, slash commands, the title
/// turn, the stopped-turn wording and live command output).
///
/// `NHC_LIVE_PARITY=1 NHC_LIVE_PARITY_WORKSPACE=<throwaway project>` runs them. The CLIs run only in
/// that folder, on the accounts they are already signed in to (`NHC_LIVE_CLAUDE_CONFIG_DIR` picks a
/// Claude config folder; Codex uses its default home). Yardlet's index, drafts and preferences are a
/// private temporary folder and suite; no credentials are read or copied. Every frame on the wire is
/// written, with account fields removed, to `.build/live-parity/<test>.jsonl`.
@MainActor
final class RealModelParityLiveTests: XCTestCase {
    private var savedDirectory: String?

    override func tearDown() async throws {
        if let savedDirectory { FileManager.default.changeCurrentDirectoryPath(savedDirectory) }
        try await super.tearDown()
    }

    // MARK: Claude Code

    /// A message sent while Claude runs a tool is written with `priority: "next"`; one withdrawn
    /// before the CLI takes it is cancelled, the other is read after the tool result and its bubble
    /// lands between the tool and the answer. A withdrawal after the CLI took it is refused.
    func testClaudeFollowUpFoldsInAfterTheToolResultAndWithdrawalRaces() async throws {
        let rig = try await LiveRig.make(for: .claudeCode, name: #function, test: self)
        let model = rig.model
        do {
            let session = try await rig.createClaudeTask()
            let started = Date()
            await model.send("Use the Bash tool to run exactly `sleep 10 && echo done`. After it finishes, reply with one short sentence. Do not use any other tool.", to: session)
            try await rig.waitForClaudeCommandToRun(in: session)
            try await Task.sleep(for: .seconds(1))

            // A: withdrawn while the tool still runs.
            await model.send("Ignore this message, it is a test: WITHDRAWN_A", to: try rig.current(session))
            let first = try XCTUnwrap(model.followUps.queue(for: session.id).last, "The follow-up is queued, not a bubble")
            XCTAssertEqual(first.state, .sent)
            let firstID = try XCTUnwrap(first.providerMessageID)
            await model.removeQueued(first.id, for: try rig.current(session))
            XCTAssertFalse(model.followUps.queue(for: session.id).contains { $0.id == first.id })

            // B: read at the turn's next step.
            await model.send("Also end your reply with the word FOLDED_B.", to: try rig.current(session))
            let second = try XCTUnwrap(model.followUps.queue(for: session.id).last)
            let secondID = try XCTUnwrap(second.providerMessageID)
            try await rig.waitUntil("B taken into the turn", timeout: 60) {
                await rig.log.claudeLifecycle(secondID).contains("started")
            }
            // Withdrawing it now goes straight to the CLI, which already has it.
            let late = try await rig.claudeTransport(for: session).rawRequest(
                ClaudeProtocol.cancelAsyncMessage(id: "live-late-cancel", messageUUID: secondID), id: "live-late-cancel")
            try await rig.waitForClaudeTurnEnd(session, timeout: 120)

            let entries = model.transcriptBySessionID[session.id] ?? []
            let lines = LiveRig.lines(entries)
            print("NHC_LIVE_TRANSCRIPT \(lines)")
            let bash = try XCTUnwrap(entries.lastIndex { if case .activity = $0.content { true } else { false } })
            let bubble = try XCTUnwrap(entries.lastIndex { if case let .user(text, _) = $0.content { text.contains("FOLDED_B") } else { false } })
            let answer = try XCTUnwrap(entries.lastIndex { if case .assistant = $0.content { true } else { false } })
            XCTAssertLessThan(bash, bubble, "The bubble is placed after the tool")
            XCTAssertLessThan(bubble, answer, "and before the answer it changed")
            XCTAssertFalse(lines.contains { $0.contains("WITHDRAWN_A") })
            XCTAssertTrue(model.followUps.queue(for: session.id).isEmpty)

            let firstLifecycle = await rig.log.claudeLifecycle(firstID)
            let secondLifecycle = await rig.log.claudeLifecycle(secondID)
            let cancelAnswers = await rig.log.claudeControlAnswers(subtype: "cancel_async_message")
            print("NHC_LIVE_FINDING lifecycle.A=\(firstLifecycle) lifecycle.B=\(secondLifecycle)")
            print("NHC_LIVE_FINDING cancel.answers=\(cancelAnswers) late=\(LiveRig.json(late))")
            XCTAssertEqual(cancelAnswers.first?["cancelled"], .bool(true), "Withdrawn before the CLI took it")
            XCTAssertEqual(late["cancelled"], .bool(false), "Refused once the CLI took it")
            XCTAssertTrue(secondLifecycle.contains("started"))

            // The context ring reads the CLI's own numbers after the turn.
            try await rig.waitUntil("context usage", timeout: 20) {
                model.providerUsageBySessionID[session.id]?.contextUsedTokens ?? 0 > 0
            }
            let usage = try XCTUnwrap(model.providerUsageBySessionID[session.id])
            print("NHC_LIVE_FINDING context=\(usage.contextUsedTokens ?? 0)/\(usage.contextWindowTokens ?? 0) elapsed=\(Int(Date().timeIntervalSince(started)))s")
            XCTAssertGreaterThan(usage.contextWindowTokens ?? 0, usage.contextUsedTokens ?? 0)
            await rig.finish(session)
        } catch {
            await rig.finish(nil); throw error
        }
    }

    /// Send now while a foreground Bash command runs, on a message Yardlet still held: Yardlet writes
    /// it (`priority: "next"`, `origin: {kind: "human"}`), and once the CLI reports it queued asks
    /// for it now with `interrupt{send_now: true, message_uuid}` (`interrupt_send_now_v1`). The CLI
    /// moves the command to the background instead of stopping it, the running turn reads the
    /// message within seconds, and the command's later completion reaches the same card. Records
    /// the receipt, the lifecycle, the task frames and the turn results.
    func testClaudeSendNowMovesTheRunningCommandToTheBackground() async throws {
        let rig = try await LiveRig.make(for: .claudeCode, name: #function, test: self)
        let model = rig.model
        do {
            let session = try await rig.createClaudeTask()
            await model.send("Use the Bash tool to run exactly `sleep 20 && echo done` in the foreground. Do not use any other tool.", to: session)
            try await rig.waitForClaudeCommandToRun(in: session)
            try await Task.sleep(for: .seconds(1))
            await model.submitFollowUp(HarnessUserInput(text: "Reply with exactly NOW_OK right away. Do not wait for the command."),
                                             action: .queue, to: try rig.current(session))
            let item = try XCTUnwrap(model.followUps.queue(for: session.id).last)
            XCTAssertEqual(item.state, .pending, "Yardlet holds it")
            let pressedAt = Date()
            await model.sendQueuedNow(item.id, for: try rig.current(session))
            let sentFrames = await rig.log.claudeSentUserFrames()
            let messageID = try XCTUnwrap(sentFrames.last?["uuid"]?.stringValue)
            try await rig.waitUntil("the message read", timeout: 15) {
                await rig.log.claudeLifecycle(messageID).contains("started")
            }
            let readAfter = Date().timeIntervalSince(pressedAt)
            try await rig.waitUntil("the turn's answer", timeout: 60) {
                (try? rig.current(session).status) == .ready
                    && (model.transcriptBySessionID[session.id] ?? []).contains { entry in
                        if case let .assistant(_, streaming) = entry.content { !streaming } else { false }
                    }
            }
            let answeredAfter = Date().timeIntervalSince(pressedAt)
            let atTurnEnd = model.transcriptBySessionID[session.id] ?? []
            print("NHC_LIVE_TRANSCRIPT turnEnd \(LiveRig.lines(atTurnEnd))")
            let bashAtTurnEnd = try XCTUnwrap(LiveRig.activity(kind: "Bash", in: atTurnEnd))

            // The command keeps running in the background and ends about 20 s after it started; the
            // CLI then reports it and starts a turn of its own to tell the model.
            try await rig.waitUntil("the background command's end", timeout: 60) {
                await rig.log.claudeFrames(type: "system").contains { $0["subtype"]?.stringValue == "task_notification" }
            }
            try await rig.waitUntil("the CLI's own turn", timeout: 60) {
                await rig.log.claudeFrames(type: "result").count >= 2 && (try? rig.current(session).status) == .ready
            }
            let entries = model.transcriptBySessionID[session.id] ?? []
            print("NHC_LIVE_TRANSCRIPT final \(LiveRig.lines(entries))")
            let receipts = await rig.log.claudeControlAnswers(subtype: "interrupt")
            let lifecycle = await rig.log.claudeLifecycle(messageID)
            let written = await rig.log.claudeSentUserFrames().last
            print("NHC_LIVE_FINDING sendNow.receipt=\(receipts.map(LiveRig.json)) read=\(String(format: "%.1f", readAfter))s answered=\(String(format: "%.1f", answeredAfter))s lifecycle=\(lifecycle)")
            print("NHC_LIVE_FINDING written=\(written.map(LiveRig.json) ?? "-")")
            for frame in await rig.log.claudeFrames(type: "system") where (frame["subtype"]?.stringValue ?? "").hasPrefix("task_") {
                print("NHC_LIVE_FINDING task=\(LiveRig.json(frame))")
            }
            for frame in await rig.log.claudeFrames(type: "user") {
                for block in frame["message"]?["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "tool_result" {
                    print("NHC_LIVE_FINDING toolResult=\(LiveRig.json(block)) typed=\(LiveRig.json(frame["tool_use_result"] ?? .null))")
                }
            }
            for result in await rig.log.claudeFrames(type: "result") { print("NHC_LIVE_FINDING result=\(LiveRig.json(LiveRig.resultShape(result)))") }

            XCTAssertEqual(receipts.first?["send_now"]?.stringValue, "delivering", "The command was moved, not stopped")
            XCTAssertEqual(written?["origin"]?["kind"]?.stringValue, "human")
            XCTAssertEqual(written?["priority"]?.stringValue, "next")
            XCTAssertLessThan(readAfter, 5, "Read within seconds, not after the 20 s command")
            XCTAssertLessThan(answeredAfter, 18, "Answered before the command would have ended")
            XCTAssertEqual(bashAtTurnEnd.state, .running, "In the background, not stopped, when the turn ended")
            XCTAssertEqual(bashAtTurnEnd.activity.isBackground, true)
            let bash = try XCTUnwrap(LiveRig.activity(kind: "Bash", in: entries))
            XCTAssertEqual(bash.state, .completed, "Its later completion reaches the same card")
            XCTAssertEqual(entries.filter { if case let .activity(activity, _) = $0.content { activity.kind == "Bash" } else { false } }.count, 1)
            let card = try XCTUnwrap(entries.firstIndex { if case let .activity(activity, _) = $0.content { activity.kind == "Bash" } else { false } })
            let bubble = try XCTUnwrap(entries.firstIndex { if case let .user(text, _) = $0.content { text.contains("NOW_OK") } else { false } })
            let answer = try XCTUnwrap(entries.firstIndex { if case .assistant = $0.content { true } else { false } })
            XCTAssertLessThan(card, bubble)
            XCTAssertLessThan(bubble, answer)
            XCTAssertTrue(model.followUps.queue(for: session.id).isEmpty)
            XCTAssertNil(model.errorBySessionID[session.id])
            await rig.finish(session)
        } catch {
            await rig.finish(nil); throw error
        }
    }

    /// Bash mode runs a command in the task's folder and sends it as one `<bash-input>` message,
    /// which Claude answers. The kept permission mode and the context ring survive a restart, and
    /// the reloaded history shows the command as one row.
    func testClaudeBashModeHistoryContextAndModeOnResume() async throws {
        let rig = try await LiveRig.make(for: .claudeCode, name: #function, test: self)
        var model = rig.model
        do {
            let session = try await rig.createClaudeTask()
            model.runShellCommand("echo yardlet-bash-$((6*7)) && pwd", in: session)
            try await rig.waitUntil("the command and Claude's answer", timeout: 120) {
                let entries = model.transcriptBySessionID[session.id] ?? []
                guard let bash = entries.firstIndex(where: { if case let .user(text, _) = $0.content {
                    ClaudeBashMessage.parse(text)?.hasOutput == true } else { false } }) else { return false }
                return entries[(bash + 1)...].contains { if case let .assistant(text, streaming) = $0.content {
                    !streaming && !text.isEmpty } else { false } } && (try? rig.current(session).status) == .ready
            }
            let sent = await rig.log.claudeSentUserTexts()
            let bashMessage = try XCTUnwrap(sent.first { $0.contains("<bash-input>") })
            print("NHC_LIVE_FINDING bash.sent=\(LiveRig.json(.string(bashMessage)))")
            XCTAssertTrue(bashMessage.contains("<bash-stdout>"))
            XCTAssertTrue(bashMessage.contains("yardlet-bash-42"))
            let answer = (model.transcriptBySessionID[session.id] ?? []).compactMap { entry -> String? in
                if case let .assistant(text, _) = entry.content { text } else { nil }
            }.joined(separator: "\n")
            print("NHC_LIVE_FINDING bash.answer=\(LiveRig.json(.string(answer)))")
            // Claude answers about the output in its own words (the recorded run read the `pwd` line).
            XCTAssertFalse(answer.isEmpty)

            try await rig.waitUntil("context usage", timeout: 20) {
                model.providerUsageBySessionID[session.id]?.contextUsedTokens ?? 0 > 0
            }
            await model.setProviderOption("permissionMode", value: "acceptEdits", for: try rig.current(session))
            XCTAssertEqual(try rig.current(session).providerOptions["permissionMode"], "acceptEdits")
            let providerID = try XCTUnwrap(try rig.current(session).providerSessionID)
            await model.shutdown()

            // The history Claude Code wrote, read as the conversation reloads it.
            let reader = ClaudeSubagentTranscriptReader(configDirectory: ClaudeSubagentTranscriptReader.configDirectory(
                connection: nil, workspaceURL: rig.workspace))
            let history = try XCTUnwrap(try reader.readConversation(sessionID: providerID)).entries
            let historyLines = LiveRig.lines(history)
            print("NHC_LIVE_TRANSCRIPT history=\(historyLines)")
            let bashRows = history.filter { if case let .user(text, _) = $0.content { text.contains("bash-") } else { false } }
            XCTAssertEqual(bashRows.count, 1, "One row for the command and its output")
            if case let .user(text, _)? = bashRows.first?.content {
                XCTAssertEqual(ClaudeBashMessage.parse(text)?.command, "echo yardlet-bash-$((6*7)) && pwd")
                XCTAssertTrue(ClaudeBashMessage.parse(text)?.output.contains("yardlet-bash-42") == true)
            }

            // A second launch of the app: resume reloads the history and restarts in the kept mode.
            model = try await rig.relaunch()
            let saved = try XCTUnwrap(model.store.sessions.first { $0.id == session.id })
            await model.resume(saved)
            let resumedTransport = try XCTUnwrap(rig.transports.claude(session.id).last)
            let recordedLaunch = await resumedTransport.launch
            let launch = try XCTUnwrap(recordedLaunch)
            print("NHC_LIVE_FINDING resume.launch=\(ClaudeProcessTransport.arguments(for: launch).joined(separator: " "))")
            XCTAssertTrue(launch.resumesExistingSession)
            XCTAssertEqual(launch.permissionMode, "acceptEdits")
            await model.loadProviderCapabilities(for: saved)
            XCTAssertEqual(model.providerCapabilitiesBySessionID[session.id]?.selectors
                .first { $0.id == "permissionMode" }?.currentValue, "acceptEdits")
            let reloaded = model.transcriptBySessionID[session.id] ?? []
            print("NHC_LIVE_TRANSCRIPT reloaded=\(LiveRig.lines(reloaded))")
            XCTAssertEqual(reloaded.filter { if case let .user(text, _) = $0.content { text.contains("bash-") } else { false } }.count, 1)
            try await rig.waitUntil("context usage after resume", timeout: 20) {
                model.providerUsageBySessionID[session.id]?.contextUsedTokens ?? 0 > 0
            }
            let modeFrames = await rig.log.claudePermissionModeAnnouncements()
            print("NHC_LIVE_FINDING resume.context=\(model.providerUsageBySessionID[session.id]?.contextUsedTokens ?? 0) announced=\(modeFrames)")
            await rig.finish(saved)
        } catch {
            await rig.finish(nil); throw error
        }
    }

    // MARK: Codex

    /// A follow-up during a running turn steers it (`turn/steer`) and lands in the same turn; the
    /// command's output streams in before it ends; the first request names the thread through the
    /// side title turn. Then, with the queue setting, an interrupt holds the queued message until
    /// Resume, and the stopped turn reads "You stopped after N seconds".
    func testCodexSteerTitleLiveOutputInterruptAndQueuePause() async throws {
        let rig = try await LiveRig.make(for: .codex, name: #function, test: self)
        let model = rig.model
        do {
            let session = try await rig.createCodexTask(runLocation: .readOnly, provisionalTitle: "Yardlet live parity")
            await model.send("Run this exact shell command once: `for i in 1 2 3 4 5; do echo tick$i; sleep 2; done`. When it has finished, reply with one short sentence.", to: session)
            try await rig.waitUntil("command running", timeout: 90) { rig.runningCommand(in: session) != nil }
            // What the running command's card holds before the command ends.
            let observed = LiveObservation()
            let observer = Task { @MainActor in
                while !Task.isCancelled {
                    if let output = rig.runningCommand(in: session)?.aggregatedOutput, !output.isEmpty,
                       observed.values.last != output { observed.values.append(output) }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            await model.send("When you reply, end with the word STEERED_OK.", to: try rig.current(session))
            let turn = try await rig.completedCodexTurn(session, count: 1, timeout: 120)
            observer.cancel()
            let liveOutputs = observed.values
            let steers = await rig.log.codexRequests("turn/steer")
            print("NHC_LIVE_FINDING steer=\(steers.map(LiveRig.json)) live.outputs=\(liveOutputs.map { LiveRig.json(.string($0)) })")
            XCTAssertEqual(steers.count, 1)
            XCTAssertEqual(steers.first?["expectedTurnId"]?.stringValue, turn.id)
            XCTAssertEqual(turn.items.filter { if case .userMessage = $0.content { true } else { false } }.count, 2,
                           "The steered message is part of the same turn")
            XCTAssertTrue(LiveRig.agentText(turn).contains("STEERED_OK"))
            let deltas = await rig.log.codexNotificationCount("item/commandExecution/outputDelta")
            print("NHC_LIVE_FINDING outputDelta.count=\(deltas) items=\(turn.items.map(\.content.typeName))")
            XCTAssertGreaterThan(deltas, 0)
            // The card grows while the command runs. codex-cli 0.157.1 itself drops the first line
            // (`tick1`) of a `unifiedExecStartup` command, in its deltas and its aggregated output.
            XCTAssertGreaterThanOrEqual(liveOutputs.count, 2, "Output shows while the command runs")
            XCTAssertTrue(liveOutputs.last?.contains("tick") == true)

            // The side turn that names the thread.
            try await rig.waitUntil("thread name", timeout: 60) {
                !(model.codexPresentationBySessionID[session.id]?.thread?.name ?? "").isEmpty
            }
            let titleStarts = await rig.log.codexRequests("thread/start").filter { $0["ephemeral"] == .bool(true) }
            let titleTurns = await rig.log.codexRequests("turn/start").filter { $0["outputSchema"] != nil }
            let names = await rig.log.codexRequests("thread/name/set")
            let threadName = model.codexPresentationBySessionID[session.id]?.thread?.name ?? ""
            print("NHC_LIVE_FINDING title.thread=\(titleStarts.map(LiveRig.json)) title.name=\(LiveRig.json(.string(threadName))) set=\(names.map(LiveRig.json))")
            XCTAssertEqual(titleStarts.first?["sandbox"], .string("read-only"))
            XCTAssertEqual(titleStarts.first?["config"]?["model_reasoning_effort"], .string("low"))
            XCTAssertEqual(titleTurns.count, 1)
            try await rig.waitUntil("task title adopted", timeout: 30) {
                (try? rig.current(session))?.titleOrigin == .provider
            }
            XCTAssertEqual(try rig.current(session).title, threadName)

            // Queue, interrupt, pause, resume.
            rig.defaults.set(CodexFollowUpMode.queue.rawValue, forKey: CodexFollowUpMode.preferenceKey)
            await model.send("Run this exact shell command: `sleep 30`. Then reply DONE.", to: try rig.current(session))
            try await rig.waitUntil("second command running", timeout: 90) { rig.runningCommand(in: session) != nil }
            await model.send("Reply with exactly QUEUED_OK.", to: try rig.current(session))
            XCTAssertEqual(model.followUps.queue(for: session.id).map(\.state), [.pending])
            try await Task.sleep(for: .seconds(2))
            await model.interrupt(try rig.current(session))
            XCTAssertTrue(model.followUps.isPaused(session.id))
            let stopped = try await rig.completedCodexTurn(session, count: 2, timeout: 60, allowing: [.interrupted])
            XCTAssertEqual(stopped.status, .interrupted)
            let wording = CodexTurnProgressProjection.finishedTitle(status: stopped.status, duration:
                CodexTurnProgressProjection.completedDuration(durationMilliseconds: stopped.durationMilliseconds,
                    startedAt: stopped.startedAt, completedAt: stopped.completedAt))
            let interruptedFrame = await rig.log.codexNotifications("turn/completed").last
            print("NHC_LIVE_FINDING interrupted.wording=\(LiveRig.json(.string(wording))) durationMs=\(stopped.durationMilliseconds ?? -1) frame=\(LiveRig.json(interruptedFrame.map(LiveRig.turnShape) ?? .null))")
            let stoppedCommands = stopped.items.compactMap { item -> String? in
                if case let .commandExecution(command) = item.content { command.status } else { nil }
            }
            print("NHC_LIVE_FINDING interrupted.items=\(stopped.items.map(\.content.typeName)) commandStatus=\(stoppedCommands)")
            // The real frame carries `durationMs`, so the line reads as the Codex app's stopped turn.
            XCTAssertEqual(wording, L10n.format("You stopped after %lld seconds", Int64((stopped.durationMilliseconds ?? 0) / 1_000)))
            try await Task.sleep(for: .seconds(4))
            XCTAssertEqual(model.followUps.queue(for: session.id).count, 1, "Held until Resume")
            XCTAssertEqual(model.codexPresentationBySessionID[session.id]?.thread?.turns.count, 2)

            model.resumeQueue(for: try rig.current(session))
            let queued = try await rig.completedCodexTurn(session, count: 3, timeout: 90)
            XCTAssertTrue(LiveRig.agentText(queued).contains("QUEUED_OK"))
            XCTAssertTrue(model.followUps.queue(for: session.id).isEmpty)
            await rig.finish(try rig.current(session), archiveCodexThreads: true)
        } catch {
            await rig.finish(nil, archiveCodexThreads: true); throw error
        }
    }

    /// The Codex app's slash commands on a real thread: Plan mode reaches the next `turn/start`,
    /// compact, rename, fork, init (its AGENTS.md is removed again), archive and unarchive.
    func testCodexSlashCommandsOnARealThread() async throws {
        let rig = try await LiveRig.make(for: .codex, name: #function, test: self)
        let model = rig.model
        do {
            let session = try await rig.createCodexTask(runLocation: .readOnly, provisionalTitle: nil)
            await model.prepareCodexComposerCommands(for: try rig.current(session))
            let modes = model.codexCapabilitiesBySessionID[session.id]?.modes ?? []
            print("NHC_LIVE_FINDING modes=\(modes.map { "\($0.name)|\($0.mode)|\($0.model ?? "null")|\($0.reasoningEffort ?? "null")" })")
            XCTAssertEqual(Set(modes.map(\.mode)), ["plan", "default"])

            await model.runCodexComposerCommand(.planMode, in: try rig.current(session))
            var state = try XCTUnwrap(model.codexCapabilitiesBySessionID[session.id])
            XCTAssertEqual(state.modes.first { $0.id == state.selectedModeID }?.mode, "plan")
            await model.send("We are only planning. Propose a two-step plan to add a multiply(a, b) function to calc.py. Do not ask questions and do not edit any file.", to: try rig.current(session))
            let planned = try await rig.completedCodexTurn(session, count: 1, timeout: 120)
            let turnStarts = await rig.log.codexRequests("turn/start")
            let planStart = try XCTUnwrap(turnStarts.first { $0["outputSchema"] == nil })
            print("NHC_LIVE_FINDING plan.turnStart.collaborationMode=\(LiveRig.json(planStart["collaborationMode"] ?? .null)) items=\(planned.items.map(\.content.typeName))")
            XCTAssertEqual(planStart["collaborationMode"]?["mode"], .string("plan"))
            XCTAssertEqual(planStart["collaborationMode"]?["settings"]?["model"], .string(rig.codexModel))
            await model.runCodexComposerCommand(.planMode, in: try rig.current(session))
            state = try XCTUnwrap(model.codexCapabilitiesBySessionID[session.id])
            XCTAssertEqual(state.modes.first { $0.id == state.selectedModeID }?.mode, "default")

            await model.runCodexComposerCommand(.compact, in: try rig.current(session))
            let compacted = try await rig.completedCodexTurn(session, count: 2, timeout: 120)
            print("NHC_LIVE_FINDING compact.items=\(compacted.items.map(\.content.typeName)) notice=\(model.composerDrafts.tasks.draft(for: session.id).notice ?? "")")
            XCTAssertTrue(compacted.items.contains { if case .contextCompaction = $0.content { true } else { false } })

            await model.rename(try rig.current(session), to: "Yardlet live parity renamed")
            try await rig.waitUntil("thread renamed", timeout: 20) {
                model.codexPresentationBySessionID[session.id]?.thread?.name == "Yardlet live parity renamed"
            }
            let renamed = await rig.log.codexNotifications("thread/name/updated")
            print("NHC_LIVE_FINDING rename=\(renamed.map(LiveRig.json))")

            let before = Set(model.store.sessions.map(\.id))
            await model.runCodexComposerCommand(.fork, in: try rig.current(session))
            let fork = try XCTUnwrap(model.store.sessions.first { !before.contains($0.id) }, model.bootstrapError ?? "No fork")
            print("NHC_LIVE_FINDING fork.thread=\(fork.providerSessionID ?? "") from=\(try rig.current(session).providerSessionID ?? "")")
            XCTAssertNotEqual(fork.providerSessionID, try rig.current(session).providerSessionID)
            rig.createdCodexSessions.append(fork.id)

            let instructions = rig.workspace.appending(path: CodexInitPrompt.fileName)
            XCTAssertFalse(FileManager.default.fileExists(atPath: instructions.path))
            await model.selectCodexRunLocation(.workspaceWrite, for: try rig.current(session))
            await model.runCodexComposerCommand(.initialize, in: try rig.current(session))
            let initialized = try await rig.completedCodexTurn(session, count: 3, timeout: 240, acceptingFileChanges: [instructions])
            let wrote = FileManager.default.fileExists(atPath: instructions.path)
            print("NHC_LIVE_FINDING init.items=\(initialized.items.map(\.content.typeName)) wroteAgents=\(wrote)")
            XCTAssertTrue(wrote)
            try? FileManager.default.removeItem(at: instructions)

            await model.runCodexComposerCommand(.archive, in: try rig.current(session))
            XCTAssertFalse(model.store.sessions.contains { $0.id == session.id })
            await model.loadArchivedTasks()
            let archived = try XCTUnwrap(model.store.archivedSessions?.first { $0.id == session.id })
            XCTAssertTrue(archived.isProviderArchived)
            await model.unarchive(archived)
            XCTAssertNil(model.archivedTaskError)
            XCTAssertTrue(model.store.sessions.contains { $0.id == session.id })
            let archiveAnswers = await rig.log.codexResponses("thread/archive")
            let unarchiveAnswers = await rig.log.codexResponses("thread/unarchive")
            print("NHC_LIVE_FINDING archive=\(archiveAnswers.map(LiveRig.json)) unarchive=\(unarchiveAnswers.map(LiveRig.json))")
            await rig.finish(try rig.current(session), archiveCodexThreads: true)
        } catch {
            try? FileManager.default.removeItem(at: rig.workspace.appending(path: CodexInitPrompt.fileName))
            await rig.finish(nil, archiveCodexThreads: true); throw error
        }
    }
}

// MARK: - Rig

@MainActor
private final class LiveRig {
    let workspace: URL
    let root: URL
    let defaults: UserDefaults
    let log: LiveWireLog
    let transports: LiveTransports
    let binary: URL
    let harness: HarnessKind
    let name: String
    private var storedModel: AppModel?
    var model: AppModel { storedModel! }
    private let repository: SQLiteSessionRepository
    private let claudeConfigDirectory: String?
    var createdCodexSessions: [UUID] = []
    private(set) var codexModel = ""

    private init(harness: HarnessKind, name: String, workspace: URL, binary: URL, claudeConfigDirectory: String?) throws {
        self.harness = harness
        self.name = name
        self.workspace = workspace
        self.binary = binary
        self.claudeConfigDirectory = claudeConfigDirectory
        root = FileManager.default.temporaryDirectory.appending(path: "Yardlet.LiveParity.\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: testDefaultsSuite("Yardlet.LiveParity"))!
        log = LiveWireLog()
        transports = LiveTransports()
        repository = try SQLiteSessionRepository(databaseURL: root.appending(path: "index.sqlite3"))
        storedModel = makeModel(store: SessionStore(repository: repository))
    }

    static func make(for harness: HarnessKind, name: String, test: RealModelParityLiveTests) async throws -> LiveRig {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NHC_LIVE_PARITY"] == "1", let path = environment["NHC_LIVE_PARITY_WORKSPACE"] else {
            throw XCTSkip("Set NHC_LIVE_PARITY=1 and NHC_LIVE_PARITY_WORKSPACE=<throwaway project> for real model turns")
        }
        let workspace = URL(filePath: path, directoryHint: .isDirectory).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw XCTSkip("The live workspace does not exist")
        }
        // Started from inside a Claude Code session, the test inherits that host's variables, as
        // the app does at launch; they are dropped the same way.
        let configDirectory = environment["NHC_LIVE_CLAUDE_CONFIG_DIR"]
        HostSessionEnvironment.detachFromHostSession()
        if let configDirectory { setenv("CLAUDE_CONFIG_DIR", configDirectory, 1) }
        let binaryName = harness == .codex ? "codex" : "claude"
        let override = environment[harness == .codex ? "NHC_LIVE_CODEX_BINARY" : "NHC_LIVE_CLAUDE_BINARY"]
        guard let binary = override.map({ URL(filePath: $0) }) ?? Self.which(binaryName) else {
            throw XCTSkip("No \(binaryName) on PATH")
        }
        // The App Server inherits the working directory; keep every CLI in the live workspace.
        let rig = try LiveRig(harness: harness, name: name, workspace: workspace, binary: binary,
                              claudeConfigDirectory: configDirectory)
        test.setSavedDirectory(FileManager.default.currentDirectoryPath)
        FileManager.default.changeCurrentDirectoryPath(workspace.path)
        await rig.log.note("start \(name) workspace=\(workspace.path) binary=\(binary.path)")
        return rig
    }

    private static func which(_ name: String) -> URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return paths.map { URL(filePath: $0).appending(path: name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func makeModel(store: SessionStore) -> AppModel {
        let log = log, transports = transports
        let overrides = claudeConfigDirectory.map { ["CLAUDE_CONFIG_DIR": $0] } ?? [:]
        let registry = HarnessRegistry { kind, url in
            if kind == .codex {
                let transport = RecordingCodexTransport(inner: CodexProcessTransport(
                    executableURL: url, environmentManager: CodexEnvironmentManager(paths: .live()), environmentScope: .native
                ), log: log)
                transports.add(codex: transport)
                return YHPCodexCompatibilityAdapter(
                    adapter: CodexAdapter(executableURL: url, transport: transport, namesNewThreads: true),
                    manifest: HarnessProtocolCompatibilityManifest.codex())
            }
            return YHPProviderCompatibilityAdapter(
                adapter: ClaudeAdapter(executableURL: url, transportFactory: { localID in
                    let transport = RecordingClaudeTransport(
                        inner: ClaudeProcessTransport(executableURL: url, environmentOverrides: overrides), log: log)
                    transports.add(claude: transport, for: localID)
                    return transport
                }),
                manifest: HarnessProtocolCompatibilityManifest.claude())
        }
        return AppModel(store: store,
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: registry,
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
            preferences: defaults,
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            composerDraftRepository: FileComposerDraftRepository(directoryURL: root.appending(path: "drafts")),
            sessionTitleResolver: { _ in nil }, systemNotificationCenter: LiveQuietNotificationCenter(),
            restoresIndexOnLaunch: false)
    }

    /// The app launched again over the same index and preferences.
    func relaunch() async throws -> AppModel {
        let saved = try await repository.loadSessions()
        storedModel = makeModel(store: SessionStore(sessions: saved, repository: repository))
        return model
    }

    func current(_ session: SessionRecord) throws -> SessionRecord {
        try XCTUnwrap(model.store.sessions.first { $0.id == session.id }, "Task \(session.id) is gone")
    }

    // MARK: Claude

    func createClaudeTask() async throws -> SessionRecord {
        let created = await model.createSession(harness: .claudeCode, workspaceURL: workspace,
            runtimeExecutableURL: binary, title: "Yardlet live parity")
        let session = try XCTUnwrap(created, model.bootstrapError ?? "Claude task was not created")
        await model.loadProviderCapabilities(for: session)
        let choices = model.providerCapabilitiesBySessionID[session.id]?.selectors.first { $0.id == "model" }?.choices ?? []
        let cheap = ["haiku", "sonnet"].first { name in choices.contains { $0.value == name } }
            ?? choices.first { $0.value.localizedCaseInsensitiveContains("haiku") }?.value
        print("NHC_LIVE_FINDING claude.models=\(choices.map(\.value)) chosen=\(cheap ?? "default")")
        if let cheap { await model.setProviderOption("model", value: cheap, for: try current(session)) }
        await log.note("claude task \(session.id) provider=\(try current(session).providerSessionID ?? "") model=\(cheap ?? "default")")
        print("NHC_LIVE_SESSION claude local=\(session.id) provider=\(try current(session).providerSessionID ?? "")")
        return try current(session)
    }

    func claudeTransport(for session: SessionRecord) throws -> RecordingClaudeTransport {
        try XCTUnwrap(transports.claude(session.id).last)
    }

    /// Waits for the turn's Bash command to start (`system/task_started`), allowing it if Claude
    /// Code asks. The account's own settings may already allow it, as the developer account does.
    func waitForClaudeCommandToRun(in session: SessionRecord) async throws {
        let before = await log.claudeFrames(type: "system").filter { $0["subtype"]?.stringValue == "task_started" }.count
        try await waitUntil("the Bash command to start", timeout: 90) {
            if let pending = (self.model.transcriptBySessionID[session.id] ?? []).compactMap({ entry -> PermissionRequest? in
                if case let .permission(request, state) = entry.content, state == .pending { request } else { nil }
            }).last {
                await self.log.note("allow \(pending.id) \(pending.command ?? pending.title)")
                await self.model.respond(to: pending.id, decision: .allow, in: try self.current(session))
            }
            return await self.log.claudeFrames(type: "system").filter { $0["subtype"]?.stringValue == "task_started" }.count > before
        }
    }

    func waitForClaudeTurnEnd(_ session: SessionRecord, timeout: TimeInterval) async throws {
        try await waitUntil("Claude turn end", timeout: timeout) {
            let entries = self.model.transcriptBySessionID[session.id] ?? []
            guard (try? self.current(session).status) == .ready, case let .assistant(_, streaming)? = entries.last?.content else { return false }
            return !streaming && self.model.followUps.queue(for: session.id).isEmpty
        }
    }

    // MARK: Codex

    func createCodexTask(runLocation: CodexRunLocation, provisionalTitle: String?) async throws -> SessionRecord {
        let created = await model.createSession(harness: .codex, workspaceURL: workspace,
            runtimeExecutableURL: binary, title: provisionalTitle ?? "Yardlet live parity commands")
        let session = try XCTUnwrap(created, model.bootstrapError ?? "Codex task was not created")
        createdCodexSessions.append(session.id)
        if let provisionalTitle {
            // A task created from the home composer starts with a provisional title, which the
            // provider's name replaces.
            try await model.store.renameSession(id: session.id, title: provisionalTitle, titleOrigin: .provisional)
        }
        await model.loadCodexModels(for: try current(session))
        let catalog = try XCTUnwrap(model.codexCapabilitiesBySessionID[session.id]?.modelCatalog)
        let option = try XCTUnwrap(catalog.models.first { $0.model == CodexThreadTitle.preferredModel }
            ?? catalog.models.first { $0.model.localizedCaseInsensitiveContains("luna") }
            ?? catalog.models.first { $0.model.localizedCaseInsensitiveContains("mini") })
        let effort = option.supportedReasoningEfforts.contains("low") ? "low" : option.defaultReasoningEffort
        codexModel = option.model
        print("NHC_LIVE_FINDING codex.models=\(catalog.models.map(\.model)) chosen=\(option.model)/\(effort)")
        await model.selectCodexModel(.init(model: option.model, reasoningEffort: effort), for: try current(session))
        await model.selectCodexRunLocation(runLocation, for: try current(session))
        XCTAssertNil(model.errorBySessionID[session.id])
        print("NHC_LIVE_SESSION codex local=\(session.id) thread=\(try current(session).providerSessionID ?? "")")
        await log.note("codex task \(session.id) thread=\(try current(session).providerSessionID ?? "")")
        return try current(session)
    }

    func runningCommand(in session: SessionRecord) -> CodexCommandItem? {
        guard let turn = model.codexPresentationBySessionID[session.id]?.thread?.turns.last, turn.status == .inProgress else { return nil }
        return turn.items.compactMap { item -> CodexCommandItem? in
            if case let .commandExecution(command) = item.content, command.status == "inProgress" { command } else { nil }
        }.last
    }

    func completedCodexTurn(_ session: SessionRecord, count: Int, timeout: TimeInterval,
                            allowing statuses: [CodexTurnStatus] = [.completed],
                            acceptingFileChanges: [URL] = []) async throws -> CodexTurnState {
        var finished: CodexTurnState?
        try await waitUntil("Codex turn \(count)", timeout: timeout) {
            if let error = self.model.errorBySessionID[session.id] { throw HarnessAdapterError.invalidProviderEvent(error) }
            let state = self.model.codexPresentationBySessionID[session.id]
            for request in (state?.serverRequestsByID ?? [:]).values where request.resolution == .pending {
                await self.log.note("server request \(request.method) \(LiveRig.json(request.params ?? .null))")
                let paths = Self.paths(in: request.params ?? .null)
                guard request.kind == .fileChangeApproval, !paths.isEmpty,
                      paths.allSatisfy({ path in acceptingFileChanges.contains { $0.path == path } }) else {
                    throw HarnessAdapterError.invalidProviderEvent("Unexpected Codex request \(request.method)")
                }
                await self.model.respondCodex(to: request.id, response: .fileChange(.accept), in: try self.current(session))
            }
            guard let turns = state?.thread?.turns, turns.count == count, let last = turns.last, last.status.isTerminal,
                  (try? self.current(session).status) == .ready else { return false }
            guard statuses.contains(last.status) else {
                throw HarnessAdapterError.invalidProviderEvent("Codex turn ended \(last.status)")
            }
            finished = last
            return true
        }
        return try XCTUnwrap(finished)
    }

    private static func paths(in value: JSONValue) -> [String] {
        switch value {
        case let .object(object):
            return object.flatMap { key, value -> [String] in
                if key == "path", let path = value.stringValue { return [path] }
                return paths(in: value)
            }
        case let .array(values): return values.flatMap(paths(in:))
        default: return []
        }
    }

    static func agentText(_ turn: CodexTurnState) -> String {
        turn.items.compactMap { item -> String? in
            if case let .agentMessage(message) = item.content { message.text } else { nil }
        }.joined(separator: "\n")
    }

    // MARK: Waiting and reporting

    func waitUntil(_ what: String, timeout: TimeInterval, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        await log.note("timed out waiting for \(what)")
        throw HarnessAdapterError.invalidProviderEvent("Timed out waiting for \(what)")
    }

    /// Ends the test's provider work: archives the Codex threads it created when asked, closes the
    /// runtimes and writes the wire log.
    func finish(_ session: SessionRecord?, archiveCodexThreads: Bool = false) async {
        if archiveCodexThreads {
            for id in createdCodexSessions {
                guard let record = model.store.sessions.first(where: { $0.id == id }) else { continue }
                if !model.isAttached(id) { await model.resume(record) }
                if let attached = model.store.sessions.first(where: { $0.id == id }) { await model.archive(attached) }
                print("NHC_LIVE_SESSION archived codex thread=\(record.providerSessionID ?? "") ok=\(!model.store.sessions.contains { $0.id == id })")
            }
        }
        await model.shutdown()
        let output = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".build/live-parity")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let file = output.appending(path: name.replacingOccurrences(of: "()", with: "") + ".jsonl")
        await log.write(to: file)
        print("NHC_LIVE_LOG \(file.path)")
        try? FileManager.default.removeItem(at: root)
    }

    static func lines(_ entries: [TranscriptEntry]) -> [String] {
        entries.map { entry in
            switch entry.content {
            case let .user(text, _): "user: \(text.prefix(160))"
            case let .assistant(text, _): "assistant: \(text.prefix(160))"
            case let .reasoning(text, _): "reasoning: \(text.prefix(40))"
            case let .activity(activity, state): "activity(\(state.rawValue)): \(activity.kind) \(activity.title.prefix(60))"
            case let .permission(request, state): "permission(\(state.rawValue)): \(request.title.prefix(60))"
            case let .plan(text): "plan: \(text.prefix(60))"
            case let .error(message, recoverable, _): "error(\(recoverable)): \(message.prefix(120))"
            case .compaction: "compaction"
            case .usageLimit: "usageLimit"
            }
        }
    }

    /// The last card of a tool, with the state it shows.
    static func activity(kind: String, in entries: [TranscriptEntry]) -> (activity: HarnessActivity, state: TranscriptActivityState)? {
        entries.lazy.reversed().compactMap { entry -> (HarnessActivity, TranscriptActivityState)? in
            if case let .activity(activity, state) = entry.content, activity.kind == kind { (activity, state) } else { nil }
        }.first
    }

    static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
    }

    /// A Claude `result` frame without its text and token details.
    static func resultShape(_ frame: JSONValue) -> JSONValue {
        guard case var .object(object) = frame else { return frame }
        for key in ["result", "usage", "modelUsage", "permission_denials", "session_id", "uuid"] where object[key] != nil {
            object[key] = .string("…")
        }
        return .object(object)
    }

    /// A Codex `turn/completed` notification without its items.
    static func turnShape(_ params: JSONValue) -> JSONValue {
        guard case var .object(object) = params, case var .object(turn)? = object["turn"] else { return params }
        if let items = turn["items"]?.arrayValue { turn["items"] = .string("\(items.count) items") }
        object["turn"] = .object(turn)
        return .object(object)
    }
}

private extension RealModelParityLiveTests {
    func setSavedDirectory(_ path: String) { savedDirectory = path }
}

@MainActor
private final class LiveObservation {
    var values: [String] = []
}

@MainActor
private final class LiveQuietNotificationCenter: SystemNotificationCenter {
    func authorization() async -> SystemNotificationAuthorization { .denied }
    func requestAuthorization() async -> Bool { false }
    func post(title: String, body: String, identifier: String) async {}
}

// MARK: - Wire recording

/// Every frame each runtime wrote and read, in order, with account fields removed.
actor LiveWireLog {
    struct Line: Sendable {
        let at: TimeInterval
        let channel: String
        let direction: String
        let value: JSONValue
    }

    private let started = Date()
    private(set) var lines: [Line] = []
    private static let redacted: Set<String> = [
        "email", "account", "accountUuid", "organization", "organizationName", "organizationUuid", "oauthAccount",
        "apiKey", "apiKeySource", "token", "accessToken", "refreshToken", "authToken", "subscriptionType", "userId", "planType"
    ]

    func record(_ channel: String, _ direction: String, _ value: JSONValue) {
        lines.append(Line(at: Date().timeIntervalSince(started), channel: channel, direction: direction, value: Self.redact(value)))
    }

    func record(_ channel: String, _ direction: String, data: Data) {
        let value = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .string(String(decoding: data, as: UTF8.self))
        record(channel, direction, value)
    }

    func record<T: Encodable>(_ channel: String, _ direction: String, encoding value: T) {
        let value = (try? JSONEncoder().encode(value)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .null
        record(channel, direction, value)
    }

    func note(_ text: String) { record("test", "note", .string(text)) }

    private static func redact(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .object(object):
            return .object(Dictionary(uniqueKeysWithValues: object.map { key, value in
                (key, redacted.contains(key) ? .string("<redacted>") : redact(value))
            }))
        case let .array(values): return .array(values.map(redact))
        default: return value
        }
    }

    // Claude

    func claudeLifecycle(_ messageID: String) -> [String] {
        lines.filter { $0.channel == "claude" && $0.direction == "in" && $0.value["type"]?.stringValue == "command_lifecycle"
            && $0.value["command_uuid"]?.stringValue == messageID }.compactMap { $0.value["state"]?.stringValue }
    }

    func claudeFrames(type: String) -> [JSONValue] {
        lines.filter { $0.channel == "claude" && $0.direction == "in" && $0.value["type"]?.stringValue == type }.map(\.value)
    }

    func claudeControlAnswers(subtype: String) -> [JSONValue] {
        let ids = Set(lines.filter { $0.channel == "claude" && $0.direction == "out"
            && $0.value["request"]?["subtype"]?.stringValue == subtype }.compactMap { $0.value["request_id"]?.stringValue })
        return lines.filter { $0.channel == "claude" && $0.direction == "response"
            && ids.contains($0.value["request_id"]?.stringValue ?? "") }.compactMap { $0.value["response"] }
    }

    func claudeSentUserTexts() -> [String] {
        lines.filter { $0.channel == "claude" && $0.direction == "out" && $0.value["type"]?.stringValue == "user" }
            .compactMap { line in
                line.value["message"]?["content"]?.stringValue
                    ?? line.value["message"]?["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined()
            }
    }

    func claudeSentUserFrames() -> [JSONValue] {
        lines.filter { $0.channel == "claude" && $0.direction == "out" && $0.value["type"]?.stringValue == "user" }.map(\.value)
    }

    func claudePermissionModeAnnouncements() -> [String] {
        lines.filter { $0.channel == "claude" && $0.direction == "in" }
            .compactMap { ClaudeProtocol.announcedPermissionMode(in: $0.value) }
    }

    // Codex

    func codexRequests(_ method: String) -> [JSONValue] {
        lines.filter { $0.channel == "codex" && $0.direction == "out" && $0.value["method"]?.stringValue == method }
            .compactMap { $0.value["params"] }
    }

    func codexResponses(_ method: String) -> [JSONValue] {
        let ids = lines.filter { $0.channel == "codex" && $0.direction == "out" && $0.value["method"]?.stringValue == method }
            .compactMap { $0.value["id"] }
        return lines.filter { $0.channel == "codex" && $0.direction == "response" && ids.contains($0.value["id"] ?? .null) }
            .map { $0.value["result"] ?? $0.value["error"] ?? .null }
    }

    func codexNotifications(_ method: String) -> [JSONValue] {
        lines.filter { $0.channel == "codex" && $0.direction == "in" && $0.value["method"]?.stringValue == method }
            .compactMap { $0.value["params"] }
    }

    func codexNotificationCount(_ method: String) -> Int { codexNotifications(method).count }

    func write(to url: URL) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for line in lines {
            let object: JSONValue = .object(["t": .number((line.at * 1000).rounded() / 1000), "ch": .string(line.channel),
                                             "dir": .string(line.direction), "frame": line.value])
            if let encoded = try? encoder.encode(object) { data.append(encoded); data.append(0x0A) }
        }
        try? data.write(to: url)
    }
}

final class LiveTransports: @unchecked Sendable {
    private let lock = NSLock()
    private var claudeByTask: [UUID: [RecordingClaudeTransport]] = [:]
    private var codexTransports: [RecordingCodexTransport] = []

    func add(claude transport: RecordingClaudeTransport, for localID: UUID) {
        lock.lock(); defer { lock.unlock() }
        claudeByTask[localID, default: []].append(transport)
    }

    func add(codex transport: RecordingCodexTransport) {
        lock.lock(); defer { lock.unlock() }
        codexTransports.append(transport)
    }

    func claude(_ localID: UUID) -> [RecordingClaudeTransport] {
        lock.lock(); defer { lock.unlock() }
        return claudeByTask[localID] ?? []
    }
}

/// The product's Claude process transport, with each frame written to the log on its way.
actor RecordingClaudeTransport: ClaudeTransport {
    private let inner: ClaudeProcessTransport
    private let log: LiveWireLog
    private var tee: AsyncStream<ClaudeRawFrame>?
    private(set) var launch: ClaudeLaunchConfiguration?

    init(inner: ClaudeProcessTransport, log: LiveWireLog) {
        self.inner = inner
        self.log = log
    }

    func start(_ configuration: ClaudeLaunchConfiguration) async throws {
        launch = configuration
        await log.record("claude", "launch", .string(ClaudeProcessTransport.arguments(for: configuration).joined(separator: " ")))
        try await inner.start(configuration)
    }

    func request(_ value: JSONValue, id: String) async throws -> JSONValue {
        await log.record("claude", "out", value)
        do {
            let response = try await inner.request(value, id: id)
            await log.record("claude", "response", .object(["request_id": .string(id), "response": response]))
            return response
        } catch {
            await log.record("claude", "response", .object(["request_id": .string(id), "error": .string(error.localizedDescription)]))
            throw error
        }
    }

    /// A control request the adapter itself would not send.
    func rawRequest(_ value: JSONValue, id: String) async throws -> JSONValue {
        try await request(value, id: id)
    }

    func send(_ value: JSONValue) async throws {
        await log.record("claude", "out", value)
        try await inner.send(value)
    }

    func messages() async -> AsyncStream<ClaudeRawFrame> {
        if let tee { return tee }
        let source = await inner.messages()
        let pair = AsyncStream<ClaudeRawFrame>.makeStream()
        let log = log
        Task {
            for await frame in source {
                await log.record("claude", "in", frame.value)
                pair.continuation.yield(frame)
            }
            pair.continuation.finish()
        }
        tee = pair.stream
        return pair.stream
    }

    func stop() async {
        await log.record("claude", "note", .string("stop"))
        await inner.stop()
    }
}

/// The product's App Server transport, with each frame written to the log on its way.
actor RecordingCodexTransport: CodexTransport {
    private let inner: CodexProcessTransport
    private let log: LiveWireLog
    private var tee: AsyncStream<CodexRawFrame>?

    init(inner: CodexProcessTransport, log: LiveWireLog) {
        self.inner = inner
        self.log = log
    }

    func start() async throws { try await inner.start() }

    func request(_ request: CodexRPCRequest) async throws -> CodexRPCIncomingMessage {
        await log.record("codex", "out", encoding: request)
        do {
            let response = try await inner.request(request)
            await log.record("codex", "response", encoding: response)
            return response
        } catch {
            await log.record("codex", "response", .object(["id": (try? JSONDecoder().decode(JSONValue.self,
                from: JSONEncoder().encode(request.id))) ?? .null, "error": .string(error.localizedDescription)]))
            throw error
        }
    }

    func sendResponse(_ response: CodexRPCResponse) async throws {
        await log.record("codex", "out", encoding: response)
        try await inner.sendResponse(response)
    }

    func sendErrorResponse(_ response: CodexRPCErrorResponse) async throws {
        await log.record("codex", "out", encoding: response)
        try await inner.sendErrorResponse(response)
    }

    func notifications() async -> AsyncStream<CodexRawFrame> {
        if let tee { return tee }
        let source = await inner.notifications()
        let pair = AsyncStream<CodexRawFrame>.makeStream()
        let log = log
        Task {
            for await frame in source {
                await log.record("codex", "in", data: frame.data)
                pair.continuation.yield(frame)
            }
            pair.continuation.finish()
        }
        tee = pair.stream
        return pair.stream
    }

    func stop() async { await inner.stop() }
}
