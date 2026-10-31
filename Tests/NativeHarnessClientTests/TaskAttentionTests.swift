import Foundation
import XCTest
@testable import NativeHarnessClient
import YardletAgentTools

final class TaskAttentionTests: XCTestCase {
    private func task(
        _ title: String,
        at time: TimeInterval,
        status: SessionStatus = .ready,
        unread: Bool = false,
        folder: String = "/tmp/attention",
        harness: HarnessKind = .claudeCode
    ) -> SessionRecord {
        SessionRecord(harness: harness, workspaceURL: URL(filePath: folder),
            runtimeExecutableURL: URL(filePath: "/tmp/runtime"), title: title, status: status,
            updatedAt: Date(timeIntervalSince1970: time), hasUnreadUpdate: unread)
    }

    // MARK: - The one definition

    func testAttentionStatesFollowTheCodexApp() {
        func state(_ session: SessionRecord, _ detail: TaskAttentionDetail? = nil, busy: Bool = false) -> TaskAttentionState {
            TaskAttentionProjection.state(of: session, detail: detail, isShellBusy: busy)
        }
        XCTAssertEqual(state(task("Approval", at: 0, status: .waitingForApproval)), .waiting)
        XCTAssertEqual(state(task("Question", at: 0, status: .running), TaskAttentionDetail(pendingRequest: .input)), .waiting)
        XCTAssertEqual(state(task("Waiting, unread", at: 0, status: .waitingForApproval, unread: true)), .waiting)
        XCTAssertEqual(state(task("Finished", at: 0, status: .completed, unread: true)), .unread)
        XCTAssertEqual(state(task("Failed", at: 0, status: .failed, unread: true)), .unread)
        XCTAssertEqual(state(task("Running, unread", at: 0, status: .running, unread: true)), .active,
                       "A running turn has no finished result to read yet")
        XCTAssertEqual(state(task("Running", at: 0, status: .running)), .active)
        XCTAssertEqual(state(task("Shell", at: 0), busy: true), .active)
        XCTAssertEqual(state(task("Shell, unread", at: 0, status: .completed, unread: true), busy: true), .unread)
        XCTAssertEqual(state(task("Read", at: 0, status: .completed)), .idle)
        XCTAssertEqual(state(task("Failed, read", at: 0, status: .failed)), .idle)
        XCTAssertEqual([TaskAttentionState.waiting, .unread, .active, .idle].map(\.needsAttention),
                       [true, true, false, false])
        XCTAssertEqual([TaskAttentionState.idle, .active, .waiting, .unread].sorted(), [.waiting, .unread, .active, .idle])
    }

    // MARK: - What the latest turn waits on

