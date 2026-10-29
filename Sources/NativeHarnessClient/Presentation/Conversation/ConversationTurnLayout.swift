import Foundation

/// How every harness lays out a turn and folds its work: the Codex app 26.1016's rules
/// (`split-items-into-render-groups`, and `kk`, `Ak` and `Lk` of the block that folds its work),
/// one rule for every harness (decisions of 2026-10-23: follow the Codex app properly, and use one
/// rule rather than one per harness so the app does not become a patchwork).
///
/// - Everything after the turn's request stays where it happened. Only the answer that closes the
///   turn is drawn under the work (`arrange`), as are proposed plans.
/// - The work folds once the provider began to answer, unless the person stopped the turn
///   (`ConversationTurn.foldsWork`), while the turn runs too.
/// - A folded turn keeps in view the answers it went on past, the messages sent into it that no
///   finished answer followed, and while it runs, everything after the latest answer it finished
///   (`ConversationTurn.workKeptWhenFolded`).
///
/// What differs between harnesses is only how each projection classifies what its provider wrote:
/// working notes (`ConversationItemKind.commentary`), what is said to the person
/// (`ConversationItemKind.answer`), and of that, what was sent while the work went on and so never
/// answers the turn (`ConversationItem.isSentWhileWorking`).
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

    /// The answer that closes the turn, as the Codex app picks its turn's answer: the last item, when
    /// it is said to the person and was not sent while the work went on. Reasoning that settled after
    /// it and a proposed plan leave it the last, as the Codex app draws them above its answer; anything
    /// else after it (a call, a message the person sent into the turn, working notes) means the turn
    /// went on past it. An answer being written counts once it is the last, so it streams where it
    /// stays.
    static func closingAnswerIndex(in items: [ConversationItem]) -> Int? {
        for index in items.indices.reversed() {
            let item = items[index]
            if leavesAnswerLast(item) { continue }
            guard case .answer = item.kind else { return nil }
            return item.isSentWhileWorking ? nil : index
        }
        return nil
    }

    /// An item after an answer that leaves it the turn's last: reasoning that settled after it, or
    /// a proposed plan.
    static func leavesAnswerLast(_ item: ConversationItem) -> Bool {
        switch item.kind {
        case .reasoning where item.phase == .completed, .proposedPlan: true
        default: false
        }
    }

    /// The answer a turn's outcome reads (`read_task`, a subagent's card): the last one with words
    /// in its work, else its closing answer.
    static func latestAnswer(answers: [ConversationItem], work: [ConversationItem]) -> String? {
        for item in (answers + work).reversed() {
            if case let .answer(text, _) = item.kind, !text.isEmpty { return text }
        }
        return nil
    }

    /// An answer said to the person that has begun (`B2n`): it has words, or it ended.
    static func isAnswer(_ item: ConversationItem) -> Bool {
        guard case let .answer(text, _) = item.kind, !item.isSentWhileWorking else { return false }
        return item.phase == .completed || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// An answer said to the person that ended with words (`V2n`).
    static func isFinishedAnswer(_ item: ConversationItem) -> Bool {
        guard case let .answer(text, _) = item.kind, !item.isSentWhileWorking else { return false }
        return item.phase == .completed && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isProposedPlan(_ item: ConversationItem) -> Bool {
        if case .proposedPlan = item.kind { return true }
        return false
    }
}

extension ConversationTurn {
    /// The work folds unless the reader opened it (`Lk`): the provider began to answer — the turn's
    /// closing answer has words, or its work holds an answer it went on past — and the person did not
    /// stop the turn. It folds while the turn runs too, once its answer streams. A turn that ended with
    /// work still going (a background command or agent) stays open, as the Codex app keeps a turn open
    /// while its subagents run (`preventAutoCollapse`), and a turn read from inside, with no request,
    /// does not fold.
    var foldsWork: Bool {
        guard !prompt.isEmpty, status != .interrupted else { return false }
        if status.isTerminal, work.contains(where: { $0.phase == .running }) { return false }
        return answers.contains(where: ConversationTurnLayout.isAnswer) || work.contains(where: ConversationTurnLayout.isAnswer)
    }

    /// What a folded turn keeps in view of its work, in its order (`kk`, `Ak`):
    /// - an answer it went on past;
    /// - a message sent into it that no finished answer followed: once the closing answer has ended,
    ///   none; before, those after the latest answer the work finished, or all of them while it has none;
    /// - while it runs, everything after the latest answer the work finished;
    /// - what waits on the person or tells them what was done, which only Yardlet draws: a suggested
    ///   task, a schedule an agent created, an answered question, which reads as its answers, and an
    ///   error or limit the turn went on past, which a final answer never hides.
    var workKeptWhenFolded: [ConversationItem] {
        let answered = answers.contains(where: ConversationTurnLayout.isFinishedAnswer)
            ? work.count : work.lastIndex(where: ConversationTurnLayout.isFinishedAnswer) ?? -1
        return work.enumerated().compactMap { index, item in
            if status == .running, answered >= 0, index > answered { return item }
            switch item.kind {
            case .answer:
                return ConversationTurnLayout.isAnswer(item) ? item : nil
            case .userMessage, .scheduledTaskMessage:
                return index >= answered ? item : nil
            case .taskSuggestion, .scheduleCreated, .outcome:
                return item
            case let .request(request):
                return request.isAnsweredQuestion ? item : nil
            default:
                return nil
            }
        }
    }
}
