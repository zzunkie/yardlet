import Foundation
import Observation
import UWP
import WinUI

/// The shown task's composer, as the Mac's (`PromptComposer`): the card at most as wide as the conversation, its text
/// above and a bottom row with the task's session controls (`ComposerOptionChips`), the context ring, and Send, which
/// Stop replaces while the turn runs. While it runs, what Enter sends follows the follow-up setting, steered into the
/// turn or queued for after it (Codex steers, Claude Code takes it at its next step), Ctrl+Enter sends the other way,
/// and the queue-or-steer button beside Stop chooses either; the queued messages stand above the text, each with its
/// actions (`ComposerQueueChip`). "+" and a paste add files and pictures, which stand as chips above the text
/// (`ComposerAttachments`). Everything it shows is the Mac's reading of the task
/// (`ComposerSessionOptionsProjection`), and it sends through the model's draft (`AppModel.sendDraft`), which takes the
/// message as the Mac's composer takes it (`TaskComposerDraft.takeMessage`).
///
/// It follows the task through Observation and redraws only what changed: a conversation streams many events, and the
/// controls are made again only when the options they show change.
@MainActor
final class TaskComposer {
    /// Above the card: that the task's folder is gone, as the Mac's banner says it.
    let noticeView = TextBlock()
    /// Above the card while a sent message is being edited (`ComposerEditBanner`).
    var editBanner: Grid { edit.view }
    private lazy var edit = ComposerEditBanner { [weak self] in self?.cancelEdit() }
    /// The card in its gutter.
    let view: FrameworkElement

    private let model: AppModel
    private let log: QAEventLog
    private let card: ComposerCard
    private let chips = ComposerOptionChips()
    private let attachments: ComposerAttachments
    private let sendButton: Button
    private let stopButton: Button
    private let followUpButton = ComposerFollowUpButton()
    private var sessionID: SessionRecord.ID?
    private let answersInHome: Bool
    /// The text as it last went to the task's draft or came from it, which tells the person's typing from a message
    /// the model put back in the draft.
    private var textInDraft: String?
    /// Ends the following of a task no longer shown.
    private var generation = 0
    private var shown: Shown?
    private var shownDraftNotice: String?

    /// While New task answers the task in its composer's place (`NewTaskHomeReplyPane`): each message sent tells it,
    /// and Escape goes back to New task's composer rather than stopping the turn, as the Mac's reply composer does.
    var onSent: (() -> Void)?
    var onEscape: (() -> Void)?

    /// The window "+"'s dialogs belong to, as an `HWND`'s value.
    var windowHandle: () -> UInt64 {
        get { attachments.windowHandle }
        set { attachments.windowHandle = newValue }
    }

    /// What the composer last drew, so a change redraws only its part.
    private struct Shown: Equatable {
        var id: SessionRecord.ID
        var options: ComposerSessionOptions
        var isRunning: Bool
        var canSteer: Bool
        var isAttached: Bool
        var isHeld: Bool
        var queue: [QueuedFollowUp]
        var isQueuePaused: Bool
        var missingFolder: String?
    }

    /// `answersInHome`: the composer of a task New task answers in its composer's place, which takes the keyboard when
    /// it is shown there and does not stand for the window being ready.
    init(model: AppModel, log: QAEventLog, answersInHome: Bool = false) {
        self.model = model
        self.log = log
        self.answersInHome = answersInHome
        sendButton = ComposerParts.sendButton(name: L10n.string("Send"))
        stopButton = ComposerParts.stopButton(name: L10n.string("Stop"))
        try? ToolTipService.setToolTip(stopButton, "\(L10n.string("Stop")) (Esc)")
        let card = ComposerCard(metrics: .task)
        self.card = card
        attachments = ComposerAttachments(log: log)
        view = card.placed()
        make()
    }

