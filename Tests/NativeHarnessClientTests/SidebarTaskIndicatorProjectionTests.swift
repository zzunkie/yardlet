import XCTest
@testable import NativeHarnessClient

final class SidebarTaskIndicatorProjectionTests: XCTestCase {
    private let limit = HarnessRateLimit(status: .rejected, window: .session,
                                         resetsAt: Date(timeIntervalSince1970: 1_800_000_000))

    private func task(
        _ status: SessionStatus = .ready,
        completion: SessionCompletionState = .none,
        unread: Bool = false,
        at time: TimeInterval = 0
    ) -> SessionRecord {
        SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/states"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Task", status: status,
            updatedAt: Date(timeIntervalSince1970: time), hasUnreadUpdate: unread, completionState: completion)
    }

    private func status(
        _ session: SessionRecord, _ detail: TaskAttentionDetail? = nil, shellBusy: Bool = false
    ) -> SidebarTaskStatus? {
        SidebarTaskIndicatorProjection.status(of: session, detail: detail, isShellBusy: shellBusy)
    }

    func testEachTaskStatusHasItsOwnRowState() {
        // Waiting: an approval unless the turn asked a question; a Codex question keeps the turn running.
        XCTAssertEqual(status(task(.waitingForApproval)), .awaitingApproval)
        XCTAssertEqual(status(task(.waitingForApproval), TaskAttentionDetail(pendingRequest: .approval)), .awaitingApproval)
        XCTAssertEqual(status(task(.waitingForApproval), TaskAttentionDetail(pendingRequest: .input)), .needsInput)
        XCTAssertEqual(status(task(.running), TaskAttentionDetail(pendingRequest: .input)), .needsInput)
        XCTAssertEqual(status(task(.waitingForApproval, unread: true)), .awaitingApproval,
                       "A waiting task is not shown as running, as it was before")
        // Working, and a bash-mode command whatever the provider says.
        XCTAssertEqual(status(task(.running)), .running)
        XCTAssertEqual(status(task(.running, unread: true)), .running)
        for provider in [SessionStatus.ready, .completed, .failed] {
            XCTAssertEqual(status(task(provider, completion: .completed, unread: true), shellBusy: true), .running)
        }
        XCTAssertEqual(status(task(.waitingForApproval), shellBusy: true), .awaitingApproval)
        // A failed turn, also once the task has reattached and reads ready.
        XCTAssertEqual(status(task(.failed, completion: .failed)), .failed(message: nil))
        XCTAssertEqual(status(task(.ready, completion: .failed, unread: true)), .failed(message: nil))
        XCTAssertEqual(status(task(.failed), TaskAttentionDetail(errorMessage: "Connection lost")),
                       .failed(message: "Connection lost"))
        // A plan limit names the stop more exactly than the failure it caused.
        XCTAssertEqual(status(task(.completed, completion: .completed), TaskAttentionDetail(usageLimit: limit)),
                       .usageLimit(limit))
        XCTAssertEqual(status(task(.failed, completion: .failed), TaskAttentionDetail(usageLimit: limit)),
                       .usageLimit(limit))
        XCTAssertEqual(status(task(.running), TaskAttentionDetail(usageLimit: limit)), .running,
                       "A new turn running is past the limit")
        // Unread, however the turn finished or the person marked it.
        XCTAssertEqual(status(task(.completed, completion: .completed, unread: true)), .unread)
        XCTAssertEqual(status(task(.ready, unread: true)), .unread)
        XCTAssertNil(status(task(.ready)))
        XCTAssertNil(status(task(.completed, completion: .completed)))
        XCTAssertNil(status(task(.ready), TaskAttentionDetail(pendingRequest: .approval)),
                     "A request left pending in a saved transcript does not make an idle task wait")
    }

    func testEachStateIsNamedInTheClaudeAppsWords() throws {
        XCTAssertEqual(SidebarTaskStatus.awaitingApproval.accessibilityName, L10n.string("Awaiting input"))
        XCTAssertEqual(SidebarTaskStatus.needsInput.accessibilityName, L10n.string("Awaiting answer"))
        XCTAssertEqual(SidebarTaskStatus.failed(message: nil).accessibilityName,
                       L10n.string("Task encountered a system error"))
        XCTAssertEqual(SidebarTaskStatus.running.accessibilityName, L10n.string("Running"))
        XCTAssertEqual(SidebarTaskStatus.unread.accessibilityName, L10n.string("Unread response"))
        XCTAssertEqual(SidebarTaskStatus.usageLimit(limit).accessibilityName, L10n.string("Session limit reached"))
        XCTAssertNotEqual(SidebarTaskStatus.awaitingApproval.accessibilityName, L10n.string("Running"))

        XCTAssertEqual(SidebarTaskStatus.failed(message: "Stream closed\n  at reader.swift:12").help,
                       L10n.string("Task encountered a system error") + "\nStream closed")
        XCTAssertEqual(SidebarTaskStatus.failed(message: nil).help, L10n.string("Task encountered a system error"))
        XCTAssertEqual(SidebarTaskStatus.usageLimit(limit).help,
                       L10n.string("Session limit reached") + "\n" + (ProviderNoticeText.limitReset(limit) ?? ""))
        XCTAssertEqual(SidebarTaskStatus.running.help, L10n.string("Running"))

        // The Korean catalog has the Claude app's own Korean for the marks (ion-dist `ko-KR`), and
        // the Codex app's for the failure, which the Claude app names by each kind of error.
        let korean = try XCTUnwrap(Bundle.module.path(forResource: "Localizable", ofType: "strings", inDirectory: "ko.lproj"))
        let catalog = try XCTUnwrap(NSDictionary(contentsOfFile: korean) as? [String: String])
        XCTAssertEqual(catalog["Awaiting input"], "입력 대기 중")
        XCTAssertEqual(catalog["Awaiting answer"], "답변 대기 중")
        XCTAssertEqual(catalog["Task encountered a system error"], "작업에 시스템 오류가 발생했습니다")
        XCTAssertEqual(catalog["Running"], "실행 중")
        XCTAssertEqual(catalog["Unread response"], "읽지 않은 응답")
        XCTAssertEqual(catalog["Hide nested sessions"], "중첩된 세션 숨기기")
        XCTAssertEqual(catalog["Show nested sessions"], "중첩된 세션 표시")
        XCTAssertEqual(catalog["%lld nested sessions"], "중첩된 세션 %lld개")
        XCTAssertEqual(catalog["%lld more nested sessions"], "중첩된 세션 %lld개 더 보기")
        XCTAssertEqual(catalog["Nested session"], "중첩 세션")
        XCTAssertEqual(catalog["View activity"], "활동 보기")
        XCTAssertEqual(catalog["View activity, needs attention"], "활동 보기, 확인 필요")
        XCTAssertEqual(catalog["Turn off activity view"], "활동 보기 끄기")
        XCTAssertEqual(catalog["Mark all as read"], "모두 읽음으로 표시")
        XCTAssertEqual(catalog["Nothing needs attention"], "주의가 필요한 항목이 없습니다")
        XCTAssertEqual(catalog["Priority"], "우선순위")
    }

    func testRowsHoldingSeveralTasksShowTheMostUrgent() {
        let approval = task(.waitingForApproval)
        let question = task(.running)
        let failed = task(.failed, completion: .failed)
        let limited = task(.completed, completion: .completed)
        let running = task(.running)
        let unread = task(.completed, completion: .completed, unread: true)
        let idle = task(.ready)
        let details = [question.id: TaskAttentionDetail(pendingRequest: .input),
                       limited.id: TaskAttentionDetail(usageLimit: limit)]
        func summary(_ sessions: [SessionRecord]) -> SidebarTaskStatus? {
            SidebarTaskIndicatorProjection.summary(of: sessions, details: details)
        }

        XCTAssertEqual(
            [SidebarTaskStatus.unread, .reconnecting, .running, .usageLimit(limit), .failed(message: nil), .waitingInBrowser,
             .needsInput, .awaitingApproval].map(\.urgency),
            [7, 6, 5, 4, 3, 2, 1, 0])
        // A tab of the task's browser waiting on the person (a passkey, a dialog) shows whatever the turn does.
        XCTAssertEqual(SidebarTaskIndicatorProjection.status(
            of: idle, detail: TaskAttentionDetail(browserWait: BrowserPersonWait(kind: .passkey, id: "window-1"))),
                       .waitingInBrowser)
        XCTAssertEqual(summary([idle, unread, running, limited, failed, question, approval]), .awaitingApproval)
        XCTAssertEqual(summary([idle, unread, running, limited, failed, question]), .needsInput)
        XCTAssertEqual(summary([idle, unread, running, limited, failed]), .failed(message: nil))
        XCTAssertEqual(summary([idle, unread, running, limited]), .usageLimit(limit))
        XCTAssertEqual(summary([unread, idle, running]), .running, "As the Codex app's collapsed project: running first")
        XCTAssertEqual(summary([idle, unread]), .unread)
        XCTAssertNil(summary([idle]))
        XCTAssertNil(summary([]))
        XCTAssertEqual(SidebarTaskIndicatorProjection.summary(of: [idle, unread], shellBusy: [idle.id]), .running)
    }

    func testTheRowEndListsItsMarksInOneOrder() {
        XCTAssertEqual(SidebarTaskIndicatorProjection.trailingItems(isCloud: true, isWorktree: true, cpuPercent: 142, status: .running),
                       [.cloud, .worktree, .cpu(142), .status(.running)])
        XCTAssertEqual(SidebarTaskIndicatorProjection.trailingItems(isWorktree: true, cpuPercent: 142, status: .running),
                       [.worktree, .cpu(142), .status(.running)])
        XCTAssertEqual(SidebarTaskIndicatorProjection.trailingItems(cpuPercent: 64, status: .awaitingApproval),
                       [.cpu(64), .status(.awaitingApproval)], "The CPU stays beside any state")
        XCTAssertEqual(SidebarTaskIndicatorProjection.trailingItems(isCloud: true, status: nil), [.cloud])
        XCTAssertEqual(SidebarTaskIndicatorProjection.trailingItems(status: .unread), [.status(.unread)])
        XCTAssertEqual(SidebarTaskIndicatorProjection.trailingItems(status: nil), [])
    }
}
