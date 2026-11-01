import SwiftUI

/// The harness-neutral handoff point for task-owned presentation.
///
/// The legacy transcript remains the compatibility output for every harness while
/// Codex receives its typed projection as an optional side channel. This keeps the
/// common session identity and the conversation and composer actions stable while
/// Codex-specific timeline and composer behavior evolves independently.
struct TaskPresentationBoundary: View {
    var conversationOnly = false
    var sideChat: AnyView? = nil
    var onOpenSideChat: (() -> Void)? = nil
    var sidePanelTasks: SidePanelTaskServices? = nil
    let session: SessionRecord
    let composerDraft: TaskComposerDraft
    let workspaceState: TaskWorkspaceState
    @Binding var panelState: TaskSurfaceNavigationProjection.PanelState
    var focusedSurface: FocusState<TaskSurface?>.Binding
    /// The task's transcript, read where it is drawn (`TaskTranscriptView`).
    let transcript: TaskTranscriptReader
    /// The task's saved conversation is being read from the provider's own history.
    var isReadingSavedConversation = false
    let errorMessage: String?
    let codexTaskState: CodexTaskState?
    let codexHistorySelection: CodexHistorySearchSelection?
    let codexQueue: [CodexQueuedSubmission]
    var isCodexQueuePaused = false
    let codexCapabilities: CodexCapabilityState
    let providerCapabilities: ProviderCapabilityState?
    let providerUsage: HarnessProtocolUsage?
    var restoredCodexTokenUsage: CodexThreadTokenUsage? = nil
    let isProviderAttached: Bool
    let onShowCodexCapabilities: () -> Void
    let conversationActions: ConversationActions
    let composerActions: ComposerActions

    var body: some View {
        TaskDetail(
            conversationOnly: conversationOnly,
            sideChat: sideChat,
            onOpenSideChat: onOpenSideChat,
            sidePanelTasks: sidePanelTasks,
            session: session,
            composerDraft: composerDraft,
            workspaceState: workspaceState,
            panelState: $panelState,
            focusedSurface: focusedSurface,
            transcript: transcript,
            isReadingSavedConversation: isReadingSavedConversation,
            errorMessage: errorMessage,
            codexTaskState: codexTaskState,
            codexHistorySelection: codexHistorySelection,
            codexQueue: codexQueue,
            isCodexQueuePaused: isCodexQueuePaused,
            codexCapabilities: codexCapabilities,
            providerCapabilities: providerCapabilities,
            providerUsage: providerUsage,
            restoredCodexTokenUsage: restoredCodexTokenUsage,
            isProviderAttached: isProviderAttached,
            onShowCodexCapabilities: onShowCodexCapabilities,
            conversationActions: conversationActions,
            composerActions: composerActions
        )
        .id(session.id)
    }
}
