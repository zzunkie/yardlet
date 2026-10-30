import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// A schedule an agent created, drawn by the one conversation renderer with no window on screen,
/// into `.build/schedule-tools-qa/`, light and dark:
///
/// - `claude-row-*`: a finished Claude Code turn whose calls folded, the `create_scheduled_task` call
///   left in view as one row — clock, name, its rule and next run, and Open.
/// - `codex-row-*`: a Codex thread's `yardlet` MCP call as the same row.
/// - `states-*`: three rows of one turn — a paused schedule, a one-off, and one deleted since.
/// - `claude-request-*`: Claude Code asking before the call, on the request card, in Yardlet's words.
@MainActor
final class ScheduleToolRenderingTests: XCTestCase {
    private static let workspace = URL(filePath: "/work/uploader", directoryHint: .isDirectory)
    private static let now = Date(timeIntervalSince1970: 1_792_220_400)  // 2026-10-17 20:00 KST

    private let morning = UUID()
    private let paused = UUID()
    private let once = UUID()
    private let deleted = UUID()

    func testAClaudeCallIsOneRowWithItsNameNextRunAndOpen() throws {
        let center = center()
        let drawings = try draw("claude-row", height: 340) {
            ConversationTimeline(source: .transcript(entries: claudeEntries([(morning, "Morning check")]),
                                                     harness: .claudeCode, status: .ready, latestTurnIsComplete: true))
                .environment(\.scheduledTaskRowActions, actions(center))
        }
        let schedule = try XCTUnwrap(center.schedule(id: morning))
        let detail = ScheduleText.summary(schedule.trigger, now: Self.now) + " · "
            + ScheduleText.status(schedule, nextRun: center.nextRun(of: schedule), isStarting: false, now: Self.now)
        for drawing in drawings {
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            for drawn in [L10n.format("Scheduled task %@", "Morning check"), detail,
                          L10n.format("Open %@ in Scheduled tasks", "Morning check")] {
                XCTAssertTrue(texts.contains(drawn), "\(drawn) is not drawn:\n\(texts)")
            }
            XCTAssertFalse(texts.contains("mcp__yardlet__create_scheduled_task"), texts)
            XCTAssertFalse(texts.contains("Check the overnight builds"), "The prompt stays in Scheduled tasks:\n\(texts)")
        }
    }

