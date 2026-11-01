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
        return TurnCompletionAnnouncement.answersPerson(sessionToolPresentation(of: session).turns)
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
            NotificationApprovalProjection.PendingRequest(id: $0.id, allowOnce: RemoteApprovalPolicy.allowOnce($0))
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
        return NotificationApprovalProjection.PendingRequest(id: request.id, allowOnce: nil)
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
        projects.visibleGroups(sessions: store.sessions).flatMap(\.sessions) + projects.chats(sessions: store.sessions)
    }

    /// How many tasks need the person, the Dock badge's number.
    var attentionBadgeCount: Int {
        TaskAttentionProjection.count(in: sidebarSessions, details: taskAttentionDetails, shellBusy: shellBusySessionIDs)
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
