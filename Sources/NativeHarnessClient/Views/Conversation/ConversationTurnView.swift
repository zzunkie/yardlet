import SwiftUI

/// What a turn's controls do. The timeline makes them from the task's `ConversationActions` and the
/// turn's own `ConversationTurnActions`: a control is drawn only when the turn offers it and the task
/// can carry it out (nil).
struct ConversationTurnHandlers {
    /// Retry the turn the server was too busy for.
    var retry: (() -> Void)? = nil
    /// Put the turn's request back in the composer (its request's "Edit message", Codex), and "Edit
    /// request" on its error card while the turn's request can be edited.
    var edit: ((CodexComposerDraft) -> Void)? = nil
    /// Fork from this turn: Codex from any finished turn, Claude Code its whole conversation from its
    /// latest turn (D10).
    var fork: (() -> Void)? = nil
    /// The provider's own edit of the turn's message and restore of its files (Claude Code).
    var editMessage: ((ConversationMessageTarget) -> Void)? = nil
    var restoreFiles: (() -> Void)? = nil
    var implementPlan: (() -> Void)? = nil
    /// Sends an option of the question the turn ended on.
    var answerQuestion: ((String) -> Void)? = nil
    var loadMoreItems: () -> Void = {}
}

/// What a turn draws from the task around it, beyond the turn itself: which of its controls the task
/// can carry out, and the values its cards read from the task's actions.
struct ConversationTurnOffers: Equatable, Sendable {
    let harness: HarnessKind
    let workspaceURL: URL
    let lastEntryID: UUID?
    let handlers: [Bool]
    let actions: [Bool]
    let autoContinueEntryID: UUID?
    let canContinue: Bool
    let switchError: String?
    let limitWarning: HarnessRateLimit?

    @MainActor
    init(context: ConversationItemContext, handlers: ConversationTurnHandlers) {
        harness = context.harness
        workspaceURL = context.workspaceURL
        lastEntryID = context.lastEntryID
        self.handlers = [handlers.retry != nil, handlers.edit != nil, handlers.fork != nil,
                         handlers.editMessage != nil, handlers.restoreFiles != nil, handlers.implementPlan != nil,
                         handlers.answerQuestion != nil]
        let actions = context.actions
        self.actions = [actions.chooseOption != nil, actions.answer != nil, actions.showHarnessSettings != nil,
                        actions.subtaskControls != nil, actions.subtaskControls?.stop != nil,
                        actions.providerNotices != nil, actions.rewind != nil, actions.runInTerminal != nil]
        autoContinueEntryID = actions.providerNotices?.autoContinueEntryID
        canContinue = actions.providerNotices?.canContinue ?? false
        switchError = actions.providerNotices?.switchError
        limitWarning = actions.providerNotices?.limitWarning
    }
}

/// What a turn offers to do with its messages, drawn on the message it acts on beside that message's
/// copy and shown as the copy is, on hover or focus: the person's request offers its edit and the
/// restore of its files, the turn's answer its fork. The Claude app's Code tab (3.1623.3) and the
/// Codex app (26.1016) both put these under the message, not in a menu on the turn (2026-10-23;
/// the turn header's `…` menu is gone). The items are each provider's own: Codex
/// forks from any finished turn and puts its request back in the composer; Claude Code edits its
/// latest message, restores the files its latest message changed, and forks its whole conversation
/// from the latest turn (D10). What the turn cannot carry out now is not offered, as neither app offers
/// it.
enum ConversationTurnAction: Hashable, Sendable {
    case fork
    case editTurn
    case editMessage
    case restoreFiles

    static func items(for actions: ConversationTurnActions, handlers: ConversationTurnHandlers) -> [Self] {
        var items: [Self] = []
        if handlers.fork != nil, actions.canFork { items.append(.fork) }
        if actions.editsTurnInComposer, actions.canEdit, handlers.edit != nil { items.append(.editTurn) }
        if actions.editLatest != nil, handlers.editMessage != nil { items.append(.editMessage) }
        if actions.restoreFiles != nil, handlers.restoreFiles != nil { items.append(.restoreFiles) }
        return items
    }

