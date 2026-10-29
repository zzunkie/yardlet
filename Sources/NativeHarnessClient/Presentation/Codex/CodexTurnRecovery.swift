import Foundation

/// Native capacity recovery continues the retained conversation with an empty input. It does
/// not regenerate a completed turn or resend a historical user message and its attachments.
protocol CodexTurnRecovering: Actor {
    func retryFailedTurn(_ turnID: String, in session: HarnessSessionHandle) async throws
}

enum CodexTurnRecoveryProjection {
    /// A latest turn that failed because the server was too busy, or because its connection was lost
    /// (the Codex app's Resume on it, `resume_interrupted_task`), with nothing waiting on the person.
    static func canRetry(_ turnID: String, in state: CodexTaskState) -> Bool {
        guard let thread = state.thread, thread.status.isSettled, state.activeTurnID == nil,
              let latest = thread.turns.last, latest.id == turnID, latest.status == .failed,
              retryTrigger(latest.error) != nil else { return false }
        return !state.approvalsByID.values.contains { $0.resolution == .pending }
            && !state.serverRequestsByID.values.contains { $0.resolution == .pending }
    }

    /// The `turnTrigger` the Codex app sends for a retry of a turn that failed this way: its capacity
    /// retry for a busy server (`capacity_retry_manual`), its Resume for a lost connection
    /// (`resume_interrupted_task`); nil for any other failure.
    static func retryTrigger(_ error: JSONValue?) -> String? {
        if error?["codexErrorInfo"]?.stringValue == "serverOverloaded" { return "capacity_retry_manual" }
        return CodexTurnErrorPresentation.isConnectionCut(error) ? RestartContinuation.codexResumeTrigger : nil
    }
}
