import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// A send that ends in failure says why where the person looks: the Codex timeline draws the
/// provider's turns and none of Yardlet's own failures, so the task's error shows under it.
/// The case is a real send on 2026-10-16: the ChatGPT app's App Server held the thread and
/// `thread/resume` was refused, which until now showed only a red "Failed" chip.
@MainActor
final class TaskErrorNoticeTests: XCTestCase {
    private let heldElsewhere = CodexThreadHeldElsewhere(
        providerMessage: "thread 0000aaaa-0000-0000-0000-000000000001 already has an active writer"
    ).localizedDescription

    func testACodexThreadShowsYardletsOwnFailureUnderItsTurns() throws {
        let state = try codexState(latest: completedTurn())
        XCTAssertEqual(TaskErrorNotice.message(heldElsewhere, harness: .codex, entries: localEntries,
                                               codexTaskState: state), heldElsewhere)
    }

    func testATurnsOwnProviderErrorIsNotRepeated() throws {
        let error = JSONValue.object(["message": .string("Stream disconnected before completion")])
        let state = try codexState(latest: failedTurn(error))
        let shown = try XCTUnwrap(CodexTurnErrorPresentation(error)).text
        XCTAssertNil(TaskErrorNotice.message(shown, harness: .codex, entries: localEntries, codexTaskState: state))
        // A later send that fails for Yardlet's own reason still shows, under that failed turn.
        XCTAssertEqual(TaskErrorNotice.message(heldElsewhere, harness: .codex, entries: localEntries,
                                               codexTaskState: state), heldElsewhere)
        // Nor while a later turn runs: the error stays on the turn it ended.
        let retried = CodexTaskState(thread: try thread([try failedTurn(error), try retryTurn()]))
        XCTAssertNil(TaskErrorNotice.message(shown, harness: .codex, entries: localEntries, codexTaskState: retried))
        XCTAssertEqual(TaskErrorNotice.message(heldElsewhere, harness: .codex, entries: localEntries,
                                               codexTaskState: retried), heldElsewhere)
    }

    func testATranscriptConversationShowsItsErrorsInlineAndAnEmptyOneShowsTheCard() throws {
        XCTAssertNil(TaskErrorNotice.message("Harness process exited (3): boom", harness: .claudeCode,
                                             entries: localEntries, codexTaskState: nil))
        XCTAssertEqual(TaskErrorNotice.message("Harness process exited (3): boom", harness: .claudeCode,
                                               entries: [], codexTaskState: nil), "Harness process exited (3): boom")
        // A Codex task whose thread has no turns yet is drawn from the transcript too.
        XCTAssertNil(TaskErrorNotice.message(heldElsewhere, harness: .codex, entries: localEntries,
                                             codexTaskState: CodexTaskState(thread: try thread([]))))
        XCTAssertNil(TaskErrorNotice.message(nil, harness: .codex, entries: [], codexTaskState: nil))
        XCTAssertNil(TaskErrorNotice.message("  ", harness: .codex, entries: [], codexTaskState: nil))
    }

