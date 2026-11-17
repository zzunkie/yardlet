import Foundation
import Observation
import UWP
// WinRT's async operations are not marked Sendable; a dialog's answer comes back on the window's thread.
@preconcurrency import WindowsFoundation
import WinUI
import YardletRemote

/// New task on another computer, as the Mac's host window draws it (`RemoteNewTaskView`), with the window's own New
/// task pieces (`NewTaskTitle`, `NewTaskParts`, `ComposerCard`, `ComposerOptionChips`, `ComposerAttachments`,
/// `NewTaskHomeListsView`): over the composer the host's projects with what their tasks need, read from the lists the
/// sidebar reads (`RemoteHostModel.newTaskHomeActivity`), or while none has anything to show, the host's recent tasks;
/// the title naming the host's project the task starts in, whose name is the menu of the host's projects and Chat (no
/// project); and the composer card, whose bottom row holds "+" where the harness takes files, New worktree where the
/// host can make one, the host's harnesses, its accounts, the settings the host's new-task composer offers, and Start.
/// What is chosen, read from the host and started is the engine's (`RemoteNewTaskForm`), as the Mac's is: the choices
/// apply to this task only, a choice the host asks about first is asked about here in the host's words, and once the
/// host started the task the window shows it. The words wait in the window's drafts (`RemoteComposerDrafts.newTask`).
@MainActor
final class RemoteNewTaskPane {
    let view = Grid()
    private let model: RemoteHostModel
    private let drafts: RemoteComposerDrafts
    private let log: QAEventLog
    /// The form while the pane shows; a new one each time it is shown, as the Mac's screen starts afresh.
    private var form: RemoteNewTaskForm?
    private let card = ComposerCard(metrics: .newTask)
    private let chips = ComposerOptionChips()
    private let attachments: ComposerAttachments
    private let over = StackPanel()
    private let recent = StackPanel()
    private let lists: NewTaskHomeListsView
    private let listScroll = ScrollViewer()
    private let bottom = StackPanel()
    private let heroTitle = NewTaskTitle()
    /// What the host says about the accounts the task can start on, over the bottom row.
    private let accountLine = TextBlock()
    /// What the host refused last, in orange under the composer.
    private let refusal = TextBlock()
    private let worktree = CheckBox()
    private let sendButton = ComposerParts.sendButton(name: L10n.string("Start task"))
    private let starting = ProgressRing()
    private var generation = 0
    /// What each part last drew, so a change redraws only its part: the host's tasks change with every turn's status.
    private var shownTitle: Title?
    private var shownControls: Controls?
    private var shownRecent: [String]?
    private var shownRefusal: String?
    private var textInDraft: String?
    /// The choices the host's options were last read for.
    private var readKey: RemoteNewTaskForm.OptionsKey?
    /// The setting asked about before the start, while its question is up.
    private var asking: String?
    private var loggedReady = false
    /// The columns and lines per project the window's size gives the projects.
    private var listsSize: (columns: Int, rowLimit: Int) = (1, 3)
    private var ticking: Task<Void, Never>?
    private var autosave: Task<Void, Never>?

    /// The window "+"'s dialogs belong to, as an `HWND`'s value.
    var windowHandle: () -> UInt64 {
        get { attachments.windowHandle }
        set { attachments.windowHandle = newValue }
    }

    private struct Title: Equatable {
        var kind: NewTaskHeroTitleKind
        var isChat: Bool
        var projectID: String?
        var projects: [String]
    }

    private struct Controls: Equatable {
        var harnesses: [RemoteHarnessOption]
        var harness: String?
        var harnessName: String?
        var worktree: Bool?
        var accounts: [RemoteAccount]
        var accountID: String?
        var accountLine: String?
        var extended: Bool
        var settings: [RemoteSetting]
        var picks: [String: String]
        var options: ComposerSessionOptions
        var isStarting: Bool
        var isConnected: Bool
        var acceptsImages: Bool
        var acceptsFiles: Bool

