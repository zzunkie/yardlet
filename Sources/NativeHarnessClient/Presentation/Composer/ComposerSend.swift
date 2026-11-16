import Foundation

/// Where a task composer's message goes once it leaves the draft: Codex's own draft path, or the harness's input,
/// sent as any message (`.automatic`) or queued or steered as the person chose. A bash-mode command is the composer's
/// own and never comes here.
enum ComposerSend: Equatable {
    /// Codex's typed draft, which keeps its attachments as Codex's inputs (`AppModel.submitCodex`).
    case codexDraft(CodexComposerDraft, CodexComposerAction)
    /// The harness's input; an explicit queue or steer goes through the follow-up path (`AppModel.submitFollowUp`).
    case input(HarnessUserInput, CodexComposerAction)
}

extension TaskComposerDraft {
    /// Takes the message out of the draft as a task composer's Send and its follow-up keys do, on the Mac and on
    /// Windows alike. The draft empties as the message goes, except while it edits an earlier message, which the
    /// model refuses with why, or when it holds a command its harness runs from the draft (`ComposerDraftRetention`).
    /// A message the harness cannot carry, such as an image for a harness without image input, stays with why
    /// (`notice`), and nothing goes. A queue or steer goes only where the composer has the follow-up path that takes
    /// it (`submitsFollowUp`); Codex's own draft path (`submitsCodexDraft`) takes every action.
    func takeMessage(options: ComposerSessionOptions, action: CodexComposerAction, submitsCodexDraft: Bool,
                     submitsFollowUp: Bool) -> ComposerSend? {
        let draft = submission
        guard !draft.isEmpty else { return nil }
        if options.submission == .codexDraft, submitsCodexDraft {
            if editState == nil && !options.draftRetention.keepsDraft(afterSending: draft.text) { clear() }
            return .codexDraft(draft, action)
        }
        if action != .automatic {
            guard options.followUp?.delivery == .providerInput, submitsFollowUp else { return nil }
        }
        switch options.input.submission(for: draft) {
        case let .refuse(why):
            notice = why
            return nil
        case let .send(input):
            // A queued or steered message is never a command the draft keeps.
            let keeps = action == .automatic && options.draftRetention.keepsDraft(afterSending: input.text)
            if editState == nil && !keeps { clear() }
            return .input(input, action)
        }
    }
}

extension ComposerQueueChip {
    /// A queued message's words, as its row in the composer names it: its request, the task that sent it, or the
    /// count of the comments it carries alone.
    static func title(of draft: CodexComposerDraft) -> String {
        if let message = TaskMessage.parse(draft.text) {
            return L10n.format("%@: %@", message.senderLabel, message.body)
        }
        if let sent = DiffCommentPrompt.parse(draft.text) {
            guard sent.request.isEmpty else { return sent.request }
            return sent.comments.isEmpty ? BrowserComment.countTitle(sent.browserComments.count)
                : DiffComment.countTitle(sent.comments.count)
        }
        return draft.text.isEmpty ? L10n.string("Attached context") : draft.text
    }
}
