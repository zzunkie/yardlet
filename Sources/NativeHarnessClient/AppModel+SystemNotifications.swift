import Foundation
import Observation

/// Notifications that lead back to their task, "Allow once" from an approval notification, and
/// the Dock badge and bounce.
///
/// - A click brings Yardlet forward and opens the task, selecting its pane when it sits in a
///   split view, as the Claude app's click calls `focusAppAndNavigate` to the session. A task
///   archived since shows the archived list; a deleted one only brings Yardlet forward.
/// - "Allow once" answers the very request the notification named, through the same model call
///   as the request card's narrowest allow, and only while that request still waits in that task
///   and the card itself would offer it (`NotificationApprovalProjection`). Otherwise the action
///   opens the task. The notification is withdrawn once its request is answered, wherever.
/// - A request or a question shows while Yardlet is in front too, unless a window draws its task,
///   so the person answers it without leaving the task they work in
///   (`TaskNotificationKind.showsWhileActive`). It says what it asks, in the words a phone's
///   notification has for it (`RemoteTaskProjection.requestSummary`).
/// - A finished turn is announced only when the person asked for it and the task does not go on
///   by itself (`TurnCompletionAnnouncement`).
/// - The Dock badge counts the tasks that need the person (`TaskAttentionProjection`).
extension AppModel {
    enum NotificationOpenOutcome: Equatable {
        case opened
        case archived
        case missing
    }

    func handleNotificationResponse(_ response: SystemNotificationResponse) async {
        // A dot's notification needs no task index.
        if let reveal = response.target.personalAgent { return revealPersonalAgent(reveal) }
        // So does a new mail's.
        if let thread = response.target.mailThread { return revealMailThread(thread) }
        // And a task of another Mac, which opens in that Mac's window; "Allow once" answers there first.
        if let remote = response.target.remoteTask {
            if response.action == .allowOnce, let requestID = response.target.requestID,
               await allowRemoteOnce?(remote.hostID, remote.taskID, requestID) == true {
                withdrawRemoteTaskNotification(hostID: remote.hostID, taskID: remote.taskID)
                return
            }
            withdrawRemoteTaskNotification(hostID: remote.hostID, taskID: remote.taskID)
            applicationAttention?.bringForward()
            return openRemoteTask?(remote.hostID, remote.taskID) ?? ()
        }
        guard !isRestoringIndex else {
            pendingNotificationResponses.append(response)
            return
        }
        switch response.action {
        case .open:
            await openTask(from: response.target)
        case .allowOnce:
            if await !allowOnce(response.target) {
                await openTask(from: response.target)
            }
        }
    }

    /// Clicks that arrived while launch was reading the task index, handled once it has.
    func handlePendingNotificationResponses() {
        let responses = pendingNotificationResponses
        pendingNotificationResponses = []
        guard !responses.isEmpty else { return }
        Task {
            for response in responses { await handleNotificationResponse(response) }
        }
    }

    @discardableResult
    func openTask(from target: SystemNotificationTarget) async -> NotificationOpenOutcome {
        applicationAttention?.bringForward()
        guard let sessionID = target.sessionID else { return .missing }
        if store.sessions.contains(where: { $0.id == sessionID }) {
            // As choosing the task in the sidebar or with ⌥⌘A: a task in a split view opens the
            // split with its pane focused.
            revealTask(sessionID)
            // A browser tab's notification opens the task's panel on that tab.
            if let tab = target.browserTab { showBrowserTab(tab, under: sessionID) }
            // A device handed to the person: the task's panel shows its Simulator tab.
            if target.simulator { showHandedOverSimulator(of: sessionID) }
            return .opened
        }
        if store.archivedSessions == nil { try? await store.loadArchivedSessions() }
        guard store.archivedSessions?.contains(where: { $0.id == sessionID }) == true else {
            return .missing
        }
        archivedTasksRevealRequest += 1
        return .archived
    }

    /// Answers the notification's request with "Allow once" when it still waits in its task and
    /// the notification may answer it. Returns whether it answered.
    @discardableResult
    func allowOnce(_ target: SystemNotificationTarget) async -> Bool {
        guard let requestID = target.requestID,
              let session = store.sessions.first(where: { $0.id == target.sessionID }),
              session.status == .waitingForApproval,
              isAttached(session.id),
              let route = pendingApproval(requestID, in: session)?.allowOnce else { return false }
        return await answer(requestID, with: route, in: session)
    }

    /// Answers the oldest request the task waits on from the composer's keys (`ComposerApprovalKey`):
    /// with its "Allow once", or with the card's one-time denial, as a notification answers it, and only
    /// for a request a notification could answer. Returns whether the key answered; the answer itself
    /// goes on after this returns. It goes by the requests that wait rather than the task's status, which
    /// can read running again after one of several requests is answered.
    func answerOldestApproval(in sessionID: UUID, allowing: Bool) -> Bool {
        guard let session = store.sessions.first(where: { $0.id == sessionID }), isAttached(session.id),
              let oldest = pendingApprovals(in: session).first,
              let route = allowing ? oldest.allowOnce : oldest.deny else { return false }
        Task { await answer(oldest.id, with: route, in: session) }
        return true
    }

