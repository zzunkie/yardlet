import SwiftUI

/// An archived task's conversation, read-only, in the window's task area while the sidebar lists
/// archived tasks: the conversation as its task draws it (`TaskConversationView`), earlier turns read
/// as it scrolls up, and in the composer's place what the Codex app and the Claude app show under an
/// archived chat, with the way to unarchive it. Nothing here sends, edits, forks or answers.
struct ArchivedTaskConversation: View {
    let reading: ArchivedTaskReading
    let isUnarchiving: Bool
    let onUnarchive: () -> Void
    let onReadEarlier: () -> Void

    private var session: SessionRecord { reading.session }

    var body: some View {
        VStack(spacing: 0) {
            switch reading.outcome {
            case .reading, .shown:
                TaskConversationView(
                    harness: session.harness,
                    workspaceURL: session.workspaceURL,
                    transcript: reading.transcript,
                    // No runtime holds an archived task, whatever it was doing when it was archived.
                    sessionStatus: .ready,
                    latestTurnIsComplete: session.completionState == .completed,
                    codexTaskState: reading.codexState,
                    providerSessionID: session.providerSessionID,
                    actions: actions,
                    isReadingSavedConversation: reading.outcome == .reading,
                    diagnosticID: session.id.uuidString
                )
                .environment(\.transcriptWorkspaceURL, session.workspaceURL)
            case .unsupported, .unavailable:
                Text(unreadableMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ArchivedTaskNote(isUnarchiving: isUnarchiving, onUnarchive: onUnarchive)
        }
        // Another archived task starts its conversation's view anew.
        .id(session.id)
    }

    /// Only reading further back: the conversation's controls that act on the task stay unavailable.
    private var actions: ConversationActions {
        ConversationActions(loadMoreCodexTurns: onReadEarlier,
                            readEarlierHistory: reading.hasEarlierHistory ? onReadEarlier : nil)
    }

    private var unreadableMessage: String {
        reading.outcome == .unsupported
            ? L10n.format("Yardlet can't show archived %@ conversations. Unarchive the task to open it.",
                          session.harness.displayName)
            : L10n.format("This conversation could not be read from %@'s history.", session.harness.displayName)
    }
}

/// What stands in for an archived task's composer: that the task is archived, and Unarchive, as the
/// Claude app says it under an archived session ("This session is archived. Unarchive it to keep
/// working in this session.") and the Codex app under an archived chat. Drawn in the composer's shape
/// and column, so the conversation ends where it would above the composer.
struct ArchivedTaskNote: View {
    let isUnarchiving: Bool
    let onUnarchive: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L10n.string("This task is archived. Unarchive it to keep working in it."))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if isUnarchiving {
                ProgressView()
                    .controlSize(.small)
            }
            Button(L10n.string("Unarchive"), action: onUnarchive)
                .disabled(isUnarchiving)
                .parityPointer()
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(ParityTheme.input, in: RoundedRectangle(cornerRadius: ParityTheme.composerCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ParityTheme.composerCornerRadius)
                .stroke(ParityTheme.separator)
        }
        .frame(maxWidth: ParityTheme.contentWidth)
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilitySortPriority(ParityAccessibility.composer)
    }
}
