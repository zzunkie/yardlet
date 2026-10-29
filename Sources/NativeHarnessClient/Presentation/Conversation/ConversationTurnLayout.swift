import Foundation

/// How every harness lays out a turn and folds its work: the Codex app's rules, one rule for every
/// harness (decisions of 2026-10-23: follow the Codex app properly, and use one rule rather than one
/// per harness so the app does not become a patchwork; 2026-10-30: fold as the Codex app does rather
/// than leave notes open as the Claude app does). Where the Codex app 26.1023 has them:
/// `split-items-into-render-groups` lays the turn out, and the work's fold (`Mj`, `wj` and `Tj`) is in
/// `subagent-activity-chip-group`.
///
/// - Everything after the turn's request stays where it happened. Only the message that closes the
///   turn is drawn under the work (`arrange`), as are proposed plans.
/// - The work folds once a final answer began, unless the person stopped the turn or an agent still
///   runs (`ConversationTurn.foldsWork`), while the turn runs too.
/// - A folded turn keeps in view the final answers it went on past, the messages sent into it that no
///   finished final answer followed, the questions it asked, the calls refused for want of an approval,
///   and while it runs, everything after the latest final answer it finished
///   (`ConversationTurn.workKeptWhenFolded`).
///
/// What differs between harnesses is only how each projection classifies what its provider wrote:
/// working notes (`ConversationItemKind.commentary`), what is said to the person
/// (`ConversationItemKind.answer`), and of that, what was sent while the work went on and so never
/// answers the turn (`ConversationItem.isSentWhileWorking`) and what the provider did not mark its
/// final answer (`ConversationItem.isUnmarkedAnswer`).
enum ConversationTurnLayout {
    /// The work and the answers of a turn whose items after its request are `items`, in the order
    /// they happened: the closing answer and the proposed plans under the work, everything else in
    /// the work where it happened.
    static func arrange(_ items: [ConversationItem]) -> (work: [ConversationItem], answers: [ConversationItem]) {
        let closing = closingAnswerIndex(in: items)
        var work: [ConversationItem] = []
        var answers: [ConversationItem] = []
        for (index, item) in items.enumerated() {
            if index == closing || isProposedPlan(item) { answers.append(item) } else { work.append(item) }
        }
        return (work, answers)
    }

    /// The message that closes the turn, as the Codex app picks its turn's last message: the last item,
    /// when it is said to the person and was not sent while the work went on, final answer or not.
    /// Reasoning that settled after it and a proposed plan leave it the last, as the Codex app draws them
    /// above its answer; anything else after it (a call, a message the person sent into the turn,
    /// working notes) means the turn went on past it. An answer being written counts once it is the
    /// last, so it streams where it stays.
    static func closingAnswerIndex(in items: [ConversationItem]) -> Int? {
        for index in items.indices.reversed() {
            let item = items[index]
            switch item.kind {
            case .reasoning where item.phase == .completed, .proposedPlan:
                continue
            case .answer:
                return item.isSentWhileWorking ? nil : index
            default:
                return nil
            }
        }
        return nil
    }

    /// A final answer that has begun (`N7a`): said to the person and marked final, not sent while the
    /// work went on, with words or ended.
    static func isAnswer(_ item: ConversationItem) -> Bool {
        guard case let .answer(text, _) = item.kind, !item.isSentWhileWorking, !item.isUnmarkedAnswer
        else { return false }
        return item.phase == .completed || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A final answer that ended with words (`P7a`).
    static func isFinishedAnswer(_ item: ConversationItem) -> Bool {
        guard case let .answer(text, _) = item.kind, !item.isSentWhileWorking, !item.isUnmarkedAnswer
        else { return false }
        return item.phase == .completed && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isProposedPlan(_ item: ConversationItem) -> Bool {
        if case .proposedPlan = item.kind { return true }
        return false
    }
}

extension ConversationTurn {
    /// The work folds unless the reader opened it (`Mj`): a final answer began — the turn's closing
    /// answer has words, or its work holds a final answer it went on past — and the person did not stop
    /// the turn. It folds while the turn runs too, once its answer streams. Work still going keeps the
    /// turn open: an agent while the turn runs too, as the Codex app keeps a turn open while its
    /// subagents run (`preventAutoCollapse`), and anything (a background command) once the turn ended.
    /// A turn read from inside, with no request, does not fold.
    var foldsWork: Bool {
        guard !prompt.isEmpty, status != .interrupted else { return false }
        if work.contains(where: { item in
            guard item.phase == .running else { return false }
            if status.isTerminal { return true }
            if case .subagent = item.kind { return true }
            return false
        }) { return false }
        return answers.contains(where: ConversationTurnLayout.isAnswer) || work.contains(where: ConversationTurnLayout.isAnswer)
    }

    /// What a folded turn keeps in view of its work, in its order (`wj`, `Tj`):
    /// - a final answer it went on past;
    /// - a message sent into it that no finished final answer followed: once the closing answer has
    ///   ended, none; before, those after the latest final answer the work finished, or all of them
    ///   while it has none;
    /// - a question it asked, answered or not (the Codex app keeps one left unanswered; Yardlet keeps
    ///   an answered one too, which reads as its answers);
    /// - a call refused for want of an approval the task's policy never asks for;
    /// - while it runs, everything after the latest final answer the work finished;
    /// - what waits on the person or tells them what was done, which only Yardlet draws: a suggested
    ///   task, a schedule an agent created, and an error or limit the turn went on past, which a final
    ///   answer never hides.
    var workKeptWhenFolded: [ConversationItem] {
        let answered = answers.contains(where: ConversationTurnLayout.isFinishedAnswer)
            ? work.count : work.lastIndex(where: ConversationTurnLayout.isFinishedAnswer) ?? -1
        return work.enumerated().compactMap { index, item in
            if status == .running, answered >= 0, index > answered { return item }
            if item.wasRefusedForApproval { return item }
            switch item.kind {
            case .answer:
                return ConversationTurnLayout.isAnswer(item) ? item : nil
            case .userMessage, .scheduledTaskMessage:
                return index >= answered ? item : nil
            case .taskSuggestion, .scheduleCreated, .outcome:
                return item
            case let .request(request):
                return request.isQuestion ? item : nil
            default:
                return nil
            }
        }
    }
}