    /// What a message the person sends to a task that waits on them, from its composer on the Mac or a phone, answers
    /// once it has gone (`answerWaits(_:forPersonsMessageIn:)`), read before it goes; nil when the task waits on nothing
    /// or the message would not go: an edit, a command the composer runs itself, or a task the send refuses.
    func waitsForPersonsMessage(_ text: String, in sessionID: UUID) -> [NotificationApprovalProjection.PendingRequest]? {
        guard let session = store.sessions.first(where: { $0.id == sessionID }), isRunning(sessionID), isAttached(sessionID),
              composerDrafts.tasks.existingDraft(for: sessionID)?.editState == nil,
              !isHeld(session, by: TaskBlocker.holdingOffActions), sendRefusal(for: session) == nil else { return nil }
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch session.harness {
        case .codex where CodexComposerCommands.isBuiltin(command): return nil
        case .claudeCode where ClaudeComposerCommands.isResetCandidate(command): return nil
        default: break
        }
        let requests = pendingApprovals(in: session).filter { $0.declinedByMessage != nil }
        return requests.isEmpty && browserHandoffWaits[sessionID]?.isEmpty != false
            && simulatorTools.handoffs.waiting(for: sessionID) == nil ? nil : requests
    }

    /// Answers what the task waited on when the person's message went, as the harness's own app lets the person type
    /// past a request: Claude Code's "No, and tell Claude what to do differently", the Codex app's decline. The message
    /// goes first, so a harness that takes it during the turn has it with the answer's result: Claude Code reads it at
    /// that step, Codex at its next one; a harness that takes nothing while its turn runs has it once the turn ends.
    /// - Each request is declined once (`NotificationApprovalProjection.declinedByMessage`). Claude Code, which reads a
    ///   denial's words, is told the person sent a message instead and did not refuse, as it closes an approval itself
    ///   when a new message arrives while one waits.
    /// - Each tab handed to the person ends its wait as that message (`BrowserHandoff.Answer.personSentMessage`), and
    ///   so does a device handed to them (`SimulatorHandoff.Answer.personSentMessage`).
    /// A request only its card answers keeps waiting.
    func answerWaits(_ requests: [NotificationApprovalProjection.PendingRequest], forPersonsMessageIn sessionID: UUID) async {
        endBrowserWaitsForPersonsMessage(in: sessionID)
        simulatorTools.handoffs.answer(.personSentMessage, for: sessionID)
        for request in requests {
            // An earlier answer can end the turn and the rest with it.
            guard let route = request.declinedByMessage,
                  let current = store.sessions.first(where: { $0.id == sessionID }),
                  pendingApproval(request.id, in: current) != nil else { continue }
            if route.isPlainDenial, readsDenialNote(request.id, in: current) {
                await respond(to: request.id, answer: .denial(reason: PersonsMessageAnswer.denial), in: current)
            } else {
                _ = await answer(request.id, with: route, in: current)
            }
        }
    }

    /// Whether a denial's words reach the agent: Claude Code reads them as its tool's result, whether the task's own
    /// session asks or a subagent it runs does. A session tool's own approval takes only a yes or a no.
    func readsDenialNote(_ requestID: String, in session: SessionRecord) -> Bool {
        guard heldRequests(in: session.id).contains(where: { $0.id == requestID }) else {
            return session.harness == .claudeCode
        }
        let run = sessionTools.runs(hostedBy: session.id).first { $0.pendingRequests.contains { $0.id == requestID } }
        return run?.adapter is any HarnessStructuredPermissionResponding
    }

    /// Sends a request card's answer by its route, as the card sends it; false for an answer only the
    /// card's form gives.
    private func answer(_ requestID: String, with route: ConversationRequestRoute, in session: SessionRecord) async -> Bool {
        switch route {
        case let .decision(decision):
            await respond(to: requestID, decision: decision, in: session)
        case let .providerAction(action):
            await respond(to: requestID, action: action, in: session)
        case let .codex(response):
            await respondCodex(to: requestID, response: response, in: session)
        case .answer, .structured:
            return false
        }
        return true
    }

    /// Whether the task's finished turn is announced (`TurnCompletionAnnouncement`): not while a
    /// queued message is to be sent next or a background agent the turn started still runs, nor
    /// when the person did not ask for the turn.
    func announcesCompletion(of session: SessionRecord) -> Bool {
        if !followUps.isPaused(session.id), followUps.queue(for: session.id).contains(where: { $0.state != .failed }) {
            return false
        }
        if TurnCompletionAnnouncement.leavesBackgroundAgentRunning(transcriptBySessionID[session.id] ?? []) {
            return false
        }
        // Read from the latest turn back, only as far as the rule reads.
        return TurnCompletionAnnouncement.answersPerson(conversationTurns(of: session))
    }

