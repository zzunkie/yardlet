import Foundation

/// One thing that keeps a task busy now (`AppModel.firstBlocker(of:among:)`). Each automation that touches a task's
/// runtime or account says, by a `switch` over these, which it waits for, so a new kind does not compile until each
/// has said. Declared in the order the memory saver names them.
enum TaskBlocker: CaseIterable {
    /// A side chat: its runtime holds its whole conversation, which its harness keeps none of.
    case sideChat
    /// Its turn runs, or waits for an approval.
    case turn
    /// Its Codex thread has a turn in progress.
    case codexTurn
    /// A shell command the person ran in it.
    case shellCommand
    /// A question or request in its conversation, or one Yardlet holds, waits for the person's answer.
    case request
    /// Messages wait in its queue.
    case queuedMessages
    /// A queued message is on its way to the provider: the provider holds it, or an action is sending it.
    case messageOnItsWay
    /// Shell output waits to go to the provider.
    case shellOutput
    /// The harness's background commands, as its conversation shows them. Reads the whole conversation.
    case backgroundWork
    /// Session jobs its running CLI holds.
    case sessionJobs
    /// A server of the task, or its processes keeping a core busy, as the resource monitor last saw them.
    case processes
    /// Agents it runs (`run_agent`).
    case agents
    /// A child task or agent it asked for waits for room to start.
    case childStartWaiting
    /// One of its child tasks works.
    case childTasks
    /// A message the person is editing.
    case edit
    /// Another change under way: a session change, an account switch, a fork, a restart, a side chat opening,
    /// unarchiving, or its worktree being made again.
    case change
    /// It is a child task that waits for room to start, or starts.
    case startingAsChild
    /// A turn a restart or a lost connection cut off is to continue in it.
    case cutOffTurn
    /// Its CLI starts again for the session jobs it brings back.
    case sessionJobRelaunch
    /// A continue is armed for its plan limit's reset.
    case limitContinue

    /// What an account move waits for while this holds the task, as the line above the composer names it; nil for
    /// what does not keep its account from changing. With `heldMessagesGoAfter` the messages and shell output Yardlet
    /// holds go after the move, on the new account, and only one on its way is waited for. A move does not wait for
    /// what the runtime brings back on resuming (session jobs and their relaunch), for the task's processes or
    /// children, or for an armed continue after a limit, which goes on under the same account (`moveSettledTask`).
    func accountMoveWait(heldMessagesGoAfter: Bool) -> AccountMoveBlocker? {
        switch self {
        case .turn: .turn
        case .queuedMessages, .shellOutput: heldMessagesGoAfter ? nil : .messages
        case .messageOnItsWay: .messages
        case .shellCommand: .shellCommand
        case .request: .request
        case .edit: .edit
        case .change, .startingAsChild, .cutOffTurn: .otherChange
        case .agents: .agents
        case .backgroundWork: .backgroundWork
        case .sideChat, .codexTurn, .sessionJobs, .processes, .childStartWaiting, .childTasks, .sessionJobRelaunch,
             .limitContinue: nil
        }
    }

    /// What an account move waits for, in the order the line above the composer names them when several hold.
    static func accountMoveWaits(heldMessagesGoAfter: Bool) -> [TaskBlocker] {
        heldMessagesGoAfter ? accountMoveWaitsSendingHeldMessagesAfter : accountMoveWaitsHoldingMessages
    }

    private static let accountMoveWaitsHoldingMessages = ordered(byAccountMoveWait: false)
    private static let accountMoveWaitsSendingHeldMessagesAfter = ordered(byAccountMoveWait: true)

    private static func ordered(byAccountMoveWait heldMessagesGoAfter: Bool) -> [TaskBlocker] {
        AccountMoveBlocker.allCases.flatMap { wait in
            allCases.filter { $0.accountMoveWait(heldMessagesGoAfter: heldMessagesGoAfter) == wait }
        }
    }

    /// What keeps a task's runtime whether or not it is on screen, in a word for the memory saver's log and tests;
    /// nil for what the runtime may end under. An idle terminal does not keep it: the shell goes on without it.
    var memorySaverWord: String? {
        switch self {
        case .sideChat: "side chat"
        case .turn, .codexTurn, .shellCommand: "turn"
        case .request: "question"
        case .queuedMessages, .messageOnItsWay, .shellOutput: "queued"
        case .backgroundWork: "background"
        case .sessionJobs: "schedule"
        case .processes: "processes"
        case .agents, .childStartWaiting, .childTasks: "children"
        case .edit, .change: "changing"
        case .cutOffTurn, .sessionJobRelaunch, .limitContinue: "continuing"
        case .startingAsChild: nil
        }
    }

    /// What keeps a task's runtime, in the order the memory saver names them.
    static let keepingRuntime = allCases.filter { $0.memorySaverWord != nil }
}
