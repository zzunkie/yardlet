import Foundation

/// What ended a task's turn (`AppModel.turnEnded`). The words are what the coordination log records.
enum TurnEndCause: String, Sendable, CaseIterable {
    /// The provider reported the task's state: ready, completed or failed.
    case providerStatus = "provider-status"
    /// The provider reported an error.
    case providerError = "provider-error"
    /// The runtime's event stream ended while the turn ran.
    case streamEnded = "stream-ended"
    /// The turn never started: the task's runtime did not start, or the provider refused the message
    /// that was to start it.
    case notStarted = "not-started"
    /// A turn something cut off was to continue, and the provider had nothing to continue or could not.
    case continuationEnded = "continuation-ended"

    /// What Yardlet does after a turn that ended this way. The provider's own report of the task's
    /// state runs everything that waits for a turn's end. A provider error runs what it ran when it
    /// wrote the task's status itself: the provider's report of the state follows it. A stream that
    /// ended, a message that did not go and a continuation that did not are the last word on the
    /// turn, so what waited for the task to be free goes then too, and a task off screen says it
    /// failed. Not the queue or a pull request's auto-fix: they would send again after a send that
    /// just failed.
    var followUps: TurnFollowUps {
        switch self {
        case .providerStatus: .all
        case .providerError: [.unreadMark, .notification, .toolChanges]
        case .streamEnded, .notStarted, .continuationEnded:
            [.unreadMark, .notification, .toolChanges, .accountMove, .contextLimit, .shellOutput, .dueConnectionResumes]
        }
    }
}

/// What may follow a turn's end (`TurnEndCause.followUps`), in the order `AppModel.turnEnded` does it.
struct TurnFollowUps: OptionSet, Sendable {
    let rawValue: Int

    /// The rail's browser preview goes with the turn.
    static let browserPreview = TurnFollowUps(rawValue: 1 << 0)
    /// The session jobs the CLI holds are read again when the turn touched them.
    static let sessionJobs = TurnFollowUps(rawValue: 1 << 1)
    /// A continuation after a lost connection that ended without being cut again is done.
    static let connectionResume = TurnFollowUps(rawValue: 1 << 2)
    /// The task's row says there is something new, when the task is not on screen.
    static let unreadMark = TurnFollowUps(rawValue: 1 << 3)
    /// The turn is recorded for the routing evaluation, and a dialog the agent left open becomes the person's.
    static let routingEvaluation = TurnFollowUps(rawValue: 1 << 4)
    /// Notifications of approvals since answered are withdrawn.
    static let approvalNotifications = TurnFollowUps(rawValue: 1 << 5)
    /// A notification says how the turn ended, when the task is not on screen.
    static let notification = TurnFollowUps(rawValue: 1 << 6)
    /// The next message Yardlet holds goes, after a turn that left the task ready.
    static let queue = TurnFollowUps(rawValue: 1 << 7)
    /// A pull request's auto-fix held while the task worked may go.
    static let autoFix = TurnFollowUps(rawValue: 1 << 8)
    /// A change to the task's tools that waited for the turn's end is passed on.
    static let toolChanges = TurnFollowUps(rawValue: 1 << 9)
    /// An account move that waited for the turn goes, and one Yardlet may choose is looked for.
    static let accountMove = TurnFollowUps(rawValue: 1 << 10)
    /// A context limit, or next-message suggestions, that waited for the turn restart the runtime.
    static let contextLimit = TurnFollowUps(rawValue: 1 << 11)
    /// Shell output that waited for the turn is delivered.
    static let shellOutput = TurnFollowUps(rawValue: 1 << 12)
    /// Turns a lost connection cut off that are due continue.
    static let dueConnectionResumes = TurnFollowUps(rawValue: 1 << 13)

    static let all = TurnFollowUps(rawValue: (1 << 14) - 1)
}
