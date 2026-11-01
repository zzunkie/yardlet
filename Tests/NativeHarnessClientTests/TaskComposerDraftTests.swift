import AppKit
import Observation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

@MainActor
final class TaskComposerDraftTests: XCTestCase {
    func testReturningToTaskPreservesUnsentTextAndTypedAttachments() {
        let store = TaskComposerDraftStore()
        let firstID = UUID(), secondID = UUID()
        let text = "  한글 👩🏽‍💻\n  keep indentation\n"
        let attachments: [CodexUserInput] = [
            .localImage(URL(filePath: "/tmp/context.png")),
            .mention(name: "Sources", path: URL(filePath: "/tmp/Sources")),
            .skill(name: "verification", path: URL(filePath: "/tmp/SKILL.md"))
        ]
        let first = store.draft(for: firstID)
        first.text = text
        first.attachments = attachments
        let second = store.draft(for: secondID)
        XCTAssertTrue(second.submission.isEmpty)
        second.text = "A separate task"

        let returned = store.draft(for: firstID)
        XCTAssertTrue(returned === first)
        XCTAssertEqual(returned.text, text)
        XCTAssertEqual(returned.attachments, attachments)
        XCTAssertEqual(returned.submission.inputs, [.text("한글 👩🏽‍💻\n  keep indentation")] + attachments)
        XCTAssertEqual(second.text, "A separate task")
    }

    func testRestoreAndClearOnlyAffectTheOwningTask() {
        let store = TaskComposerDraftStore()
        let firstID = UUID(), secondID = UUID()
        let first = store.draft(for: firstID)
        let second = store.draft(for: secondID)
        second.text = "Keep the other task"
        let input = CodexUserInput.audio(URL(string: "https://example.test/audio.mp3")!)
        first.restore(CodexComposerDraft(inputs: [.text("Review this request"), input]))
        XCTAssertEqual(first.text, "Review this request")
        XCTAssertEqual(first.attachments, [input])
        XCTAssertNil(first.notice)
        first.clear()
        XCTAssertTrue(store.draft(for: firstID).submission.isEmpty)
        XCTAssertNil(first.notice)
        XCTAssertEqual(store.draft(for: secondID).text, "Keep the other task")
    }

    func testRemovedTasksAreDiscardedWithoutClearingRetainedTasks() {
        let store = TaskComposerDraftStore()
        let removed = UUID(), retained = UUID()
        store.draft(for: removed).text = "Removed task"
        store.draft(for: retained).text = "Still here"
        store.retainSessions([retained])
        XCTAssertTrue(store.draft(for: removed).submission.isEmpty)
        XCTAssertEqual(store.draft(for: retained).text, "Still here")
        XCTAssertTrue(TaskComposerDraftStore().draft(for: retained).submission.isEmpty)
    }

    func testTaskReturnRestoresEachDraftsOwnUnicodeSelection() throws {
        let store = TaskComposerDraftStore()
        let firstID = UUID(), secondID = UUID()
        let first = store.draft(for: firstID)
        let second = store.draft(for: secondID)
        let text = "  선택 한글 👩🏽‍💻\n  둘째 줄"
        first.text = text
        second.text = text
        first.rememberSelection(NSRange(try XCTUnwrap(text.range(of: "선택")), in: text), in: text)
        second.rememberSelection(NSRange(try XCTUnwrap(text.range(of: "👩🏽‍💻")), in: text), in: text)

        let returned = store.draft(for: firstID)
        let firstSelection = try XCTUnwrap(returned.selection)
        XCTAssertEqual(String(returned.text[firstSelection]), "선택")
        var edited = returned.text
        edited.replaceSubrange(firstSelection, with: "복귀")
        XCTAssertEqual(edited, "  복귀 한글 👩🏽‍💻\n  둘째 줄")
        XCTAssertEqual(String(second.text[try XCTUnwrap(second.selection)]), "👩🏽‍💻")
        XCTAssertEqual(second.text, text)
    }

    func testTextReplacementInvalidatesSelectionAndIgnoresLateEditorCallbacks() {
        let draft = TaskComposerDraft()
        let pastedText = "  긴 초안 👩🏽‍💻\n  둘째 줄"
        let pastedCaret = NSRange(location: pastedText.utf16.count, length: 0)
        draft.rememberSelection(pastedCaret, in: pastedText)
        XCTAssertNil(draft.selection, "The native editor may publish before the text binding")
        draft.text = pastedText
        draft.rememberSelection(pastedCaret, in: pastedText)
        XCTAssertEqual(draft.selection?.lowerBound, draft.text.endIndex)
        draft.text = "Original draft"
        draft.rememberSelection(NSRange(location: 4, length: 5), in: draft.text)
        draft.text = "Short"
        XCTAssertNil(draft.selection)
        draft.rememberSelection(NSRange(location: 4, length: 5), in: "Original draft")
        XCTAssertNil(draft.selection)
        draft.rememberSelection(NSRange(location: 1, length: 0), in: draft.text)
        XCTAssertEqual(draft.selection?.lowerBound, draft.text.index(after: draft.text.startIndex))
        draft.rememberSelection(NSRange(location: 20, length: 1), in: draft.text)
        XCTAssertEqual(draft.selection?.lowerBound, draft.text.index(after: draft.text.startIndex))

        draft.text = "e\u{301}"
        draft.rememberSelection(NSRange(location: 2, length: 0), in: draft.text)
        draft.text = "é"
        XCTAssertNil(draft.selection, "Canonically equal strings may have different UTF-16 offsets")
    }

