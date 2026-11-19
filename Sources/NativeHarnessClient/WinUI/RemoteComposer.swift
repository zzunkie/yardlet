import Foundation
import Observation
import UWP
import WinUI
import YardletRemote

/// The composer of a host's task, as the Mac's (`RemoteComposer`): the main window's card and chips
/// (`ComposerCard`, `ComposerOptionChips`, `ComposerAttachments`, `ComposerFollowUps`) with what the host takes from
/// another computer (docs/REMOTE_PROTOCOL.md §15.14, §15.15, §15.20, §15.23). Its bottom row draws the task's settings as
/// the host reads them (`RemoteHostModel.railComposerOptions`), each choice applied on the host, and the context ring
/// with the host's Compact; "+" and a paste add files and pictures, which go up to the host as it takes them
/// (`RemoteAttachments`). While a turn runs, Enter sends where the host's follow-up setting says, Ctrl+Enter the other
/// way, the queue-or-steer button chooses either, the host's queue stands above the text with the actions the host
/// offers for each message, and Stop stops the turn. A message being edited (Edit message, §15.23) goes as the host's
/// edit, and a typed slash command the host runs from elsewhere runs there. Each task's words are kept in the window's
/// drafts (`RemoteComposerDrafts`); while the host cannot be reached, sending waits and the words stay.
@MainActor
final class RemoteComposer {
    /// The card in its gutter.
    let view: FrameworkElement
    /// Above the card while a sent message is being edited.
    var editBanner: Grid { edit.view }

    private let model: RemoteHostModel
    private let drafts: RemoteComposerDrafts
    private let log: QAEventLog
    private let card: ComposerCard
    private let chips = ComposerOptionChips()
    private let attachments: ComposerAttachments
    private let sendButton = ComposerParts.sendButton(name: L10n.string("Send"))
    private let stopButton = ComposerParts.stopButton(name: L10n.string("Stop"))
    private let followUpButton = ComposerFollowUpButton()
    private let sending = ConversationStyle.spinner(size: 14)
    private lazy var edit = ComposerEditBanner { [weak self] in self?.cancelEdit() }
    private var taskID: String?
    private var shown: Shown?
    /// The text as it last went to the task's draft or came from it, which tells the person's typing from words the
    /// composer put in the draft.
    private var textInDraft: String?
    private var shownDraftNotice: String?
    /// What the host's composer last said about the task's last message or command (`RemoteComposerState.notice`).
    private var hostNotice: String?
    /// Ends the following of a task no longer shown.
    private var generation = 0
    /// The host's slash commands that may run from here, read when the task is shown.
    private var commands: [RemoteComposerCommand]?
    /// When the host's commands and composer state were last read: the task, the connection, its running and queue.
    private var readFor: (task: String, state: String)?
    /// A queued message being edited, with what the composer held before.
    private var queuedEdit: QueuedEdit?
    private var isSending = false {
        didSet { if isSending != oldValue { redrawControls() } }
    }
    private var autosave: Task<Void, Never>?

    /// The window "+"'s dialogs belong to, as an `HWND`'s value.
    var windowHandle: () -> UInt64 {
        get { attachments.windowHandle }
        set { attachments.windowHandle = newValue }
    }

    /// What the composer last drew, so a change redraws only its part.
    private struct Shown: Equatable {
        var taskID: String
        var harness: HarnessKind
        var harnessName: String
        var options: ComposerSessionOptions?
        var isConnected: Bool
        var isRunning: Bool
        var policy: FollowUpPolicy
        var preferred: FollowUpMode
        var queued: [RemoteItem]
        var isQueuePaused: Bool
        var extended: Bool
        var compact: Compact?
        var acceptsImages: Bool
        var acceptsFiles: Bool

        struct Compact: Equatable {
            var isAvailable: Bool
            var reason: String
        }

        /// Where Enter sends while a turn runs; a harness that cannot steer queues.
        var returnMode: FollowUpMode { policy.steers ? preferred : .queue }
        var acceptsAttachments: Bool { acceptsImages || acceptsFiles }
        var inputPolicy: HarnessComposerInputPolicy { HarnessComposerInputPolicy(harness: harness, negotiatedImageInput: acceptsImages) }
    }

