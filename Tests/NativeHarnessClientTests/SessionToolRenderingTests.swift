import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// The session tools drawn by the one conversation renderer with no window on screen, into
/// `.build/session-tools-qa/`, light and dark:
///
/// - `received-message-*`: a message another task sent, under "Sent from {task}" (a link to it), then
///   the receiving task's answer.
/// - `subagents-running-*`: a running Claude Code turn with two `run_agent` cards: one working (its
///   latest step on one line, Stop) and one waiting for the person, whose request waits at the end of
///   the turn like every request.
/// - `subagent-done-*`: a finished Codex subagent's card with its model and answer.
/// - `approval-card-*`: `send_message_to_task` into another project waiting on the person's card;
///   `read-approval-card-*` and `list-approval-card-*`: `read_task` of another project's task and `list_tasks` of every
///   project's, on the same card.
/// - `setting-approval-card-*`, `setting-changed-*`: `update_setting` waiting on the person's card, and the
///   change it made as a row in the folded turn.
@MainActor
final class SessionToolRenderingTests: XCTestCase {
    private static let workspace = URL(filePath: "/work/uploader", directoryHint: .isDirectory)
    private static let sender = UUID()

    func testAMessageFromAnotherTaskReadsAsThatTasksAndLinksToIt() throws {
        let message = TaskMessage(senderID: Self.sender.uuidString, senderName: "Rewrite upload queue",
                                  body: "The queue rewrite is done. Can you run the retry tests on this branch once?",
                                  quotes: [TaskMessage.Quote(text: "Run the retry tests too", sentAt: "2026-10-24T06:12:05+09:00")])
        let entries = transcript([
            .user(text: "Write up the upload limits doc"),
            .assistant(text: "I wrote the limits and retry intervals in docs/uploads.md.", isStreaming: false),
            .user(text: message.text(in: .yardlet)),
            .activity(HarnessActivity(id: "toolu_test", kind: "Bash", title: "Bash", input: "swift test --filter RetryTests",
                                      output: "Executed 6 tests, with 0 failures"), state: .completed),
            .assistant(text: "All 6 retry tests pass.", isStreaming: false)
        ])
        let drawings = try draw("received-message", height: 520) {
            ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .ready,
                                                     latestTurnIsComplete: true))
                .environment(\.taskSuggestionActions, TaskSuggestionActions(
                    resolution: { _ in nil }, start: { _ in }, dismiss: { _ in }, openTask: { _ in },
                    canOpenTask: { $0 == Self.sender }))
        }
        for drawing in drawings {
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains(L10n.format("Sent from %@", "Rewrite upload queue")), texts)
            XCTAssertTrue(texts.contains("run the retry tests on this branch"), texts)
            XCTAssertFalse(texts.contains("cross-session-message"), "The envelope never shows:\n\(texts)")
        }
    }

    func testRunningSubagentsShowTheirStepAndTheirRequestWaitsAtTheEndOfTheTurn() throws {
        let host = UUID()
        let working = AgentRun(callerID: host, hostTaskID: host, harness: .claudeCode, model: "sonnet",
                               prompt: "Find the concurrency bug in UploadQueue.swift", workspaceURL: Self.workspace, depth: 1)
        working.state = .running
        working.entries = [
            TranscriptEntry(content: .user(text: working.prompt)),
            TranscriptEntry(content: .activity(HarnessActivity(
                id: "c1", kind: "Read", title: "Read",
                input: #"{"file_path":"/work/uploader/Sources/Uploader/UploadQueue.swift"}"#), state: .running))
        ]
        let request = PermissionRequest(id: "perm-build", title: "Bash", detail: "Build the package",
                                        command: "swift build --build-tests")
        let asking = AgentRun(callerID: host, hostTaskID: host, harness: .openCode, model: "kimi-k2",
                              prompt: "Check whether the build breaks", workspaceURL: Self.workspace, depth: 1)
        asking.state = .waitingForApproval
        asking.entries = [
            TranscriptEntry(content: .user(text: asking.prompt)),
            TranscriptEntry(content: .permission(request, state: .pending))
        ]
        // One waits for room to start: it reads Pending and can be stopped.
        let queued = AgentRun(callerID: host, hostTaskID: host, harness: .codex, model: "gpt-5.5",
                              prompt: "Update the upload retry doc", workspaceURL: Self.workspace, depth: 1)
        queued.state = .queued
        let runs = [working, asking, queued]
        let entries = transcript([
            .user(text: "Split the upload queue review between Codex and Claude"),
            .activity(runAgent(harness: "claude-code", model: "sonnet", prompt: working.prompt), state: .running),
            .activity(runAgent(harness: "opencode", model: "kimi-k2", prompt: asking.prompt), state: .running),
            .activity(runAgent(harness: "codex", model: "gpt-5.5", prompt: queued.prompt), state: .running)
        ])
        let drawings = try draw("subagents-running", height: 760) {
            ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .running,
                                                     latestTurnIsComplete: false),
                                 actions: ConversationActions(heldRequests: asking.pendingRequests))
                .environment(\.agentRunActions, AgentRunActions(
                    run: { _, prompt in runs.first { $0.prompt == prompt } }, stop: { _ in }))
        }
        XCTAssertNotNil(working.progressLine)
        for drawing in drawings {
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            // Each is named by what it was asked, with its harness and model, as the rail's Agents card names it.
            XCTAssertTrue(texts.contains(working.prompt) && texts.contains("Claude Code · sonnet"), texts)
            XCTAssertTrue(texts.contains(asking.prompt) && texts.contains("OpenCode · kimi-k2"), texts)
            XCTAssertTrue(texts.contains("UploadQueue.swift"), "The working one's step is its line:\n\(texts)")
            XCTAssertTrue(texts.contains(L10n.string("Needs approval")), texts)
            XCTAssertTrue(texts.contains("swift build --build-tests"), "The subagent's request is drawn:\n\(texts)")
            XCTAssertTrue(texts.contains(L10n.format("%@: %@", asking.prompt, "Bash")),
                          "Named for the subagent that asks, as its card names it:\n\(texts)")
            XCTAssertTrue(texts.contains(L10n.string("Stop task")), texts)
            XCTAssertTrue(texts.contains(queued.prompt) && texts.contains(L10n.string("Pending")), texts)
        }
    }

    func testAFinishedSubagentShowsItsModelAndAnswer() throws {
        let host = UUID()
        let run = AgentRun(callerID: host, hostTaskID: host, harness: .codex, model: "gpt-5.5",
                           prompt: "Find the concurrency bug in UploadQueue.swift", workspaceURL: Self.workspace, depth: 1)
        run.state = .completed
        run.answer = "`flush()` reads `pending` without a lock. At line 214, wrap it in `queue.sync`."
        let result = AppModel.agentRunResultText(run)
        // The caller's turn goes on after its subagent answered; once it ends, the card folds into the
        // turn's work like any call.
        let entries = transcript([
            .user(text: "Have Codex look for the upload queue's concurrency bug"),
            .activity(runAgent(harness: "codex", model: "gpt-5.5", prompt: run.prompt, result: result), state: .completed),
            .assistant(text: "Codex found the missing lock in `flush()`. I'll fix it.", isStreaming: true)
        ])
        let drawings = try draw("subagent-done", height: 420) {
            ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .running,
                                                     latestTurnIsComplete: false))
                .environment(\.agentRunActions, AgentRunActions(run: { id, _ in id == run.id.uuidString ? run : nil },
                                                                 stop: { _ in }))
        }
        for drawing in drawings {
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains(run.prompt) && texts.contains("Codex · gpt-5.5"), texts)
            XCTAssertTrue(texts.contains(L10n.string("Open conversation")), texts)
            XCTAssertTrue(texts.contains("At line 214"), "The answer's first line is on the card:\n\(texts)")
            XCTAssertFalse(texts.contains(L10n.string("Stop task")), texts)
            XCTAssertFalse(texts.contains("mcp__yardlet__run_agent"), texts)
        }
    }

    func testAMessageIntoAnotherProjectWaitsOnTheCallersCard() throws {
        let caller = UUID()
        let approval = SessionToolApproval(
            id: SessionToolApproval.idPrefix + "render", taskID: caller,
            request: PermissionRequest(id: SessionToolApproval.idPrefix + "render",
                                       title: L10n.string("Send a message to another project's task"),
                                       detail: L10n.format("%@ → %@", "Upload limits doc", "Payment webhook retries") + " · billing\n\n"
                                           + "I changed the upload retry interval to 3 s. Can you check the webhook retries use the same?",
                                       command: nil))
        let entries = transcript([
            .user(text: "Tell the payments task the retry interval changed"),
            .activity(HarnessActivity(id: "toolu_send", kind: "mcp__yardlet__send_message_to_task",
                                      title: "mcp__yardlet__send_message_to_task",
                                      input: #"{"task_id":"5D0F…","message":"I changed the upload retry interval to 3 s."}"#),
                      state: .running)
        ])
        let drawings = try draw("approval-card", height: 520) {
            ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .running,
                                                     latestTurnIsComplete: false),
                                 actions: ConversationActions(heldRequests: [approval.conversationRequest]))
        }
        for drawing in drawings {
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains(L10n.string("Send a message to another project's task")), texts)
        }

        // Reading another project's task, and listing every project's tasks, ask on the same card.
        let reads = [
            ("read-approval-card", "read_task", #"{"task_id":"5D0F…"}"#, L10n.string("Read another project's task"),
             L10n.format("%@ → %@", "Upload limits doc", "Payment webhook retries") + " · billing"),
            ("list-approval-card", "list_tasks", #"{"scope":"all"}"#, L10n.string("List every project's tasks"),
             L10n.format("%@ → %@", "Upload limits doc", "billing, site, Chats"))
        ]
        for (name, tool, input, title, detail) in reads {
            let read = SessionToolApproval(
                id: SessionToolApproval.idPrefix + name, taskID: caller,
                request: PermissionRequest(id: SessionToolApproval.idPrefix + name, title: title, detail: detail, command: nil))
            let asked = transcript([
                .user(text: "What did the payments task decide about retries?"),
                .activity(HarnessActivity(id: "toolu_\(tool)", kind: "mcp__yardlet__\(tool)", title: "mcp__yardlet__\(tool)",
                                          input: input), state: .running)
            ])
            let drawn = try draw(name, height: 420) {
                ConversationTimeline(source: .transcript(entries: asked, harness: .claudeCode, status: .running,
                                                         latestTurnIsComplete: false),
                                     actions: ConversationActions(heldRequests: [read.conversationRequest]))
            }
            for drawing in drawn {
                let texts = drawing.elements.map(\.description).joined(separator: "\n")
                XCTAssertTrue(texts.contains(title), texts)
                XCTAssertTrue(texts.contains(detail), texts)
            }
        }
    }

    /// `update_setting` on a setting that asks every time: the task's card names the setting, where it is in
    /// Settings, the change and the setting's help; once allowed, the call is a row with Open that stays when
    /// the turn folds.
    func testASettingChangeAsksOnTheCallersCardAndStaysAsARowOnceMade() throws {
        let caller = UUID()
        let setting = YardletSetting.keepCookies
        let approval = SessionToolApproval(
            id: SessionToolApproval.idPrefix + "setting", taskID: caller,
            request: PermissionRequest(id: SessionToolApproval.idPrefix + "setting",
                                       title: AppModel.settingCardTitle(setting),
                                       detail: AppModel.settingCardDetail(setting, from: "perTask", to: "shared"),
                                       command: nil))
        let input = #"{"id":"keep_cookies","value":"shared"}"#
        let asking = transcript([
            .user(text: "Let every task share one set of cookies"),
            .activity(HarnessActivity(id: "toolu_setting", kind: "mcp__yardlet__update_setting",
                                      title: "mcp__yardlet__update_setting", input: input), state: .running)
        ])
        let cards = try draw("setting-approval-card", height: 520) {
            ConversationTimeline(source: .transcript(entries: asking, harness: .claudeCode, status: .running,
                                                     latestTurnIsComplete: false),
                                 actions: ConversationActions(heldRequests: [approval.conversationRequest]))
        }
        for drawing in cards {
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains(AppModel.settingCardTitle(setting)), texts)
            XCTAssertTrue(texts.contains(L10n.format("%@ → %@", L10n.string("Per task"), L10n.string("Shared by all tasks"))), texts)
        }

        let result = SettingsToolCatalog.changedLine(title: setting.title, from: setting.title(of: "perTask"),
                                                     to: setting.title(of: "shared"), id: setting.id) + "\n" + setting.help
        let made = transcript([
            .user(text: "Let every task share one set of cookies"),
            .activity(HarnessActivity(id: "toolu_setting", kind: "mcp__yardlet__update_setting",
                                      title: "mcp__yardlet__update_setting", input: input, output: result), state: .completed),
            .assistant(text: "Every task now shares one set of cookies.", isStreaming: false)
        ])
        var opened: [SettingsSection] = []
        let rows = try draw("setting-changed", height: 360) {
            ConversationTimeline(source: .transcript(entries: made, harness: .claudeCode, status: .ready,
                                                     latestTurnIsComplete: true))
                .environment(\.openSettingsSection, { opened.append($0) })
        }
        for drawing in rows {
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains(L10n.format("Changed setting: %@", setting.title)),
                          "The row stays in the folded turn:\n\(texts)")
            XCTAssertTrue(texts.contains(L10n.format("Open %@ in Settings", setting.title)), texts)
            XCTAssertFalse(texts.contains("update_setting"), "Not a tool line:\n\(texts)")
        }
        XCTAssertTrue(opened.isEmpty)
    }

    // MARK: - Fixtures

    private func runAgent(harness: String, model: String, prompt: String, result: String? = nil) -> HarnessActivity {
        let arguments: JSONValue = .object(["harness": .string(harness), "model": .string(model), "prompt": .string(prompt)])
        return HarnessActivity(id: "toolu_\(harness)", kind: "mcp__yardlet__run_agent", title: "mcp__yardlet__run_agent",
                               input: arguments.readableText, output: result)
    }

    private func transcript(_ contents: [TranscriptEntryContent]) -> [TranscriptEntry] {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        return contents.enumerated().map { index, content in
            TranscriptEntry(createdAt: start.addingTimeInterval(Double(index) * 7), content: content)
        }
    }

    private func draw<Content: View>(_ name: String, height: CGFloat,
                                     _ content: () -> Content) throws -> [ConversationDrawing.Drawing] {
        let directory = try WindowlessRender.directory("session-tools-qa")
        return try WindowlessRender.Appearance.allCases.map { appearance in
            let drawing = try ConversationDrawing.draw(content(), size: NSSize(width: 760, height: height),
                                                      appearance: appearance)
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
            return drawing
        }
    }
}