    /// The answer's item, where the others are the request's.
    var isOnAnswer: Bool { self == .fork }

    /// The control the message draws for the item. Both edits read "Edit message", as the Codex app
    /// names its request's edit.
    @MainActor
    func messageAction(turn: ConversationTurn, handlers: ConversationTurnHandlers) -> ConversationMessageAction {
        switch self {
        case .fork:
            ConversationMessageAction(id: self, title: L10n.string("Fork from here"),
                                      systemImage: "arrow.triangle.branch") { handlers.fork?() }
        case .editTurn:
            ConversationMessageAction(id: self, title: L10n.string("Edit message"), systemImage: "pencil") {
                guard let draft = turn.actions.editDraft else { return }
                handlers.edit?(draft)
            }
        case .editMessage:
            ConversationMessageAction(id: self, title: L10n.string("Edit message"), systemImage: "pencil") {
                guard let target = turn.actions.editLatest else { return }
                handlers.editMessage?(target)
            }
        case .restoreFiles:
            ConversationMessageAction(id: self, title: L10n.string("Restore files…"),
                                      systemImage: "arrow.uturn.backward") { handlers.restoreFiles?() }
        }
    }
}

/// One turn, in the same order for every harness (plan A5.1): what was sent, the provider's notices,
/// the turn header (its work time, the fold of its work and its menu), the outcome, the work (plan
/// first, then everything in the order it happened, answered requests and messages sent into the
/// running turn included), the answers, the plan question, the status line, more items, and the
/// requests still waiting, pinned under the turn (D1). A folded turn keeps in view what the rule every
/// harness shares keeps (`ConversationTurn.workKeptWhenFolded`): the answers it went on past, the
/// messages no finished answer followed, and while it runs, what came after its latest answer.
struct ConversationTurnView: View, Equatable {
    let turn: ConversationTurn
    let context: ConversationItemContext
    let handlers: ConversationTurnHandlers
    /// What the turn draws from `context` and `handlers`, for telling an unchanged turn apart.
    private let offers: ConversationTurnOffers
    /// `turn.foldsWork`, read once: the header, the fold and every run's summary ask it, and each
    /// asking walks the turn's work.
    private let foldsWork: Bool

    init(turn: ConversationTurn, context: ConversationItemContext, handlers: ConversationTurnHandlers) {
        self.turn = turn
        self.context = context
        self.handlers = handlers
        offers = ConversationTurnOffers(context: context, handlers: handlers)
        foldsWork = turn.foldsWork
    }

