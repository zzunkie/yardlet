import Foundation

/// What a tool call learns of the cards it waited on, and the time a card's wait takes from it (docs/AGENT_BROWSER_TOOLS.md,
/// "Approvals"). A call waits on a card for as long as it may (`SessionToolCaller.deadline`); when it may wait no longer and
/// nobody has answered, the card stays up for its own time and the call answers that nobody answered yet, not that the
/// person refused (`AgentToolBroker.unanswered`). The same call made again waits on that card, or takes the answer the
/// person gave meanwhile (`SessionToolCenter.decide`).
enum ApprovalWait {
    /// The call being answered now, bound by `AgentToolBroker.handle` for each call, a script's own included.
    @TaskLocal static var record: Record?
    /// A clock that stops while the person reads a card: a script's (`CodeModeRunner`), so the time a card waits for
    /// the person does not count against the script.
    @TaskLocal static var clock: (any PersonWaitClock)?
    /// When the harness's call to a script began: a call the script makes shares the script's deadline.
    @TaskLocal static var callStarted: ContinuousClock.Instant?

    /// What became of the cards one call waited on.
    final class Record: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Unanswered?

        /// A card the call waited on that nobody answered while it could wait.
        var unanswered: Unanswered? { lock.withLock { value } }

        func note(_ unanswered: Unanswered) {
            lock.withLock { value = unanswered }
        }
    }

    struct Unanswered: Equatable, Sendable {
        /// How much longer the card stays up for the same call made again; nil once its own time ended and it went.
        var cardStays: Duration?
    }

    /// Waits on the person with the caller's clock stopped.
    static func whilePersonReads<T>(isolation: isolated (any Actor)? = #isolation, _ wait: () async throws -> T) async rethrows -> T {
        let clock = clock
        clock?.personWaitBegan()
        defer { clock?.personWaitEnded() }
        return try await wait()
    }
}

/// A clock that does not run while the person reads a card its owner waits on (`ApprovalWait.whilePersonReads`).
protocol PersonWaitClock: AnyObject, Sendable {
    func personWaitBegan()
    func personWaitEnded()
}
