import Foundation

// What the windows, the remote bridge, the app and tests ask of a task's continuations, as they asked
// it of the model before `TaskContinuationCoordinator` held them. AppModel's own code calls
// `continuations` directly.
extension AppModel {
    var usageLimitAutoContinue: [UUID: UsageLimitAutoContinue] { continuations.usageLimitAutoContinue }
    var usageLimitSwitchErrorBySessionID: [UUID: String] { continuations.usageLimitSwitchErrorBySessionID }
    var restartResumeNoticeSessionIDs: Set<UUID> { continuations.restartResumeNoticeSessionIDs }
    var restartResumeLine: RestartResumeLine { continuations.restartResumeLine }
    var connectionResumes: [UUID: ConnectionResume] { continuations.connectionResumes }
    var accountSwitchesAfterTurn: [UUID: ProviderConnection] { continuations.accountSwitchesAfterTurn }
    var accountMoveHolds: [UUID: AccountMoveHold] { continuations.accountMoveHolds }

    /// Test clocks.
    var usageLimitResumeGrace: Duration {
        get { continuations.usageLimitResumeGrace }
        set { continuations.usageLimitResumeGrace = newValue }
    }
    var connectionResumeSleep: @Sendable (Duration) async throws -> Void {
        get { continuations.connectionResumeSleep }
        set { continuations.connectionResumeSleep = newValue }
    }
    var restartResumeSleep: @Sendable (Duration) async throws -> Void {
        get { continuations.restartResumeSleep }
        set { continuations.restartResumeSleep = newValue }
    }
    var accountMoveClock: () -> Date {
        get { continuations.accountMoveClock }
        set { continuations.accountMoveClock = newValue }
    }

    func chooseAccount(_ connection: ProviderConnection, for session: SessionRecord) async {
        await continuations.chooseAccount(connection, for: session)
    }

    func cancelAccountSwitchAfterTurn(for sessionID: UUID, declined: Bool = true) {
        continuations.cancelAccountSwitchAfterTurn(for: sessionID, declined: declined)
    }

    func restartForContextLimit(_ id: UUID) async {
        await continuations.restartForContextLimit(id)
    }

    func continueAfterUsageLimit(using connection: ProviderConnection, for session: SessionRecord) async {
        await continuations.continueAfterUsageLimit(using: connection, for: session)
    }

    func setUsageLimitAutoContinue(_ enabled: Bool, resetsAt: Date, armedBy: UsageLimitAutoContinue.ArmedBy? = nil,
                                   for session: SessionRecord) {
        continuations.setUsageLimitAutoContinue(enabled, resetsAt: resetsAt, armedBy: armedBy, for: session)
    }

    func continueAfterUsageLimitReset(entryID: UUID, for session: SessionRecord) async {
        await continuations.continueAfterUsageLimitReset(entryID: entryID, for: session)
    }

    func recordWorkForRestart(trigger: RestartTrigger, now: Date = Date()) {
        continuations.recordWorkForRestart(trigger: trigger, now: now)
    }

    func tasksContinuingAfterRestart() -> Set<UUID> {
        continuations.tasksContinuingAfterRestart()
    }

    func continueWorkInterruptedByRestart(now: Date = Date()) async {
        await continuations.continueWorkInterruptedByRestart(now: now)
    }

    func continuesWhenOpened(_ id: UUID) -> Bool {
        continuations.continuesWhenOpened(id)
    }

    func networkPathChanged(isSatisfied: Bool) {
        continuations.networkPathChanged(isSatisfied: isSatisfied)
    }

    func continueTasks(afterSignInOf harness: HarnessKind, connection: ProviderConnection?,
                       isFirstReading: Bool = false) async {
        await continuations.continueTasks(afterSignInOf: harness, connection: connection, isFirstReading: isFirstReading)
    }
}