    /// The timeline draws each turn `.equatable()`, so an update redraws only the turns it changed
    /// rather than every turn of the conversation: the handlers and actions are closures made afresh
    /// each time, so they are compared by what they offer. What a card reads through Observation or
    /// the environment still updates it on its own.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.turn == rhs.turn && lhs.offers == rhs.offers
    }

    @State private var showsWorkDetails = false
    /// What the person opened and folded in this turn, which a line or run reads when it moves
    /// between the live line and the listed work (`ConversationWorkDisclosure`).
    @State private var choices = ConversationDisclosureChoices()
    @Environment(\.conversationFind) private var find

    private func workLine(_ item: ConversationItem) -> ConversationWorkLine {
        ConversationWorkLine(item: item, harness: context.harness, workspaceURL: context.workspaceURL,
                             runInTerminal: context.actions.runInTerminal,
                             subtaskControls: context.actions.subtaskControls)
    }

    /// The live line, drawn anew for each run it stands for so that each starts where its rule
    /// and the person's choice for that run put it.
    private func liveLine(_ live: ConversationLiveWork) -> some View {
        let key = ConversationDisclosureChoices.runKey(live.items)
        return ConversationLiveWorkLine(
            live: live, startsOpen: ConversationWorkDisclosure.liveLineStartsOpen(live.items, choice: choices.choice(key)),
            startedAt: turn.timing.startedAt
        ) { isOpen in
            choices.record(key, isOpen: isOpen)
            // One call opens on what it holds: the line under the live line reads this choice.
            if live.items.count == 1 { choices.record(live.items[0].id, isOpen: isOpen) }
        } cell: { item in
            workLine(item)
                .equatable()
        }
        .id(key ?? "live")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ConversationLayout.itemSpacing) {
            ForEach(turn.prompt) { item in
                itemView(item)
            }

            ForEach(turn.notices) { item in
                itemView(item)
            }

            if showsHeader {
                header
            }

            if let outcome = turn.outcome {
                outcomeCard(outcome)
            }

            if workDetailsAreVisible {
                if let plan = turn.plan {
                    planCard(plan)
                }

                // While the turn runs, its last run with a call still running is the live line's
                // below, not listed here as well.
                ForEach(ConversationLiveWork.listedRuns(turn)) { run in
                    runView(run)
                }
            } else {
                // What the fold keeps in view, as the Codex app keeps it out of its folded work; a
                // running turn's live call stays the live line's.
                ForEach(ConversationWorkGrouping.runsKeptWhenFolded(
                    turn, live: ConversationLiveWork.make(turn, harness: context.harness, workspaceURL: context.workspaceURL)
                )) { run in
                    runView(run)
                }
            }

            ForEach(turn.answers) { item in
                itemView(item)
            }

            if let implementPlan = handlers.implementPlan {
                CodexImplementPlanPrompt(onImplement: implementPlan)
            }

            if let answered = turn.actions.answeredQuestions {
                CodexQuestionOptions(questions: answered.questions, answers: answered.answers)
            } else if turn.status.isTerminal, !turn.actions.questionsToAnswer.isEmpty {
                CodexQuestionOptions(questions: turn.actions.questionsToAnswer, onAnswer: handlers.answerQuestion)
            }

            if let live = ConversationLiveWork.make(turn, harness: context.harness, workspaceURL: context.workspaceURL) {
                // One line for the work in progress: thinking, the call that runs, or waiting on
                // the person, with the turn's steps and time.
                liveLine(live)
            } else if workDetailsAreVisible {
                ConversationTurnStatusLine(progress: turn.progress)
            }

            if workDetailsAreVisible, turn.hasMoreItems {
                Button {
                    handlers.loadMoreItems()
                } label: {
                    Label(L10n.string("Load more items"), systemImage: "square.stack.3d.up")
                }
                .buttonStyle(.borderless)
                .parityPointer()
                .font(.caption)
                .foregroundStyle(ParityTheme.accent)
                .accessibilityHint(L10n.string("Load the next page of items for this turn."))
            }

            ForEach(turn.requests) { request in
                ConversationRequestCard(request: request, actions: context.actions)
            }

            // Questions Codex asked while it goes on working wait for the person under the turn, as the
            // Codex app keeps its question panel above its composer while the turn runs.
            if !turn.status.isTerminal, !turn.actions.questionsToAnswer.isEmpty {
                CodexQuestionOptions(questions: turn.actions.questionsToAnswer, onAnswer: handlers.answerQuestion)
            }
        }
        .environment(\.conversationDisclosureChoices, choices)
        .accessibilityElement(children: .contain)
        // Find opens the turn's work when its current match is commentary inside, as the Codex app
        // expands a turn to show a match.
        .onChange(of: find?.slot(for: .container(turn.id)).revealToken ?? 0, initial: true) { _, token in
            if token > 0 { showsWorkDetails = true }
        }
    }

    // MARK: - Items

    /// A run of the turn's work, drawn alike in the listed work and in what a folded turn keeps in
    /// view. A run of calls folds into one summary line, while the turn runs as well; it opens when one
    /// of its calls failed, when the person opened it under the live line, and when the person opened
    /// the turn's folded work to see it.
    @ViewBuilder
    private func runView(_ run: ConversationWorkGrouping.Run) -> some View {
        switch run {
        case let .single(item):
            itemView(item)
        case let .group(items):
            let key = ConversationDisclosureChoices.runKey(items)
            ConversationWorkRun(
                lines: items.map(workLine), harness: context.harness,
                startsOpen: ConversationWorkDisclosure.groupStartsOpen(
                    items, turnIsRunning: !turn.status.isTerminal, workWasOpened: foldsWork && showsWorkDetails,
                    choice: choices.choice(key)
                ),
                onToggle: { choices.record(key, isOpen: $0) }
            )
            .equatable()
        case let .suggestions(items):
            TaskSuggestionCard(items: items)
        }
    }

    /// An item of the turn: an answered request by the one request card, a compaction by its marker
    /// and an earlier error or limit by its turn card for every harness (B7), everything else by its
    /// item card.
    @ViewBuilder
    private func itemView(_ item: ConversationItem) -> some View {
        switch item.kind {
        case let .request(request):
            ConversationRequestCard(request: request, actions: context.actions)
        case let .compaction(compaction):
            CompactionMarker(compaction: compaction)
        case let .outcome(outcome):
            outcomeCard(outcome, isTurnOutcome: false)
        default:
            ConversationItemView(item: item, isTurnFinished: turn.status.isTerminal, context: context)
                .environment(\.conversationMessageActions, messageActions(for: item))
        }
    }

    /// The turn's actions the item draws beside its copy: the person's request draws its edit and
    /// restore, the turn's last answer its fork — the request, when the turn has no answer (it failed
    /// or stopped first) — (`ConversationTurnAction`); any other item none.
    private func messageActions(for item: ConversationItem) -> [ConversationMessageAction] {
        let answerID = turn.answers.last?.id
        let isAnswer = item.id == answerID, isRequest = item.id == requestItemID
        guard isAnswer || isRequest else { return [] }
        return ConversationTurnAction.items(for: turn.actions, handlers: handlers)
            .filter { $0.isOnAnswer ? isAnswer || (isRequest && answerID == nil) : isRequest }
            .map { $0.messageAction(turn: turn, handlers: handlers) }
    }

    /// The request the person sent to open the turn, which its edit and restore act on.
    private var requestItemID: String? {
        turn.prompt.first { item in
            guard case .userMessage = item.kind else { return false }
            return item.taskMessage == nil && item.backgroundTaskNotice == nil
        }?.id
    }

    // MARK: - Header

    /// The work summary and its fold. A finished turn reads how long it worked when its times give
    /// one — the provider's own, or its entries' (D4). A running turn reads its time on the live line
    /// instead, so its header is drawn only to fold its work, under "Work details", as is a settled
    /// turn's without a time. What the turn offers to do with its messages is on the messages
    /// (`ConversationTurnAction`).
    private var header: some View {
        let canExpand = foldsWork && turn.hasWorkDetails
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if canExpand {
                    Button {
                        showsWorkDetails.toggle()
                    } label: {
                        headerLabel(canExpand: canExpand)
                    }
                    .buttonStyle(.plain)
                    .parityPointer()
                    .accessibilityHint(
                        workDetailsAreVisible
                            ? L10n.string("Hide work details")
                            : L10n.string("Show work details")
                    )
                } else {
                    headerLabel(canExpand: canExpand)
                }

                Spacer()
            }
            // No rule under the header: Claude Code's turns have none (2026-10-15).
        }
    }

    /// The header is drawn when it holds something: a work time or a fold.
    private var showsHeader: Bool {
        guard turn.showsHeader else { return false }
        return showsWorkTime || (foldsWork && turn.hasWorkDetails)
    }

    /// The header reads the turn's work time once the turn no longer runs: always for a provider's own
    /// times, and for times read from the entries when they span a second or more (D4). While the turn
    /// runs, every harness reads its time on the live line, beside what it does now, so the header
    /// adds no row of its own before the work folds.
    private var showsWorkTime: Bool {
        turn.status != .running && (!turn.timing.isApproximate || turn.timing.durationMilliseconds != nil)
    }

    @ViewBuilder
    private func headerLabel(canExpand: Bool) -> some View {
        if showsWorkTime {
            CodexWorkSummaryLabel(
                status: turn.status, timing: turn.timing, isExpanded: workDetailsAreVisible, canExpand: canExpand
            )
            .contentShape(Rectangle())
        } else if canExpand {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 11, weight: .medium))
                    .accessibilityHidden(true)
                Text(L10n.string("Work details"))
                    .conversationSelectionText(L10n.string("Work details"))
                DisclosureCaret(isOpen: workDetailsAreVisible)
                    .centeredOnCapHeight(ofTextSize: CodexWorkSummaryLabel.fontSize)
            }
            .font(.system(size: CodexWorkSummaryLabel.fontSize))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .contentShape(Rectangle())
        }
    }

    // MARK: - Cards

    /// A turn card for an error or a plan limit, the same for every harness (B7). The turn's own
    /// outcome offers what the turn can do about it; an earlier one the turn went on past only
    /// reports it.
    @ViewBuilder
    private func outcomeCard(_ outcome: ConversationTurnOutcome, isTurnOutcome: Bool = true) -> some View {
        switch outcome {
        case let .error(error):
            // A transcript error offers the harness's settings, as its row did; a Codex turn error
            // offers retry instead.
            TranscriptErrorCard(
                harness: context.harness, title: error.title, message: error.message,
                recoverable: error.isRecoverable,
                onRetry: isTurnOutcome ? handlers.retry : nil, onEditRequest: isTurnOutcome ? editFailedRequest : nil,
                onShowHarnessSettings: error.entryID == nil ? nil : context.actions.showHarnessSettings
            )
        case let .usageLimit(limit, entryID):
            // Only the transcript's last entry offers to continue, under another account or once
            // the limit resets (D7: a Codex limit names no reset and has no account to move to).
            UsageLimitCard(
                entryID: entryID, limit: limit, isLatest: entryID == context.lastEntryID,
                notices: context.actions.providerNotices
            )
        }
    }

    /// Every harness's plan is the Codex step card (M12c); text that is not steps is its one block.
    private func planCard(_ plan: ConversationPlan) -> some View {
        CodexPlanCard(plan: plan)
    }

    private var editFailedRequest: (() -> Void)? {
        guard turn.status.isTerminal, let draft = turn.actions.failedRequestDraft, let edit = handlers.edit
        else { return nil }
        return { edit(draft) }
    }

    private var workDetailsAreVisible: Bool {
        !foldsWork || showsWorkDetails
    }
}

/// A run of calls folded on its summary line (`ConversationWorkGroup`), drawn again only when one of
/// its lines changed. A running turn is drawn again with each streamed fragment, and its closures are
/// made afresh each time, so without this every run of the turn worked out its summary and compared
/// its calls again for a fragment that changed none of them. Where the run starts (`startsOpen`) is
/// read only when it first appears, and `onToggle` records the person's choice under a key its calls
/// make, so neither tells two runs apart.
private struct ConversationWorkRun: View, Equatable {
    let lines: [ConversationWorkLine]
    let harness: HarnessKind
    let startsOpen: Bool
    let onToggle: (Bool) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // Every nonempty run carries the harness in each line's offers.
        lhs.lines == rhs.lines
    }

    var body: some View {
        let byID = Dictionary(lines.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
        ConversationWorkGroup(items: lines.map(\.item), harness: harness, startsOpen: startsOpen, onToggle: onToggle) { item in
            if let line = byID[item.id] {
                line.equatable()
            }
        }
    }
}
