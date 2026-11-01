import Foundation

/// What a task shows about its provider's retries and plan limits, and the actions its limit card
/// offers. The app model owns the state; these views read it and call back.
struct TaskProviderNotices {
    var retry: HarnessProviderRetry?
    var limitWarning: HarnessRateLimit?
    /// Yardlet continued the task's turn after a restart cut it off (`RestartResumePolicy`).
    var resumedAfterRestart = false
    /// A lost connection cut the task's turn off, and it continues once the network is back
    /// (`ConnectionResumePolicy`).
    var reconnecting = false
    /// The limit card whose automatic continue is armed.
    var autoContinueEntryID: UUID?
    /// The task is idle and not being moved to another account, so a limit card can act.
    var canContinue = false
    /// Why the last attempt to continue under another account was refused.
    var switchError: String?
    var accounts: @MainActor () -> UsageLimitAccounts? = { nil }
    var refreshAccounts: @MainActor () async -> Void = {}
    var continueWithAccount: @MainActor (ProviderConnection) -> Void = { _ in }
    var setAutoContinue: @MainActor (_ enabled: Bool, _ entryID: UUID, _ resetsAt: Date) -> Void = { _, _, _ in }
    /// Continues the task under its own account from a limit card whose reset has passed; nil where
    /// its harness has no such continue.
    var continueAfterReset: (@MainActor (_ entryID: UUID) -> Void)?
    /// The account the task runs under, for a limit card to offer its resets; nil where its
    /// harness reports none.
    var usageReset: @MainActor () -> (choice: AccountChoice, context: UsageResetContext)? = { nil }
}

/// What a limit card's "Continue with another account" opens: the task's account list, with the
/// accounts other than the task's own that share its history.
struct UsageLimitAccounts {
    let session: SessionRecord
    let store: ProviderConnectionStore
    let runtimeSelections: RuntimeSelectionStore
    let others: [ProviderConnection]
}

/// The account store and runtimes a reset of an account's plan limits is used with. An account list
/// and a limit card provide it; without it the resets are not offered.
struct UsageResetContext {
    let store: ProviderConnectionStore
    let runtimeSelections: RuntimeSelectionStore
}
