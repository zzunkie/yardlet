import Foundation
import UserNotifications
import XCTest
@testable import NativeHarnessClient

/// Notifications that lead back to their task, "Allow once" from an approval notification, and the
/// Dock badge and bounce. Every test uses a recording notification center and a recording Dock, so
/// nothing reaches Notification Center or the Dock.
@MainActor
final class NotificationRoutingTests: XCTestCase {
    // MARK: - A click opens the task

    func testClickingANotificationBringsYardletForwardAndOpensItsTask() async throws {
        let first = task("First"), second = task("Second")
        let (model, _, attention) = makeModel(sessions: [first, second])
        model.splits.activate(.session(first.id))

        await model.handleNotificationResponse(.init(target: .init(sessionID: second.id), action: .open))

        XCTAssertEqual(model.splits.selection, .session(second.id))
        XCTAssertEqual(model.store.selectedSessionID, second.id)
        XCTAssertEqual(attention.bringForwardCount, 1)
    }

    func testClickingANotificationForATaskInASplitViewSelectsItsPane() async throws {
        let left = task("Left"), right = task("Right"), other = task("Other")
        let (model, _, _) = makeModel(sessions: [left, right, other])
        model.splits.activate(.session(left.id))
        model.splits.split(.right, placing: right.id)
        let split = try XCTUnwrap(model.splits.activeSplit)
        XCTAssertEqual(split.focusedSessionID, right.id)
        model.splits.activate(.session(other.id))

        await model.handleNotificationResponse(.init(target: .init(sessionID: left.id), action: .open))

        XCTAssertEqual(model.splits.selection, .split(split.id))
        XCTAssertEqual(model.splits.focusedSessionID, left.id)
        XCTAssertEqual(model.store.selectedSessionID, left.id)
        XCTAssertEqual(model.splits.activeSplit?.sessionIDs, [left.id, right.id])
    }

    func testANotificationForAnArchivedOrDeletedTaskLeavesTheWindowWhereItWas() async throws {
        let kept = task("Kept"), archived = task("Archived")
        let (model, _, attention) = makeModel(sessions: [kept, archived])
        model.splits.activate(.session(kept.id))
        try await model.store.archiveSession(id: archived.id)

        let archivedOutcome = await model.openTask(from: .init(sessionID: archived.id))
        XCTAssertEqual(archivedOutcome, .archived)
        XCTAssertEqual(model.archivedTasksRevealRequest, 1)
        XCTAssertEqual(model.splits.selection, .session(kept.id))

        let deletedOutcome = await model.openTask(from: .init(sessionID: UUID()))
        XCTAssertEqual(deletedOutcome, .missing)
        XCTAssertEqual(model.archivedTasksRevealRequest, 1)
        XCTAssertEqual(model.splits.selection, .session(kept.id))
        XCTAssertEqual(attention.bringForwardCount, 2)
    }

    func testAClickThatLaunchedYardletWaitsForTheTaskIndex() async throws {
        let first = task("First"), second = task("Second")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NotificationRoutingTests")))
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository(sessions: [first, second])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            systemNotificationCenter: RecordingCenter(),
            applicationAttention: RecordingAttention()
        )
        XCTAssertTrue(model.isRestoringIndex)

        await model.handleNotificationResponse(.init(target: .init(sessionID: second.id), action: .open))
        XCTAssertEqual(model.pendingNotificationResponses.count, 1)

