import Foundation
import UWP
import WinUI

/// What a turn draws from the conversation around it: its harness and folder, the request cards the timeline keeps,
/// and what the task can do about it (retry a turn, sign in, edit a message, continue past a plan limit).
@MainActor
struct ConversationTurnContext {
    let harness: HarnessKind
    let workspaceURL: URL?
    /// The card for a request, the same one while the request is in the turn (`ConversationTimeline`).
    let card: (ConversationRequest, ConversationTurn) -> RequestCard
    /// The card for a turn's Codex async questions (`ConversationTimeline`).
    var questionCard: ((ConversationTurn, [CodexAsyncQuestion], [String: ConversationQuestionAnswer]?,
                        (@MainActor (String) -> Void)?) -> CodexQuestionCard)? = nil
    /// Retries a turn by its ID, where the task can (`AppModel.retryTurn`).
    let retry: (@MainActor (String) -> Void)?
    let signIn: HarnessSignIn?
    /// Puts a request back in the composer without sending it (the error card's Edit request); nil where it cannot.
    var restoreRequest: (@MainActor (CodexComposerDraft) -> Void)? = nil
    /// Starts editing the turn's message in the composer (its Edit message); nil where the task cannot.
    var editMessage: (@MainActor (ConversationTurn) -> Void)? = nil
    /// Sends the person's answer to a Codex async question once the turn ended.
    var answerQuestion: (@MainActor (String, String) -> Void)? = nil
    /// Sends the person's answer to a Codex async question into a running turn.
    var answerQuestionWhileWorking: (@MainActor (String, String) -> Void)? = nil
    /// The task's notices and its limit card's actions (`AppModel.providerNotices`).
    var notices: TaskProviderNotices? = nil
    /// The limit card the task continues from (`ConversationPresentation.limitCardEntryID`).
    var limitCardEntryID: UUID? = nil
}

/// One turn, laid out as the Mac's `ConversationTurnView` lays it out for every harness: what was sent, the provider's
/// notices, the header (how long it worked, which folds the work once a final answer began, `foldsWork`), the work
/// (its plan, then everything in the order it happened, runs of calls folded on their summary lines), the answers,
/// while it runs the one live line, then how it ended. The timeline docks pending requests above the composer. A folded turn
/// keeps in view what the rule every harness shares keeps (`workKeptWhenFolded`), parted at the messages sent into it
/// (`workStretches`). What the person opened and folded stays as the turn is drawn again
/// (`ConversationDisclosureChoices`); the timeline keeps one element per turn while the turn is shown.
@MainActor
final class ConversationTurnElement {
    let view = StackPanel()
    private(set) var turn: ConversationTurn
    private var context: ConversationTurnContext
    /// The person opened the folded work.
    private var showsWorkDetails = false
    /// The stretches of the folded work the person opened on their own lines.
    private var openedStretches: Set<String> = []
    private let choices = ConversationDisclosureChoices()
    /// When the turn was first drawn, for a running turn whose start no record gave.
    private let firstObservedAt = Date()
    /// The live line's steps and time, counted on each second while the turn runs.
    private var liveDetail: (text: TextBlock, steps: Int)?
    private var ticker: Task<Void, Never>?
    /// Draws the turn again when its limit card's reset comes, so its switch gives way to Resume.
    private var limitReset: Task<Void, Never>?
    private var signInRow: SignInRow?

    init(turn: ConversationTurn, context: ConversationTurnContext) {
        self.turn = turn
        self.context = context
        view.spacing = ConversationStyle.itemSpacing
        draw()
    }

    /// The turn as it stands now, drawn again.
    func update(_ turn: ConversationTurn, context: ConversationTurnContext) {
        self.turn = turn
        self.context = context
        draw()
    }

    private var lineContext: ConversationLineContext {
        ConversationLineContext(harness: context.harness, workspaceURL: context.workspaceURL, choices: choices)
    }

    // MARK: - Drawing