    private struct QueuedEdit {
        let id: String
        let text: String
        let attachments: [CodexUserInput]
        let mentions: [WorkspaceFileMatch]
    }

    init(model: RemoteHostModel, drafts: RemoteComposerDrafts, log: QAEventLog) {
        self.model = model
        self.drafts = drafts
        self.log = log
        attachments = ComposerAttachments(log: log)
        let card = ComposerCard(metrics: .task)
        self.card = card
        view = card.placed()
        make()
    }

    private func make() {
        let field = card.field
        field.loaded.addHandler { [weak self] _, _ in self?.focus() }
        field.textChanged.addHandler { [weak self] _, _ in self?.textChanged() }
        field.paste.addHandler { [weak self] _, args in self?.attachments.paste(args) }
        card.attachments.child = attachments.chipRow
        attachments.offersFolders = false
        attachments.target = { [weak self] in
            guard let self, let taskID = self.taskID, let shown = self.shown, shown.taskID == taskID,
                  shown.acceptsAttachments else { return nil }
            return (self.drafts.draft(for: taskID), shown.inputPolicy)
        }
        ComposerKeys.prepare(field, send: { [weak self] in self?.enter() },
                             alternate: { [weak self] in self?.alternate() ?? false },
                             escape: { [weak self] in self?.escape() ?? false })
        sendButton.click.addHandler { [weak self] _, _ in self?.send(nil) }
        stopButton.click.addHandler { [weak self] _, _ in self?.stop() }
        try? ToolTipService.setToolTip(stopButton, "\(L10n.string("Stop")) (Esc)")
        stopButton.visibility = .collapsed
        sending.margin = Thickness(left: 4, top: 0, right: 4, bottom: 0)
        chips.redraw = { [weak self] in self?.redrawControls() }
        chips.choose = { [weak self] id, value, apply in self?.choose(id, value, apply) }
        chips.prepare = { [weak self] in await self?.prepare() }
    }

    // MARK: Following the task

    /// Shows `taskID`'s composer, or an empty one with no task.
    func show(_ taskID: String?) {
        guard taskID != self.taskID else { return }
        if queuedEdit != nil { cancelQueueEdit() }
        drafts.save()
        self.taskID = taskID
        shown = nil
        shownDraftNotice = nil
        hostNotice = nil
        commands = nil
        readFor = nil
        textInDraft = nil
        card.showNotice(nil)
        follow()
    }

    /// Gives the text the keyboard.
    func focus() {
        _ = try? card.field.focus(.programmatic)
    }

