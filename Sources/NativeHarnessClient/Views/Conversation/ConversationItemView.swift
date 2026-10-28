import SwiftUI

/// What an item and a request card read from the conversation around them.
struct ConversationItemContext {
    let harness: HarnessKind
    /// The task's folder, which Codex cards resolve paths and file changes against.
    let workspaceURL: URL
    let actions: ConversationActions
    /// The transcript's last entry, whose limit card is the one that offers to continue.
    var lastEntryID: UUID? = nil
}

/// One item of a turn, drawn from its normalized `kind` with one card per kind, whatever the harness:
/// a sent message, a provider's message (plan M12f, D12), a call or the provider's own thinking, its
/// summary too, as a status line (`ConversationWorkLine`, 2026-10-15), a subagent (M12b), a Claude
/// bash command. Only what one provider alone sends —
/// a Codex proposed plan and a Codex notice — is still drawn by the card its record has (`source`).
struct ConversationItemView: View {
    let item: ConversationItem
    /// Whether the item's turn has ended, which a Codex card reads. Only that, not the turn: a view
    /// holding its whole turn is compared with it on every update, and a running turn's every item
    /// compared every item of the turn each time the turn streamed.
    let isTurnFinished: Bool
    let context: ConversationItemContext

    var body: some View {
        switch item.kind {
        case let .userMessage(text, images):
            ConversationSentMessage(itemID: item.id, text: text, images: images, attachments: item.promptAttachments,
                                    sentFromTask: item.taskMessage, backgroundTaskNotice: item.backgroundTaskNotice,
                                    phase: item.phase, isHistoryMatch: item.isHistoryMatch)
        case let .scheduledTaskMessage(message):
            ConversationSentMessage(itemID: item.id, text: message.instructions, images: [],
                                    isSentByScheduledTask: true, claudeSchedule: message.claudeSchedule,
                                    phase: item.phase, isHistoryMatch: item.isHistoryMatch)
        case let .shellCommand(message, entryID):
            ClaudeBashCommandRow(entryID: entryID, message: message, runInTerminal: context.actions.runInTerminal)
        case let .answer(text, isStreaming):
            agentMessage(text: text, isCommentary: false, isStreaming: isStreaming)
        case let .commentary(text, isStreaming):
            agentMessage(text: text, isCommentary: true, isStreaming: isStreaming)
        case .reasoning, .command, .fileChange, .tool:
            ConversationWorkLine(item: item, harness: context.harness, workspaceURL: context.workspaceURL,
                                 runInTerminal: context.actions.runInTerminal,
                                 subtaskControls: context.actions.subtaskControls)
                .equatable()
        case let .subagent(subagent):
            ConversationSubagentCard(subagent: subagent, phase: item.phase, actions: context.actions,
                                     copyDetails: item.copyDetails, isHistoryMatch: item.isHistoryMatch)
        case .taskSuggestion:
            TaskSuggestionCard(items: [item])
        case let .scheduleCreated(creation):
            ScheduledTaskCreatedRow(creation: creation)
        case .proposedPlan, .notice, .compaction, .request, .outcome:
            // The turn draws a compaction, an answered request and an earlier outcome itself.
            sourceCard
        }
    }

    private func agentMessage(text: String, isCommentary: Bool, isStreaming: Bool) -> some View {
        ConversationAgentMessage(
            itemID: item.id, harness: context.harness, text: text, isCommentary: isCommentary,
            isStreaming: isStreaming, providerPhase: providerPhase, isSummary: item.isSummary, phase: item.phase,
            copyDetails: item.copyDetails, isHistoryMatch: item.isHistoryMatch
        )
    }

    /// A Codex message's phase that Codex sent but Yardlet does not know, which the message names.
    private var providerPhase: String? {
        guard case let .codex(codexItem, _) = item.source, case let .agentMessage(message) = codexItem.content,
              case let .unknown(phase) = message.phase else { return nil }
        return phase
    }

    @ViewBuilder
    private var sourceCard: some View {
        if case let .codex(codexItem, _) = item.source {
            CodexItemCard(item: codexItem, isTurnFinished: isTurnFinished, historyMatch: item.isHistoryMatch)
        }
    }
}
