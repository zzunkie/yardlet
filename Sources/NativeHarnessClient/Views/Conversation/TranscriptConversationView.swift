import SwiftUI

/// A shared transcript (`[TranscriptEntry]`) drawn by the conversation renderer, from the
/// conversation model, in the one look every harness shares (plan M8–M10, M12f).
///
/// Surfaces that show a transcript outside a task's own conversation use it: a subtask's read-only
/// panel and the development reading fixtures. A task's conversation goes through
/// `TaskConversationView`, which also draws a Codex thread, and draws it as the task's own.
struct TranscriptConversationView: View {
    let harness: HarnessKind
    let transcript: TranscriptTurns
    var latestTurnIsComplete = false
    var sessionStatus: SessionStatus = .ready
    var readingPosition: TranscriptReadingPosition? = nil
    var actions = ConversationActions()
    /// A side panel's conversation by default; a task's own when the task draws it.
    var placement: ConversationPlacement = .panel
    var turnWindowCount = ConversationTurnWindow.initialTurnCount
    var isLoading = false
    var diagnosticID: String? = nil
    var renderState: ConversationRenderState? = nil

    var body: some View {
        ConversationTimeline(
            source: .transcript(
                transcript, harness: harness, status: sessionStatus,
                latestTurnIsComplete: latestTurnIsComplete
            ),
            placement: placement,
            readingPosition: readingPosition,
            actions: actions,
            turnWindowCount: turnWindowCount,
            isLoading: isLoading,
            diagnosticID: diagnosticID,
            renderState: renderState
        )
    }
}

extension TranscriptConversationView {
    /// A transcript drawn from its entries as they are.
    init(
        harness: HarnessKind, entries: [TranscriptEntry], latestTurnIsComplete: Bool = false,
        sessionStatus: SessionStatus = .ready, readingPosition: TranscriptReadingPosition? = nil,
        actions: ConversationActions = ConversationActions(), placement: ConversationPlacement = .panel,
        turnWindowCount: Int = ConversationTurnWindow.initialTurnCount, isLoading: Bool = false,
        diagnosticID: String? = nil, renderState: ConversationRenderState? = nil
    ) {
        self.init(
            harness: harness, transcript: TranscriptTurns(entries), latestTurnIsComplete: latestTurnIsComplete,
            sessionStatus: sessionStatus, readingPosition: readingPosition, actions: actions, placement: placement,
            turnWindowCount: turnWindowCount, isLoading: isLoading, diagnosticID: diagnosticID,
            renderState: renderState)
    }
}
