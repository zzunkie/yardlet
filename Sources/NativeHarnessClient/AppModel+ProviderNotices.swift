import Foundation

// A task's provider notices and its limit card's actions, which the Mac's window and the Windows app's conversation
// both draw: a Claude task's retries, limit warning and limit-card actions, a Codex task's limit-card resets, and for
// any task that Yardlet continued it after a restart or a lost connection.
@MainActor
extension AppModel {
    /// A Claude task's retries, limit warning and limit-card actions, which other harnesses do not
    /// report, a Codex task's limit-card resets, and for any task that Yardlet continued it after a
    /// restart.
    func providerNotices(for session: SessionRecord) -> TaskProviderNotices? {
        let resumedAfterRestart = restartResumeNoticeSessionIDs.contains(session.id)
        let reconnecting = connectionResumes[session.id]?.isWaiting == true
        let canContinue = session.status != .running && session.status != .waitingForApproval
            && !isHeld(session, by: TaskBlocker.holdingOffActions)
        // Read when a limit card draws, so it names the account the task runs under now.
        let usageReset: @MainActor () -> (choice: AccountChoice, context: UsageResetContext)? = { [self] in
            (connections.choice(for: session.harness, connection: session.connection),
             UsageResetContext(store: connections, runtimeSelections: runtimeSelections))
        }
        if session.harness == .codex {
            return TaskProviderNotices(
                resumedAfterRestart: resumedAfterRestart, reconnecting: reconnecting, canContinue: canContinue,
                refreshAccounts: { [self] in
                    await connections.check(connections.choice(for: .codex, connection: session.connection),
                        runtimeSelections: runtimeSelections)
                },
                usageReset: usageReset)
        }
        guard session.harness == .claudeCode else {
            return resumedAfterRestart || reconnecting
                ? TaskProviderNotices(resumedAfterRestart: resumedAfterRestart, reconnecting: reconnecting) : nil
        }
        return TaskProviderNotices(
            retry: providerRetryBySessionID[session.id],
            limitWarning: rateLimitWarningBySessionID[session.id],
            resumedAfterRestart: resumedAfterRestart,
            reconnecting: reconnecting,
            autoContinueResetsAt: usageLimitAutoContinue[session.id]?.resetsAt,
            canContinue: canContinue,
            switchError: usageLimitSwitchErrorBySessionID[session.id],
            accounts: { [self] in usageLimitAccountOptions(for: session) },
            refreshAccounts: { [self] in await refreshUsageLimitAccounts(for: session) },
            continueWithAccount: { [self] connection in
                Task { await continueAfterUsageLimit(using: connection, for: session) }
            },
            setAutoContinue: { [self] enabled, resetsAt in
                setUsageLimitAutoContinue(enabled, resetsAt: resetsAt, for: session)
            },
            continueAfterReset: { [self] entryID in
                Task { await continueAfterUsageLimitReset(entryID: entryID, for: session) }
            },
            usageReset: usageReset
        )
    }
}
