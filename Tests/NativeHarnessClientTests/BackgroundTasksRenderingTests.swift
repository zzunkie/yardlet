import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The background tasks line above the composer, drawn offscreen into `.build/turn-summary-qa`, light
/// and dark. No provider, process, app launch or window server interaction.
///
/// - `task-bar-*.png`: a Claude Code task whose two background agents and one background shell run
///   after its turn ended: the collapsed line on the composer rail, above the composer.
/// - `bar-expanded-*.png`: the line opened over a composer: each task with its elapsed time and stop
///   control, one already stopping, one whose stop failed.
@MainActor
final class BackgroundTasksRenderingTests: XCTestCase {
    private let now = Date()

    private var session: SessionRecord {
        SessionRecord(harness: .claudeCode, workspaceURL: WindowlessRender.repositoryRoot,
                      runtimeExecutableURL: URL(filePath: "/usr/bin/false"), title: "Parser review",
                      titleOrigin: .provider, status: .ready, completionState: .completed)
    }

    private var entries: [TranscriptEntry] {
        func agent(_ id: String, _ title: String, task: String, type: String, minutesAgo: Double,
                   state: TranscriptActivityState, background: Bool = true) -> TranscriptEntry {
            TranscriptEntry(createdAt: now.addingTimeInterval(-minutesAgo * 60), content: .activity(
                HarnessActivity(id: id, kind: type == "local_bash" ? "Bash" : "Agent", title: title,
                                isBackground: background,
                                subtask: HarnessSubtaskReference(taskID: task, toolUseID: id, taskType: type)),
                state: state))
        }
        return [
            TranscriptEntry(createdAt: now.addingTimeInterval(-600),
                            content: .user(text: "Review the parser and run the slow suite in the background")),
            agent("front", "Read the lexer", task: "t-front", type: "local_agent", minutesAgo: 9.5,
                  state: .completed, background: false),
            agent("agent-a", "Review the parser", task: "t-a", type: "local_agent", minutesAgo: 3.2, state: .running),
            agent("agent-b", "Check the error recovery paths", task: "t-b", type: "local_agent", minutesAgo: 2.1,
                  state: .running),
            agent("shell", "swift test --parallel", task: "t-shell", type: "local_bash", minutesAgo: 8.4,
                  state: .running),
            TranscriptEntry(createdAt: now.addingTimeInterval(-60), content: .assistant(
                text: "Two agents are reviewing the parser and the suite runs in the background. I'll report back.",
                isStreaming: false)),
        ]
    }

    func testTheBackgroundTasksLineSitsOnTheComposerRail() throws {
        let directory = try WindowlessRender.directory("turn-summary-qa")
        let projection = BackgroundTasksProjection(entries: entries)
        XCTAssertEqual(projection.rows.map(\.id), ["agent-a", "agent-b", "shell"])
        let size = NSSize(width: 900, height: 560)
        let captures = try WindowlessRender.hostedInBothAppearances("task-bar", in: directory, size: size,
                                                                    passes: 12) { appearance in
            TaskHost(session: session, entries: entries)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height)
                .background(ParityTheme.canvas)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }

        let host = WindowlessRender.Host(TaskHost(session: session, entries: entries)
            .frame(width: size.width, height: size.height), size: size)
        defer { host.close() }
        host.settle(passes: 12)
        let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
        XCTAssertTrue(spoken.contains { $0.contains(projection.countText) }, spoken.description)
        XCTAssertTrue(spoken.contains { $0.contains(L10n.string("Stop all")) }, spoken.description)
    }

    func testTheOpenedLineListsEachTaskWithItsStopControl() throws {
        let directory = try WindowlessRender.directory("turn-summary-qa")
        let projection = BackgroundTasksProjection(entries: entries)
        let actions = HarnessActivityActions(open: { _ in }, stop: { _ in }, isStopping: { $0 == "agent-b" },
                                             error: { $0 == "shell" ? L10n.string("This task is no longer running.") : nil })
        let size = NSSize(width: 820, height: 330)
        let captures = try WindowlessRender.hostedInBothAppearances("bar-expanded", in: directory, size: size) { appearance in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                BackgroundTasksBar(projection: projection, actions: actions, startsExpanded: true)
                    .attachedAboveComposer()
                PromptComposer(harness: .claudeCode, composerDraft: TaskComposerDraft(), isRunning: false)
                    .zIndex(1)
            }
            .environment(\.colorScheme, appearance.colorScheme)
            .frame(width: size.width, height: size.height)
            .background(ParityTheme.canvas)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }

        // The stop control speaks the Claude app's words, not the card's.
        let host = WindowlessRender.Host(BackgroundTasksBar(projection: projection, actions: actions, startsExpanded: true)
            .frame(width: size.width), size: size)
        defer { host.close() }
        host.settle()
        let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }
        XCTAssertEqual(spoken.filter { $0.contains(L10n.string("Stop this task")) }.count, 3, spoken.description)
        XCTAssertTrue(spoken.contains { $0.contains(L10n.string("Stopping…")) }, spoken.description)
        XCTAssertFalse(spoken.contains { $0.contains(L10n.string("Stop task")) }, spoken.description)
    }
}

/// A Claude Code task as the window shows it, attached, with its subtask controls.
private struct TaskHost: View {
    let session: SessionRecord
    let entries: [TranscriptEntry]
    @State private var workspace = TaskWorkspaceState()
    @FocusState private var focused: TaskSurface?

    var body: some View {
        TaskDetail(
            session: session, composerDraft: TaskComposerDraft(), workspaceState: workspace,
            panelState: Binding(get: { workspace.panels }, set: { workspace.setPanels($0) }),
            focusedSurface: $focused, transcript: TaskTranscriptReader(entries), errorMessage: nil, codexTaskState: nil,
            codexHistorySelection: nil, codexQueue: [], codexCapabilities: .empty, providerCapabilities: nil,
            providerUsage: nil, isProviderAttached: true, onShowCodexCapabilities: {},
            conversationActions: ConversationActions(
                readSubtask: { _ in HarnessSubtaskTranscript(entries: [], isTruncated: false) },
                stopSubtask: { _ in }
            ),
            composerActions: ComposerActions()
        )
        .environment(\.taskKeyboardFocus, workspace.keyboardFocus)
    }
}