        var acceptsAttachments: Bool { acceptsImages || acceptsFiles }
        var inputPolicy: HarnessComposerInputPolicy {
            HarnessComposerInputPolicy(harness: HarnessKind(rawValue: harness ?? HarnessKind.claudeCode.rawValue),
                                       negotiatedImageInput: acceptsImages)
        }
    }

    /// What the pane reads of the form and the host at once.
    private struct Reading {
        var title: Title
        var controls: Controls
        var text: String
        var carried: [CodexUserInput]
        var lists: NewTaskHomeListsView.Reading
        var recent: [SessionRecord]
        var refusal: String?
        var canStart: Bool
        var key: RemoteNewTaskForm.OptionsKey
        var confirmation: RemoteSetting?
    }

    init(model: RemoteHostModel, drafts: RemoteComposerDrafts, log: QAEventLog) {
        self.model = model
        self.drafts = drafts
        self.log = log
        attachments = ComposerAttachments(log: log)
        // The host's folders and pull requests are the host's: the lists read neither, as the Mac's host window's.
        lists = NewTaskHomeListsView(pullRequests: nil, readsFolders: false, log: log)
        make()
    }

    private func make() {
        let listsRow = RowDefinition()
        listsRow.height = GridLength(value: 1, gridUnitType: .star)
        let bottomRow = RowDefinition()
        bottomRow.height = GridLength(value: 0, gridUnitType: .auto)
        view.rowDefinitions.append(listsRow)
        view.rowDefinitions.append(bottomRow)

        // Over the composer, as New task's: the area takes the view's width, capped by its widest, rather than
        // stretching to it (`NewTaskPane`).
        over.maxWidth = Double(NewTaskHomeLayout.composerWidth)
        over.horizontalAlignment = .center
        over.margin = Thickness(left: 28, top: 28, right: 28, bottom: 16)
        recent.spacing = 2
        recent.visibility = .collapsed
        over.children.append(recent)
        over.children.append(lists.view)
        lists.onAction = { [weak self] action in self?.perform(action) }
        lists.onRedraw = { [weak self] in self?.follow() }
        listScroll.content = over
        listScroll.sizeChanged.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.over.width = max(0, self.listScroll.actualWidth - 56)
        }
        view.children.append(listScroll)

