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
/// - A folded turn keeps in view the final answers it went on past, the messages the person sent into
///   it, the other messages sent into it that no finished final answer followed, the questions it
///   asked, the calls refused for want of an approval, and while it runs, everything after the latest
///   final answer it finished (`ConversationTurn.workKeptWhenFolded`).
/// - A message sent into the turn that stays in view parts the fold: the work before it folds under
///   the turn header, the work after it on a line of its own (`ConversationTurn.workStretches`).
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
    /// - a message the person sent into it. The Codex app folds one that a finished final answer
    ///   followed, so a message that stayed in view while the turn ran went out of sight when it ended;
    ///   the Claude app, which does not fold a turn, leaves it where it was sent. What the person wrote
    ///   is never folded away (2026-10-31);
    /// - a message another task, a background command or a schedule sent into it that no finished final
    ///   answer followed: once the closing answer has ended, none; before, those after the latest final
    ///   answer the work finished, or all of them while it has none;
    /// - a question it asked, answered or not (the Codex app keeps one left unanswered; Yardlet keeps
    ///   an answered one too, which reads as its answers);
    /// - a call refused for want of an approval the task's policy never asks for;
    /// - while it runs, everything after the latest final answer the work finished;
    /// - what waits on the person or tells them what was done, which only Yardlet draws: a suggested
    ///   task, a schedule an agent created, and an error or limit the turn went on past, which a final
    ///   answer never hides.
    var workKeptWhenFolded: [ConversationItem] {
        let answered = finishedAnswerIndex
        return work.enumerated().compactMap { index, item in
            keepsInViewWhenFolded(item, at: index, answered: answered) ? item : nil
        }
    }

    /// A folded turn's work, parted at each message sent into the turn that stays in view
    /// (`workKeptWhenFolded`): the work before the first such message, which the turn header folds,
    /// then each message with the work after it up to the next, which folds on a line of its own. One
    /// fold above the person's message read as if the message came after all the work and the answer
    /// replied to it alone, when it was sent while the work went on. A message folded with the work
    /// (one a finished final answer followed, from another task or a schedule) parts nothing, as it is
    /// not in view to part it.
    var workStretches: [ConversationWorkStretch] {
        let answered = finishedAnswerIndex
        var stretches: [ConversationWorkStretch] = []
        var message: ConversationItem?, start = 0, kept: [ConversationItem] = []
        for (index, item) in work.enumerated() where keepsInViewWhenFolded(item, at: index, answered: answered) {
            if item.isSentIntoTurn {
                stretches.append(ConversationWorkStretch(message: message, work: work[start..<index], kept: kept))
                message = item
                start = index + 1
                kept = []
            } else {
                kept.append(item)
            }
        }
        stretches.append(ConversationWorkStretch(message: message, work: work[start...], kept: kept))
        return stretches
    }

    /// Where in the work the latest finished final answer is: past the work when the closing answer
    /// has ended, -1 when there is none.
    private var finishedAnswerIndex: Int {
        answers.contains(where: ConversationTurnLayout.isFinishedAnswer)
            ? work.count : work.lastIndex(where: ConversationTurnLayout.isFinishedAnswer) ?? -1
    }

    private func keepsInViewWhenFolded(_ item: ConversationItem, at index: Int, answered: Int) -> Bool {
        if status == .running, answered >= 0, index > answered { return true }
        if item.wasRefusedForApproval { return true }
        switch item.kind {
        case .answer:
            return ConversationTurnLayout.isAnswer(item)
        case .userMessage where item.isPersonMessage:
            return true
        case .userMessage, .scheduledTaskMessage:
            return index >= answered
        case .taskSuggestion, .scheduleCreated, .settingChanged, .outcome:
            return true
        case let .tool(tool) where tool.view != nil:
            return true
        case let .request(request):
            return request.isQuestion
        default:
            return false
        }
    }
}

/// A stretch of a folded turn's work (`ConversationTurn.workStretches`): the message sent into the
/// turn that opens it, the work after that message up to the next, and what of that work stays in
/// view while it folds.
struct ConversationWorkStretch: Identifiable {
    /// The message that opens the stretch; nil for the first, whose work the turn header folds.
    var message: ConversationItem?
    /// The work after the message, in its order: what the fold hides and what it keeps. A part of the
    /// turn's work, not a copy of it, as a turn can hold thousands of items.
    var work: ArraySlice<ConversationItem>
    /// What of `work` stays in view while the stretch folds.
    var kept: [ConversationItem]

    var id: String { message.map { "stretch-" + $0.id } ?? "stretch" }

    /// The fold hides some of the stretch's work.
    var hidesWork: Bool { kept.count < work.count }
}

private extension ConversationItem {
    /// A message sent into the turn: the person's, another task's, a background command's or a
    /// schedule's.
    var isSentIntoTurn: Bool {
        switch kind {
        case .userMessage, .scheduledTaskMessage: true
        default: false
        }
    }
}
