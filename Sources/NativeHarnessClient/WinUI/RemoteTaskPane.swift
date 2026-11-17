import Foundation
import Observation
import UWP
@preconcurrency import WindowsFoundation
import WinUI
import YardletRemote

/// A host's task as the Mac's host window shows it (`RemoteTaskView`): its conversation through the main window's
/// timeline (`ConversationTimeline`), with every request card answered on the host as the Mac's card answers it
/// (`RemoteHostModel.respond`), an answer that leaves a rule behind on the host asked about first; Retry while the task
/// is idle, Edit message under its latest message where the host offers it (docs/REMOTE_PROTOCOL.md §15.23), and the
/// latest limit card's actions through the host (§15.17). Under it the host's notices for the task (its last error and a
/// missing folder), a message being edited, what the host refused last, and the composer (`RemoteComposer`). The
/// conversation follows the host through Observation; the timeline redraws only the turns that changed.
@MainActor
final class RemoteTaskPane {
    let view = Grid()
    private let model: RemoteHostModel
    private let drafts: RemoteComposerDrafts
    private let log: QAEventLog
    private let timeline = ConversationTimeline()
    private let composer: RemoteComposer
    /// The host's notices for the task, over the composer: its last error's card and that its folder is gone.
    private let notices = StackPanel()
    /// What the host refused last, in orange over the composer.
    private let refusal = TextBlock()
    private var taskID: String?
    private var generation = 0
    private var shownNotices: RemoteTaskNotices??
    private var offersRetry: Bool?
    private var offersEdit: Bool?
    private var loggedAnswer: String?

    /// What the pane reads of the host for the task shown.
    private struct Shown {
        let conversation: RemoteConversationModel
        let presentation: ConversationPresentation
        let task: RemoteTask?
        let error: String?
        let retries: Bool
        let edits: Bool
        let limit: TaskProviderNotices?
    }

    init(model: RemoteHostModel, drafts: RemoteComposerDrafts, log: QAEventLog) {
        self.model = model
        self.drafts = drafts
        self.log = log
        composer = RemoteComposer(model: model, drafts: drafts, log: log)
        make()
    }

    /// The window "+"'s dialogs belong to, as an `HWND`'s value.
    var windowHandle: () -> UInt64 {
        get { composer.windowHandle }
        set { composer.windowHandle = newValue }
    }

    private func make() {
        for height in [GridLength(value: 1, gridUnitType: .star), GridLength(value: 0, gridUnitType: .auto),
                       GridLength(value: 0, gridUnitType: .auto)] {
            let row = RowDefinition()
            row.height = height
            view.rowDefinitions.append(row)
        }
        view.children.append(timeline.view)
        // Over the composer, in its column: the host's notices, a message being edited, and what the host refused.
        let above = StackPanel()
        notices.spacing = 8
        notices.maxWidth = WindowsTheme.contentWidth
        notices.margin = Thickness(left: 24, top: 0, right: 24, bottom: 0)
        notices.visibility = .collapsed
        above.children.append(notices)
        above.children.append(composer.editBanner)
        refusal.textWrapping = .wrap
        refusal.isTextSelectionEnabled = true
        refusal.fontSize = 12
        refusal.foreground = ComposerParts.orange.brush
        refusal.maxWidth = WindowsTheme.contentWidth
        refusal.margin = Thickness(left: 24, top: 8, right: 24, bottom: 0)
        refusal.visibility = .collapsed
        above.children.append(refusal)
        try? Grid.setRow(above, 1)
        view.children.append(above)
        try? Grid.setRow(composer.view, 2)
        view.children.append(composer.view)

        timeline.respond = { [weak self] request, response in self?.answer(request, response) }
        timeline.confirmAnswer = { [weak self] _, response in await self?.confirm(response) ?? false }
        timeline.loadEarlier = { [weak self] in
            guard let self, let taskID = self.taskID else { return }
            self.model.loadOlder(taskID)
        }
    }

    /// Shows the host's task `taskID`, or nothing.
    func show(_ taskID: String?) {
        guard taskID != self.taskID else { return }
        self.taskID = taskID
        shownNotices = nil
        composer.show(taskID)
        follow()
    }

    private func follow() {
        generation += 1
        let current = generation
        guard let taskID else {
            timeline.show(nil, conversationID: nil)
            return
        }
        let shown = withObservationTracking {
            model.conversations[taskID].map { conversation in
                Shown(conversation: conversation, presentation: conversation.presentation, task: model.task(taskID),
                      error: model.commandError,
                      retries: model.offersRetry(in: conversation, isEditing: drafts.edits[taskID] != nil),
                      edits: model.taskControls, limit: model.limitNotices(for: conversation))
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.follow()
            }
        }
        guard let shown else {
            timeline.show(nil, conversationID: taskID)
            return
        }
        let conversation = shown.conversation, presentation = shown.presentation, task = shown.task
        let error = shown.error
        // What the task can do about its turns, given to the timeline only when it changes: it draws the shown turns
        // again then.
        if shown.retries != offersRetry {
            offersRetry = shown.retries
            if shown.retries {
                timeline.retry = { [weak self] turnID in self?.retry(turnID) }
            } else {
                timeline.retry = nil
            }
        }
        if shown.edits != offersEdit {
            offersEdit = shown.edits
            if shown.edits {
                timeline.editMessage = { [weak self] turn in self?.beginEdit(turn) }
            } else {
                timeline.editMessage = nil
            }
        }
        timeline.notices = shown.limit
        timeline.show(presentation.withoutShowTab(), conversationID: taskID,
                      placeholder: conversation.isLoaded ? nil : L10n.string("Loading…"))
        showNotices(task?.notices, harness: conversation.harness)
        refusal.text = error ?? ""
        refusal.visibility = (error ?? "").isEmpty ? .collapsed : .visible
        logAnswer(presentation, title: task?.title)
    }