    private func draw() {
        view.children.clear()
        liveDetail = nil
        limitReset?.cancel()
        limitReset = nil
        let foldsWork = turn.foldsWork
        let workShows = !foldsWork || showsWorkDetails
        let live = ConversationLiveWork.make(turn, harness: context.harness, workspaceURL: context.workspaceURL)

        for item in turn.prompt { add(item, offersEdit: true) }
        for item in turn.notices { add(item) }
        if turn.drawsHeader(foldsWork: foldsWork) { view.children.append(header(foldsWork: foldsWork)) }
        if workShows {
            if let plan = turn.plan { view.children.append(planCard(plan)) }
            // While the turn runs, its last run with a call still running is the live line's, not listed as well.
            for run in ConversationLiveWork.listedRuns(turn) { add(run, foldsWork: foldsWork, stretchWasOpened: false) }
        } else {
            // What the fold keeps in view, parted at the messages sent into the turn.
            for stretch in ConversationWorkGrouping.stretchesWhenFolded(turn, live: live) { add(stretch, foldsWork: foldsWork) }
        }
        for item in turn.answers { add(item) }
        if let answered = turn.actions.answeredQuestions, let make = context.questionCard {
            make(turn, answered.questions, answered.answers, nil).place(in: view)
        } else if turn.status.isTerminal, !turn.actions.questionsToAnswer.isEmpty, let make = context.questionCard {
            let turnID = turn.id
            let send: (@MainActor (String) -> Void)? = context.answerQuestion.map { answer in { answer(turnID, $0) } }
            make(turn, turn.actions.questionsToAnswer, nil, send).place(in: view)
        }
        if let live {
            view.children.append(liveLine(live))
        } else if workShows, let line = statusLine(turn.progress) {
            view.children.append(line)
        }
        if let outcome = turn.outcome { view.children.append(outcomeCard(outcome, isTurnOutcome: true)) }
        if !turn.status.isTerminal, !turn.actions.questionsToAnswer.isEmpty, let make = context.questionCard {
            let turnID = turn.id
            let send: (@MainActor (String) -> Void)? = context.answerQuestionWhileWorking.map { answer in
                { answer(turnID, $0) }
            }
            make(turn, turn.actions.questionsToAnswer, nil, send).place(in: view)
        }
        followTime()
    }

    /// An item of the turn: an answered request by its card, an earlier error by its card, a compaction by its
    /// marker, a call by its line, a message by its card; the message the turn was sent with offers its edit.
    private func add(_ item: ConversationItem, offersEdit: Bool = false) {
        switch item.kind {
        case let .request(request):
            context.card(request, turn).place(in: view)
        case let .outcome(outcome):
            view.children.append(outcomeCard(outcome, isTurnOutcome: false))
        case let .userMessage(text, images):
            view.children.append(ConversationMessages.sent(item, text: text, images: images,
                                                           edit: offersEdit ? editMessage : nil))
        case let .compaction(compaction):
            view.children.append(ConversationNotices.compaction(compaction))
        case let .scheduledTaskMessage(message):
            view.children.append(ConversationMessages.scheduled(message))
        case let .answer(text, isStreaming):
            view.children.append(ConversationMessages.agent(item, text: text, isCommentary: false,
                                                            isStreaming: isStreaming, harness: context.harness))
        case let .commentary(text, isStreaming):
            view.children.append(ConversationMessages.agent(item, text: text, isCommentary: true,
                                                            isStreaming: isStreaming, harness: context.harness))
        case let .proposedPlan(text, _):
            view.children.append(MarkdownView.element(text, dialect: TranscriptMarkdownDialect(messagesOf: context.harness)))
        default:
            if let line = ConversationWorkLines.line(for: item, context: lineContext) { view.children.append(line) }
        }
    }

    /// A run of the work: a call alone as its line, consecutive calls on their summary line, which opens when one of
    /// them failed, when the person opened it, and when the person opened the folded work, or the stretch it is in.
    private func add(_ run: ConversationWorkGrouping.Run, foldsWork: Bool, stretchWasOpened: Bool) {
        switch run {
        case let .single(item):
            add(item)
        case let .group(items):
            let key = ConversationDisclosureChoices.runKey(items)
            let choices = self.choices
            let startsOpen = ConversationWorkDisclosure.groupStartsOpen(
                items, turnIsRunning: !turn.status.isTerminal,
                workWasOpened: foldsWork && (showsWorkDetails || stretchWasOpened), choice: choices.choice(key)
            )
            view.children.append(ConversationWorkLines.group(items, context: lineContext, startsOpen: startsOpen) { open in
                choices.record(key, isOpen: open)
            })
        case .suggestions:
            // Suggested tasks come from Yardlet's own tools, which the Windows app does not offer yet.
            break
        }
    }

