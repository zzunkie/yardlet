import SwiftUI

/// What a task's conversation can ask of the app: answers to requests, Codex turn actions, edits,
/// and what the task around the conversation offers.
///
/// The window builds it once per task from the app model; `TaskPresentationBoundary` and
/// `TaskDetail` hand it to the renderers, and `TaskDetail` adds what depends on its own state
/// (`restoreDraft`, `subtaskControls`, and the retry and plan gates). An optional action that is
/// nil is unavailable, and its control is not drawn. The others have always been offered wherever
/// their card appears; a surface that cannot act on them, such as a fixture or a read-only child
/// conversation, keeps their no-op defaults.
@MainActor
struct ConversationActions {
    // MARK: Requests

    /// Allows or denies a request.
    var decide: (String, PermissionDecision) -> Void = { _, _ in }
    /// Forwards the provider's own approval option instead of a plain allow or deny.
    var chooseOption: ((String, PermissionRequestAction) -> Void)? = nil
    /// Returns the answer a provider question or plan review asked for.
    var answer: ((String, PermissionStructuredAnswer) -> Void)? = nil
    /// Answers a Codex server request.
    var respondToCodexRequest: (String, CodexServerRequestResponse) -> Void = { _, _ in }
    /// Requests Yardlet itself holds in this task (`AppModel.heldRequests`): what its session tools
    /// wait on, and a question a restart cut off. Drawn at the end of the latest turn and answered by
    /// the same routes.
    var heldRequests: [ConversationRequest] = []

    // MARK: Codex turns

    /// Opens a Codex subagent's thread as its own task.
    var openCodexSubagent: (String) -> Void = { _ in }
    var loadMoreCodexTurns: () -> Void = {}
    /// Reads earlier turns the provider's saved file holds before the ones read (a Claude task's
    /// transcript, read from its end); nil when the file holds none.
    var readEarlierHistory: (() -> Void)? = nil
    /// Loads the next page of one turn's items.
    var loadMoreCodexItems: (String) -> Void = { _ in }
    /// Retries a turn by its ID (`AppModel.retryTurn`); nil while the task is busy, editing, or holding
    /// queued messages.
    var retryTurn: ((String) -> Void)? = nil
    var forkCodexTurn: ((String) -> Void)? = nil
    /// Forks the task through a point of its conversation (`AppModel.branch`); nil where the task
    /// cannot branch. A transcript turn's menu forks the whole conversation from its latest turn
    /// (D10).
    var branch: ((BranchPoint) -> Void)? = nil
    /// Implements the latest turn's proposed plan; nil while the task cannot start a turn.
    var implementCodexPlan: ((String) -> Void)? = nil
    /// Sends the person's answer to a question the latest turn asked (an option of a Codex
    /// `request_user_input_async` question) as the next message; nil while the task cannot start a turn.
    var answerQuestion: ((String) -> Void)? = nil
    /// Sends the person's answer to a question Codex asked while its turn still runs into that turn
    /// (`turn/steer`), as the Codex app sends it from its question panel; nil where the task cannot.
    var answerQuestionWhileWorking: ((String) -> Void)? = nil

    // MARK: Edits

    /// Puts a request back into the composer without sending it. The shared transcript offers
    /// "Edit request" only with it; the Codex turn menu offers its edit by the timeline's rules.
    var restoreDraft: ((CodexComposerDraft) -> Void)? = nil
    /// The edits and file restores the provider carries out itself.
    var rewind: ConversationRewindActions? = nil

    // MARK: The task around the conversation

    var showHarnessSettings: (() -> Void)? = nil
    /// Runs a command in the task's terminal, opening it: "Run in terminal" on every harness's
    /// command card (plan B10). Nil where the conversation has no terminal of its own.
    var runInTerminal: ((String) -> Void)? = nil
    /// The provider's retries and plan limits, and what the limit card offers.
    var providerNotices: TaskProviderNotices? = nil
    /// Reads and stops a provider's subtask.
    var readSubtask: (@MainActor @Sendable (HarnessActivity) async throws -> HarnessSubtaskTranscript)? = nil
    var stopSubtask: (@MainActor @Sendable (HarnessActivity) async throws -> Void)? = nil
    /// The open and stop controls a subtask's card draws, which `TaskDetail` makes from
    /// `readSubtask` and `stopSubtask` with the panel state it owns.
    var subtaskControls: HarnessActivityActions? = nil

    /// What a read-only child conversation (a subtask shown beside its task) may do: nothing that
    /// would edit, restore or answer for the parent task. Limit notices still read the parent.
    var readOnlyChild: ConversationActions {
        ConversationActions(providerNotices: providerNotices)
    }

    /// What a `run_agent` subagent's conversation beside its task may do: answer the requests it waits
    /// on, which go to the subagent as they do from the end of the task's turn, and nothing else.
    var answeringRequestsOnly: ConversationActions {
        ConversationActions(decide: decide, chooseOption: chooseOption, answer: answer,
                            respondToCodexRequest: respondToCodexRequest, providerNotices: providerNotices)
    }
}

extension ConversationActions {
    /// Sends a request card's answer by its route, the one way every harness's requests are
    /// answered (plan A5.2): a decision, the provider's own option, a form's answer, or a Codex
    /// response. A form route becomes one of these before it is sent
    /// (`ConversationRequest.route(for:input:)`); one that did not is dropped.
    func respond(_ requestID: String, _ route: ConversationRequestRoute) {
        switch route {
        case let .decision(decision):
            decide(requestID, decision)
        case let .providerAction(action):
            chooseOption?(requestID, action)
        case let .answer(answer):
            self.answer?(requestID, answer)
        case let .codex(response):
            respondToCodexRequest(requestID, response)
        case .structured:
            break
        }
    }
}