        await model.restoreIndex()
        try await waitUntil { model.store.selectedSessionID == second.id }
        XCTAssertEqual(model.store.selectedSessionID, second.id)
        XCTAssertTrue(model.pendingNotificationResponses.isEmpty)
    }

    func testANotificationCarriesItsTaskAndReadsBackOnlyAClickOrAllowOnce() throws {
        let sessionID = UUID()
        let target = SystemNotificationTarget(sessionID: sessionID, requestID: "bash-1")
        let userInfo: [AnyHashable: Any] = target.userInfo
        XCTAssertEqual(SystemNotificationTarget(userInfo: userInfo), target)

        XCTAssertEqual(
            LocalSystemNotificationCenter.response(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: userInfo),
            .init(target: target, action: .open)
        )
        XCTAssertEqual(
            LocalSystemNotificationCenter.response(
                actionIdentifier: LocalSystemNotificationCenter.allowOnceActionIdentifier, userInfo: userInfo
            ),
            .init(target: target, action: .allowOnce)
        )
        XCTAssertNil(LocalSystemNotificationCenter.response(
            actionIdentifier: UNNotificationDismissActionIdentifier, userInfo: userInfo
        ))
        XCTAssertNil(LocalSystemNotificationCenter.response(
            actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: ["other": "app"]
        ))
        XCTAssertNil(SystemNotificationTarget(userInfo: [SystemNotificationTarget.sessionKey: sessionID.uuidString])?.requestID)
    }

    /// A dot's notification carries its dot and account, not a task; its click brings Yardlet forward
    /// and asks a window to show that dot, even while the task index is read, and selects no task.
    /// Turning the setting off ends the watch and forgets the account it followed.
    func testADotsNotificationLeadsToItsDotAndTheSettingLeavesNothingWhenOff() async throws {
        let first = task("First")
        let (model, center, attention) = makeModel(sessions: [first])
        model.splits.activate(.session(first.id))
        let dot = PersonalAgent(id: .init(accountID: "account", userID: "person", agentID: "dot", roomID: "room"),
                                name: "Atlas", rootThreadID: nil, isPaused: false, isPrimary: true)
        await model.postPersonalAgentNotification(.init(agent: dot, accountChoiceID: "codex:home",
                                                        preview: "May I deploy?", isRequest: true))
        let posted = try XCTUnwrap(center.posted.last)
        XCTAssertEqual(posted.title, "Atlas")
        XCTAssertEqual(posted.body, L10n.format("Needs your input: %@", "May I deploy?"))
        XCTAssertEqual(posted.identifier, "yardlet-dot-room-request")
        XCTAssertFalse(posted.offersAllowOnce)
        let reveal = PersonalAgentReveal(agent: dot.id, accountChoiceID: "codex:home")
        XCTAssertEqual(posted.target, SystemNotificationTarget(personalAgent: reveal))
        let userInfo: [AnyHashable: Any] = posted.target.userInfo
        XCTAssertNil(userInfo[SystemNotificationTarget.sessionKey])
        XCTAssertEqual(SystemNotificationTarget(userInfo: userInfo), posted.target)

        await model.handleNotificationResponse(.init(target: posted.target, action: .open))
        XCTAssertEqual(model.personalAgentReveal, reveal)
        XCTAssertEqual(attention.bringForwardCount, 1)
        XCTAssertEqual(model.splits.selection, .session(first.id))
        XCTAssertEqual(model.taskSurfaceRevealRequest, 0)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("PersonalAgentNotifications")))
        XCTAssertTrue(PersonalAgentNotificationPreference.isOn(in: defaults), "On by default")
        defaults.set("codex:home", forKey: PersonalAgentNotificationPreference.accountKey)
        defaults.set(false, forKey: PersonalAgentNotificationPreference.key)
        model.followPersonalAgents(defaults: defaults, force: true)
        XCTAssertNil(defaults.object(forKey: PersonalAgentNotificationPreference.accountKey))
        XCTAssertNil(model.personalAgentWatch.source)
        // A window that reads dots while it is off records nothing.
        model.notePersonalAgentsRead(accountChoiceID: "codex:home", hasAgents: true, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: PersonalAgentNotificationPreference.accountKey))
    }

    // MARK: - Which finished turns are announced

    /// A turn another task's message opened ends without a notification; one the person asked for is
    /// announced (`TurnCompletionAnnouncement`).
    func testAFinishedTurnIsAnnouncedOnlyWhenThePersonAskedForIt() async throws {
        let claude = try await makeClaudeModel()
        defer { claude.cleanUp() }
        let (model, center, session, transport) = (claude.model, claude.center, claude.session, claude.transport)
        model.store.selectedSessionID = nil
        let result: JSONValue = .object([
            "type": .string("result"), "subtype": .string("success"), "is_error": .bool(false),
            "session_id": .string(try XCTUnwrap(model.store.sessions.first { $0.id == session.id }?.providerSessionID))
        ])
        func completed() -> Bool { model.store.sessions.first { $0.id == session.id }?.completionState == .completed }

        let delivery = await model.deliverTaskMessage(
            TaskMessage(senderID: UUID().uuidString, senderName: "Parent", body: "Report when the build passes."), to: session)
        XCTAssertEqual(delivery, .delivered)
        await transport.emit(result)
        try await waitUntil(completed)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(center.posted.isEmpty)

        await model.send("Summarize what changed.", to: session)
        await transport.emit(result)
        let announced = try await waitForPost(in: center)
        XCTAssertEqual(announced.title, L10n.string("Task completed"))
        XCTAssertEqual(announced.target, SystemNotificationTarget(sessionID: session.id))
        await model.shutdown()
    }

    // MARK: - Which notifications offer "Allow once"

    func testAllowOnceIsOfferedOnlyForAPlainToolApproval() {
        let plain = PermissionRequest(id: "1", title: "Run", detail: nil, command: "ls")
        XCTAssertEqual(NotificationApprovalProjection.allowOnce(for: plain), .decision(.allow))

        let claudeOffer = [
            PermissionRequestAction(id: "allow", label: "Allow", decision: .allow, kind: "allow_once"),
            PermissionRequestAction(id: "allow_session", label: "Allow for session", decision: .allow, kind: "allow_session"),
            PermissionRequestAction(id: "deny", label: "Deny", decision: .deny, kind: "reject_once")
        ]
        XCTAssertEqual(
            NotificationApprovalProjection.allowOnce(for: request(actions: claudeOffer)),
            .providerAction(claudeOffer[0])
        )

        // The provider's narrowest allow is standing, so there is no one-time allow to give.
        let onlyAlways = [
            PermissionRequestAction(id: "always", label: "Always", decision: .allow, kind: "allow_always"),
            PermissionRequestAction(id: "reject", label: "Reject", decision: .deny, kind: "reject_once")
        ]
        XCTAssertNil(NotificationApprovalProjection.allowOnce(for: request(actions: onlyAlways)))

        let question = PermissionQuestion(question: "Which?", options: [.init(label: "A"), .init(label: "B")])
        XCTAssertNil(NotificationApprovalProjection.allowOnce(for: request(structured: .questions([question]))))
        XCTAssertNil(NotificationApprovalProjection.allowOnce(for: request(structured: .plan("1. Do it"))))
        XCTAssertNil(NotificationApprovalProjection.allowOnce(for: PermissionRequest(
            id: "held", title: "AskUserQuestion", detail: nil, command: nil, requiresInAppAnswer: true
        )))
        XCTAssertNil(NotificationApprovalProjection.allowOnce(for: PermissionRequest(
            id: "mode", title: "Ready to code?", detail: "switch_mode", command: nil,
            actions: [PermissionRequestAction(id: "yes", label: "Yes", decision: .allow, kind: "allow_once")]
        )))
    }

    func testCodexOffersAllowOnceOnlyForCommandAndFileChangeApprovals() {
        XCTAssertEqual(
            NotificationApprovalProjection.allowOnce(for: codexRequest(.commandExecutionApproval, "item/commandExecution/requestApproval")),
            .codex(.command(.accept))
        )
        XCTAssertEqual(
            NotificationApprovalProjection.allowOnce(for: codexRequest(.fileChangeApproval, "item/fileChange/requestApproval")),
            .codex(.fileChange(.accept))
        )
        XCTAssertEqual(
            NotificationApprovalProjection.allowOnce(for: codexRequest(.execCommandApproval, "execCommandApproval")),
            .codex(.legacyReview(.approved))
        )
        // More sandbox or network access is Codex's Full access counterpart: answered in the app.
        XCTAssertNil(NotificationApprovalProjection.allowOnce(
            for: codexRequest(.permissionsApproval, "item/permissions/requestApproval")
        ))
        XCTAssertNil(NotificationApprovalProjection.allowOnce(for: codexRequest(.toolUserInput, "item/tool/requestUserInput")))
        XCTAssertNil(NotificationApprovalProjection.allowOnce(
            for: codexRequest(.mcpElicitation, "mcpServer/elicitation/request")
        ))
        XCTAssertNil(NotificationApprovalProjection.allowOnce(for: codexRequest(.dynamicToolCall, "item/tool/call")))
        var answered = codexRequest(.commandExecutionApproval, "item/commandExecution/requestApproval")
        answered.resolution = .resolved(.object(["decision": .string("accept")]))
        XCTAssertNil(NotificationApprovalProjection.allowOnce(for: answered))
    }

    // MARK: - Allow once from the notification (Claude Code, the real adapter on a fake CLI)

    func testABackgroundApprovalNotificationNamesItsRequestAndOnlyAToolCallOffersAllowOnce() async throws {
        let claude = try await makeClaudeModel()
        defer { claude.cleanUp() }
        let (model, center, session, transport) = (claude.model, claude.center, claude.session, claude.transport)
        // The task stays selected, but neither window shows Tasks any more: one turned to personal
        // agents, the other closed.
        XCTAssertEqual(model.store.selectedSessionID, session.id)
        let (first, second) = (UUID(), UUID())
        model.setShowsTasks(true, inWindow: first)
        model.setShowsTasks(true, inWindow: second)
        model.setShowsTasks(false, inWindow: first)
        XCTAssertTrue(model.isSessionVisible(session.id), "The other window still shows the task")
        model.setShowsTasks(false, inWindow: second)
        XCTAssertFalse(model.isSessionVisible(session.id))

        await transport.emit(canUseTool("bash-1", tool: "Bash", input: .object(["command": .string("swift test")])))
        let approval = try await waitForPost(in: center)
        XCTAssertEqual(model.store.sessions.first { $0.id == session.id }?.hasUnreadUpdate, true)
        XCTAssertEqual(approval.target, SystemNotificationTarget(sessionID: session.id, requestID: "bash-1"))
        XCTAssertTrue(approval.offersAllowOnce)
        XCTAssertEqual(approval.identifier, "yardlet-session-\(session.id.uuidString)-waitingForApproval-bash-1")
        XCTAssertEqual(approval.title, L10n.string("Task needs your attention"))

        await model.respond(to: "bash-1", decision: .deny, in: session)
        await transport.emit(canUseTool("question-1", tool: "AskUserQuestion", input: .object([
            "questions": .array([.object([
                "question": .string("Which layout?"),
                "header": .string("Layout"),
                "multiSelect": .bool(false),
                "options": .array([.object(["label": .string("Grid")]), .object(["label": .string("List")])])
            ])])
        ])))
        let question = try await waitForPost(in: center, count: 2)
        XCTAssertEqual(question.target.requestID, "question-1")
        XCTAssertFalse(question.offersAllowOnce)

        await model.respond(
            to: "question-1",
            answer: .questions([.init(question: "Which layout?", selectedLabels: ["Grid"])]),
            in: session
        )
        await transport.emit(canUseTool("held-1", tool: "Bash", input: .object(["command": .string("rm -rf build")]),
                                        extra: ["classifier_approvable": .bool(false)]))
        let held = try await waitForPost(in: center, count: 3)
        XCTAssertEqual(held.target.requestID, "held-1")
        XCTAssertFalse(held.offersAllowOnce)
        await model.shutdown()
    }

    func testAllowOnceAnswersOnlyThatStillPendingRequestOfThatTask() async throws {
        let claude = try await makeClaudeModel()
        defer { claude.cleanUp() }
        let (model, center, session, transport) = (claude.model, claude.center, claude.session, claude.transport)
        let createdOther = await model.createSession(
            harness: .codex, workspaceURL: URL(filePath: "/tmp/notification-other"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Other task"
        )
        let other = try XCTUnwrap(createdOther)
        model.store.selectedSessionID = other.id

        await transport.emit(canUseTool("bash-1", tool: "Bash", input: .object(["command": .string("swift test")]),
                                        suggestions: [Self.bashRule]))
        let posted = try await waitForPost(in: center)
        XCTAssertTrue(posted.offersAllowOnce)
        let sentBefore = await transport.sentValues.count

        // Another request ID, another task, or no request named: nothing is answered.
        let otherRequest = await model.allowOnce(.init(sessionID: session.id, requestID: "bash-2"))
        let otherTask = await model.allowOnce(.init(sessionID: other.id, requestID: "bash-1"))
        let noRequest = await model.allowOnce(.init(sessionID: session.id))
        XCTAssertFalse(otherRequest)
        XCTAssertFalse(otherTask)
        XCTAssertFalse(noRequest)
        let sentAfterRefusals = await transport.sentValues.count
        XCTAssertEqual(sentAfterRefusals, sentBefore)

        await model.handleNotificationResponse(.init(target: posted.target, action: .allowOnce))
        let sent = await transport.sentValues
        let answer = try XCTUnwrap(sent.last?["response"])
        XCTAssertEqual(answer["request_id"]?.stringValue, "bash-1")
        XCTAssertEqual(answer["response"]?["behavior"]?.stringValue, "allow")
        // Once: the CLI's "don't ask again" rules are not applied.
        XCTAssertNil(answer["response"]?["updatedPermissions"])
        XCTAssertTrue(model.transcriptBySessionID[session.id]?.contains { entry in
            if case let .permission(request, .allowed) = entry.content { request.id == "bash-1" } else { false }
        } == true)
        // Answered without bringing Yardlet forward or changing the shown task.
        XCTAssertEqual(claude.attention.bringForwardCount, 0)
        XCTAssertEqual(model.store.selectedSessionID, other.id)
        XCTAssertTrue(center.removed.contains(posted.identifier))

        // The same notification again: the request no longer waits, so the action opens the task.
        await model.handleNotificationResponse(.init(target: posted.target, action: .allowOnce))
        let sentAtEnd = await transport.sentValues.count
        XCTAssertEqual(sentAtEnd, sent.count)
        XCTAssertEqual(model.store.selectedSessionID, session.id)
        XCTAssertEqual(claude.attention.bringForwardCount, 1)
        await model.shutdown()
    }

    func testAllowOnceNeverAnswersAQuestionAndOpensItsTaskInstead() async throws {
        let claude = try await makeClaudeModel()
        defer { claude.cleanUp() }
        let (model, _, session, transport) = (claude.model, claude.center, claude.session, claude.transport)
        model.store.selectedSessionID = nil
        await transport.emit(canUseTool("plan-1", tool: "ExitPlanMode", input: .object(["plan": .string("1. Build")])))
        try await waitUntil { model.pendingApproval("plan-1", in: model.store.sessions[0]) != nil }
        let sentBefore = await transport.sentValues.count

        await model.handleNotificationResponse(.init(target: .init(sessionID: session.id, requestID: "plan-1"), action: .allowOnce))

        let sentAfter = await transport.sentValues.count
        XCTAssertEqual(sentAfter, sentBefore)
        XCTAssertEqual(model.store.selectedSessionID, session.id)
        XCTAssertEqual(claude.attention.bringForwardCount, 1)
        await model.shutdown()
    }

    // MARK: - Allow once from the notification (Codex)

    func testAllowOnceAcceptsAPendingCodexCommandButNotAPermissionsRequest() async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NotificationRoutingTests")))
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults, keyPrefix: "pending."),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            systemNotificationCenter: RecordingCenter(),
            applicationAttention: RecordingAttention(),
            restoresIndexOnLaunch: false
        )
        let createdSession = await model.createSession(
            harness: .codex, workspaceURL: URL(filePath: "/tmp/notification-codex"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Codex approvals"
        )
        let session = try XCTUnwrap(createdSession)
        var state = CodexTaskState.empty
        let reducer = CodexTaskReducer()
        XCTAssertTrue(reducer.applySnapshot(.object([
            "id": .string("thread-1"),
            "turns": .array([.object(["id": .string("turn-1"), "status": .string("inProgress"), "items": .array([])])])
        ]), to: &state))
        XCTAssertTrue(reducer.applyServerRequest(
            id: .string("command-1"), method: "item/commandExecution/requestApproval",
            params: .object(["threadId": .string("thread-1"), "turnId": .string("turn-1"), "command": .string("swift test")]),
            sequence: 1, to: &state
        ))
        XCTAssertTrue(reducer.applyServerRequest(
            id: .string("access-1"), method: "item/permissions/requestApproval",
            params: .object(["threadId": .string("thread-1"), "turnId": .string("turn-1"),
                             "permissions": .object(["network": .object(["enabled": .bool(true)])])]),
            sequence: 2, to: &state
        ))
        await adapter.emitPresentation(state, for: session.id)
        await adapter.emit(.sessionStatusChanged(.waitingForApproval), for: session.id, sequence: 1)
        try await waitUntil {
            model.store.sessions.first?.status == .waitingForApproval
                && model.codexPresentationBySessionID[session.id]?.serverRequestsByID.count == 2
        }
        XCTAssertEqual(model.pendingApprovals(in: model.store.sessions[0]).map(\.id), ["s:access-1", "s:command-1"])

        let access = await model.allowOnce(.init(sessionID: session.id, requestID: "s:access-1"))
        XCTAssertFalse(access)
        let command = await model.allowOnce(.init(sessionID: session.id, requestID: "s:command-1"))
        XCTAssertTrue(command)
        let requests = try XCTUnwrap(model.codexPresentationBySessionID[session.id]?.serverRequestsByID)
        XCTAssertEqual(
            requests["s:command-1"].map { CodexRequestResponseProjection.state($0.resolution) },
            .allowed
        )
        XCTAssertEqual(requests["s:access-1"]?.resolution, .pending)
        await model.shutdown()
    }

    // MARK: - Withdrawing answered approvals

    func testAnApprovalAnsweredOnItsCardWithdrawsItsNotification() async throws {
        let claude = try await makeClaudeModel()
        defer { claude.cleanUp() }
        let (model, center, session, transport) = (claude.model, claude.center, claude.session, claude.transport)
        model.store.selectedSessionID = nil

        await transport.emit(canUseTool("bash-1", tool: "Bash", input: .object(["command": .string("ls")])))
        let posted = try await waitForPost(in: center)
        XCTAssertTrue(center.removed.isEmpty)

        // The card's Allow is the same model call as before.
        await model.respond(to: "bash-1", decision: .allow, in: session)

        XCTAssertEqual(center.removed, [posted.identifier])
        XCTAssertNil(model.approvalNotificationIDs[session.id])
        await model.shutdown()
    }

    func testAnApprovalThatStopsWaitingWithdrawsItsNotification() async throws {
        let adapter = FakeHarnessAdapter(kind: .claudeCode)
        let center = RecordingCenter()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NotificationRoutingTests")))
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter },
            systemNotificationCenter: center,
            restoresIndexOnLaunch: false
        )
        let createdSession = await model.createSession(
            harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/notification-expiry"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Expiry"
        )
        let session = try XCTUnwrap(createdSession)
        model.store.selectedSessionID = nil
        await adapter.emit(.permissionRequested(PermissionRequest(id: "p-1", title: "Run", detail: nil, command: "ls")),
                           for: session.id, sequence: 1)
        await adapter.emit(.sessionStatusChanged(.waitingForApproval), for: session.id, sequence: 2)
        let posted = try await waitForPost(in: center)
        XCTAssertEqual(posted.target.requestID, "p-1")

        await adapter.emit(.permissionExpired("p-1"), for: session.id, sequence: 3)
        await adapter.emit(.sessionStatusChanged(.running), for: session.id, sequence: 4)
        try await waitUntil { center.removed == [posted.identifier] }
        await model.shutdown()
    }

    // MARK: - Dock badge

    func testTheBadgeCountsTheTasksTheAttentionCommandWouldVisit() {
        func counted(_ status: SessionStatus, unread: Bool) -> Bool {
            TaskAttentionProjection.needsAttention(task("T", status: status, unread: unread))
        }
        XCTAssertTrue(counted(.waitingForApproval, unread: false))
        XCTAssertTrue(counted(.failed, unread: true))
        XCTAssertTrue(counted(.completed, unread: true))
        XCTAssertTrue(counted(.ready, unread: true))
        XCTAssertFalse(counted(.running, unread: true))
        XCTAssertFalse(counted(.failed, unread: false))
        XCTAssertFalse(counted(.completed, unread: false))
        XCTAssertFalse(counted(.ready, unread: false))

        let sessions = [
            task("Waiting", status: .waitingForApproval),
            task("Failed", status: .failed, unread: true),
            task("Seen failure", status: .failed),
            task("Running", status: .running)
        ]
        XCTAssertEqual(TaskAttentionProjection.count(in: sessions), 2)
        // The same definition picks ⌥⌘A's next task.
        XCTAssertEqual(TaskAttentionProjection.nextSession(in: sessions, excluding: nil), sessions[0].id)
    }

    func testTheDockBadgeFollowsTheTasksAndTheBadgePermission() async throws {
        let waiting = task("Waiting", status: .waitingForApproval)
        let failed = task("Failed", status: .failed, unread: true)
        let idle = task("Idle")
        let (model, center, attention) = makeModel(sessions: [waiting, failed, idle])
        XCTAssertEqual(attention.badges, [], "No badge before macOS says badges are allowed")

        center.badgesAllowed = true
        await model.refreshNotificationPermission()
        XCTAssertEqual(attention.badges, ["2"])

        await model.store.markUnread(id: idle.id)
        try await waitUntil { attention.badges.last == "3" }

        await model.store.markRead(id: failed.id)
        try await waitUntil { attention.badges.last == "2" }
        await model.store.markRead(id: idle.id)
        try await model.store.updateSession(id: waiting.id, status: .running)
        // Nothing needs the person: the badge clears.
        try await waitUntil { attention.badges.last == .some(nil) }
        XCTAssertEqual(model.attentionBadgeCount, 0)

        // Badges turned off in System Settings: none, whatever the count.
        await model.store.markUnread(id: idle.id)
        center.badgesAllowed = false
        await model.refreshNotificationPermission()
        try await waitUntil { attention.badges.last == .some(nil) }
        XCTAssertEqual(attention.badges.last, .some(nil))
        XCTAssertEqual(model.attentionBadgeCount, 1)
    }

    // MARK: - Dock bounce

    func testANewApprovalBouncesTheDockOnceOnlyWhileYardletIsBehind() {
        let attention = RecordingAttention()
        let dock = DockAttention(application: attention)
        let sessionID = UUID()

        attention.isActive = false
        XCTAssertTrue(dock.announceApproval("r1", in: sessionID))
        XCTAssertFalse(dock.announceApproval("r1", in: sessionID))
        XCTAssertEqual(attention.attentionRequests, 1)

        attention.isActive = true
        XCTAssertFalse(dock.announceApproval("r2", in: sessionID))
        attention.isActive = false
        XCTAssertFalse(dock.announceApproval("r2", in: sessionID), "Seen while Yardlet was in front")
        XCTAssertTrue(dock.announceApproval("r3", in: sessionID))
        XCTAssertEqual(attention.attentionRequests, 2)

        // A later turn may reuse a request ID once the task stopped waiting.
        dock.forgetApprovals(in: sessionID)
        XCTAssertTrue(dock.announceApproval("r1", in: sessionID))
        XCTAssertEqual(attention.attentionRequests, 3)
    }

    func testAnApprovalArrivingBehindOtherAppsBouncesOnceForThatRequest() async throws {
        let claude = try await makeClaudeModel()
        defer { claude.cleanUp() }
        let (model, _, session, transport) = (claude.model, claude.center, claude.session, claude.transport)
        claude.attention.isActive = false

        await transport.emit(canUseTool("bash-1", tool: "Bash", input: .object(["command": .string("ls")])))
        try await waitUntil { claude.attention.attentionRequests == 1 }
        // The task is shown; the bounce does not depend on which task the window shows.
        XCTAssertEqual(model.store.selectedSessionID, session.id)

        await transport.emit(canUseTool("bash-1", tool: "Bash", input: .object(["command": .string("ls")])))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(claude.attention.attentionRequests, 1)
        await model.shutdown()
    }

    // MARK: - Helpers

    private static let bashRule: JSONValue = .object([
        "type": .string("addRules"),
        "rules": .array([.object(["toolName": .string("Bash"), "ruleContent": .string("swift test:*")])]),
        "behavior": .string("allow"),
        "destination": .string("localSettings")
    ])

    private func task(_ title: String, status: SessionStatus = .ready, unread: Bool = false) -> SessionRecord {
        SessionRecord(
            harness: .claudeCode,
            workspaceURL: URL(filePath: "/tmp/notification-routing"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"),
            title: title,
            status: status,
            hasUnreadUpdate: unread
        )
    }

    private func request(
        actions: [PermissionRequestAction] = [],
        structured: PermissionRequestStructure? = nil
    ) -> PermissionRequest {
        PermissionRequest(id: "r", title: "Run", detail: nil, command: nil, actions: actions, structured: structured)
    }

    private func codexRequest(_ kind: CodexServerRequestKind, _ method: String) -> CodexServerRequestState {
        CodexServerRequestState(id: "s:1", method: method, kind: kind, threadID: "thread", turnID: "turn",
                                itemID: "item", params: .object([:]), resolution: .pending)
    }

    private func makeModel(sessions: [SessionRecord]) -> (AppModel, RecordingCenter, RecordingAttention) {
        let center = RecordingCenter()
        let attention = RecordingAttention()
        let model = AppModel(
            store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
            runtimeSelections: RuntimeSelectionStore(
                defaults: UserDefaults(suiteName: testDefaultsSuite("NotificationRoutingTests"))!
            ),
            systemNotificationCenter: center,
            applicationAttention: attention,
            restoresIndexOnLaunch: false
        )
        return (model, center, attention)
    }

    private struct ClaudeModel {
        let model: AppModel
        let center: RecordingCenter
        let attention: RecordingAttention
        let session: SessionRecord
        let transport: FakeClaudeTransport
        let executable: URL
        let root: URL

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// A Claude Code task on the real adapter, whose CLI is a fake transport.
    private func makeClaudeModel() async throws -> ClaudeModel {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-notification-routing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appending(path: "fixture-claude")
        try "#!/bin/sh\nprintf '%s\\n' '2.1.281 (Claude Code)'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path(percentEncoded: false))
        let transport = FakeClaudeTransport()
        let adapter = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(executableURL: executable, transportFactory: { _ in transport }),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        // Another task runs on its own adapter; the fake CLI speaks for the Claude task alone.
        let otherAdapter = FakeHarnessAdapter(kind: .codex)
        let center = RecordingCenter()
        let attention = RecordingAttention()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("NotificationRoutingTests")))
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { kind, _ in kind == .claudeCode ? adapter as any HarnessAdapter : otherAdapter },
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults, keyPrefix: "pending."),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            systemNotificationCenter: center,
            applicationAttention: attention,
            restoresIndexOnLaunch: false
        )
        let createdSession = await model.createSession(
            harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/notification-claude"),
            runtimeExecutableURL: executable, title: "Claude approvals"
        )
        let session = try XCTUnwrap(createdSession)
        return ClaudeModel(model: model, center: center, attention: attention, session: session,
                           transport: transport, executable: executable, root: root)
    }

    private func canUseTool(
        _ requestID: String,
        tool: String,
        input: JSONValue,
        suggestions: [JSONValue]? = nil,
        extra: [String: JSONValue] = [:]
    ) -> JSONValue {
        var request: [String: JSONValue] = [
            "subtype": .string("can_use_tool"),
            "tool_name": .string(tool),
            "input": input,
            "tool_use_id": .string("toolu-\(requestID)")
        ]
        if let suggestions { request["permission_suggestions"] = .array(suggestions) }
        request.merge(extra) { _, new in new }
        return .object([
            "type": .string("control_request"),
            "request_id": .string(requestID),
            "request": .object(request)
        ])
    }

    private func waitForPost(in center: RecordingCenter, count: Int = 1) async throws -> SystemNotification {
        try await waitUntil { center.posted.count >= count }
        return center.posted[count - 1]
    }
}

/// Records what Yardlet would post and withdraw; never reaches Notification Center.
@MainActor
private final class RecordingCenter: SystemNotificationCenter {
    var badgesAllowed = false
    private(set) var posted: [SystemNotification] = []
    private(set) var removed: [String] = []

    func authorization() async -> SystemNotificationAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }

    func post(title: String, body: String, identifier: String) async {
        XCTFail("Task notifications carry their task")
    }

    func post(_ notification: SystemNotification) async {
        posted.append(notification)
    }

    func removeNotifications(identifiers: [String]) {
        removed += identifiers
    }

    func allowsBadges() async -> Bool { badgesAllowed }
}

/// Records Dock badges, bounces and activation; never touches the Dock.
@MainActor
private final class RecordingAttention: ApplicationAttention {
    var isActive = true
    private(set) var badges: [String?] = []
    private(set) var attentionRequests = 0
    private(set) var bringForwardCount = 0

    func setDockBadge(_ label: String?) { badges.append(label) }
    func requestAttention() { attentionRequests += 1 }
    func bringForward() { bringForwardCount += 1 }
}