        bottom.maxWidth = 760 + 2 * 28
        bottom.horizontalAlignment = .stretch
        bottom.padding = Thickness(left: 28, top: 14, right: 28, bottom: 20)
        bottom.children.append(heroTitle.view)
        let composer = card.view
        composer.margin = Thickness(left: 0, top: 20, right: 0, bottom: 0)
        bottom.children.append(composer)
        refusal.textWrapping = .wrap
        refusal.isTextSelectionEnabled = true
        refusal.fontSize = 12
        refusal.foreground = ComposerParts.orange.brush
        refusal.margin = Thickness(left: 0, top: 10, right: 0, bottom: 0)
        refusal.visibility = .collapsed
        bottom.children.append(refusal)
        try? Grid.setRow(bottom, 1)
        view.children.append(bottom)
        view.sizeChanged.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.heroTitle.fit(width: self.view.actualWidth)
            if self.measureLists() { self.follow() }
        }

        let field = card.field
        ComposerKeys.prepare(field, send: { [weak self] in self?.start() })
        field.textChanged.addHandler { [weak self] _, _ in self?.textChanged() }
        field.paste.addHandler { [weak self] _, args in self?.attachments.paste(args) }
        card.attachments.child = attachments.chipRow
        attachments.offersFolders = false
        attachments.target = { [weak self] in
            guard let self, let controls = self.shownControls, controls.acceptsAttachments else { return nil }
            return (self.drafts.newTask, controls.inputPolicy)
        }
        accountLine.fontSize = 12
        accountLine.foreground = WindowsTheme.secondaryText.brush
        accountLine.textTrimming = .characterEllipsis
        accountLine.margin = Thickness(left: 0, top: 0, right: 0, bottom: 6)
        accountLine.visibility = .collapsed
        card.extras.children.append(accountLine)

        worktree.content = ComposerParts.label(L10n.string("New worktree"), size: 12, color: WindowsTheme.text, weight: 400)
        worktree.minWidth = 0
        worktree.verticalAlignment = .center
        worktree.margin = Thickness(left: 4, top: 0, right: 2, bottom: 0)
        try? AutomationProperties.setName(worktree, L10n.string("New worktree"))
        worktree.click.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.form?.worktree = self.worktree.isChecked == true
        }

        starting.isActive = true
        starting.minWidth = 0
        starting.minHeight = 0
        starting.width = 14
        starting.height = 14
        starting.verticalAlignment = .center
        starting.visibility = .collapsed
        try? ToolTipService.setToolTip(sendButton, L10n.string("Start task"))
        sendButton.click.addHandler { [weak self] _, _ in self?.start() }

        chips.redraw = { [weak self] in self?.showControls() }
        chips.choose = { [weak self] id, value, _ in self?.form?.choose(.providerOption(id: id, value: value)) }
        chips.prepare = { [weak self] in await self?.form?.readOptions() }
    }

    /// Shows New task on the host, its words as they were left and its choices read anew from the host.
    func show() {
        let form = RemoteNewTaskForm(model: model, draft: drafts.newTask)
        if let chosen = drafts.newTaskProjectID {
            drafts.newTaskProjectID = nil
            if !form.take(chosenProjectID: chosen) { form.appear() }
        } else {
            form.appear()
        }
        self.form = form
        shownTitle = nil
        shownControls = nil
        shownRecent = nil
        shownRefusal = nil
        textInDraft = nil
        readKey = nil
        asking = nil
        loggedReady = false
        lists.reset()
        _ = measureLists()
        log.write("remote new task")
        follow()
        tick()
        _ = try? card.field.focus(.programmatic)
    }

    /// The window shows something else: the pane stops following the host until it is shown again.
    func hide() {
        generation += 1
        ticking?.cancel()
        ticking = nil
        lists.hide()
        form = nil
        drafts.save()
    }

    /// The times the lists show read again each minute.
    private func tick() {
        ticking?.cancel()
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.follow()
            }
        }
    }

    /// The columns and lines per project for the window's size now; true when they changed.
    private func measureLists() -> Bool {
        let height = view.xamlRoot.map { Double($0.size.height) } ?? view.actualHeight
        let size = (columns: NewTaskHomeLayout.columns(width: CGFloat(view.actualWidth)),
                    rowLimit: NewTaskHomeListsProjection.rowLimit(windowHeight: CGFloat(height)))
        guard size != listsSize else { return false }
        listsSize = size
        return true
    }

    // MARK: Following the host

    /// Follows the form, the draft and the host's lists through Observation while the pane shows, and draws what
    /// changed; the host's choices are read again whenever what they are read for changes.
    private func follow() {
        generation += 1
        let current = generation
        guard let form else { return }
        let reading = withObservationTracking {
            read(form)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.follow()
            }
        }
        if reading.text != textInDraft {
            textInDraft = reading.text
            if card.field.text != reading.text { card.field.text = reading.text }
        }
        lists.show(reading.lists)
        let width = Double(listsSize.columns > 1 ? NewTaskHomeLayout.gridWidth : NewTaskHomeLayout.composerWidth)
        if over.maxWidth != width { over.maxWidth = width }
        showRecent(reading.lists.isEmpty ? reading.recent : [])
        if reading.title != shownTitle {
            shownTitle = reading.title
            showTitle(reading.title)
        }
        if reading.controls != shownControls {
            shownControls = reading.controls
            showControls()
        }
        attachments.redraw(reading.carried)
        ComposerParts.setEnabled(sendButton, reading.canStart)
        if reading.refusal != shownRefusal {
            shownRefusal = reading.refusal
            refusal.text = reading.refusal ?? ""
            refusal.visibility = (reading.refusal ?? "").isEmpty ? .collapsed : .visible
            if let refused = reading.refusal, !refused.isEmpty { log.write("remote new task refused: \(refused)") }
        }
        if reading.key != readKey {
            readKey = reading.key
            Task { await form.readOptions() }
        }
        if let confirmation = reading.confirmation, asking != confirmation.id { ask(confirmation, form: form) }
    }

    private func read(_ form: RemoteNewTaskForm) -> Reading {
        let controls = Controls(
            harnesses: form.options?.harnesses ?? [], harness: form.harnessID, harnessName: form.harnessName,
            worktree: form.worktree, accounts: form.options?.accounts ?? [], accountID: form.accountID,
            accountLine: form.options?.accountLine, extended: model.composerExtensions,
            settings: form.options?.settings ?? [], picks: form.picks, options: form.sessionOptions,
            isStarting: form.isStarting, isConnected: model.isConnected,
            acceptsImages: form.chosenHarness?.acceptsImages == true, acceptsFiles: form.chosenHarness?.acceptsFiles == true)
        let projects = form.projects
        let title = Title(kind: form.heroKind, isChat: form.isChat, projectID: form.projectID,
                          projects: projects.map { "\($0.id) \($0.kind) \($0.name)" })
        let activity = model.newTaskHomeActivity()
        let listed = lists.read(activity: activity,
                               selectedProjectID: form.isChat ? nil : form.projectID.flatMap(UUID.init(uuidString:)),
                               startsChat: form.isChat, replyTaskID: nil, columns: listsSize.columns,
                               rowLimit: listsSize.rowLimit)
        return Reading(title: title, controls: controls, text: form.draft.text, carried: form.draft.attachments,
                       lists: listed, recent: activity.sessions.sorted { $0.updatedAt > $1.updatedAt },
                       refusal: model.commandError, canStart: form.canStart, key: form.optionsKey,
                       confirmation: form.startConfirmation)
    }

    // MARK: Over the composer

    /// The host's recent tasks while none of its projects has anything to show, as the Mac's host window lists them.
    private func showRecent(_ sessions: [SessionRecord]) {
        guard !sessions.isEmpty || shownRecent != [] else { return }
        let names = Dictionary(model.sidebar.groups.flatMap { group in group.sessions.map { ($0.id, group.displayName) } },
                               uniquingKeysWith: { first, _ in first })
        let rows = sessions.map { [$0.id.uuidString, $0.title, $0.status.displayName, names[$0.id] ?? ""]
            .joined(separator: "\u{1F}") }
        guard rows != shownRecent else { return }
        shownRecent = rows
        recent.children.clear()
        recent.visibility = sessions.isEmpty ? .collapsed : .visible
        guard !sessions.isEmpty else { return }
        let header = ComposerParts.label(L10n.string("Recent tasks"), size: 12, weight: 600)
        header.margin = Thickness(left: 10, top: 0, right: 0, bottom: 6)
        recent.children.append(header)
        for session in sessions {
            let id = session.id
            recent.children.append(NewTaskParts.recentRow(session, place: names[id] ?? L10n.string("Chats")) {
                [weak self] in self?.model.select(.task(id.uuidString))
            })
        }
    }

    /// What a line of the host's projects does, as the Mac's host window does it: a project's name starts the task
    /// there and gives the composer the keyboard, and a task opens; answering one in the composer's place is the local
    /// home's alone for now.
    private func perform(_ action: NewTaskHomeAction) {
        guard let form else { return }
        switch action {
        case let .openTask(id), let .reply(id):
            model.select(.task(id.uuidString))
        case let .draft(prompt):
            form.draft.text = form.draft.text.isEmpty ? prompt : form.draft.text + "\n\n" + prompt
            focus()
        case .useNewWorktree:
            if form.worktree != nil { form.worktree = true }
            focus()
        case let .chooseProject(id):
            form.projectID = id.uuidString
            focus()
        case .chooseChat:
            form.projectID = RemoteTaskProjection.chatsProjectID
            focus()
        case .openSchedule, .openEvent:
            break
        }
    }

    private func focus() {
        _ = try? card.field.focus(.programmatic)
    }

    // MARK: The title

    /// The title naming the host's project the task starts in, its name the project menu; with no project, Chat (no
    /// project) under it, as the Mac's host window shows it.
    private func showTitle(_ title: Title) {
        let chip: (title: String, glyph: String)? = title.isChat ? (L10n.string("Chat (no project)"), "\u{E8BD}") : nil
        heroTitle.show(title.kind, chip: chip) { [weak self] in self?.projectMenu() ?? MenuFlyout() }
        heroTitle.fit(width: view.actualWidth)
    }

    /// The host's projects, then Chat (no project), the one the task starts in checked.
    private func projectMenu() -> MenuFlyout {
        let menu = MenuFlyout()
        guard let form else { return menu }
        let isChat = form.isChat
        for project in form.projects where project.kind != .chats {
            let item = RadioMenuFlyoutItem()
            item.text = project.name
            item.groupName = "project"
            item.isChecked = !isChat && project.id == form.projectID
            let id = project.id
            item.click.addHandler { [weak self] _, _ in
                self?.log.write("remote new task place: \(project.name)")
                self?.form?.projectID = id
            }
            menu.items.append(item)
        }
        if menu.items.size > 0 { menu.items.append(MenuFlyoutSeparator()) }
        let chat = RadioMenuFlyoutItem()
        chat.text = L10n.string("Chat (no project)")
        chat.groupName = "project"
        chat.isChecked = isChat
        chat.click.addHandler { [weak self] _, _ in
            self?.log.write("remote new task place: chat")
            self?.form?.projectID = RemoteTaskProjection.chatsProjectID
        }
        menu.items.append(chat)
        return menu
    }

    // MARK: The composer's row

    /// The bottom row, as the Mac's host window's: "+", New worktree, the harness, the account and the settings, then
    /// Start; where the host names its settings' roles, the composer's own controls (`ComposerOptionChips`), the model
    /// beside Start.
    private func showControls() {
        guard let controls = shownControls else { return }
        card.field.placeholderText = NewTaskComposerText.placeholder(harnessName: controls.harnessName)
        card.leading.children.clear()
        attachments.show(policy: controls.inputPolicy)
        attachments.plusButton.visibility = controls.acceptsAttachments ? .visible : .collapsed
        card.leading.children.append(attachments.plusButton)
        if let checked = controls.worktree {
            worktree.isChecked = checked
            worktree.isEnabled = !controls.isStarting
            card.leading.children.append(worktree)
        }
        card.leading.children.append(NewTaskParts.harnessControl(
            controls.harness.map(HarnessKind.init(rawValue:)), name: controls.harnessName,
            choices: controls.harnesses.map { (kind: HarnessKind(rawValue: $0.harness), name: $0.harnessName) }) { [weak self] kind in
            self?.log.write("remote new task harness: \(kind.rawValue)")
            self?.form?.chooseHarness(kind.rawValue)
        })
        if !controls.accounts.isEmpty { card.leading.children.append(accountControl(controls)) }
        if controls.extended {
            for control in chips.leading(controls.options) { card.leading.children.append(control) }
        } else {
            for setting in controls.settings {
                card.leading.children.append(settingControl(setting, value: controls.picks[setting.id] ?? setting.value))
            }
        }
        card.trailing.children.clear()
        if controls.extended {
            for control in chips.trailing(controls.options) { card.trailing.children.append(control) }
        }
        starting.visibility = controls.isStarting ? .visible : .collapsed
        card.trailing.children.append(starting)
        card.trailing.children.append(sendButton)
        accountLine.text = controls.accountLine ?? ""
        accountLine.visibility = (controls.accountLine ?? "").isEmpty ? .collapsed : .visible
        if let line = controls.accountLine { try? ToolTipService.setToolTip(accountLine, line) }
        if !loggedReady, !controls.harnesses.isEmpty {
            loggedReady = true
            log.write("remote new task ready: \(controls.harnessName ?? "")")
        }
    }

    /// The account the task starts on, and a menu of the host's accounts for the harness, read again as it opens.
    private func accountControl(_ controls: Controls) -> Button {
        let accounts = controls.accounts
        let title = accounts.first { $0.id == controls.accountID }?.name
            ?? accounts.first { $0.current == true }?.name ?? L10n.string("Account unavailable")
        let control = ComposerParts.control(title: title, glyph: "\u{E77B}", chevron: true, name: L10n.string("Choose account"))
        try? ToolTipService.setToolTip(control, title)
        let menu = MenuFlyout()
        menu.placement = .top
        let chosen = controls.accountID ?? accounts.first { $0.current == true }?.id
        for account in accounts {
            let item = RadioMenuFlyoutItem()
            item.text = account.name
            item.groupName = "account"
            item.isChecked = account.id == chosen
            item.isEnabled = account.available == true
            if let detail = account.detail { try? ToolTipService.setToolTip(item, detail) }
            let id = account.id
            item.click.addHandler { [weak self] _, _ in self?.form?.chooseAccount(id) }
            menu.items.append(item)
        }
        menu.opening.addHandler { [weak self] _, _ in
            guard let form = self?.form else { return }
            Task { await form.readOptions() }
        }
        control.flyout = menu
        return control
    }

    /// A setting the host names no role for, as the Mac's host window draws it: its choice, and a menu of its choices.
    private func settingControl(_ setting: RemoteSetting, value: String) -> Button {
        let control = ComposerParts.control(title: setting.choices.first { $0.value == value }?.name ?? value,
                                            chevron: true, tint: WindowsTheme.text, name: setting.name)
        try? ToolTipService.setToolTip(control, setting.name)
        let menu = MenuFlyout()
        menu.placement = .top
        for choice in setting.choices {
            let item = RadioMenuFlyoutItem()
            item.text = choice.name
            item.groupName = setting.id
            item.isChecked = choice.value == value
            if let description = choice.description { try? ToolTipService.setToolTip(item, description) }
            let id = setting.id, picked = choice.value
            item.click.addHandler { [weak self] _, _ in
                self?.log.write("remote new task \(id): \(picked)")
                self?.form?.pick(id, picked)
            }
            menu.items.append(item)
        }
        control.flyout = menu
        return control
    }

    // MARK: Typing and starting

    /// What the person types goes to the new task's draft, saved a moment after the typing stops, as the Mac's window
    /// saves it.
    private func textChanged() {
        let text = card.field.text
        guard text != textInDraft else { return }
        textInDraft = text
        drafts.newTask.text = text
        autosave?.cancel()
        autosave = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.drafts.save()
        }
    }

    private func start() {
        guard let form else { return }
        // The draft takes the text as shown, the syllable being composed included.
        if form.draft.text != card.field.text {
            form.draft.text = card.field.text
            textInDraft = form.draft.text
        }
        guard form.canStart else { return }
        log.write("remote new task start: \(form.draft.text.trimmingCharacters(in: .whitespacesAndNewlines))")
        form.start()
    }

    /// A choice the host asks about first that stands chosen, asked about in the host's words before the task starts.
    private func ask(_ setting: RemoteSetting, form: RemoteNewTaskForm) {
        guard let confirm = setting.choices.first(where: { $0.value == setting.value })?.confirm else {
            form.startConfirmation = nil
            return
        }
        asking = setting.id
        log.write("remote new task asks: \(confirm.title)")
        let dialog = ContentDialog()
        dialog.title = confirm.title
        dialog.content = confirm.message
        dialog.primaryButtonText = confirm.button
        dialog.closeButtonText = L10n.string("Cancel")
        dialog.defaultButton = .close
        dialog.xamlRoot = view.xamlRoot
        Task { [weak self] in
            let result = try? await dialog.showAsync()?.get()
            self?.asking = nil
            guard self?.form === form else { return }
            if result == .primary { form.confirmStart() } else { form.startConfirmation = nil }
        }
    }
}
