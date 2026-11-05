import Foundation

/// Whether a task's finished turn is announced with a notification. An
/// approval, a question or a failure is announced whoever started the turn; this decides only
/// "Task completed".
///
/// - **The task goes on by itself:** not announced, as in both apps. A message waits in the task's
///   queue to be sent next (the Codex app's `hasPendingContinuation`), or a background agent the
///   turn started still runs and its notice will open the next turn (the Claude app's
///   `selfResumeReason` "background_agent").
/// - **The person did not ask for it:** not announced. That is a turn another task's message opened
///   (`TaskMessage`, a child's first message included), one a schedule's prompt opened inside the
///   task (Claude Code's own `CronCreate` or `/loop`, a Codex app automation), or one the provider
///   started itself with a request Yardlet has not read. The Codex app has no such turns, and the
///   Claude app announces them, but passively and without a sound (`interruptionLevel: "passive"`);
///   they were most of Yardlet's notifications (2026-10-25: 217 in six hours, mostly parents hearing
///   from their children and a check-in every 15 minutes).
/// - **A background notice opened it:** it goes on with the work of the turn that started that
///   background work, and is announced when that turn would have been, as the Claude app announces
///   the wake that ends a background agent's work.
/// - A message the person sent into the running turn makes it theirs, as the Claude app's turn
///   initiator becomes "user". A run a Yardlet schedule started as a new task opens with the
///   schedule's words as its message and is announced, as both apps announce a scheduled run.
enum TurnCompletionAnnouncement {
    /// Whether the latest of `turns` answers the person. With no turn to read, it does. The turns are
    /// read from the latest, only as far as a turn that decides it.
    static func answersPerson(_ turns: some BidirectionalCollection<ConversationTurn>) -> Bool {
        for turn in turns.reversed() {
            switch opener(of: turn) {
            case .person: return true
            case .other: return false
            case .backgroundNotice: continue
            }
        }
        return true
    }

    /// Whether the latest turn in `transcript` started a background agent that still runs.
    static func leavesBackgroundAgentRunning(_ transcript: [TranscriptEntry]) -> Bool {
        guard let start = transcript.lastIndex(where: \.opensTurn) else { return false }
        return BackgroundTasksProjection(entries: Array(transcript[start...]), includesTasks: false).isShown
    }

    private enum Opener {
        case person
        case other
        case backgroundNotice
    }

    private static func opener(of turn: ConversationTurn) -> Opener {
        if (turn.prompt + turn.work).contains(where: isPersonsMessage) { return .person }
        if turn.prompt.contains(where: { $0.backgroundTaskNotice != nil }) { return .backgroundNotice }
        return .other
    }

    private static func isPersonsMessage(_ item: ConversationItem) -> Bool {
        switch item.kind {
        case .userMessage: item.taskMessage == nil && item.backgroundTaskNotice == nil
        case .shellCommand: true
        default: false
        }
    }
}