    private func make() {
        noticeView.textWrapping = .wrap
        noticeView.isTextSelectionEnabled = true
        noticeView.foreground = WindowsTheme.secondaryText.brush
        noticeView.fontSize = 12
        noticeView.maxWidth = WindowsTheme.contentWidth
        noticeView.horizontalAlignment = .stretch
        noticeView.margin = Thickness(left: 39, top: 8, right: 39, bottom: 0)
        noticeView.visibility = .collapsed

        let field = card.field
        field.loaded.addHandler { [weak self] _, _ in
            guard let self, !self.answersInHome else { return }
            _ = try? field.focus(.programmatic)
            self.log.write("ready")
        }
        field.textCompositionStarted.addHandler { [weak self] _, _ in self?.log.write("composition started") }
        field.textCompositionChanged.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.log.write("composition changed: \(field.text)")
        }
        field.textCompositionEnded.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.log.write("composition ended: \(field.text)")
        }
        field.textChanged.addHandler { [weak self] _, _ in self?.textChanged() }
        field.paste.addHandler { [weak self] _, args in self?.attachments.paste(args) }
        card.attachments.child = attachments.chipRow
        attachments.target = { [weak self] in
            guard let self, let id = self.sessionID, let shown = self.shown, shown.id == id else { return nil }
            return (self.model.composerDrafts.tasks.draft(for: id), shown.options.input)
        }
        // Enter sends what the field shows, the syllable being composed included, and Shift+Enter starts a new line.
        ComposerKeys.prepare(field, send: { [weak self] in self?.enter() },
                             alternate: { [weak self] in self?.alternate() ?? false },
                             escape: { [weak self] in self?.escape() ?? false })

        sendButton.click.addHandler { [weak self] _, _ in self?.submit(.automatic) }
        stopButton.click.addHandler { [weak self] _, _ in self?.stop() }
        stopButton.visibility = .collapsed

        chips.redraw = { [weak self] in self?.redrawControls() }
        chips.choose = { [weak self] id, value, apply in self?.choose(id, value, apply) }
        chips.prepareModels = { [weak self] hasChoices in
            guard let self, let session = self.session else { return }
            await self.model.prepareModelPicker(for: session, hasChoices: hasChoices)
        }
        chips.prepare = { [weak self] in await self?.prepare() }
    }

    // MARK: Following the task

    /// Gives the text the keyboard.
    func focus() {
        _ = try? card.field.focus(.programmatic)
    }

    /// Shows `id`'s composer, or an empty one with no task.
    func show(_ id: SessionRecord.ID?) {
        guard id != sessionID else { return }
        sessionID = id
        shown = nil
        shownDraftNotice = nil
        card.showNotice(nil)
        textInDraft = nil
        follow()
        refreshFolder()
    }

    /// Looks at the task's folder again, which the line above the card names when it is gone: when the task is shown
    /// and when the window comes to the front, as on the Mac.
    /// Opens the task's model menu, as the Mac's Control+Shift+M does in its composer.
    func openModelMenu() {
        chips.openModelMenu()
    }

    func refreshFolder() {
        guard let sessionID else { return }
        Task { await model.refreshTaskFolder(sessionID) }
    }

    private var session: SessionRecord? {
        sessionID.flatMap { id in model.store.sessions.first { $0.id == id } }
    }

    private func follow() {
        generation += 1
        let current = generation
        guard let id = sessionID else {
            card.field.placeholderText = L10n.string("Choose a task")
            card.showNotice(nil)
            showEdit(nil)
            attachments.redraw([])
            showNotice("")
            ComposerParts.setEnabled(sendButton, false)
            return
        }
        let draft = model.composerDrafts.tasks.draft(for: id)
        let (state, text, notice, carried, edit) = withObservationTracking {
            (read(id), draft.text, draft.notice, draft.attachments, draft.editState)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.follow()
            }
        }
        if text != textInDraft {
            textInDraft = text
            if card.field.text != text { card.field.text = text }
        }
        if notice != shownDraftNotice {
            shownDraftNotice = notice
            card.showNotice(notice)
            if let notice, !notice.isEmpty { log.write("notice: \(notice)") }
        }
        attachments.redraw(carried)
        showEdit(edit)
        guard let state else { return }
        let previous = shown
        shown = state
        let queueChanged = previous?.queue != state.queue
        if queueChanged { followUpButton.show(count: personQueue.count) }
        if previous?.options != state.options || previous?.isRunning != state.isRunning
            || previous?.canSteer != state.canSteer || previous?.isAttached != state.isAttached
            || previous?.queue.isEmpty != state.queue.isEmpty {
            redrawControls()
        } else if queueChanged {
            card.fitTaskControls(modelLabel: chips.modelLabel)
        }
        if queueChanged || previous?.isQueuePaused != state.isQueuePaused
            || previous?.options.followUp != state.options.followUp {
            redrawQueue()
        }
        showNotice(state.missingFolder ?? "")
        showSendable()
    }

    /// What the composer shows of the task, read where the Mac's task surface reads it.
    private func read(_ id: SessionRecord.ID) -> Shown? {
        guard let session = model.store.sessions.first(where: { $0.id == id }) else { return nil }
        let isRunning = session.status == .running || session.status == .waitingForApproval
        let isAttached = model.isAttached(id)
        let codexState = session.harness == .codex ? model.codexPresentationBySessionID[id] : nil
        let codexUsage = codexState?.thread?.turns.last(where: { $0.tokenUsage != nil })?.tokenUsage
            ?? model.restoredCodexTokenUsageBySessionID[id]
        // The requests that wait name the permission control; they are read only while one may wait, since the
        // transcript changes with every event a turn streams.
        let entries = session.status == .waitingForApproval ? model.transcriptBySessionID[id] ?? [] : []
        let options = ComposerSessionOptionsProjection.make(
            harness: session.harness, session: session, codexCapabilities: model.composerCodexCapabilities(for: session),
            providerCapabilities: model.composerProviderCapabilities(for: session),
            providerUsage: model.providerUsageBySessionID[id], codexTokenUsage: codexUsage, entries: entries,
            isAttached: isAttached)
        let canSteer = session.harness == .codex ? codexState?.activeTurnID != nil
            : session.harness == .claudeCode && isAttached
        return Shown(id: id, options: options, isRunning: isRunning, canSteer: canSteer, isAttached: isAttached,
                     isHeld: model.isHeld(session, by: TaskBlocker.holdingOffActions),
                     queue: model.followUps.queue(for: id), isQueuePaused: model.followUps.isPaused(id),
                     missingFolder: model.missingTaskFolders[id]?.localizedDescription)
    }

    /// The banner of a message being edited: Cancel edit while the provider has not taken the edit yet.
    private func showEdit(_ editing: ConversationEditState?) {
        edit.show(canCancel: editing.map { $0.preparedProviderSessionID == nil })
    }

    /// Cancel edit: the composer gets back what it held before the edit (`AppModel.cancelConversationEdit`).
    private func cancelEdit() {
        guard let session else { return }
        log.write("cancel edit")
        model.cancelConversationEdit(in: session)
    }

    private func showNotice(_ text: String) {
        guard noticeView.text != text else { return }
        noticeView.text = text
        noticeView.visibility = text.isEmpty ? .collapsed : .visible
        if !text.isEmpty { log.write("notice: \(text)") }
    }

    // MARK: The bottom row

    /// The follow-up a message typed now takes: while the turn runs, where the harness keeps a queue.
    private var runningFollowUp: ComposerFollowUpOptions? {
        guard let shown, shown.isRunning else { return nil }
        return shown.options.followUp
    }

    private func redrawControls() {
        guard let shown, let session else {
            card.leading.children.clear()
            card.trailing.children.clear()
            attachments.show(policy: nil)
            card.fitTaskControls(modelLabel: nil)
            return
        }
        let options = shown.options
        card.field.placeholderText = runningFollowUp?.runningPlaceholder(preferred: model.followUpMode, keys: .return)
            ?? options.placeholder
        chips.turnOffPlanMode = session.harness == .codex ? { [weak self] in self?.runCodexCommand(.planMode) } : nil
        card.leading.children.clear()
        attachments.show(policy: options.input)
        card.leading.children.append(attachments.plusButton)
        for control in chips.leading(options) { card.leading.children.append(control) }

        card.trailing.children.clear()
        if let summary = ComposerContextSummary.make(usage: options.contextUsage,
                                                     reportsContextWindow: options.reportsContextWindow) {
            card.trailing.children.append(ComposerParts.contextRing(summary, compact: compact(options, shown)))
        }
        for control in chips.trailing(options) { card.trailing.children.append(control) }
        if let running = runningFollowUp {
            followUpButton.button.flyout = ComposerFollowUps.menu(
                policy: running.policy, returnMode: running.policy.steers ? model.followUpMode : .queue,
                canSteer: shown.canSteer) { [weak self] mode in self?.submit(mode.action) }
            try? ToolTipService.setToolTip(followUpButton.button, "\(L10n.string("Queue or steer")) · "
                + running.runningPlaceholder(preferred: model.followUpMode, keys: .return))
            followUpButton.button.visibility = .visible
            card.trailing.children.append(followUpButton.button)
        }
        stopButton.visibility = shown.isRunning ? .visible : .collapsed
        sendButton.visibility = shown.isRunning ? .collapsed : .visible
        card.trailing.children.append(stopButton)
        card.trailing.children.append(sendButton)
        card.fitTaskControls(modelLabel: chips.modelLabel)
    }

    /// The context window's "Compact session": Claude Code's `/compact` as the next message, or Codex's Compact,
    /// once the turn has finished, as the Mac's ring offers it.
    private func compact(_ options: ComposerSessionOptions, _ shown: Shown)
        -> (title: String, isAvailable: Bool, reason: String, run: () -> Void)? {
        guard let path = options.compact else { return nil }
        let reason = shown.isRunning ? L10n.format("Available when %@ finishes this turn", options.harnessName)
            : L10n.string("Available when reconnected")
        return (L10n.string("Compact session"), !shown.isRunning && shown.isAttached, reason, { [weak self] in
            guard let self, let session = self.session else { return }
            switch path {
            case let .providerCommand(command):
                Task { await self.model.sendPersonsMessage(HarnessUserInput(text: command), to: session) }
            case .codexCommand:
                self.runCodexCommand(.compact)
            }
        })
    }

    /// Send is on while the draft holds something and the task's conversation or account is not changing.
    private func showSendable() {
        let held = shown?.isHeld ?? true
        let carries = sessionID.map { !model.composerDrafts.tasks.draft(for: $0).attachments.isEmpty } ?? false
        ComposerParts.setEnabled(sendButton, sessionID != nil && !held
            && (ComposerKeys.canSend(card.field.text) || carries))
    }

    // MARK: The queue

    /// The queue's messages the person wrote; one another task sent waits only until the harness reads it,
    /// unless it could not be sent.
    private var personQueue: [QueuedFollowUp] {
        (shown?.queue ?? []).filter(\.isListedInComposer)
    }

    /// The queued messages, one row each above the text as the Codex and Claude apps list them, and above them that
    /// the queue paused when the person stopped the turn.
    private func redrawQueue() {
        card.top.children.clear()
        guard let shown, let followUp = shown.options.followUp else {
            card.top.visibility = .collapsed
            return
        }
        var rows = 0
        if shown.isQueuePaused, !shown.queue.isEmpty {
            card.top.children.append(ComposerFollowUps.pausedRow { [weak self] in
                guard let self, let session = self.session else { return }
                self.model.resumeQueue(for: session)
            })
            rows += 1
        }
        for (index, item) in shown.queue.enumerated() where item.isListedInComposer {
            let chip = ComposerQueueChip.make(policy: followUp.policy, queue: shown.queue, at: index, canSend: true)
            card.top.children.append(queueRow(item, chip: chip, at: index))
            rows += 1
        }
        card.top.visibility = rows == 0 ? .collapsed : .visible
    }

    /// One queued message's row (`ComposerFollowUps.queueRow`), its actions through the model's queue.
    private func queueRow(_ item: QueuedFollowUp, chip: ComposerQueueChip, at index: Int) -> UIElement {
        let id = item.id
        var actions = ComposerFollowUps.RowActions()
        actions.moveUp = { [weak self] in self?.move(id, to: index - 1) }
        actions.moveDown = { [weak self] in self?.move(id, to: index + 1) }
        actions.retry = { [weak self] in self?.queued(id, .retry) }
        actions.sendNow = { [weak self] in self?.queued(id, .sendNow) }
        actions.stopAndSend = { [weak self] in self?.queued(id, .stopAndSend) }
        actions.edit = { [weak self] in self?.queued(id, .edit) }
        actions.remove = { [weak self] in self?.queued(id, .remove) }
        return ComposerFollowUps.queueRow(title: ComposerQueueChip.title(of: item.draft), failed: item.state == .failed,
                                          fromTask: TaskMessage.parse(item.draft.text) != nil, chip: chip,
                                          actions: actions)
    }

    private enum QueuedAction { case sendNow, stopAndSend, retry, edit, remove }

    /// A queued message's action, through the model's queue as the Mac's row takes it.
    private func queued(_ id: UUID, _ action: QueuedAction) {
        guard let session else { return }
        switch action {
        case .sendNow: Task { await model.sendQueuedNow(id, for: session) }
        case .stopAndSend: Task { await model.stopAndSendQueued(id, for: session) }
        case .retry: model.retryQueued(id, for: session)
        case .edit: _ = model.editQueued(id, for: session)
        case .remove: Task { await model.removeQueued(id, for: session) }
        }
    }

    private func move(_ id: UUID, to index: Int) {
        guard let session else { return }
        model.moveQueued(id, in: session, to: index)
    }

    // MARK: Typing and sending

    /// What the person types goes to the task's draft, which keeps it while another task is shown and across
    /// launches, as the Mac's composer does.
    private func textChanged() {
        let text = card.field.text
        if let sessionID, text != textInDraft {
            textInDraft = text
            model.composerDrafts.tasks.draft(for: sessionID).text = text
        }
        showSendable()
    }

    /// Enter: in the empty composer while a tool approval waits, allows it once, as the Mac's send key does; otherwise
    /// sends as the follow-up setting says.
    private func enter() {
        if answersWaitingApproval(allowing: true) { return }
        submit(.automatic)
    }

    /// Ctrl+Enter while the turn runs: the other way than Enter, where the harness can steer.
    private func alternate() -> Bool {
        guard let action = runningFollowUp?.alternateAction(preferred: model.followUpMode,
                                                             canSteer: shown?.canSteer ?? false) else { return false }
        submit(action)
        return true
    }

    /// Escape while the turn runs: a waiting tool approval is denied first, as the Codex app's Escape denies one;
    /// otherwise the turn stops.
    private func escape() -> Bool {
        if let onEscape {
            onEscape()
            return true
        }
        guard shown?.isRunning == true else { return false }
        if answersWaitingApproval(allowing: false) { return true }
        stop()
        return true
    }

    private func answersWaitingApproval(allowing: Bool) -> Bool {
        guard let sessionID, shown?.isRunning == true, card.field.text.isEmpty else { return false }
        return model.answerOldestApproval(in: sessionID, allowing: allowing)
    }

    /// Sends the draft through the model, which takes the message as the Mac's composer does and puts back, with
    /// why, a message the task does not take, such as one for a task whose folder is gone (`AppModel.sendDraft`).
    private func submit(_ action: CodexComposerAction) {
        let text = card.field.text
        guard let session else {
            if ComposerKeys.canSend(text) { log.write("sent: \(text)") }
            card.field.text = ""
            return
        }
        // The Mac's composer is off while a change of the task's conversation or account is under way; what was
        // written waits.
        guard !model.isHeld(session, by: TaskBlocker.holdingOffActions) else { return }
        // The draft takes the text as shown, the syllable being composed included, which TextChanged may not have
        // brought yet.
        let draft = model.composerDrafts.tasks.draft(for: session.id)
        draft.text = text
        guard let sending = model.sendDraft(of: session, action: action) else { return }
        onSent?()
        let noticeAsSent = draft.notice
        textInDraft = draft.text
        if card.field.text != draft.text { card.field.text = draft.text }
        // The log says what became of the message once the model has it: a message the task did not take is back
        // in the draft with why.
        let sent = (action == .automatic ? "sent" : "sent (\(action.rawValue))") + ": "
            + text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { [log] in
            await sending.value
            if let notice = draft.notice, notice != noticeAsSent {
                log.write("not \(sent): \(notice)")
            } else {
                log.write(sent)
            }
        }
    }

    /// The harness's own cancel stops the turn (`AppModel.interrupt`), as the Mac's Stop does.
    private func stop() {
        guard let session, session.status == .running || session.status == .waitingForApproval else { return }
        log.write("stop: \(session.title)")
        Task { await model.interrupt(session) }
    }

    // MARK: Session controls

    private func choose(_ id: String, _ value: String, _ apply: ComposerApplyPath) {
        guard let session, let choice = apply.choice(id: id, value: value) else { return }
        log.write("composer \(id): \(value)")
        Task {
            switch choice {
            case let .codexModel(selection): await model.selectCodexModel(selection, for: session)
            case let .codexRunLocation(location): await model.selectCodexRunLocation(location, for: session)
            case let .providerOption(id, value): await model.setProviderOption(id, value: value, for: session)
            }
        }
    }

    /// Reads a control's choices: a detached task's saved settings, or Codex's model list. No turn starts.
    private func prepare() async {
        guard let session else { return }
        switch ComposerSessionOptionsProjection.wiring(for: session.harness).settings {
        case .codexModels: await model.loadCodexModels(for: session)
        case .providerCapabilities: await model.loadProviderCapabilities(for: session)
        }
    }

    private func runCodexCommand(_ command: CodexComposerCommand) {
        guard let session else { return }
        Task { await model.runCodexComposerCommand(command, in: session) }
    }
}
