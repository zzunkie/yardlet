import SwiftUI

/// What the task composer can ask of the app: sending, the follow-up queue, the session's
/// controls, and Codex's own commands.
///
/// The window builds it once per task from the app model; `TaskPresentationBoundary` and
/// `TaskDetail` hand it to `PromptComposer`, and `TaskDetail` wraps the sends so a restored draft
/// is let go. An optional action that is nil is unavailable, and its control is not drawn. The
/// others keep their no-op defaults where nothing can act on them.
@MainActor
struct ComposerActions {
    var send: (HarnessUserInput) -> Void = { _ in }
    var interrupt: () -> Void = {}
    /// Codex's submit, which also queues or steers while a turn runs.
    var submitCodex: ((CodexComposerDraft, CodexComposerAction) -> Void)? = nil
    /// Explicit Queue and Steer for a task with a follow-up queue, from a composer whose drafts
    /// take the harness-neutral input (Claude Code). Return follows the follow-up setting.
    var submitFollowUp: ((HarnessUserInput, CodexComposerAction) -> Void)? = nil

    // MARK: The follow-up queue

    var removeQueued: ((UUID) -> Void)? = nil
    var retryQueued: ((UUID) -> Void)? = nil
    var moveQueued: ((UUID, Int) -> Void)? = nil
    /// Codex's Steer, or Claude's next step: the running turn goes on.
    var sendQueuedNow: ((UUID) -> Void)? = nil
    /// Claude's Send now, which stops the running turn for the message.
    var stopAndSendQueued: ((UUID) -> Void)? = nil
    /// Moves a queued message back into the draft and returns the draft.
    var editQueued: ((UUID) -> CodexComposerDraft?)? = nil
    var resumeQueue: (() -> Void)? = nil

    // MARK: Session controls

    var refreshProviderStatus: () async -> Void = {}
    var prepareProviderSettings: () async -> Void = {}
    var setProviderOption: (String, String) -> Void = { _, _ in }
    var selectCodexModel: (CodexModelSelection) -> Void = { _ in }
    var selectCodexRunLocation: (CodexRunLocation) -> Void = { _ in }
    /// Rereads the session's MCP servers when the connector list opens. Starts nothing.
    var refreshConnectors: () async -> Void = {}

    // MARK: Codex commands

    /// Runs a Codex command the composer does not own itself (it owns the model picker and
    /// skills). Nil outside a Codex task.
    var runCodexCommand: ((CodexComposerCommand) -> Void)? = nil
    /// Reads what the Codex command list shows beyond its fixed commands, without a turn.
    var prepareCodexCommands: () async -> Void = {}

    // MARK: Requests

    /// Answers the oldest tool approval the task waits on from the composer's keys
    /// (`ComposerApprovalKey`): true allows it once, false denies it. Returns whether a key answered
    /// one; nil where the composer answers none.
    var answerApproval: ((_ allowing: Bool) -> Bool)? = nil

    // MARK: The home's reply

    /// What Escape does in place of stopping the turn: the home's reply gives the composer back to
    /// the new task (`NewTaskHomeReplyHooks`). Nil in the task's own view.
    var escape: (() -> Void)? = nil
    /// Tab with no typed list open; true when the keyboard moved to the home's lines.
    var tab: (() -> Bool)? = nil

    /// Which optional actions are present, which is all the composer draws from them; the actions
    /// themselves are bound to its task.
    var shape: [Bool] {
        [submitCodex != nil, submitFollowUp != nil, removeQueued != nil, retryQueued != nil, moveQueued != nil,
         sendQueuedNow != nil, stopAndSendQueued != nil, editQueued != nil, resumeQueue != nil, runCodexCommand != nil,
         escape != nil, tab != nil]
    }

    /// Applies a session control's choice by the path its provider takes.
    func apply(_ choice: ComposerSessionChoice) {
        switch choice {
        case let .codexModel(selection): selectCodexModel(selection)
        case let .codexRunLocation(location): selectCodexRunLocation(location)
        case let .providerOption(id, value): setProviderOption(id, value)
        }
    }
}