    // MARK: - Requests a task waits on

    func pendingApprovals(in session: SessionRecord) -> [NotificationApprovalProjection.PendingRequest] {
        NotificationApprovalProjection.pendingRequests(
            harness: session.harness,
            transcript: transcriptBySessionID[session.id] ?? [],
            codex: codexPresentationBySessionID[session.id]
        )
        // What Yardlet holds in the task (`heldRequests`), answered by the same "Allow once".
        + heldRequests(in: session.id).map {
            NotificationApprovalProjection.pendingRequest(for: $0)
                ?? NotificationApprovalProjection.PendingRequest(
                    id: $0.id, allowOnce: nil, declinedByMessage: NotificationApprovalProjection.messageDecline(for: $0))
        }
    }

    func pendingApproval(_ requestID: String, in session: SessionRecord) -> NotificationApprovalProjection.PendingRequest? {
        pendingApprovals(in: session).first { $0.id == requestID }
    }

    /// The request a waiting task's notification names: the newest one waiting. A Codex request
    /// can reach the transcript before Codex's own state does; it is named then, with no answer.
    func newestPendingApproval(in session: SessionRecord) -> NotificationApprovalProjection.PendingRequest? {
        if let newest = pendingApprovals(in: session).last { return newest }
        guard session.harness == .codex else { return nil }
        let transcriptRequest = (transcriptBySessionID[session.id] ?? []).last { entry in
            if case .permission(_, .pending) = entry.content { true } else { false }
        }
        guard case let .permission(request, _)? = transcriptRequest?.content else { return nil }
        return NotificationApprovalProjection.PendingRequest(
            id: request.id, allowOnce: nil, asksQuestion: NotificationApprovalProjection.asksQuestion(request))
    }

    /// Bounces the Dock icon once for a new approval while Yardlet is behind other apps.
    func announceApproval(in sessionID: UUID) {
        guard let dockAttention, let session = store.sessions.first(where: { $0.id == sessionID }) else { return }
        dockAttention.announceApproval(newestPendingApproval(in: session)?.id ?? "", in: sessionID)
    }

    /// Withdraws a task's approval notifications whose request no longer waits.
    func withdrawAnsweredApprovalNotifications(for sessionID: UUID) {
        guard let delivered = approvalNotificationIDs[sessionID], !delivered.isEmpty else { return }
        var waiting = Set<String>()
        if let session = store.sessions.first(where: { $0.id == sessionID }), session.status == .waitingForApproval {
            waiting = Set(pendingApprovals(in: session).map(\.id))
        }
        // One that named no request goes with the first answer or the end of the wait.
        let answered = delivered.filter { $0.key.isEmpty || !waiting.contains($0.key) }
        guard !answered.isEmpty else { return }
        systemNotificationCenter.removeNotifications(identifiers: Array(answered.values).sorted())
        approvalNotificationIDs[sessionID] = delivered.filter { answered[$0.key] == nil }
        if approvalNotificationIDs[sessionID]?.isEmpty == true { approvalNotificationIDs[sessionID] = nil }
    }

    /// Withdraws every approval notification of a task that was archived or deleted.
    func withdrawApprovalNotifications(for sessionID: UUID) {
        guard let delivered = approvalNotificationIDs.removeValue(forKey: sessionID), !delivered.isEmpty else { return }
        systemNotificationCenter.removeNotifications(identifiers: Array(delivered.values).sorted())
        dockAttention?.forgetApprovals(in: sessionID)
    }

    // MARK: - Dock badge

    /// The tasks the sidebar lists, the ones "Next task needing attention" chooses from.
    var sidebarSessions: [SessionRecord] {
        let listed = store.listedSessions
        return projects.visibleGroups(sessions: listed).flatMap(\.sessions) + projects.chats(sessions: listed)
    }

    /// How many tasks need the person, the Dock badge's number.
    var attentionBadgeCount: Int {
        TaskAttentionProjection.count(in: sidebarSessions, details: taskAttentionDetails, shellBusy: shellBusySessionIDs)
            + remoteAttentionBadgeCount
    }

    /// Keeps the Dock badge on `attentionBadgeCount` as tasks change.
    func trackAttentionBadge() {
        guard let dockAttention else { return }
        withObservationTracking {
            dockAttention.show(count: attentionBadgeCount)
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackAttentionBadge() }
        }
    }

    /// Reads whether macOS allows Yardlet badges, at launch and whenever Yardlet comes forward
    /// (the person may have changed it in System Settings).
    func refreshNotificationPermission() async {
        guard let dockAttention else { return }
        dockAttention.setBadgesAllowed(await systemNotificationCenter.allowsBadges())
    }
}
