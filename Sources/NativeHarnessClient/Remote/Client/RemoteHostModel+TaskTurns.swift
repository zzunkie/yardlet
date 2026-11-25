import Foundation
import YardletRemote

/// What a host task's conversation and composer offer, as the Mac's and Windows' host windows both read it: Retry on a
/// turn, the latest limit card's actions (docs/REMOTE_PROTOCOL.md §15.17), and where a message sent while a turn runs
/// goes (§15.15).
extension RemoteHostModel {
    /// A turn's Retry, as the local task offers it: from a host that takes next steps, while connected, once the task
    /// is idle, with nothing queued and no message being edited.
    func offersRetry(in conversation: RemoteConversationModel, isEditing: Bool) -> Bool {
        nextSteps && isConnected && task(conversation.taskID)?.running != true && conversation.queued.isEmpty && !isEditing
    }

    /// What the latest limit card offers, as the host offers it (§15.17): continuing under another account that
    /// shares the task's history, and continuing once the limit resets.
    func limitNotices(for conversation: RemoteConversationModel) -> TaskProviderNotices? {
        guard let limit = conversation.usageLimit else { return nil }
        let options = limit.options ?? []
        guard !options.isEmpty || bankedResets else { return nil }
        let taskID = conversation.taskID
        var notices = TaskProviderNotices()
        notices.canContinue = isConnected && task(taskID)?.running != true
        if nextSteps, options.contains("resumeAfterReset") {
            notices.continueAfterReset = { [weak self] _ in
                self?.send(.nextStep(taskID: taskID, turnID: limit.turnId, action: .resumeAfterReset))
            }
        }
        if bankedResets {
            notices.hostUsageReset = { [weak self] in await self?.response(to: .usageReset(taskID: taskID)).usageReset }
            notices.useHostUsageReset = { [weak self] token in
                await self?.response(to: .useUsageReset(taskID: taskID, token: token, confirmed: true)).usageReset
            }
        }
        // An armed continue is known by the reset it waits for, as on the host.
        if limit.autoContinue == true, let resetsAt = limit.resetsAt {
            notices.autoContinueResetsAt = Date(timeIntervalSince1970: TimeInterval(resetsAt) / 1000)
        }
        notices.setAutoContinue = { [weak self] enabled, _ in self?.send(.setAutoContinue(taskID: taskID, enabled: enabled)) }
        if options.contains("continueWithAccount") {
            notices.hostAccounts = { [weak self] in
                guard let self else { return [] }
                let response = await self.response(to: .limitAccounts(taskID: taskID))
                return (response.accounts ?? []).filter { $0.available == true }
                    .map { UsageLimitHostAccount(id: $0.id, name: $0.name, detail: $0.detail) }
            }
            notices.continueWithHostAccount = { [weak self] id in
                self?.send(.continueWithAccount(taskID: taskID, accountID: id))
            }
        }
        return notices
    }

    /// The harness's way with a message sent while the task's turn runs, as the local composer reads it: Codex adds it
    /// to the running task, Claude Code delivers it at its next step, any other harness when the turn ends.
    func followUpPolicy(_ taskID: String) -> FollowUpPolicy {
        guard let task = task(taskID), task.steers == true,
              let policy = FollowUpPolicy(harness: HarnessKind(rawValue: task.harness), antigravitySteers: true)
        else { return .afterTurn }
        return policy
    }

    /// What the send key does while a turn runs: the host's setting, as this computer's own setting does locally.
    var preferredFollowUp: FollowUpMode { followUp == .queue ? .queue : .steer }
}

/// One message waiting in a host task's queue as the composer draws its row (§15.15): its chip in the harness's words,
/// and the actions the host offers for it. Moving, retrying and editing it come with the host's composer extensions.
struct RemoteQueuedRow: Equatable {
    let chip: ComposerQueueChip
    let failed: Bool
    let retries: Bool
    let sendsNow: Bool
    let stopsAndSends: Bool
    let edits: Bool
    let removes: Bool

    init(_ item: RemoteItem, at index: Int, of count: Int, policy: FollowUpPolicy, extended: Bool) {
        failed = item.queueFailed == true
        let offered = item.options ?? []
        sendsNow = offered.contains("sendNow")
        stopsAndSends = offered.contains("stopAndSend")
        edits = extended && offered.contains("edit")
        removes = offered.contains("remove")
        retries = extended
        let send = sendsNow ? policy.sendLabel.map {
            ComposerQueueChip.Send(label: $0, icon: "arrow.turn.up.right", help: policy.sendHelp ?? $0)
        } : nil
        let stopAndSendLabel = stopsAndSends ? policy.stopAndSendLabel : nil
        chip = ComposerQueueChip(icon: failed ? "exclamationmark.circle" : "clock",
            status: failed ? L10n.string("Failed") : policy.pendingHelp, help: policy.pendingHelp,
            send: send, stopAndSend: stopAndSendLabel,
            showsStopAndSendInline: !failed && !policy.steers && stopAndSendLabel != nil,
            removeLabel: policy.removeLabel, canMoveUp: extended && offered.contains("moveUp") && index > 0,
            canMoveDown: extended && offered.contains("moveDown") && index + 1 < count)
    }
}
