import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Claude subtasks: the subagent card's controls, and the child conversation's read-only panel.
/// Renders go to `.build/claude-subtask-qa`.
@MainActor
final class ClaudeSubtaskRenderingTests: XCTestCase {
    func testActualTaskControlLabelsRenderOffscreenInBothAppearances() throws {
        let directory = try WindowlessRender.directory("claude-subtask-qa")
        for appearance in [ColorScheme.light, .dark] {
            let view = VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    HarnessSubtaskActionLabel(title: "Open child task", systemName: "arrow.right.circle")
                    HarnessSubtaskActionLabel(title: "Stop task", systemName: "stop.circle")
                }
                HarnessSubtaskActionLabel(title: "Stop requested", systemName: "stop.circle")
            }
            .padding(16).frame(width: 320, height: 110).background(ParityTheme.input)
            .environment(\.colorScheme, appearance)
            let image = try WindowlessRender.image(view)
            let bitmap = NSBitmapImageRep(cgImage: image)
            XCTAssertTrue(WindowlessRender.drawsContent(bitmap, step: 6, from: 10))
            XCTAssertFalse(stride(from: 10, to: bitmap.pixelsHigh, by: 6).contains { y in
                stride(from: 10, to: bitmap.pixelsWide, by: 6).contains { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.redComponent > 0.9 && color.greenComponent > 0.65 && color.blueComponent < 0.25
                }
            }, "Native-view placeholders must not be mistaken for rendered label content")
            try WindowlessRender.writePNG(bitmap,
                to: directory.appending(path: appearance == .dark ? "controls-dark.png" : "controls-light.png"))
        }
        XCTAssertEqual(L10n.string("Stop task", languageCode: "ko"), "작업 중지")
        XCTAssertEqual(L10n.string("Open child task", languageCode: "ko"), "하위 작업 열기")
    }

    /// The parent's subagent card offers to open and stop the child; the child's panel draws its
    /// conversation read only, whatever that conversation holds: no message menu, no subtask
    /// controls of its own, though a nested agent and a request still read as cards.
    func testTheParentCardOffersTheChildAndTheChildPanelOnlyReads() throws {
        let directory = try WindowlessRender.directory("claude-subtask-qa")
        let reference = HarnessSubtaskReference(taskID: "task-1", agentID: "agent-1", toolUseID: "toolu_agent",
                                                taskType: "local_agent")
        let agent = HarnessActivity(id: "toolu_agent", kind: "Agent", title: "Explore the README",
                                    input: "Read README.md and report the title", subtask: reference)
        let controls = HarnessActivityActions(open: { _ in }, stop: { _ in }, isStopping: { _ in false },
                                              error: { _ in nil })
        let rewind = ConversationRewindActions(
            beginCodexEdit: { _ in }, beginClaudeEdit: { _ in }, cancelEdit: {}, loadFilePoints: { [] },
            previewFiles: { _ in throw CancellationError() }, restoreFiles: { _ in throw CancellationError() }
        )
        var parentActions = ConversationActions(rewind: rewind)
        parentActions.subtaskControls = controls
        // A failed card opens itself, showing the subtask's controls.
        let failedAgent = HarnessActivity(id: "toolu_failed", kind: "Agent", title: "Explore the license",
                                          subtask: HarnessSubtaskReference(agentID: "agent-3", taskType: "local_agent"))
        let parent = [
            TranscriptEntry(content: .user(text: "Use an agent to read the README")),
            TranscriptEntry(content: .activity(failedAgent, state: .failed)),
            TranscriptEntry(content: .activity(agent, state: .running))
        ]
        let child = [
            TranscriptEntry(content: .user(text: "Read README.md and report the title")),
            TranscriptEntry(content: .activity(HarnessActivity(
                id: "toolu_nested", kind: "Agent", title: "Nested check",
                subtask: HarnessSubtaskReference(agentID: "agent-2", taskType: "local_agent")
            ), state: .completed)),
            TranscriptEntry(content: .permission(PermissionRequest(
                id: "child-permission", title: "Bash", detail: "head README.md", command: "head README.md"
            ), state: .pending)),
            TranscriptEntry(content: .assistant(text: "The title is **Yardlet**.", isStreaming: false))
        ]
        let session = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/yardlet-subtask-qa"),
                                    runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Parent",
                                    providerSessionID: "parent-session")
        for appearance in WindowlessRender.Appearance.allCases {
            let card = try ConversationDrawing.draw(
                TaskConversationView(harness: .claudeCode, workspaceURL: session.workspaceURL, entries: parent,
                                     sessionStatus: .running, actions: parentActions),
                size: NSSize(width: 620, height: 360), appearance: appearance
            )
            try WindowlessRender.writePNG(card.capture.bitmap,
                                          to: directory.appending(path: "parent-card-\(appearance.suffix).png"))
            let cardLabels = card.elements.flatMap { [$0.label, $0.value] }
            XCTAssertTrue(cardLabels.contains(L10n.string("Open child task")), "\(cardLabels)")

            let panel = try ConversationDrawing.draw(
                HarnessSubtaskPane(activity: agent, session: session, readingPosition: TranscriptReadingPosition(),
                                   actions: parentActions.readOnlyChild,
                                   load: { HarnessSubtaskTranscript(entries: child, isTruncated: true) },
                                   onClose: {}),
                size: NSSize(width: 560, height: 640), appearance: appearance
            )
            try WindowlessRender.writePNG(panel.capture.bitmap,
                                          to: directory.appending(path: "child-panel-\(appearance.suffix).png"))
            let labels = panel.elements.flatMap { [$0.label, $0.value] }
            XCTAssertTrue(labels.contains(L10n.string("Showing recent conversation")), "\(labels)")
            XCTAssertTrue(labels.contains("Read README.md and report the title"), "\(labels)")
            XCTAssertFalse(panel.elements.contains { $0.role == "AXMenuButton" }, "no message menu in the child")
            XCTAssertFalse(labels.contains(L10n.string("Open child task")), "no subtask controls in the child")
            XCTAssertFalse(labels.contains(L10n.string("Stop task")))
        }
    }
}