    private func follow() {
        generation += 1
        let current = generation
        guard let taskID else {
            card.field.placeholderText = L10n.string("Choose a task")
            edit.show(canCancel: nil)
            attachments.redraw([])
            redrawControls()
            redrawQueue()
            return
        }
        let draft = drafts.draft(for: taskID)
        let (state, text, notice, carried, editing, fromHost) = withObservationTracking {
            (read(taskID), draft.text, draft.notice, draft.attachments, drafts.edits[taskID],
             model.composerStates[taskID]?.notice)
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
        // What the host's composer says about the task's last message or command stands under the text, until the
        // host's goes or the composer's own replaces it.
        if fromHost != hostNotice {
            let previous = hostNotice
            hostNotice = fromHost
            if let fromHost { draft.notice = fromHost } else if draft.notice == previous { draft.notice = nil }
        }
        if notice != shownDraftNotice {
            shownDraftNotice = notice
            card.showNotice(notice)
            if let notice, !notice.isEmpty { log.write("remote notice: \(notice)") }
        }
        attachments.redraw(carried)
        edit.show(canCancel: editing == nil ? nil : true)
        let previous = shown
        shown = state
        if previous != state || previous == nil { redrawControls() }
        if previous?.queued != state.queued || previous?.isQueuePaused != state.isQueuePaused
            || previous?.extended != state.extended || previous?.policy != state.policy
            || previous?.isConnected != state.isConnected {
            redrawQueue()
        }
        readHostComposer(state)
        showSendable()
    }

    /// What the composer shows of the task, as the Mac's reads it from the host.
    private func read(_ taskID: String) -> Shown {
        let task = model.task(taskID)
        let harness = HarnessKind(rawValue: task?.harness ?? HarnessKind.claudeCode.rawValue)
        let state = model.composerStates[taskID]
        return Shown(
            taskID: taskID, harness: harness, harnessName: task?.harnessName ?? model.name,
            options: model.railComposerOptions(taskID), isConnected: model.isConnected, isRunning: task?.running == true,
            policy: model.followUpPolicy(taskID), preferred: model.preferredFollowUp,
            queued: model.conversations[taskID]?.queued ?? [], isQueuePaused: state?.queuePaused == true,
            extended: model.composerExtensions,
            compact: model.compactOffer(taskID).map { Shown.Compact(isAvailable: $0.isAvailable, reason: $0.unavailableReason) },
            acceptsImages: task?.acceptsImages == true, acceptsFiles: task?.acceptsFiles == true)
    }

    /// Reads the host's slash commands and its composer's state (the queue paused, a notice) when the task is shown or
    /// the connection comes back, and its state again as the turn starts or ends or the queue changes.
    private func readHostComposer(_ shown: Shown) {
        let task = "\(shown.taskID)|\(shown.isConnected)|\(model.taskControls)"
        let state = "\(shown.isRunning)|\(shown.queued.map(\.id).joined(separator: ","))"
        guard readFor?.task != task || readFor?.state != state else { return }
        let readsCommands = readFor?.task != task
        readFor = (task, state)
        let taskID = shown.taskID
        Task { [weak self] in
            guard let self else { return }
            if readsCommands, let read = await self.model.composerCommands(taskID), self.taskID == taskID {
                self.commands = read
            }
            _ = await self.model.readComposerState(taskID)
        }
    }

    // MARK: The bottom row

    private var placeholder: String {
        guard let shown else { return L10n.string("Choose a task") }
        guard shown.isConnected else { return L10n.format("Waiting for %@…", model.name) }
        if shown.isRunning { return shown.policy.runningPlaceholder(preferred: shown.preferred, keys: .return) }
        return L10n.format("Ask %@…", shown.harnessName)
    }

    private func redrawControls() {
        card.field.placeholderText = placeholder
        card.leading.children.clear()
        card.trailing.children.clear()
        guard let shown, let taskID else {
            attachments.show(policy: nil)
            card.fitTaskControls(modelLabel: nil)
            return
        }
        let options = shown.options
        if options?.mode == .planIndicator {
            chips.turnOffPlanMode = { [weak self] in self?.run("plan-mode") }
        } else {
            chips.turnOffPlanMode = nil
        }
        attachments.show(policy: shown.inputPolicy)
        attachments.plusButton.visibility = shown.acceptsAttachments ? .visible : .collapsed
        attachments.plusButton.isEnabled = shown.isConnected
        card.leading.children.append(attachments.plusButton)
        if let options {
            for control in chips.leading(options) {
                (control as? Control)?.isEnabled = shown.isConnected
                card.leading.children.append(control)
            }
            if let summary = ComposerContextSummary.make(usage: options.contextUsage,
                                                         reportsContextWindow: options.reportsContextWindow) {
                card.trailing.children.append(ComposerParts.contextRing(summary, compact: compact(shown, taskID: taskID)))
            }
            for control in chips.trailing(options) {
                (control as? Control)?.isEnabled = shown.isConnected
                card.trailing.children.append(control)
            }
        }
        if isSending { card.trailing.children.append(sending) }
        if shown.isRunning {
            var pause: (title: String, action: @MainActor () -> Void)?
            if shown.extended, !shown.queued.isEmpty {
                let resumes = shown.isQueuePaused
                pause = (resumes ? L10n.string("Resume") : L10n.string("Pause"),
                         { [weak self] in self?.act(resumes ? "resume" : "pause") })
            }
            followUpButton.button.flyout = ComposerFollowUps.menu(
                policy: shown.policy, returnMode: shown.returnMode, canSteer: true, pause: pause
            ) { [weak self] mode in self?.send(mode) }
            try? ToolTipService.setToolTip(followUpButton.button, "\(L10n.string("Queue or steer")) · "
                + shown.policy.runningPlaceholder(preferred: shown.preferred, keys: .return))
            followUpButton.button.visibility = .visible
            card.trailing.children.append(followUpButton.button)
        }
        followUpButton.show(count: shown.queued.count)
        stopButton.visibility = shown.isRunning ? .visible : .collapsed
        stopButton.isEnabled = shown.isConnected
        sendButton.visibility = shown.isRunning ? .collapsed : .visible
        card.trailing.children.append(stopButton)
        card.trailing.children.append(sendButton)
        card.fitTaskControls(modelLabel: options?.model == nil ? nil : chips.modelLabel)
        showSendable()
    }

    /// The context window's "Compact session", through the host's own compact command where it offers one.
    private func compact(_ shown: Shown, taskID: String)
        -> (title: String, isAvailable: Bool, reason: String, run: () -> Void)? {
        guard let offer = shown.compact else { return nil }
        return (L10n.string("Compact session"), offer.isAvailable, offer.reason, { [weak self] in
            self?.log.write("remote compact")
            self?.model.compact(taskID)
        })
    }

    private var hasMessage: Bool {
        guard let taskID else { return false }
        let draft = drafts.draft(for: taskID)
        return ComposerKeys.canSend(card.field.text) || !draft.attachments.isEmpty || !draft.hostMentions.isEmpty
    }

    private var canSend: Bool { shown?.isConnected == true && !isSending && hasMessage }

    /// Send is on while the draft holds something, the host is reached and nothing is on its way.
    private func showSendable() {
        ComposerParts.setEnabled(sendButton, canSend)
    }

    // MARK: The queue

    /// The host's queue, one row each above the text, with the actions the host offers for each (§15.15); above them
    /// that the queue paused, and while a queued message is edited, the way back.
    private func redrawQueue() {
        card.top.children.clear()
        guard let shown else {
            card.top.visibility = .collapsed
            return
        }
        if queuedEdit != nil { card.top.children.append(queueEditRow()) }
        if shown.isQueuePaused {
            card.top.children.append(ComposerFollowUps.pausedRow { [weak self] in self?.act("resume") })
        }
        for (index, item) in shown.queued.enumerated() {
            let row = RemoteQueuedRow(item, at: index, of: shown.queued.count, policy: shown.policy, extended: shown.extended)
            let itemID = item.id
            var actions = ComposerFollowUps.RowActions()
            actions.moveUp = { [weak self] in self?.act("moveUp", itemID: itemID) }
            actions.moveDown = { [weak self] in self?.act("moveDown", itemID: itemID) }
            if row.retries { actions.retry = { [weak self] in self?.act("retry", itemID: itemID) } }
            if row.sendsNow { actions.sendNow = { [weak self] in self?.queued(itemID, .sendNow) } }
            if row.stopsAndSends { actions.stopAndSend = { [weak self] in self?.queued(itemID, .stopAndSend) } }
            if row.edits { actions.edit = { [weak self] in self?.beginQueueEdit(itemID) } }
            if row.removes { actions.remove = { [weak self] in self?.queued(itemID, .remove) } }
            let element = ComposerFollowUps.queueRow(title: item.text ?? "", failed: row.failed, fromTask: false,
                                                     chip: row.chip, actions: actions)
            // Nothing in the queue acts while the host cannot be reached.
            element.isHitTestVisible = shown.isConnected
            element.opacity = shown.isConnected ? 1 : 0.5
            card.top.children.append(element)
        }
        card.top.visibility = card.top.children.size == 0 ? .collapsed : .visible
    }

    /// "Edit message" over the queue while a queued message is in the text, with Cancel.
    private func queueEditRow() -> UIElement {
        let row = Grid()
        for width in [GridLength(value: 1, gridUnitType: .star), GridLength(value: 0, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = width
            row.columnDefinitions.append(column)
        }
        let words = ComposerParts.label(L10n.string("Edit message"), size: 12, weight: 400)
        row.children.append(words)
        let cancel = ComposerParts.control(title: L10n.string("Cancel"))
        cancel.click.addHandler { [weak self] _, _ in self?.cancelQueueEdit() }
        try? Grid.setColumn(cancel, 1)
        row.children.append(cancel)
        row.margin = Thickness(left: 5, top: 0, right: 0, bottom: 0)
        return row
    }

    private func queued(_ itemID: String, _ action: RemoteQueuedAction) {
        guard let taskID else { return }
        log.write("remote queued \(action.rawValue)")
        model.send(.actOnQueued(taskID: taskID, itemID: itemID, action: action))
    }

    /// A composer action on the host (§15.15): moving, retrying or editing a queued message, pausing or resuming the
    /// queue; the host answers with its composer's state.
    private func act(_ action: String, itemID: String? = nil, value: String? = nil) {
        guard let taskID else { return }
        log.write("remote composer \(action)")
        Task { [model] in
            if let state = await model.actOnComposer(taskID, action: action, itemID: itemID, value: value) {
                model.composerStates[taskID] = state
            }
        }
    }

    /// A queued message goes into the text to edit, what the composer held waiting to come back.
    private func beginQueueEdit(_ itemID: String) {
        guard queuedEdit == nil, let taskID, let item = shown?.queued.first(where: { $0.id == itemID }) else { return }
        let draft = drafts.draft(for: taskID)
        queuedEdit = QueuedEdit(id: item.id, text: draft.text, attachments: draft.attachments, mentions: draft.hostMentions)
        draft.text = item.text ?? ""
        draft.attachments = []
        draft.hostMentions = []
        redrawQueue()
        focus()
    }

    private func cancelQueueEdit() {
        guard let edit = queuedEdit, let taskID else { return }
        let draft = drafts.draft(for: taskID)
        draft.text = edit.text
        draft.attachments = edit.attachments
        draft.hostMentions = edit.mentions
        queuedEdit = nil
        redrawQueue()
    }

    // MARK: Typing and sending

    /// What the person types goes to the task's draft, which the window keeps for each task and saves a moment after
    /// the typing stops, as the Mac's window does.
    private func textChanged() {
        let text = card.field.text
        if let taskID, text != textInDraft {
            textInDraft = text
            drafts.draft(for: taskID).text = text
            autosave?.cancel()
            autosave = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.drafts.save()
            }
        }
        showSendable()
    }

    /// Enter: while a turn runs, where the host's follow-up setting says.
    private func enter() {
        send(shown?.isRunning == true ? shown?.returnMode : nil)
    }

    /// Ctrl+Enter while the turn runs: the other way than Enter, where the harness can steer.
    private func alternate() -> Bool {
        guard let shown, shown.isRunning, shown.policy.steers else { return false }
        send(shown.preferred.other)
        return true
    }

    /// Escape stops the running turn, as the Mac's composer's does.
    private func escape() -> Bool {
        guard shown?.isRunning == true, shown?.isConnected == true else { return false }
        stop()
        return true
    }

    private func stop() {
        guard let taskID else { return }
        log.write("remote stop")
        model.send(.stopTurn(taskID: taskID))
    }

    /// Sends the draft as the Mac's composer does; while a turn runs, queued or steered as `mode` says. A queued
    /// message being edited goes as its edit, a sent message being edited as the host's edit, and a typed command the
    /// host runs from here runs there. What was sent leaves the draft once the host took it; what did not stays, with
    /// why.
    private func send(_ mode: FollowUpMode?) {
        guard let taskID, let shown else { return }
        let draft = drafts.draft(for: taskID)
        // The draft takes the text as shown, the syllable being composed included.
        if draft.text != card.field.text {
            draft.text = card.field.text
            textInDraft = draft.text
        }
        guard canSend else { return }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let queuedEdit {
            guard !text.isEmpty, draft.attachments.isEmpty else { return }
            let value = RemoteComposerMentionIndex.message(text, mentions: draft.hostMentions)
            log.write("remote queued edit: \(text)")
            isSending = true
            Task { [weak self, model] in
                let state = await model.actOnComposer(taskID, action: "edit", itemID: queuedEdit.id, value: value)
                self?.isSending = false
                guard let state else {
                    draft.notice = model.commandError
                    return
                }
                model.composerStates[taskID] = state
                if self?.queuedEdit?.id == queuedEdit.id { self?.cancelQueueEdit() }
            }
            return
        }
        if let editing = drafts.edits[taskID] { return sendEdit(editing, text: text, taskID: taskID) }
        if draft.attachments.isEmpty, draft.hostMentions.isEmpty, let command = typedCommand(text) {
            log.write("remote command: \(command.name)")
            isSending = true
            Task { [weak self, model] in
                let ran = await model.runComposerCommand(taskID, name: command.name, arguments: command.arguments)
                self?.isSending = false
                guard ran else {
                    draft.notice = model.commandError
                    return
                }
                if draft.text.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft.text = "" }
                draft.notice = nil
            }
            return
        }
        let attachments = draft.attachments
        let hostMentions = draft.hostMentions
        let message = RemoteComposerMentionIndex.message(text, mentions: hostMentions)
        let followUp = mode.flatMap { RemoteFollowUpMode(rawValue: $0.rawValue) }
        let acceptsImages = shown.acceptsImages, acceptsFiles = shown.acceptsFiles
        log.write("remote sent" + (followUp.map { " (\($0.rawValue))" } ?? "") + ": \(text)")
        isSending = true
        Task { [weak self, model] in
            guard let parts = await RemoteAttachments.prepare(attachments, for: model, acceptsImages: acceptsImages,
                                                              acceptsFiles: acceptsFiles) else {
                self?.isSending = false
                return
            }
            let sent = await model.perform(.sendMessage(taskID: taskID, text: message, images: parts.images,
                                                        followUp: followUp, files: parts.files))
            self?.isSending = false
            guard sent else {
                draft.notice = model.commandError
                return
            }
            // What was sent leaves the draft; anything typed meanwhile stays.
            if draft.text.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft.text = "" }
            draft.attachments.removeAll { attachments.contains($0) }
            draft.hostMentions.removeAll { hostMentions.contains($0) }
            draft.notice = nil
            RemoteAttachments.discard(attachments)
        }
    }

    /// The edited message, as the host's composer sends an edit; it leaves the draft once the host took it.
    private func sendEdit(_ edit: RemoteMessageEdit, text: String, taskID: String) {
        let draft = drafts.draft(for: taskID)
        let mentions = draft.hostMentions
        let message = RemoteComposerMentionIndex.message(text, mentions: mentions)
        guard !message.isEmpty else { return }
        log.write("remote edited: \(text)")
        isSending = true
        Task { [weak self, model, drafts] in
            let taken = await model.editMessage(taskID, turnID: edit.turnID, text: message)
            self?.isSending = false
            guard taken else {
                draft.notice = model.commandError
                return
            }
            if drafts.edits[taskID] == edit { drafts.edits[taskID] = nil }
            draft.hostMentions.removeAll { mentions.contains($0) }
            if draft.text.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft.text = "" }
            draft.notice = nil
        }
    }

    /// Cancel edit: the composer gets back what it held before the edit.
    private func cancelEdit() {
        guard let taskID, let editing = drafts.edits[taskID] else { return }
        log.write("remote cancel edit")
        let draft = drafts.draft(for: taskID)
        draft.text = editing.previousText
        draft.attachments = editing.previousAttachments
        drafts.edits[taskID] = nil
    }

    /// The draft's first word names one of the host's commands: its name and the words after it.
    private func typedCommand(_ text: String) -> (name: String, arguments: String?)? {
        guard text.hasPrefix("/"), let commands else { return nil }
        let first = text.prefix { !$0.isWhitespace }
        let name = String(first.dropFirst())
        guard commands.contains(where: { $0.name == name }) else { return nil }
        let rest = text.dropFirst(first.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name, rest.isEmpty ? nil : rest)
    }

    /// Runs one of the host's commands for the task, such as turning Codex's Plan mode off.
    private func run(_ name: String) {
        guard let taskID else { return }
        log.write("remote command: \(name)")
        isSending = true
        Task { [weak self, model] in
            _ = await model.runComposerCommand(taskID, name: name, arguments: nil)
            self?.isSending = false
        }
    }

    // MARK: Session controls (§15.23)

    /// A menu's choice, applied on the host; one the host's menu asks about first was asked about here too
    /// (`ComposerOptionChips`).
    private func choose(_ id: String, _ value: String, _ apply: ComposerApplyPath) {
        guard let taskID, let choice = apply.choice(id: id, value: value) else { return }
        log.write("remote composer \(id): \(value)")
        model.chooseTaskSetting(taskID, choice)
    }

    /// Reads a control's choices from the host, as opening the host's menu does.
    private func prepare() async {
        guard let taskID else { return }
        await model.readTaskSettings(taskID, prepare: true)
    }
}
