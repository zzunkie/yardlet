import Foundation
import YardletRemote

extension AppModelRemoteBridge {
    static func taskNotices(_ session: SessionRecord, model: AppModel) -> RemoteTaskNotices? {
        var notices = RemoteTaskNotices()
        if model.restartResumeNoticeSessionIDs.contains(session.id) { notices.resumedAfterRestart = true }
        if model.connectionResumes[session.id]?.isWaiting == true { notices.reconnecting = true }
        if let warning = model.rateLimitWarningBySessionID[session.id] {
            notices.warning = RemoteLimit(status: warning.status.rawValue, window: warning.window?.rawValue,
                model: warning.model, usedFraction: warning.usedFraction, overage: warning.isUsingOverage ? true : nil)
            notices.warningReset = warning.resetsAt.map(RemoteJSON.milliseconds)
        }
        if let missing = model.missingTaskFolders[session.id] {
            notices.missingFolder = missing.path
            notices.worktreeBranch = missing.worktreeBranch
        }
        if let connection = model.accountSwitchesAfterTurn[session.id] {
            notices.accountName = model.accountChoice(harness: session.harness, connection: connection).title
            notices.accountMoveInTurn = AppModel.isWorking(session)
        }
        return notices == RemoteTaskNotices() ? nil : notices
    }
}
