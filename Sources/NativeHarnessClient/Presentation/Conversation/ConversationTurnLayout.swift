import Foundation
import YardletRemote

/// How every harness lays out a turn and folds its work: the Codex app's rules, one rule for every
/// harness (decisions of 2026-10-23: follow the Codex app properly, and use one rule rather than one
/// per harness so the app does not become a patchwork; 2026-10-30: fold as the Codex app does rather
/// than leave notes open as the Claude app does; 2026-11-24: only what a provider marks as working
/// notes is notes, so a provider that marks none has its messages kept in view and only the calls
/// between them folded, as the Claude app draws them). Where the Codex app 26.1023 has them:
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
///   final answer it finished and every call still running (`ConversationTurn.workKeptWhenFolded`).
/// - A message that stays in view, sent into the turn or said to the person, parts the fold: the work
///   before it folds under the turn header, the work after it on a line of its own that reads the calls
///   it folds (`ConversationTurn.workStretches`).
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

    /// What a turn answered, as a task waiting on it reads it (`wait_tasks`, `run_agent`): every
    /// message it said to the person since the person last wrote into it, in the order they were
    /// written, a blank line apart. A provider that marks no final answer can write its report before
    /// its last call and close on a line ("Done."), so none is left out for its length or place. Past
    /// `limit` UTF-8 bytes the latest words are kept and the cut is marked at the start. `items` is the
    /// turn's work and then its answers, which is the order they happened in.
    static func answerText<Items: BidirectionalCollection<ConversationItem>>(
        _ items: Items, limit: Int = RemoteText.assistantLimit
    ) -> String? {
        var said: [String] = []
        var bytes = 0
        for item in items.reversed() {
            if item.isPersonMessage { break }
            guard case let .answer(text, _) = item.kind, !item.isSentWhileWorking else { continue }
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { continue }
            said.append(words)
            bytes += words.utf8.count + 2
            if bytes >= limit { break }
        }
        guard !said.isEmpty else { return nil }
        let text = said.reversed().joined(separator: "\n\n")
        guard text.utf8.count > limit else { return text }
        let mark = "…"
        guard limit > mark.utf8.count else { return limit == mark.utf8.count ? mark : "" }
        // The cut moves forward to the next whole character, so a composed letter, an emoji sequence
        // or a line break is never split after the mark.
        let utf8 = text.utf8
        var start = utf8.index(utf8.endIndex, offsetBy: -(limit - mark.utf8.count))
        while start < utf8.endIndex, start.samePosition(in: text) == nil { utf8.formIndex(after: &start) }
        return mark + String(text[start...])
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

    /// The header reads the turn's work time once the turn no longer runs: always for a provider's own times, and
    /// for times read from the entries when they span a second or more (D4). While the turn runs, every harness reads
    /// its time on the live line, beside what it does now, so the header adds no row of its own before the work folds.
    var showsWorkTime: Bool {
        status != .running && (!timing.isApproximate || timing.durationMilliseconds != nil)
    }

    /// The header is drawn when it holds something: a work time or a fold. `foldsWork` is whether the part of the turn
    /// drawn folds its work (`foldsWork` for a whole turn).
    func drawsHeader(foldsWork: Bool) -> Bool {
        showsHeader && (showsWorkTime || (foldsWork && opensFoldedWork))
    }

    /// The header opens something once the work folds: the turn has work details (`hasWorkDetails`) and
    /// folding hides some of them, its plan once the turn no longer runs (a running turn keeps it in
    /// view), items still to load or work it does not keep in view (`workKeptWhenFolded`). A turn that keeps all its work in view (every message Claude wrote, with
    /// no call between them) has nothing for its header to open. Read from the start, it stops at the
    /// first hidden item.
    var opensFoldedWork: Bool {
        guard hasWorkDetails else { return false }
        if (plan != nil && status != .running) || hasMoreItems { return true }
        let answered = finishedAnswerIndex
        return work.indices.contains { !keepsInViewWhenFolded(work[$0], at: $0, answered: answered) }
    }

    /// What the header reads once the turn no longer runs: how long it worked, or that it was stopped, as the Codex
    /// app reads its turn (`CodexTurnProgressProjection.finishedTitle`).
    var workTimeTitle: String {
        CodexTurnProgressProjection.finishedTitle(
            status: CodexTurnStatus(status),
            duration: CodexTurnProgressProjection.completedDuration(
                durationMilliseconds: timing.durationMilliseconds, startedAt: timing.startedAt,
                completedAt: timing.completedAt
            )
        )
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
    /// - while it runs, everything after the latest final answer the work finished, and every call still
    ///   running;
    /// - what waits on the person or tells them what was done, which only Yardlet draws: a suggested
    ///   task, a schedule an agent created, and an error or limit the turn went on past, which a final
    ///   answer never hides.
    var workKeptWhenFolded: [ConversationItem] {
        let answered = finishedAnswerIndex
        return work.enumerated().compactMap { index, item in
            keepsInViewWhenFolded(item, at: index, answered: answered) ? item : nil
        }
    }

    /// A folded turn's work, parted at each message that stays in view (`workKeptWhenFolded`) and was
    /// sent into the turn or said to the person: the work before the first such message, which the
    /// turn header folds, then each message with the work after it up to the next, which folds on a
    /// line of its own. One fold above the person's message read as if the message came after all the
    /// work and the answer replied to it alone, when it was sent while the work went on; one fold above
    /// what the provider said read as if it said it all before working, when it worked between its
    /// messages, as the Claude app folds only the calls between them. A message folded with the work
    /// (one a finished final answer followed, from another task or a schedule) parts nothing, as it is
    /// not in view to part it.
    var workStretches: [ConversationWorkStretch] {
        let answered = finishedAnswerIndex
        var stretches: [ConversationWorkStretch] = []
        var message: ConversationItem?, start = 0, kept: [ConversationItem] = []
        for (index, item) in work.enumerated() where keepsInViewWhenFolded(item, at: index, answered: answered) {
            if item.isSentIntoTurn || ConversationTurnLayout.isAnswer(item) {
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

    /// The message "Copy full response" sits on: the last one the turn said to the person, once the
    /// turn ended having said more than one since the person last wrote into it
    /// (`ConversationTurnLayout.answerText`). A turn that said one has only that message's copy. Read
    /// from the end, it stops at the second message, so a long turn costs no more than a short one.
    var fullResponseAnswerID: String? {
        guard status.isTerminal else { return nil }
        var last: String?
        for item in [answers.reversed(), work.reversed()].joined() {
            if item.isPersonMessage { return nil }
            guard case let .answer(text, _) = item.kind, !item.isSentWhileWorking,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if last != nil { return last }
            last = item.id
        }
        return nil
    }

    /// What "Copy full response" copies: every message the turn said to the person since the person
    /// last wrote into it, whole (`ConversationTurnLayout.answerText`).
    var fullResponseText: String? {
        ConversationTurnLayout.answerText(work + answers, limit: .max)
    }

    /// Where in the work the latest finished final answer is: past the work when the closing answer
    /// has ended, -1 when there is none.
    private var finishedAnswerIndex: Int {
        answers.contains(where: ConversationTurnLayout.isFinishedAnswer)
            ? work.count : work.lastIndex(where: ConversationTurnLayout.isFinishedAnswer) ?? -1
    }

    private func keepsInViewWhenFolded(_ item: ConversationItem, at index: Int, answered: Int) -> Bool {
        if status == .running, answered >= 0, index > answered { return true }
        // While the turn runs, a call still running stays in view wherever it started: a background
        // command the provider went on past, which the person stops from its line.
        if status == .running, item.phase == .running, ConversationWorkSummary.category(of: item) != nil { return true }
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
        case let .tool(tool) where tool.drawsView:
            return true
        case let .request(request):
            return request.isQuestion
        default:
            return false
        }
    }
}

/// A stretch of a folded turn's work (`ConversationTurn.workStretches`): the message that opens it
/// (sent into the turn, or said to the person), the work after that message up to the next, and what
/// of that work stays in view while it folds.
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

    /// What the stretch's fold reads: the calls it hides, as a run of them reads folded
    /// (`ConversationWorkSummary`), so the line says what happened between the messages around it;
    /// nil when it hides no call, for the fold to read "Work details".
    func foldTitle(harness: HarnessKind) -> String? {
        let keptIDs = Set(kept.map(\.id))
        let calls = work.filter { !keptIDs.contains($0.id) && ConversationWorkSummary.category(of: $0) != nil }
        return calls.isEmpty ? nil : ConversationWorkSummary.title(for: calls, harness: harness)
    }

    /// The stretch opens with what the provider said, not with a message sent into the turn: its fold
    /// sits close to the messages around it, as the Claude app draws the calls between two messages.
    var opensWithAnswer: Bool {
        if case .answer = message?.kind { return true }
        return false
    }
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