    /// The task as the window draws it: the thread's latest turn, the refused message kept as a
    /// failed chip that also says why, and the notice above the composer.
    func testARefusedCodexSendIsReadableInTheTaskWindow() throws {
        let directory = try WindowlessRender.directory("codex-send-failure-qa")
        let state = try codexState(latest: completedTurn())
        let queue = [CodexQueuedSubmission(draft: CodexComposerDraft(inputs: [.text("Why is the screen empty?")]),
                                           state: .failed, failureMessage: heldElsewhere)]
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(
                FailedSendTaskHost(session: session(), entries: localEntries, errorMessage: heldElsewhere,
                                   codexTaskState: state, queue: queue)
                    .frame(width: 900, height: 620)
                    .background(ParityTheme.canvas)
                    .environment(\.colorScheme, appearance.colorScheme),
                size: NSSize(width: 900, height: 620), appearance: appearance
            )
            defer { host.close() }
            host.settle()
            let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }.joined(separator: "\n")
            XCTAssertTrue(spoken.contains(L10n.string(
                "This conversation is open in another Codex app, such as ChatGPT, so it cannot continue here. Quit that app, then send again."
            )), spoken)
            XCTAssertTrue(spoken.contains(L10n.format("%@ could not complete the request", "Codex")), spoken)
            try WindowlessRender.writePNG(try host.capture().bitmap,
                                          to: directory.appending(path: "held-elsewhere-\(appearance.rawValue).png"))
        }
    }

    /// The retry of a turn the busy server ended, as the window drew it on 2026-10-31: the failed turn
    /// keeps its card and the retry runs under it. The task's error left from that turn is already
    /// on its card, so nothing above the composer repeats it.
    func testARetriedTurnLeavesTheEarlierErrorOnItsOwnCard() throws {
        let error = JSONValue.object(["message": .string("Selected model is at capacity. Please try a different model."),
                                      "codexErrorInfo": .string("serverOverloaded")])
        let left = try XCTUnwrap(CodexTurnErrorPresentation(error)).text
        let state = CodexTaskState(thread: try thread([try failedTurn(error), try retryTurn()]))
        let directory = try WindowlessRender.directory("codex-retry-error-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(
                FailedSendTaskHost(session: session(status: .running), entries: localEntries, errorMessage: left,
                                   codexTaskState: state, queue: [])
                    .frame(width: 900, height: 620)
                    .background(ParityTheme.canvas)
                    .environment(\.colorScheme, appearance.colorScheme),
                size: NSSize(width: 900, height: 620), appearance: appearance
            )
            defer { host.close() }
            host.settle()
            try WindowlessRender.writePNG(try host.capture().bitmap,
                                          to: directory.appending(path: "retried-\(appearance.rawValue).png"))
            let spoken = host.accessibilityElements().map { "\($0.label) \($0.value)" }.joined(separator: "\n")
            XCTAssertTrue(spoken.contains(L10n.string("Server is busy.")), spoken)
            XCTAssertFalse(spoken.contains(L10n.format("%@ could not complete the request", "Codex")), spoken)
        }
    }

    // MARK: - Fixtures

    private func session(status: SessionStatus = .failed) -> SessionRecord {
        SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/qa-project"),
                      runtimeExecutableURL: URL(filePath: "/usr/bin/false"), title: "Store pricing",
                      titleOrigin: .provider, status: status,
                      providerSessionID: "0000aaaa-0000-0000-0000-000000000001",
                      completionState: status == .running ? SessionCompletionState.none : .completed)
    }

    /// What Yardlet's own transcript holds after the refused send: the request and the error.
    private var localEntries: [TranscriptEntry] {
        [TranscriptEntry(content: .user(text: "Why is the screen empty?")),
         TranscriptEntry(content: .error(message: heldElsewhere, recoverable: true))]
    }

    private func thread(_ turns: [CodexTurnState]) throws -> CodexThreadState {
        var thread = try XCTUnwrap(CodexTaskDecoder().thread(from: .object(["id": .string("0000aaaa-0000-0000-0000-000000000001")])))
        thread.turns = turns
        return thread
    }

    private func codexState(latest: CodexTurnState) throws -> CodexTaskState {
        CodexTaskState(thread: try thread([latest]))
    }

    private func completedTurn() throws -> CodexTurnState {
        try XCTUnwrap(CodexTaskDecoder().turn(from: .object([
            "id": .string("turn-done"), "status": .string("completed"),
            "items": .array([
                .object(["id": .string("ask"), "type": .string("userMessage"),
                         "content": .array([.object(["type": .string("text"), "text": .string("Apply the approved prices")])])]),
                .object(["id": .string("answer"), "type": .string("agentMessage"), "phase": .string("final_answer"),
                         "text": .string("The approved prices are applied for launch.")])
            ])
        ]), fallbackID: "turn-done"))
    }

    /// The retry Codex runs for the failed turn: an empty request, still thinking.
    private func retryTurn() throws -> CodexTurnState {
        var turn = try XCTUnwrap(CodexTaskDecoder().turn(from: .object([
            "id": .string("turn-retry"), "status": .string("inProgress"), "items": .array([])
        ]), fallbackID: "turn-retry"))
        turn.status = .inProgress
        return turn
    }

    private func failedTurn(_ error: JSONValue) throws -> CodexTurnState {
        var turn = try XCTUnwrap(CodexTaskDecoder().turn(from: .object([
            "id": .string("turn-failed"), "status": .string("failed"),
            "items": .array([.object(["id": .string("ask-2"), "type": .string("userMessage"),
                                      "content": .array([.object(["type": .string("text"), "text": .string("Try again")])])])]),
            "error": error
        ]), fallbackID: "turn-failed"))
        turn.status = .failed
        return turn
    }
}

/// A Codex task as the window shows it after a refused send.
private struct FailedSendTaskHost: View {
    let session: SessionRecord
    let entries: [TranscriptEntry]
    let errorMessage: String
    let codexTaskState: CodexTaskState
    let queue: [CodexQueuedSubmission]
    @State private var workspace = TaskWorkspaceState()
    @FocusState private var focused: TaskSurface?

    var body: some View {
        TaskDetail(
            session: session, composerDraft: TaskComposerDraft(), workspaceState: workspace,
            panelState: Binding(get: { workspace.panels }, set: { workspace.setPanels($0) }),
            focusedSurface: $focused, entries: entries, errorMessage: errorMessage, codexTaskState: codexTaskState,
            codexHistorySelection: nil, codexQueue: queue, codexCapabilities: .empty, providerCapabilities: nil,
            providerUsage: nil, isProviderAttached: false, onShowCodexCapabilities: {},
            conversationActions: ConversationActions(),
            composerActions: ComposerActions(removeQueued: { _ in }, retryQueued: { _ in }, editQueued: { _ in nil })
        )
        .environment(\.taskKeyboardFocus, workspace.keyboardFocus)
    }
}