    /// A stretch of the folded work: the message that opens it, its own fold when it hides work, then what it keeps
    /// in view, or all of its work once the person opened it.
    private func add(_ stretch: ConversationWorkStretch, foldsWork: Bool) {
        let folds = stretch.message != nil && stretch.hidesWork
        let isOpen = folds && openedStretches.contains(stretch.id)
        if let message = stretch.message { add(message) }
        if folds {
            let id = stretch.id
            view.children.append(workDetailsFold(isOpen: isOpen) { [weak self] open in
                guard let self else { return }
                if open { self.openedStretches.insert(id) } else { self.openedStretches.remove(id) }
                self.draw()
            })
        }
        for run in ConversationWorkGrouping.runs(isOpen ? Array(stretch.work) : stretch.kept) {
            add(run, foldsWork: foldsWork, stretchWasOpened: isOpen)
        }
    }

    // MARK: - Header

    /// The work summary and its fold: how long a finished turn worked (`workTimeTitle`), or "Work details" where it
    /// has no time to read; opening it draws the turn again with its work.
    private func header(foldsWork: Bool) -> UIElement {
        let canExpand = foldsWork && turn.hasWorkDetails
        let isOpen = showsWorkDetails
        guard turn.showsWorkTime else {
            return workDetailsFold(isOpen: isOpen) { [weak self] open in self?.showWork(open) }
        }
        let title = ConversationStyle.text(turn.workTimeTitle, size: ConversationStyle.captionSize, tone: .secondary,
                                           selectable: false, wraps: false)
        title.verticalAlignment = .center
        guard canExpand else {
            title.margin = Thickness(left: 2, top: 0, right: 2, bottom: 0)
            return title
        }
        let label = ConversationStyle.row([title, ConversationStyle.caret(isOpen: isOpen)])
        label.minHeight = 20
        return ConversationStyle.disclosure(label, name: turn.workTimeTitle, isOpen: isOpen) { [weak self] open in
            self?.showWork(open)
        }
    }

    /// "Work details" with its list mark and caret: a fold with no time to read, the turn's or a stretch's.
    private func workDetailsFold(isOpen: Bool, toggle: @escaping @MainActor (Bool) -> Void) -> UIElement {
        let title = L10n.string("Work details")
        let words = ConversationStyle.text(title, size: ConversationStyle.captionSize, tone: .secondary,
                                           selectable: false, wraps: false)
        words.verticalAlignment = .center
        let label = ConversationStyle.row([ConversationStyle.icon(ConversationStyle.Glyph.list, size: 11), words,
                                           ConversationStyle.caret(isOpen: isOpen)])
        label.minHeight = 20
        return ConversationStyle.disclosure(label, name: title, isOpen: isOpen, toggle: toggle)
    }

    private func showWork(_ open: Bool) {
        showsWorkDetails = open
        draw()
    }

    // MARK: - Live line and status line

    /// The live line, whose steps and time the turn counts on each second.
    private func liveLine(_ live: ConversationLiveWork) -> UIElement {
        let detail = TextBlock()
        liveDetail = (detail, live.steps)
        showLiveDetail()
        let key = ConversationDisclosureChoices.runKey(live.items)
        let choices = self.choices
        let single = live.items.count == 1 ? live.items[0].id : nil
        return ConversationWorkLines.liveLine(
            live, detail: detail, context: lineContext,
            startsOpen: ConversationWorkDisclosure.liveLineStartsOpen(live.items, choice: choices.choice(key))
        ) { open in
            choices.record(key, isOpen: open)
            // One call opens on what it holds: the line under the live line reads this choice.
            if let single { choices.record(single, isOpen: open) }
        }
    }

    private func showLiveDetail() {
        guard let liveDetail else { return }
        let elapsed = BackgroundTasksProjection.elapsedText(since: turn.timing.startedAt ?? firstObservedAt, now: Date())
        let detail = ConversationLiveWork.detail(steps: liveDetail.steps, elapsed: elapsed)
        liveDetail.text.text = detail.isEmpty ? "" : "· " + detail
    }