    func testExplicitDraftReplacementClearsSelectionEvenForIdenticalText() {
        let draft = TaskComposerDraft()
        draft.text = "Same text"
        draft.rememberSelection(NSRange(location: 0, length: 4), in: draft.text)
        draft.restore(CodexComposerDraft(inputs: [.text(draft.text)]))
        XCTAssertNil(draft.selection)
        draft.rememberSelection(NSRange(location: 0, length: 4), in: draft.text)
        draft.apply(draft.snapshot)
        XCTAssertNil(draft.selection)
        draft.rememberSelection(NSRange(location: 0, length: 4), in: draft.text)
        draft.clear()
        XCTAssertNil(draft.selection)
        XCTAssertTrue(draft.submission.isEmpty)
    }

    func testSelectionIsTransientAndDoesNotScheduleDraftWrites() {
        let draft = TaskComposerDraft()
        draft.text = "A stored draft"
        var changes = 0
        draft.onChange = { changes += 1 }
        let before = draft.snapshot
        draft.rememberSelection(NSRange(location: 2, length: 6), in: draft.text)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(draft.snapshot, before)
        let restored = TaskComposerDraft()
        restored.apply(before)
        XCTAssertEqual(restored.text, draft.text)
        XCTAssertNil(restored.selection)
    }

    @Observable
    final class ShownTask {
        var id: UUID
        init(_ id: UUID) { self.id = id }
    }

    /// The window's single-task area: each task in the views the window keeps for it (`TaskSurfaceHost`).
    private struct TaskArea: View {
        let shown: ShownTask
        let tasks: [SessionRecord]
        let drafts: TaskComposerDraftStore
        let workspaces: [UUID: TaskWorkspaceState]
        let queue: [CodexQueuedSubmission]
        let hostings = TaskSurfaceHostings()

        var body: some View {
            let task = tasks.first { $0.id == shown.id }!
            let workspace = workspaces[task.id]!
            TaskSurfaceHost(taskID: task.id, hostings: hostings, content: AnyView(
                TaskSurfaceFocusScope { focusedSurface in
                    TaskDetail(
                        session: task, composerDraft: drafts.draft(for: task.id), workspaceState: workspace,
                        panelState: Binding(get: { workspace.panels }, set: { workspace.setPanels($0) }),
                        focusedSurface: focusedSurface, transcript: TaskTranscriptReader([]), errorMessage: nil, codexTaskState: nil,
                        codexHistorySelection: nil, codexQueue: queue, codexCapabilities: .empty,
                        providerCapabilities: nil, providerUsage: nil, isProviderAttached: false,
                        onShowCodexCapabilities: {}, conversationActions: ConversationActions(),
                        composerActions: ComposerActions(removeQueued: { _ in }, retryQueued: { _ in },
                                                         editQueued: { id in queue.first { $0.id == id }?.draft })
                    )
                    .environment(\.taskKeyboardFocus, workspace.keyboardFocus)
                }
            ))
            .frame(width: 900, height: 600)
        }
    }

    /// A queued message brought back into the composer is brought back once: the task shown again in
    /// the views the window kept keeps what was typed into it since, and the task shown in between keeps
    /// its own draft.
    func testReturningToATaskKeepsWhatWasTypedIntoAMessageBroughtBack() {
        let tasks = ["Queue", "Other"].map {
            SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/draft-project"),
                          runtimeExecutableURL: URL(filePath: "/tmp/no-runtime"), title: $0, status: .running)
        }
        let queued = CodexQueuedSubmission(draft: CodexComposerDraft(inputs: [.text("Then update the README")]))
        let drafts = TaskComposerDraftStore()
        let shown = ShownTask(tasks[0].id)
        let host = WindowlessRender.Host(
            TaskArea(shown: shown, tasks: tasks, drafts: drafts,
                     workspaces: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, TaskWorkspaceState()) }),
                     queue: [queued]),
            size: NSSize(width: 900, height: 600), appearance: .light)
        defer { host.close() }
        host.settle(passes: 20)
        XCTAssertTrue(host.hosting.pressAccessibilityElement(labelled: L10n.string("Edit message")))
        host.settle(passes: 10)
        let draft = drafts.draft(for: tasks[0].id)
        XCTAssertEqual(draft.text, "Then update the README")
        draft.text = "Then update the README and the changelog"

        shown.id = tasks[1].id
        host.settle(passes: 10)
        drafts.draft(for: tasks[1].id).text = "A separate task"
        shown.id = tasks[0].id
        host.settle(passes: 10)
        XCTAssertEqual(draft.text, "Then update the README and the changelog")
        XCTAssertEqual(drafts.draft(for: tasks[1].id).text, "A separate task")
    }
}