    /// The task shown and the words its latest turn streamed, for the event log the CI checks read.
    private func logAnswer(_ presentation: ConversationPresentation, title: String?) {
        let answer = presentation.turns.last?.answers.last.flatMap { item -> String? in
            guard case let .answer(text, isStreaming) = item.kind else { return nil }
            return "remote answer\(isStreaming ? " streaming" : ""): \(text.prefix(80))"
        }
        let line = "\(title ?? "")\n\(answer ?? "")"
        guard line != loggedAnswer else { return }
        if loggedAnswer?.hasPrefix("\(title ?? "")\n") != true, let title { log.write("remote showing: \(title)") }
        loggedAnswer = line
        if let answer { log.write(answer) }
    }

    /// The host's notices over the composer, as the Mac's lines draw them: the task's last error as its error card, and
    /// that its folder is gone, as this computer's own task says it.
    private func showNotices(_ shown: RemoteTaskNotices?, harness: HarnessKind) {
        guard shownNotices != .some(shown) else { return }
        shownNotices = .some(shown)
        notices.children.clear()
        if let error = shown?.error, !error.isEmpty {
            notices.children.append(ConversationMessages.errorCard(
                ConversationTurnError(title: nil, message: error, isRecoverable: true), harness: harness, retry: nil,
                signIn: nil))
        }
        if let path = shown?.missingFolder {
            let words = ConversationStyle.text(TaskFolderMissing(path: path, worktreeBranch: shown?.worktreeBranch)
                .localizedDescription, size: ConversationStyle.captionSize, tone: .secondary)
            words.margin = Thickness(left: 15, top: 0, right: 15, bottom: 0)
            notices.children.append(words)
        }
        notices.visibility = notices.children.size == 0 ? .collapsed : .visible
        notices.margin = Thickness(left: 24, top: notices.children.size == 0 ? 0 : 8, right: 24, bottom: 0)
    }

    // MARK: Turn actions

    /// A request card's answer, carried out on the host as the Mac's card carries it out.
    private func answer(_ request: ConversationRequest, _ response: ConversationRequestResponse) {
        guard let taskID else { return }
        log.write("remote answered: \(response.title)")
        model.respond(taskID: taskID, requestID: request.id, route: response.route)
    }

    /// An answer that leaves a rule behind on the host is asked about once more before it goes, as on the Mac. The
    /// answer's words, often long, head the question rather than fill its button, which Windows' dialog cuts short.
    private func confirm(_ response: ConversationRequestResponse) async -> Bool {
        guard case let .providerAction(action) = response.route, action.kind == RemoteTurnProjection.Route.standing
        else { return true }
        log.write("remote asks: \(action.label)")
        let words = StackPanel()
        words.spacing = 8
        words.children.append(ConversationStyle.text(action.label, size: ConversationStyle.bodySize, semibold: true))
        words.children.append(ConversationStyle.text(
            L10n.format("This answer stays in effect on %@ after this request.", model.name), size: ConversationStyle.bodySize))
        let dialog = ContentDialog()
        dialog.title = L10n.string("Allow and save this rule?")
        dialog.content = words
        dialog.primaryButtonText = action.decision == .deny ? L10n.string("Deny") : L10n.string("Allow")
        dialog.closeButtonText = L10n.string("Cancel")
        dialog.defaultButton = .close
        dialog.xamlRoot = view.xamlRoot
        let result = try? await dialog.showAsync()?.get()
        return result == .primary
    }

    /// Retry on a turn, as the host's turn offers it (§15.23).
    private func retry(_ turnID: String) {
        guard let taskID else { return }
        log.write("remote retry: \(turnID)")
        model.send(.nextStep(taskID: taskID, turnID: turnID, action: .retry))
    }

    /// Edit message: the turn's message goes into the composer to edit, as the local turn's does; what the composer
    /// held waits to come back if the edit is cancelled, and sending it sends the host's edit.
    private func beginEdit(_ turn: ConversationTurn) {
        guard let taskID, let text = turn.actions.editLatest?.text else { return }
        log.write("remote edit message: \(turn.id)")
        let draft = drafts.draft(for: taskID)
        let previous = drafts.edits[taskID].map { ($0.previousText, $0.previousAttachments) } ?? (draft.text, draft.attachments)
        drafts.edits[taskID] = RemoteMessageEdit(turnID: turn.id, previousText: previous.0, previousAttachments: previous.1)
        draft.text = text
        draft.attachments = []
        draft.notice = nil
        composer.focus()
    }
}