    /// Counts the live line's time on each second while there is one.
    private func followTime() {
        guard liveDetail != nil, ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.liveDetail != nil else { break }
                self.showLiveDetail()
            }
            self?.ticker = nil
        }
    }

    /// What a turn whose work shows reads under it while it has no live line (the Mac's
    /// `ConversationTurnStatusLine`): a stream that reconnects, or thinking before the first output.
    private func statusLine(_ progress: ConversationTurnProgress) -> UIElement? {
        switch progress {
        case let .reconnecting(status):
            return ConversationStyle.row([
                ConversationStyle.icon(ConversationStyle.Glyph.sync, size: 11),
                ConversationStyle.text(status, size: ConversationStyle.captionSize, tone: .secondary)
            ], spacing: 5)
        case .thinking:
            return ConversationStyle.text(L10n.string("Thinking"), size: ConversationStyle.captionSize, tone: .tertiary)
        case .none:
            return nil
        }
    }

    // MARK: - Cards

    /// The error card of the turn's own outcome, which offers what the turn can do about it, or of an earlier error
    /// the turn went on past, which only reports it. A plan limit's card offers to continue past it where it is the
    /// one the task continues from (`ConversationNotices.limitCard`).
    private func outcomeCard(_ outcome: ConversationTurnOutcome, isTurnOutcome: Bool) -> UIElement {
        switch outcome {
        case let .error(error):
            let turnID = turn.id
            var retry: (@MainActor () -> Void)?
            if isTurnOutcome, turn.actions.canRetry, let retryTurn = context.retry { retry = { retryTurn(turnID) } }
            var row: SignInRow?
            if isTurnOutcome, let signIn = context.signIn, ProviderSignIn.asksToSignIn(error.message) {
                let kept = signInRow ?? SignInRow(signIn: signIn, offersAlways: true)
                signInRow = kept
                kept.show(context.harness)
                row = kept
            }
            var editRequest: (@MainActor () -> Void)?
            if isTurnOutcome, turn.status.isTerminal, let draft = turn.actions.failedRequestDraft,
               let restore = context.restoreRequest {
                editRequest = { restore(draft) }
            }
            return ConversationMessages.errorCard(error, harness: context.harness, retry: retry, editRequest: editRequest,
                                                  signIn: row)
        case let .usageLimit(limit, entryID):
            let made = ConversationNotices.limitCard(limit, entryID: entryID, isLatest: entryID == context.limitCardEntryID,
                                                     notices: context.notices)
            if let resetsAt = made.resetsAt {
                limitReset = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(max(1, resetsAt.timeIntervalSinceNow)))
                    guard !Task.isCancelled, let self else { return }
                    self.draw()
                }
            }
            return made.card
        }
    }

    /// The turn's Edit message (the Mac's `ConversationTurnAction`): Codex puts the request of its latest turn back in
    /// the composer to send again in its place, Claude Code edits its latest message; nil where the turn offers none.
    private var editMessage: (@MainActor () -> Void)? {
        let actions = turn.actions
        guard (actions.editsTurnInComposer && actions.canEdit) || actions.editLatest != nil,
              let edit = context.editMessage else { return nil }
        let turn = self.turn
        return { edit(turn) }
    }

    /// The turn's plan as its steps, each with its state (the Mac's `CodexPlanCard`).
    private func planCard(_ plan: ConversationPlan) -> UIElement {
        let stack = StackPanel()
        stack.spacing = 6
        if let explanation = plan.explanation, !explanation.isEmpty {
            stack.children.append(ConversationStyle.text(explanation, size: ConversationStyle.calloutSize, tone: .secondary))
        }
        for step in plan.steps {
            let (glyph, tone): (String, ConversationStyle.Tone) = switch step.status {
            case .completed: (ConversationStyle.Glyph.check, .tertiary)
            case .inProgress: (ConversationStyle.Glyph.circleFill, .primary)
            case .pending, .unknown: (ConversationStyle.Glyph.circle, .secondary)
            }
            let words = ConversationStyle.text(step.text, size: ConversationStyle.calloutSize, tone: tone)
            if step.status == .completed { words.textDecorations = .strikethrough }
            stack.children.append(ConversationStyle.row([ConversationStyle.icon(glyph, size: 11), words], spacing: 8))
        }
        let frame = Border()
        frame.background = WindowsTheme.elevated.brush
        frame.borderBrush = WindowsTheme.separator.brush
        frame.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        frame.cornerRadius = ConversationStyle.corners(WindowsTheme.panelCornerRadius)
        frame.padding = Thickness(left: 12, top: 10, right: 12, bottom: 10)
        frame.child = stack
        try? AutomationProperties.setName(frame, L10n.string("Plan"))
        return frame
    }
}
