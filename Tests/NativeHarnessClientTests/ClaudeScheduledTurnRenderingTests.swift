import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Renders a Claude task a schedule wakes offscreen into `.build/claude-scheduled-qa/`, light and
/// dark.
@MainActor
final class ClaudeScheduledTurnRenderingTests: XCTestCase {
    func testScheduledCheckInsDrawAsTheirOwnTurnsUnderTheClaudeAppsWords() throws {
        let directory = try WindowlessRender.directory("claude-scheduled-qa")
        let start = Date(timeIntervalSince1970: 1_792_000_000)
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
        let checkIn = "[Inbox check] Look for new messages in the shared inbox, answer what you can, and leave a note for anything that needs a person. Report what changed since the last check, keep the replies short, and do not send anything that promises a date or a refund without asking first."
        let entries = [
            TranscriptEntry(createdAt: at(0), content: .user(text: "Some files came in by message.")),
            TranscriptEntry(createdAt: at(4), content: .activity(HarnessActivity(id: "read-1", kind: "Read", title: "Read",
                detail: "inbox.txt"), state: .completed)),
            TranscriptEntry(createdAt: at(41), content: .assistant(text: "Handled both files and filed them under **Received**.", isStreaming: false)),
            // A background subagent starts a command of its own after the report: a row above the composer.
            TranscriptEntry(createdAt: at(120), content: .activity(HarnessActivity(id: "toolu_sub", kind: "Task",
                title: "Run the quick test suite once", isBackground: true,
                subtask: HarnessSubtaskReference(taskID: "bsub1", taskType: "local_bash", ownedBySubagent: true)), state: .running)),
            TranscriptEntry(createdAt: at(218), content: .user(text: checkIn), origin: .scheduled),
            TranscriptEntry(createdAt: at(226), content: .activity(HarnessActivity(id: "read-2", kind: "Read", title: "Read",
                detail: "inbox.txt"), state: .completed)),
            TranscriptEntry(createdAt: at(232), content: .assistant(text: "No new messages.", isStreaming: false)),
            TranscriptEntry(createdAt: at(900), content: .user(text: "<scheduled-task name=\"morning-brief\" file=\"/Users/qa/.claude/scheduled-tasks/morning-brief/SKILL.md\">\nSummarize the new tickets.\n</scheduled-task>"),
                            origin: .scheduled),
            TranscriptEntry(createdAt: at(930), content: .assistant(text: "Brief sent.", isStreaming: false)),
            TranscriptEntry(createdAt: at(1200), content: .user(text: "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n<summary>Background command \"Sync the inbox\" completed</summary>\n</task-notification>")),
            TranscriptEntry(createdAt: at(1204), content: .assistant(text: "The inbox is synced.", isStreaming: false))
        ]
        for appearance in WindowlessRender.Appearance.allCases {
            let drawing = try ConversationDrawing.draw(
                ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .ready,
                                                         latestTurnIsComplete: true)),
                size: NSSize(width: 760, height: 1100), appearance: appearance
            )
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "scheduled-turns-\(appearance.suffix).png"))
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertEqual(drawing.elements.filter { $0.role == "AXGroup" && $0.label == L10n.string("Scheduled check-in") }.count,
                           1, texts)
            XCTAssertEqual(drawing.elements.filter {
                $0.role == "AXGroup" && $0.label == L10n.format("Scheduled task: %@", "morning-brief")
            }.count, 1, texts)
            XCTAssertEqual(drawing.elements.filter { $0.role == "AXGroup" && $0.label == L10n.string("You") }.count,
                           1, "only the person's own message is theirs:\n\(texts)")
            XCTAssertFalse(drawing.elements.contains { $0.value == L10n.string("Sent by scheduled task") },
                           "no Codex heartbeat label in a Claude task:\n\(texts)")
            XCTAssertFalse(texts.contains("<scheduled-task"), texts)
            XCTAssertTrue(texts.contains("Summarize the new tickets."), texts)
            XCTAssertTrue(texts.contains("Handled both files"), "the report stays in view as its turn's answer:\n\(texts)")
            XCTAssertTrue(texts.contains("No new messages."), texts)
            XCTAssertTrue(texts.contains("Brief sent."), "the report before the notice stays its turn's answer:\n\(texts)")
            XCTAssertFalse(texts.contains(L10n.string("Commentary")), "no report reads as a working note:\n\(texts)")
            XCTAssertEqual(drawing.elements.filter { $0.role == "AXGroup" && $0.label == L10n.string("Background task") }.count,
                           1, texts)
            XCTAssertTrue(texts.contains("Background command \"Sync the inbox\" completed"), texts)
            XCTAssertTrue(texts.contains("The inbox is synced."), texts)
            // The check-in runs past two lines and folds as a scheduled task's message does.
            XCTAssertEqual(drawing.elements.filter { $0.role == "AXButton" && $0.label == L10n.string("Show more") }.count,
                           1, texts)
        }
    }
}