    func testTheDetailReadsOnlyTheLatestTurnOfATranscript() {
        let approval = PermissionRequest(id: "a", title: "Run command", detail: nil, command: "rm -rf build")
        let question = PermissionRequest(id: "q", title: "Question", detail: nil, command: nil,
            structured: .questions([PermissionQuestion(question: "Which?", options: [.init(label: "A")])]))
        let limit = HarnessRateLimit(status: .rejected, window: .weekly)

        XCTAssertEqual(TaskAttentionDetail.reading([
            TranscriptEntry(content: .user(text: "Go")),
            TranscriptEntry(content: .permission(question, state: .pending)),
        ]).pendingRequest, .input)
        XCTAssertEqual(TaskAttentionDetail.reading([
            TranscriptEntry(content: .user(text: "Go")),
            TranscriptEntry(content: .permission(question, state: .pending)),
            TranscriptEntry(content: .permission(approval, state: .pending)),
        ]).pendingRequest, .approval, "An approval comes before a question, as the Codex row's chips do")
        XCTAssertNil(TaskAttentionDetail.reading([
            TranscriptEntry(content: .user(text: "Go")),
            TranscriptEntry(content: .permission(approval, state: .allowed)),
        ]).pendingRequest)
        XCTAssertNil(TaskAttentionDetail.reading([
            TranscriptEntry(content: .permission(approval, state: .pending)),
            TranscriptEntry(content: .user(text: "Next")),
        ]).pendingRequest, "An earlier turn's request is over")
        XCTAssertEqual(TaskAttentionDetail.reading([
            TranscriptEntry(content: .user(text: "Go")),
            TranscriptEntry(content: .permission(approval, state: .pending)),
            TranscriptEntry(content: .user(text: "Also this"), joinsRunningTurn: true),
        ]).pendingRequest, .approval, "A message read into the running turn belongs to it")

        let limited = TaskAttentionDetail.reading([
            TranscriptEntry(content: .user(text: "Go")),
            TranscriptEntry(content: .assistant(text: "Working on it", isStreaming: false)),
            TranscriptEntry(content: .usageLimit(limit)),
        ])
        XCTAssertEqual(limited.usageLimit, limit)
        XCTAssertNil(limited.pendingRequest)
        XCTAssertNil(TaskAttentionDetail.reading([
            TranscriptEntry(content: .user(text: "Go")),
            TranscriptEntry(content: .usageLimit(limit)),
            TranscriptEntry(content: .user(text: UsageLimitContinuation.afterAccountSwitch)),
        ]).usageLimit, "Continuing after the limit starts a new turn")

        // What the home reads apart from the detail: when the turn started and the tasks it suggested,
        // and the last finished message's first line without Markdown's marks (a message still
        // streaming is not read).
        let start = Date(timeIntervalSince1970: 100)
        let entries = [
            TranscriptEntry(content: .user(text: "Earlier")),
            TranscriptEntry(content: .assistant(text: "Old answer", isStreaming: false)),
            TranscriptEntry(createdAt: start, content: .user(text: "Go")),
            TranscriptEntry(content: .assistant(text: "\n## **Done**: see [the PR](https://example.com)\nMore", isStreaming: false)),
            TranscriptEntry(content: .activity(HarnessActivity(
                id: "toolu_s", kind: "mcp__yardlet__spawn_task", title: "mcp__yardlet__spawn_task",
                input: #"{"title":"Fix the badge","prompt":"Fix it.","tldr":"Seen while here."}"#,
                output: TaskSuggestionToolCatalog.notedResult(taskID: "task_1a2b3c4d")), state: .completed)),
            TranscriptEntry(content: .assistant(text: "Still typing", isStreaming: true)),
        ]
        let read = TaskLatestTurn.reading(entries)
        XCTAssertEqual(read.startedAt, start)
        XCTAssertEqual(TaskAttentionDetail.reading(entries), .none, "Nothing the window reads changed")
        XCTAssertEqual(TaskAttentionDetail.answerLine(entries), "Done: see the PR")
        XCTAssertNil(TaskAttentionDetail.answerLine(Array(entries.prefix(3))), "An earlier turn's answer is not this turn's")
        // Every block mark goes; a line with no inline mark is read as it is, one with marks is parsed.
        XCTAssertEqual(TaskAttentionDetail.firstLine("\n\n> - 2. Fixed  the parser\n## Next"), "Fixed the parser")
        XCTAssertEqual(TaskAttentionDetail.firstLine("```swift\nlet a = 1\n```"), "let a = 1")
        XCTAssertEqual(TaskAttentionDetail.firstLine("Tom &amp; Jerry: `a_b`"), "Tom & Jerry: a_b")
        XCTAssertEqual(TaskAttentionDetail.firstLine("From 240~400ms to 110~150ms, ~~not~~ now"),
                       "From 240~400ms to 110~150ms, not now")
        XCTAssertEqual(read.suggestions, [TaskAttentionSuggestion(id: "task_1a2b3c4d", title: "Fix the badge")])
        XCTAssertEqual(TaskAttentionDetail.reading([
            TranscriptEntry(content: .user(text: "Go")),
            TranscriptEntry(content: .error(message: "Connection lost", recoverable: false)),
        ]).errorMessage, "Connection lost")
        XCTAssertEqual(TaskAttentionDetail.reading([]), .none)
    }

