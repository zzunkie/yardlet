import SwiftUI
import YardletRemote

/// The host's notices drawn by the local task's own lines, in their order: the task's error card, the missing folder,
/// the provider's notices and the account move. Recreating a missing worktree stays on the host, as does the harness's
/// settings the error card would open.
struct RemoteTaskNoticeLines: View {
    let notices: RemoteTaskNotices
    var harness: HarnessKind = .claudeCode
    let cancelAccountMove: @MainActor () -> Void

    var body: some View {
        if let error = notices.error {
            TranscriptErrorCard(harness: harness, message: error, recoverable: true)
                // The composer's column, so the reason sits over the composer, as the local task's card does.
                .frame(maxWidth: ParityTheme.contentWidth)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
        }
        if let path = notices.missingFolder {
            TaskFolderMissingBanner(notice: TaskFolderMissingNotice(
                missing: TaskFolderMissing(path: path, worktreeBranch: notices.worktreeBranch),
                isRecreating: true, recreateWorktree: {}))
        }
        if ProviderNoticeLines.showsAnything(providerNotices) { ProviderNoticeLines(notices: providerNotices) }
        if let account = notices.accountName {
            TaskAccountMoveLine(notice: TaskAccountMoveNotice(accountName: account,
                isInTurn: notices.accountMoveInTurn != false, cancel: cancelAccountMove))
        }
    }

    private var providerNotices: TaskProviderNotices {
        var result = TaskProviderNotices(resumedAfterRestart: notices.resumedAfterRestart == true,
                                         reconnecting: notices.reconnecting == true)
        if let warning = notices.warning {
            result.limitWarning = HarnessRateLimit(status: .warning,
                window: warning.window.flatMap(HarnessRateLimit.Window.init(rawValue:)), model: warning.model,
                resetsAt: notices.warningReset.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                usedFraction: warning.usedFraction, isUsingOverage: warning.overage == true)
        }
        return result
    }
}