    func testACodexCallIsTheSameRow() throws {
        let center = center()
        let drawings = try draw("codex-row", height: 300) {
            ConversationTimeline(source: .codex(codexThread(), workspaceURL: Self.workspace, historySelection: nil),
                                 actions: ConversationActions(forkCodexTurn: { _ in }))
                .environment(\.scheduledTaskRowActions, actions(center))
        }
        for drawing in drawings {
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains(L10n.format("Scheduled task %@", "Morning check")), texts)
            XCTAssertTrue(texts.contains(L10n.format("Open %@ in Scheduled tasks", "Morning check")), texts)
        }
    }

    func testPausedOneOffAndDeletedRowsSayWhereTheyStand() throws {
        let center = center()
        center.setEnabled(false, for: paused)
        let drawings = try draw("states", height: 460) {
            ConversationTimeline(source: .transcript(
                entries: claudeEntries([(paused, "Weekly notes"), (once, "Check the deploy"), (deleted, "Old digest")]),
                harness: .claudeCode, status: .ready, latestTurnIsComplete: true))
                .environment(\.scheduledTaskRowActions, actions(center))
        }
        for drawing in drawings {
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains(L10n.string("Paused")), texts)
            XCTAssertTrue(texts.contains(L10n.string("Once") + " · "), texts)
            XCTAssertTrue(texts.contains(L10n.format("Scheduled task %@", "Old digest")), texts)
            XCTAssertTrue(texts.contains(L10n.string("Deleted")), texts)
            XCTAssertFalse(texts.contains(L10n.format("Open %@ in Scheduled tasks", "Old digest")),
                           "A deleted schedule has nothing to open:\n\(texts)")
        }
    }

    func testOpenShowsTheScheduleInScheduledTasks() throws {
        let center = center()
        let recorder = Recorder()
        var actions = actions(center)
        actions.open = { recorder.opened.append($0) }
        let view = ConversationTimeline(source: .transcript(entries: claudeEntries([(morning, "Morning check")]),
                                                            harness: .claudeCode, status: .ready, latestTurnIsComplete: true))
            .environment(\.scheduledTaskRowActions, actions)
            .environment(\.colorScheme, .light)
            .frame(width: 760, height: 340, alignment: .top)
            .background(ParityTheme.canvas)
        let host = WindowlessRender.Host(view, size: NSSize(width: 760, height: 340), appearance: .light)
        defer { host.close() }
        host.settle(passes: 10)
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.format("Open %@ in Scheduled tasks", "Morning check")))
        host.settle(passes: 2)
        XCTAssertEqual(recorder.opened, [morning])
    }

    func testClaudeAsksBeforeTheCallInYardletsWords() throws {
        let input: JSONValue = .object([
            "name": .string("Morning check"), "prompt": .string("Check the overnight builds and summarize failures."),
            "cronExpression": .string("0 9 * * 1-5")
        ])
        let text = try XCTUnwrap(ScheduleToolApproval.request(toolName: "mcp__yardlet__create_scheduled_task",
                                                              input: input, now: Self.now))
        let request = PermissionRequest(id: "perm-1", title: text.title, detail: text.detail, command: nil,
                                        toolCallID: "toolu_create")
        let start = Self.now
        let entries = [
            TranscriptEntry(createdAt: start, content: .user(text: "Check the overnight build at 9 every weekday morning")),
            TranscriptEntry(createdAt: start.addingTimeInterval(4),
                            content: .assistant(text: "I'll schedule that.", isStreaming: false)),
            TranscriptEntry(createdAt: start.addingTimeInterval(6), content: .activity(HarnessActivity(
                id: "toolu_create", kind: "mcp__yardlet__create_scheduled_task",
                title: "mcp__yardlet__create_scheduled_task", input: input.readableText), state: .running)),
            TranscriptEntry(createdAt: start.addingTimeInterval(7), content: .permission(request, state: .pending))
        ]
        let drawings = try draw("claude-request", height: 420) {
            ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .waitingForApproval,
                                                     latestTurnIsComplete: false))
        }
        for drawing in drawings {
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains(text.title), texts)
            XCTAssertTrue(texts.contains("Check the overnight builds"), texts)
        }
    }

    // MARK: - Fixtures

    private func center() -> ScheduledTaskCenter {
        var seoul = Calendar(identifier: .gregorian)
        seoul.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let center = ScheduledTaskCenter()
        center.now = { Self.now }
        center.calendar = { seoul }
        let destination = ScheduleDestination(harness: .claudeCode, workspacePath: Self.workspace.path(percentEncoded: false))
        let schedules = [
            ScheduledTask(id: morning, name: "Morning check", prompt: "Check the overnight builds.",
                          trigger: .weekly(days: ScheduleWeekday.weekdays, time: ScheduleTime(hour: 9, minute: 0)),
                          destination: destination),
            ScheduledTask(id: paused, name: "Weekly notes", prompt: "Write the weekly notes.",
                          trigger: .weekly(days: [.friday], time: ScheduleTime(hour: 17, minute: 0)), destination: destination),
            ScheduledTask(id: once, name: "Check the deploy", prompt: "Check whether the deploy finished.",
                          trigger: .once(Self.now.addingTimeInterval(3_600)), destination: destination)
        ]
        for schedule in schedules { center.create(schedule) }
        return center
    }

    private func actions(_ center: ScheduledTaskCenter) -> ScheduledTaskRowActions {
        ScheduledTaskRowActions(
            schedule: { center.schedule(id: $0) }, nextRun: { center.nextRun(of: $0) },
            now: { Self.now }, open: { _ in })
    }

    private func answer(_ id: UUID, _ name: String) -> String {
        ScheduleToolCatalog.createdResult(scheduleID: id.uuidString, name: name, body: "**Schedule:** weekdays at 09:00")
    }

    private func claudeEntries(_ rows: [(UUID, String)]) -> [TranscriptEntry] {
        var offset = 0.0
        func entry(_ content: TranscriptEntryContent) -> TranscriptEntry {
            offset += 6
            return TranscriptEntry(createdAt: Self.now.addingTimeInterval(offset - 600), content: content)
        }
        var entries = [
            entry(.user(text: "Check the overnight build at 9 every weekday morning")),
            entry(.assistant(text: "I'll look at how the builds report first.", isStreaming: false)),
            entry(.activity(HarnessActivity(id: "toolu_read", kind: "Read", title: "Read",
                                            input: "scripts/nightly.sh", output: "…"), state: .completed))
        ]
        for (id, name) in rows {
            entries.append(entry(.activity(HarnessActivity(
                id: "toolu_\(id.uuidString.prefix(8))", kind: "mcp__yardlet__create_scheduled_task",
                title: "mcp__yardlet__create_scheduled_task",
                input: #"{"name":"\#(name)","prompt":"Check the overnight builds.","cronExpression":"0 9 * * 1-5"}"#,
                output: answer(id, name)), state: .completed)))
        }
        entries.append(entry(.assistant(text: "Scheduled. It runs while Yardlet is open.", isStreaming: false)))
        return entries
    }

    private func codexThread() -> CodexTaskState {
        let decoder = CodexTaskDecoder()
        var thread = decoder.thread(from: .object(["id": .string("thread-schedule")]))!
        var turn = decoder.turn(from: .object(["id": .string("turn-1"), "status": .string("completed"),
                                               "durationMs": .integer(18_000), "items": .array([])]), fallbackID: "turn-1")!
        turn.items = [
            decoder.item(from: .object([
                "id": .string("u1"), "type": .string("userMessage"),
                "content": .array([.object(["type": .string("text"), "text": .string("Schedule a build check for 9 every weekday morning")])])
            ]), fallbackID: "u1", lifecycle: .completed),
            decoder.item(from: .object([
                "id": .string("mcp-1"), "type": .string("mcpToolCall"), "server": .string("yardlet"),
                "tool": .string("create_scheduled_task"), "status": .string("completed"),
                "arguments": .object(["name": .string("Morning check"), "prompt": .string("Check the overnight builds."),
                                      "cronExpression": .string("0 9 * * 1-5")]),
                "result": .object(["content": .array([.object([
                    "type": .string("text"), "text": .string(answer(morning, "Morning check"))
                ])])])
            ]), fallbackID: "mcp-1", lifecycle: .completed),
            decoder.item(from: .object([
                "id": .string("a1"), "type": .string("agentMessage"), "text": .string("Scheduled for weekday mornings."),
                "phase": .string("final_answer")
            ]), fallbackID: "a1", lifecycle: .completed)
        ]
        thread.turns = [turn]
        return CodexTaskState(thread: thread)
    }

    private func draw<Content: View>(_ name: String, height: CGFloat,
                                     _ content: () -> Content) throws -> [ConversationDrawing.Drawing] {
        let directory = try WindowlessRender.directory("schedule-tools-qa")
        return try WindowlessRender.Appearance.allCases.map { appearance in
            let drawing = try ConversationDrawing.draw(content(), size: NSSize(width: 760, height: height),
                                                      appearance: appearance)
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
            return drawing
        }
    }

    /// What Open asked the window to do. Only the main thread touches it.
    private final class Recorder: @unchecked Sendable {
        var opened: [UUID] = []
    }
}