    func testTheDetailReadsACodexTimeline() {
        func turn(_ id: String, _ status: CodexTurnStatus, error: JSONValue? = nil) -> CodexTurnState {
            CodexTurnState(id: id, status: status, startedAt: nil, completedAt: nil, durationMilliseconds: nil,
                itemsView: .full, items: [], itemsNextCursor: nil, plan: nil, tokenUsage: nil, error: error,
                raw: .object([:]))
        }
        func state(_ turns: [CodexTurnState], requests: [CodexServerRequestState] = []) -> CodexTaskState {
            CodexTaskState(
                thread: CodexThreadState(id: "thread", sessionID: "thread", name: nil, preview: "", workspacePath: nil,
                    cliVersion: nil, modelProvider: nil, parentThreadID: nil, forkedFromID: nil, status: .idle,
                    canAcceptDirectInput: true, createdAt: nil, updatedAt: nil, turns: turns, turnsNextCursor: nil,
                    turnsBackwardsCursor: nil, itemsBackwardsCursor: nil, raw: .object([:])),
                serverRequestsByID: Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0) }))
        }
        func request(_ id: String, _ kind: CodexServerRequestKind, turn: String = "t2",
                     resolution: CodexServerRequestResolution = .pending) -> CodexServerRequestState {
            CodexServerRequestState(id: id, method: kind.wireName, kind: kind, threadID: "thread", turnID: turn,
                                    itemID: nil, params: nil, resolution: resolution)
        }
        let running = [turn("t1", .completed), turn("t2", .inProgress)]

        XCTAssertEqual(TaskAttentionDetail.reading(state(running, requests: [request("q", .toolUserInput)])).pendingRequest,
                       .input)
        XCTAssertEqual(TaskAttentionDetail.reading(state(running, requests: [request("e", .mcpElicitation)])).pendingRequest,
                       .input)
        XCTAssertEqual(TaskAttentionDetail.reading(state(running, requests: [
            request("q", .toolUserInput), request("c", .commandExecutionApproval),
        ])).pendingRequest, .approval)
        XCTAssertNil(TaskAttentionDetail.reading(state(running, requests: [
            request("q", .toolUserInput, resolution: .resolved(nil)),
        ])).pendingRequest)
        XCTAssertNil(TaskAttentionDetail.reading(state(running, requests: [request("old", .toolUserInput, turn: "t1")]))
            .pendingRequest, "A request of an earlier turn is not open")
        XCTAssertNil(TaskAttentionDetail.reading(state([turn("t1", .completed)], requests: [request("q", .toolUserInput, turn: "t1")]))
            .pendingRequest, "With no turn running, a saved request waits on nothing")
        XCTAssertNil(TaskAttentionDetail.reading(state(running, requests: [request("t", .currentTime)])).pendingRequest)

        let limitError: JSONValue = .object(["message": .string("You've hit your usage limit."),
                                             "codexErrorInfo": .string("usageLimitExceeded")])
        let limited = TaskAttentionDetail.reading(state([turn("t1", .failed, error: limitError)]))
        XCTAssertEqual(limited.usageLimit?.status, .rejected)
        XCTAssertNil(limited.errorMessage)
        let failed = TaskAttentionDetail.reading(state([turn("t1", .failed, error: .object(["message": .string("Boom")]))]))
        XCTAssertEqual(failed.errorMessage, "Boom")
        XCTAssertNil(failed.usageLimit)
        XCTAssertEqual(TaskAttentionDetail.reading(state([turn("t1", .failed, error: limitError), turn("t2", .inProgress)])),
                       .none, "A turn running again is past the limit")
    }

    @MainActor
    func testTheModelReadsEachTasksDetailFromItsTranscriptAndTimeline() {
        let claude = task("Claude", at: 10, status: .waitingForApproval)
        let codex = task("Codex", at: 20, status: .running, harness: .codex)
        let question = PermissionRequest(id: "q", title: "Question", detail: nil, command: nil,
            structured: .questions([PermissionQuestion(question: "Which?", options: [.init(label: "A")])]))
        let turn = CodexTurnState(id: "t", status: .inProgress, startedAt: nil, completedAt: nil,
            durationMilliseconds: nil, itemsView: .full, items: [], itemsNextCursor: nil, plan: nil, tokenUsage: nil,
            error: nil, raw: .object([:]))
        let codexState = CodexTaskState(
            thread: CodexThreadState(id: "thread", sessionID: "thread", name: nil, preview: "", workspacePath: nil,
                cliVersion: nil, modelProvider: nil, parentThreadID: nil, forkedFromID: nil, status: .idle,
                canAcceptDirectInput: true, createdAt: nil, updatedAt: nil, turns: [turn], turnsNextCursor: nil,
                turnsBackwardsCursor: nil, itemsBackwardsCursor: nil, raw: .object([:])),
            serverRequestsByID: ["r": CodexServerRequestState(id: "r", method: "item/tool/requestUserInput",
                kind: .toolUserInput, threadID: "thread", turnID: "t", itemID: nil, params: nil, resolution: .pending)])
        let model = AppModel(
            store: SessionStore(sessions: [claude, codex]),
            runtimeSelections: RuntimeSelectionStore(discoversRuntimes: false),
            initialTranscripts: [claude.id: [TranscriptEntry(content: .user(text: "Go")),
                                             TranscriptEntry(content: .permission(question, state: .pending))]],
            initialCodexPresentation: [codex.id: codexState],
            restoresIndexOnLaunch: false
        )
        XCTAssertEqual(model.taskAttentionDetails[claude.id]?.pendingRequest, .input)
        XCTAssertEqual(model.taskAttentionDetails[codex.id], TaskAttentionDetail(pendingRequest: .input))
        XCTAssertEqual(SidebarTaskIndicatorProjection.status(of: codex, detail: model.taskAttentionDetails[codex.id]),
                       .needsInput, "A Codex question no longer shows as running")
        XCTAssertEqual(model.attentionBadgeCount, 2, "The Dock badge counts the Codex question as waiting too")
    }

    // MARK: - The activity view

    func testTheActivityListHoldsWaitingUnreadAndWorkingTasksInTheOrderOfNextTaskNeedingAttention() {
        let oldApproval = task("Old approval", at: 10, status: .waitingForApproval, folder: "/tmp/a")
        let newQuestion = task("New question", at: 30, status: .running, folder: "/tmp/b", harness: .codex)
        let unread = task("Unread", at: 50, status: .completed, unread: true, folder: "/tmp/c")
        let failedUnread = task("Failed, unread", at: 40, status: .failed, unread: true, folder: "/tmp/a")
        let running = task("Running", at: 60, status: .running, folder: "/tmp/b")
        let shell = task("Shell", at: 5, folder: "/tmp/c")
        let read = task("Read", at: 70, status: .completed, folder: "/tmp/a")
        let failedRead = task("Failed, read", at: 80, status: .failed, folder: "/tmp/c")
        let sessions = [read, running, oldApproval, failedRead, shell, unread, newQuestion, failedUnread]
        let details = [newQuestion.id: TaskAttentionDetail(pendingRequest: .input)]

        let list = TaskAttentionProjection.activityList(in: sessions, details: details, shellBusy: [shell.id])
        XCTAssertEqual(list.map(\.title), ["New question", "Old approval", "Unread", "Failed, unread", "Running", "Shell"])
        XCTAssertEqual(TaskAttentionProjection.count(in: sessions, details: details, shellBusy: [shell.id]), 4,
                       "The Dock badge counts what ⌥⌘A visits")
        XCTAssertEqual(TaskAttentionProjection.count(in: sessions), 3, "Without the turn's question it reads as running")
        XCTAssertEqual(TaskAttentionProjection.count(in: [read, running, failedRead]), 0)

        // ⌥⌘A walks the same list, skipping what is shown, and stops before the tasks only working.
        var shown: UUID?
        var visited: [String] = []
        while let next = TaskAttentionProjection.nextSession(in: sessions.filter { !visited.contains($0.title) },
                                                             excluding: shown, details: details, shellBusy: [shell.id]) {
            let session = sessions.first { $0.id == next }!
            visited.append(session.title)
            shown = next
        }
        XCTAssertEqual(visited, list.filter {
            TaskAttentionProjection.state(of: $0, detail: details[$0.id]).needsAttention
        }.map(\.title))
        XCTAssertEqual(visited, ["New question", "Old approval", "Unread", "Failed, unread"])
    }

    func testTheActivityListKeepsEachTasksPlaceWhileItIsOpen() {
        var approval = task("Approval", at: 10, status: .waitingForApproval)
        var unread = task("Unread", at: 50, status: .completed, unread: true)
        var running = task("Running", at: 60, status: .running)
        let idle = task("Idle", at: 70)
        let kept = TaskAttentionProjection.places(of: [approval, unread, running, idle])
        XCTAssertEqual(Set(kept.keys), [approval.id, unread.id, running.id])

        // The person answers the approval and reads the unread task; the running one finishes.
        approval.status = .running
        approval.updatedAt = Date(timeIntervalSince1970: 90)
        unread.hasUnreadUpdate = false
        running.status = .completed
        running.hasUnreadUpdate = true
        let arrival = task("New question", at: 5, status: .waitingForApproval)
        let list = TaskAttentionProjection.activityList(in: [approval, unread, running, idle, arrival], kept: kept)
        XCTAssertEqual(list.map(\.title), ["Approval", "New question", "Unread", "Running"],
                       "Listed tasks keep their places; a new one takes its place in attention order")

        // Archived or deleted, a task leaves; once the view is closed, read tasks leave too.
        XCTAssertEqual(TaskAttentionProjection.activityList(in: [approval, running, idle], kept: kept).map(\.title),
                       ["Approval", "Running"])
        XCTAssertEqual(TaskAttentionProjection.activityList(in: [approval, unread, running, idle]).map(\.title),
                       ["Running", "Approval"])
    }

    @MainActor
    func testMarkAllAsReadReadsEveryListedTaskAndKeepsThemListed() async {
        let first = task("First", at: 10, status: .completed, unread: true, folder: "/tmp/one")
        let second = task("Second", at: 20, status: .failed, unread: true, folder: "/tmp/two")
        let waiting = task("Waiting", at: 30, status: .waitingForApproval, unread: true)
        let elsewhere = task("Elsewhere", at: 40, status: .completed, unread: true)
        let store = SessionStore(sessions: [first, second, waiting, elsewhere])
        let listed = TaskAttentionProjection.activityList(in: [first, second, waiting])
        let kept = TaskAttentionProjection.places(of: listed)

        await store.markRead(ids: listed.filter(\.hasUnreadUpdate).map(\.id))
        XCTAssertEqual(store.sessions.filter(\.hasUnreadUpdate).map(\.title), ["Elsewhere"],
                       "Only the listed tasks are read")
        let after = store.sessions.filter { [first.id, second.id, waiting.id].contains($0.id) }
        XCTAssertEqual(TaskAttentionProjection.activityList(in: after, kept: kept).map(\.title),
                       ["Waiting", "Second", "First"])
        XCTAssertEqual(TaskAttentionProjection.activityList(in: after).map(\.title), ["Waiting"])
    }
}
