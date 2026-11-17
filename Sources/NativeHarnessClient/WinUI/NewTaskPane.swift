import Foundation
import Observation
import UWP
// WinRT's async operations are not marked Sendable; a dialog's answer comes back on the window's thread.
@preconcurrency import WindowsFoundation
import WinUI
import YardletRemote

/// New task, which is Yardlet's home, as the Mac's (`NewTaskHome`): over it the projects with what their tasks need
/// (`NewTaskHomeListsView`), or while no project has anything to show, the recent tasks; Import conversation… over
/// either, since Windows has no File menu to hold it; and at its foot the large title ("What should we build?", or
/// "…in {project}?", whose project name opens the project menu), under a title without a project the chip that chooses
/// where the task starts, and the composer card, whose bottom row holds "+" (`ComposerAttachments`), the harness with its mark, the account, the
/// permission and the model, and Start. The choices are the Mac's home draft (`ComposerDrafts.home`), so they are remembered as the Mac remembers
/// them, and the menus are the ones the Mac's new-task controls read (`ComposerSessionOptionsProjection.newTask`), as a
/// paired computer's new task chooses them (`AppModelRemoteBridge.choosing`). A choice the Mac asks about first, such
/// as skipping permission prompts, is asked about here in the Mac's words. A harness whose login reads signed out says
/// so in the card with Sign in, as the Mac's does.
@MainActor
final class NewTaskPane {
    let view = Grid()
    /// Called once the task has started and the model has chosen it, or came to exist and could not start.
    var onStarted: (() -> Void)?
    /// Opens a task the home lists.
    var onOpenTask: ((SessionRecord.ID) -> Void)?
    /// Opens Import conversation, from the link over the recent tasks.
    var onImportConversation: (() -> Void)?

    private let model: AppModel
    private let log: QAEventLog
    private let signIn: HarnessSignIn
    /// The window's handle, which owns the folder dialog.
    private let windowHandle: () -> UInt64
    private let card = ComposerCard(metrics: .newTask)
    private let chips = ComposerOptionChips()
    private let attachments: ComposerAttachments
    /// Over the composer: Import conversation…, then the recent tasks or the projects.
    private let over = StackPanel()
    private let recent = StackPanel()
    private let lists: NewTaskHomeListsView
    /// The scroll view over the composer, whose width sets the area's.
    private let listScroll = ScrollViewer()
    private let title = StackPanel()
    private let destination = Grid()
    private let sendButton = ComposerParts.sendButton(name: L10n.string("Start task"))
    private let starting = ProgressRing()
    private let guidance = TextBlock()
    /// The chosen harness's sign-in, while its account reads signed out.
    private let signInRow: SignInRow
    /// The harnesses Yardlet found, in the menu's order.
    private var harnesses: [HarnessKind] = []
    private var lookedForRuntimes = false
    /// The draft's text as it last went to the draft or came from it.
    private var textInDraft: String?
    private var settingsGeneration = 0
    private var followGeneration = 0
    private var isInRepository = false
    private var repositoryFolder: URL?
    /// The title's words, which the window's width sizes.
    private var titleTexts: [TextBlock] = []
    /// What each part last drew, so a change redraws only its part: the tasks change with every turn's status.
    private var shownRecent: [String]?
    private var shownRecentRows: Bool?
    /// The columns and lines per project the window's size gives the projects.
    private var listsSize: (columns: Int, rowLimit: Int) = (1, 3)
    /// Draws the times again each minute while the home shows.
    private var ticking: Task<Void, Never>?
    private var shownTitle: [String]?
    private var shownControls: Controls?

    private struct Controls: Equatable {
        var harnesses: [HarnessKind]
        var harness: HarnessKind?
        var options: ComposerSessionOptions?
        var accounts: [String]
        var account: String?
        var needsSignIn: Bool
        var isCreating: Bool
        var failure: String?
        var notice: String?
        var hasRuntime: Bool
    }

    init(model: AppModel, log: QAEventLog, signIn: HarnessSignIn, windowHandle: @escaping () -> UInt64) {
        self.model = model
        self.log = log
        self.signIn = signIn
        signInRow = SignInRow(signIn: signIn, inline: true)
        self.windowHandle = windowHandle
        attachments = ComposerAttachments(log: log)
        lists = NewTaskHomeListsView(model: model, log: log)
        make()
    }

    private var draft: NewTaskDraft { model.composerDrafts.home }

    private var chosenHarness: HarnessKind? {
        draft.harness.flatMap { harnesses.contains($0) ? $0 : nil }
    }

    /// The projects the Mac's project menu lists.
    private var visibleProjects: [Project] {
        model.projects.visibleGroups(sessions: model.store.sessions).compactMap(\.project)
    }

    private var runtimeURL: URL? {
        chosenHarness.flatMap { model.runtimeSelections.selectedURL(for: $0) }
    }

    private func make() {
        let listsRow = RowDefinition()
        listsRow.height = GridLength(value: 1, gridUnitType: .star)
        let bottomRow = RowDefinition()
        bottomRow.height = GridLength(value: 0, gridUnitType: .auto)
        view.rowDefinitions.append(listsRow)
        view.rowDefinitions.append(bottomRow)

        // Over the composer: the projects, or the recent tasks with Import conversation…, as the Mac's home lists them.
        // The area's width comes from the view's, capped by its widest, rather than stretched up to it: the scroll view
        // places its content by the width the content asks for, so a stretched area stood to the right of the middle,
        // its Import conversation… past the window's edge (as `ConversationTimeline.fitColumn`).
        over.maxWidth = Double(NewTaskHomeLayout.composerWidth)
        over.horizontalAlignment = .center
        over.margin = Thickness(left: 28, top: 28, right: 28, bottom: 16)
        recent.spacing = 2
        over.children.append(recent)
        lists.view.visibility = .collapsed
        over.children.append(lists.view)
        lists.onAction = { [weak self] action in self?.perform(action) }
        lists.onRedraw = { [weak self] in self?.redrawLists() }
        listScroll.content = over
        listScroll.sizeChanged.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.over.width = max(0, self.listScroll.actualWidth - 56)
        }
        view.children.append(listScroll)

        let bottom = StackPanel()
        bottom.maxWidth = 760 + 2 * 28
        bottom.horizontalAlignment = .stretch
        bottom.padding = Thickness(left: 28, top: 14, right: 28, bottom: 20)
        title.orientation = .horizontal
        title.horizontalAlignment = .center
        bottom.children.append(title)
        destination.horizontalAlignment = .center
        destination.margin = Thickness(left: 0, top: 8, right: 0, bottom: 0)
        bottom.children.append(destination)
        let composer = card.view
        composer.margin = Thickness(left: 0, top: 20, right: 0, bottom: 0)
        bottom.children.append(composer)
        try? Grid.setRow(bottom, 1)
        view.children.append(bottom)
        // The title fits the window: smaller where the window is narrow, as the Mac's steps down; the projects stand
        // in as many columns as fit, with as many lines as the window's height gives them.
        view.sizeChanged.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.fitTitle()
            if self.measureLists() { self.redrawLists() }
        }

        let field = card.field
        ComposerKeys.prepare(field, send: { [weak self] in self?.startTask() })
        field.textChanged.addHandler { [weak self] _, _ in self?.textChanged() }
        // "+" and a paste add to the home draft as the Mac's home adds them.
        field.paste.addHandler { [weak self] _, args in self?.attachments.paste(args) }
        card.attachments.child = attachments.chipRow
        attachments.windowHandle = windowHandle
        attachments.target = { [weak self] in
            guard let self, let options = self.optionsNow() else { return nil }
            return (self.draft, options.input)
        }
        guidance.textWrapping = .wrap
        guidance.fontSize = 12
        guidance.foreground = WindowsTheme.secondaryText.brush
        guidance.margin = Thickness(left: 0, top: 0, right: 0, bottom: 10)
        guidance.visibility = .collapsed
        card.extras.children.append(guidance)
        signInRow.place(in: card.extras)
        signInRow.view.margin = Thickness(left: 0, top: 0, right: 0, bottom: 12)

        starting.isActive = true
        starting.minWidth = 0
        starting.minHeight = 0
        starting.width = 14
        starting.height = 14
        starting.verticalAlignment = .center
        starting.visibility = .collapsed
        try? ToolTipService.setToolTip(sendButton, L10n.string("Start task"))
        sendButton.click.addHandler { [weak self] _, _ in self?.startTask() }

        chips.redraw = { [weak self] in self?.showControls() }
        chips.choose = { [weak self] id, value, _ in self?.apply(value, to: id) }
        chips.prepare = { [weak self] in await self?.readModels() }
    }

    /// Fills the home from the draft and the harnesses found, when it is shown.
    func show() {
        let descriptors = model.runtimeSelections.connectedDescriptors
        harnesses = descriptors.map(\.id)
        let projects = visibleProjects
        draft.prepare(defaultProject: projects.first, availableHarnesses: harnesses)
        // With no project to start in, the task starts as a chat (`NewTaskDraft.startsChat`).
        draft.dropUnavailableProject(visible: projects)
        if let harness = draft.harness, !harnesses.contains(harness) { draft.harness = harnesses.first }
        log.write("new task harnesses: \(descriptors.map(\.displayName).joined(separator: ", "))")
        if card.field.text != draft.text {
            textInDraft = draft.text
            card.field.text = draft.text
        }
        // Drawn whole each time it is shown; while it shows, only what changes.
        shownRecent = nil
        shownRecentRows = nil
        shownTitle = nil
        shownControls = nil
        lists.reset()
        _ = measureLists()
        follow()
        tick()
        refreshSettings()
        // The installs are looked for once, when the list first comes up empty.
        guard descriptors.isEmpty, !lookedForRuntimes else { return }
        lookedForRuntimes = true
        Task {
            await model.runtimeSelections.findNewest()
            if !model.runtimeSelections.connectedDescriptors.isEmpty { show() }
        }
    }

    /// The window shows something else: the home stops following the tasks until it is shown again.
    func hide() {
        followGeneration += 1
        ticking?.cancel()
        ticking = nil
        lists.hide()
    }

    /// The times the lists show ("3 min ago", "12 min so far") read again each minute.
    private func tick() {
        ticking?.cancel()
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.redrawLists()
            }
        }
    }

    /// Reads and draws the home again, as a change it follows would.
    private func redrawLists() {
        follow()
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

    /// Follows the draft, the accounts and the tasks through Observation while the home shows, and draws them.
    private func follow() {
        followGeneration += 1
        let current = followGeneration
        let (recent, heading, controls, text, carried, projects) = withObservationTracking {
            (recentShown(), titleShown(), controlsShown(), draft.text, draft.attachments, listsShown())
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.followGeneration == current else { return }
                self.follow()
            }
        }
        if text != textInDraft {
            textInDraft = text
            if card.field.text != text { card.field.text = text }
        }
        lists.show(projects)
        // The recent tasks while no project has anything to show, as on the Mac.
        let showsRecent = projects.isEmpty
        if recent != shownRecent || showsRecent != shownRecentRows {
            shownRecent = recent
            shownRecentRows = showsRecent
            showRecent(withRows: showsRecent)
            lists.view.visibility = showsRecent ? .collapsed : .visible
        }
        let width = Double(listsSize.columns > 1 ? NewTaskHomeLayout.gridWidth : NewTaskHomeLayout.composerWidth)
        if over.maxWidth != width { over.maxWidth = width }
        if heading != shownTitle {
            shownTitle = heading
            showTitle()
        }
        if controls != shownControls { showControls() }
        attachments.redraw(carried)
        showSendable()
    }

    private func recentShown() -> [String] {
        model.store.listedSessions.prefix(6).map { session in
            [session.id.uuidString, session.title, session.status.displayName, model.projects.displayName(for: session)]
                .joined(separator: "\u{1F}")
        }
    }

    /// The projects over the composer, read from the model's tasks as the Mac's home reads them.
    private func listsShown() -> NewTaskHomeListsView.Reading {
        var activity = model.newTaskHomeActivity()
        // Windows runs no schedules and has no Scheduled tasks to open one in.
        activity.schedules = []
        activity.stoppedSchedules = []
        return lists.read(activity: activity, selectedProjectID: draft.startsChat ? nil : selectedProjectID,
                          startsChat: draft.startsChat, replyTaskID: nil, columns: listsSize.columns,
                          rowLimit: listsSize.rowLimit)
    }

    /// The project the new task starts in: the draft's, or the one that holds its folder.
    private var selectedProjectID: UUID? {
        let projects = visibleProjects
        return (draft.projectID.flatMap { id in projects.first { $0.id == id } }
            ?? draft.workspaceURL.flatMap { folder in projects.first { $0.contains(root: folder) } })?.id
    }

    private func titleShown() -> [String] {
        [draft.startsChat ? "chat" : "", draft.workspaceURL?.path ?? "", draft.projectID?.uuidString ?? ""]
            + visibleProjects.map { "\($0.id) \($0.name)" }
    }

    private func controlsShown() -> Controls {
        let harness = chosenHarness
        let connections = model.connections
        let choices = harness.map { connections.choices(for: [$0]) } ?? []
        return Controls(harnesses: harnesses, harness: harness, options: optionsNow(),
                        accounts: choices.map { "\($0.title) \($0.canSelect)" },
                        account: harness.flatMap { connections.selection[$0] },
                        needsSignIn: harness.map { signIn.needsSignIn($0) } ?? false,
                        isCreating: draft.isCreating, failure: draft.creationFailed ? draft.creationError ?? "" : nil,
                        notice: draft.notice, hasRuntime: runtimeURL != nil)
    }

    // MARK: Over the composer

    /// "Recent tasks" with Import conversation… beside it, then the latest tasks, each opening its task; while the
    /// projects show, Import conversation… alone.
    private func showRecent(withRows: Bool) {
        recent.children.clear()
        let header = Grid()
        let wide = ColumnDefinition()
        wide.width = GridLength(value: 1, gridUnitType: .star)
        header.columnDefinitions.append(wide)
        let links = ColumnDefinition()
        links.width = GridLength(value: 0, gridUnitType: .auto)
        header.columnDefinitions.append(links)
        header.margin = Thickness(left: 10, top: 0, right: 0, bottom: 6)
        if withRows { header.children.append(ComposerParts.label(L10n.string("Recent tasks"), size: 12, weight: 600)) }
        let link = ComposerParts.control(title: L10n.string("Import conversation…"), name: L10n.string("Import conversation"))
        try? ToolTipService.setToolTip(link, L10n.string("Continue a conversation started in another app or CLI."))
        link.click.addHandler { [weak self] _, _ in self?.onImportConversation?() }
        try? Grid.setColumn(link, 1)
        header.children.append(link)
        recent.children.append(header)
        guard withRows else { return }
        for session in model.store.listedSessions.prefix(6) {
            recent.children.append(recentRow(session))
        }
    }

    /// A recent task (`RecentTaskButton`): its harness's mark, its title over its project and harness, its state.
    private func recentRow(_ session: SessionRecord) -> UIElement {
        let button = Button()
        ComposerParts.styleFlat(button, radius: 8)
        button.horizontalAlignment = .stretch
        button.horizontalContentAlignment = .stretch
        button.padding = Thickness(left: 10, top: 6, right: 10, bottom: 6)
        button.minHeight = 48
        let row = Grid()
        row.columnSpacing = 11
        for width in [GridLength(value: 24, gridUnitType: .pixel), GridLength(value: 1, gridUnitType: .star),
                      GridLength(value: 0, gridUnitType: .auto), GridLength(value: 0, gridUnitType: .auto)] {
            let column = ColumnDefinition()
            column.width = width
            row.columnDefinitions.append(column)
        }
        if let icon = HarnessIcon.element(for: session.harness) {
            icon.verticalAlignment = .center
            icon.horizontalAlignment = .center
            row.children.append(icon)
        }
        let words = StackPanel()
        words.spacing = 2
        words.verticalAlignment = .center
        words.children.append(ComposerParts.label(session.title, size: 14, color: WindowsTheme.text))
        words.children.append(ComposerParts.label(
            "\(model.projects.displayName(for: session)) · \(session.harness.displayName)", size: 12, weight: 400))
        try? Grid.setColumn(words, 1)
        row.children.append(words)
        let state = ComposerParts.label(session.status.displayName, size: 12,
                                        color: session.status == .failed ? ComposerParts.red : WindowsTheme.secondaryText,
                                        weight: 400)
        try? Grid.setColumn(state, 2)
        row.children.append(state)
        let chevron = ComposerParts.glyph("\u{E76C}", size: 10, color: WindowsTheme.tertiaryText)
        try? Grid.setColumn(chevron, 3)
        row.children.append(chevron)
        button.content = row
        try? AutomationProperties.setName(button, session.title)
        let id = session.id
        button.click.addHandler { [weak self] _, _ in self?.onOpenTask?(id) }
        return button
    }

    // MARK: The projects' lines

    /// What a line of the projects does, as the Mac's home does it: a project's name starts the new task there and
    /// gives the composer the keyboard; a task opens.
    private func perform(_ action: NewTaskHomeAction) {
        switch action {
        case let .openTask(id), let .reply(id):
            onOpenTask?(id)
        case let .chooseProject(id):
            guard let project = visibleProjects.first(where: { $0.id == id }) else { return }
            draft.projectID = project.id
            draft.workspaceURL = project.primaryRoot
            log.write("new task place: \(project.name)")
            refreshSettings()
            _ = try? card.field.focus(.programmatic)
        case .chooseChat:
            draft.chooseChat()
            log.write("new task place: chat")
            refreshSettings()
            _ = try? card.field.focus(.programmatic)
        case let .draft(prompt):
            draft.insertPrompt(prompt)
            _ = try? card.field.focus(.programmatic)
        case .useNewWorktree, .openSchedule, .openEvent:
            // Worktrees, Scheduled tasks and the calendar are the Mac's; the lists here offer none of them.
            break
        }
    }

    // MARK: The title and where the task starts

    private func showTitle() {
        let folder = draft.startsChat ? nil : draft.workspaceURL
        if folder != repositoryFolder {
            repositoryFolder = folder
            isInRepository = folder.map { GitWorktreeOriginResolver.isInRepository($0) } ?? false
        }
        let kind = NewTaskHeroTitleKind(startsChat: draft.startsChat, workspaceURL: draft.workspaceURL,
                                        isInRepository: isInRepository,
                                        projectName: { [model] in model.projects.displayName(for: $0) })
        let parts = kind.parts
        title.children.clear()
        titleTexts = []
        if !parts.before.isEmpty { title.children.append(heroText(parts.before)) }
        if let project = parts.project {
            // The project's name is the project menu, underlined as the Codex app's is.
            let name = Button()
            ComposerParts.styleFlat(name, pointerOver: ComposerParts.clear, pressed: ComposerParts.clear, radius: 0)
            name.padding = Thickness(left: 0, top: 0, right: 0, bottom: 0)
            let text = heroText(project)
            text.foreground = WindowsTheme.text.brush
            let underline = Border()
            underline.borderBrush = WindowsTheme.tertiaryText.brush
            underline.borderThickness = Thickness(left: 0, top: 0, right: 0, bottom: 1.5)
            underline.child = text
            name.content = underline
            name.flyout = destinationMenu()
            try? AutomationProperties.setName(name, L10n.string("Project"))
            try? ToolTipService.setToolTip(name, L10n.string("Project"))
            title.children.append(name)
        }
        if !parts.after.isEmpty { title.children.append(heroText(parts.after)) }
        try? AutomationProperties.setName(title, kind.sentence)
        fitTitle()

        destination.children.clear()
        if draft.workspaceURL == nil {
            let label = draft.startsChat ? L10n.string("Chat (no project)") : L10n.string("Choose project")
            let chip = ComposerParts.control(title: label, glyph: draft.startsChat ? "\u{E8BD}" : ComposerParts.Glyph.folder,
                                             chevron: true, name: L10n.string("Project"))
            chip.flyout = destinationMenu()
            destination.children.append(chip)
            destination.visibility = .visible
        } else {
            destination.visibility = .collapsed
        }
    }

    private func heroText(_ words: String) -> TextBlock {
        let text = TextBlock()
        text.text = words
        text.fontSize = 28
        text.fontWeight = UWP.FontWeight(weight: 600)
        text.foreground = WindowsTheme.text.brush
        text.textWrapping = .noWrap
        text.verticalAlignment = .bottom
        titleTexts.append(text)
        return text
    }

    /// 28 points where the window has room, 22 where it is narrow.
    private func fitTitle() {
        let size: Double = view.actualWidth > 0 && view.actualWidth < 640 ? 22 : 28
        for text in titleTexts where text.fontSize != size { text.fontSize = size }
    }

    /// The project menu (`NewTaskDestinationMenuItems`): Choose project…, Chat (no project), then the projects, the
    /// current one checked.
    private func destinationMenu() -> MenuFlyout {
        let menu = MenuFlyout()
        menu.items.append(ComposerParts.menuItem(L10n.string("Choose project…")) { [weak self] in
            // The dialog runs modally until it closes, so it opens after the menu's click returns.
            Task { @MainActor in self?.chooseFolder() }
        })
        let chat = ToggleMenuFlyoutItem()
        chat.text = L10n.string("Chat (no project)")
        chat.isChecked = draft.startsChat
        chat.click.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.draft.chooseChat()
            self.log.write("new task place: chat")
            self.refreshSettings()
        }
        menu.items.append(chat)
        let projects = visibleProjects
        if !projects.isEmpty {
            menu.items.append(MenuFlyoutSeparator())
            let current = draft.startsChat ? nil : (draft.projectID.flatMap { id in projects.first { $0.id == id } }
                ?? draft.workspaceURL.flatMap { folder in projects.first { $0.contains(root: folder) } })?.id
            for project in projects {
                let item = RadioMenuFlyoutItem()
                item.text = project.name
                item.groupName = "project"
                item.isChecked = project.id == current
                item.click.addHandler { [weak self] _, _ in
                    guard let self else { return }
                    self.draft.projectID = project.id
                    self.draft.workspaceURL = project.primaryRoot
                    self.log.write("new task place: \(project.name)")
                    self.refreshSettings()
                }
                menu.items.append(item)
            }
        }
        return menu
    }

    /// Choose project…: a folder from Windows' own dialog, in the project that holds it or as a folder the task's
    /// start makes a project, as the Mac's Choose project… does.
    private func chooseFolder() {
        guard let folder = WindowsFolderPicker.chooseFolder(window: windowHandle(), title: L10n.string("Choose project"))
        else { return }
        draft.workspaceURL = folder
        draft.projectID = visibleProjects.first { $0.contains(root: folder) }?.id
        log.write("new task place: \(folder.lastPathComponent)")
        refreshSettings()
    }

    // MARK: The composer's row

    private func optionsNow() -> ComposerSessionOptions? {
        chosenHarness.map { harness in
            ComposerSessionOptionsProjection.newTask(harness: harness, choice: draft.modelChoices[harness],
                                                     catalogs: model.modelCatalogs,
                                                     connection: model.connections.selected(for: harness),
                                                     workspaceURL: draft.workspaceURL)
        }
    }

    /// The bottom row (`NewTaskComposerControlRow`): the harness, the account and the permission, then the model and
    /// Start; over it what stops a start, in the Mac's words.
    private func showControls() {
        shownControls = controlsShown()
        let harness = chosenHarness
        card.field.placeholderText = NewTaskComposerText.placeholder(harnessName: harness?.displayName)
        let options = optionsNow()
        card.leading.children.clear()
        attachments.show(policy: options?.input)
        card.leading.children.append(attachments.plusButton)
        card.leading.children.append(harnessControl())
        if let harness { card.leading.children.append(accountControl(harness)) }
        if let options { for control in chips.leading(options) { card.leading.children.append(control) } }
        card.trailing.children.clear()
        if let options { for control in chips.trailing(options) { card.trailing.children.append(control) } }
        starting.visibility = draft.isCreating ? .visible : .collapsed
        card.trailing.children.append(starting)
        card.trailing.children.append(sendButton)

        // Why the last edit left the draft as it is, as the Mac's editor says it, else why the last start failed.
        card.showNotice(draft.notice ?? (draft.creationFailed
            ? draft.creationError ?? L10n.string("The task could not start. Your draft is still here.") : nil))
        if harness != nil, runtimeURL == nil {
            showGuidance(L10n.string("The selected harness is unavailable. Choose another harness or manage harnesses."))
        } else if harnesses.isEmpty {
            showGuidance(L10n.string("Add a harness to start a task."))
        } else {
            showGuidance(nil)
        }
        signInRow.show(harness)
        showSendable()
    }

    private func showGuidance(_ text: String?) {
        guidance.text = text ?? ""
        guidance.visibility = text == nil ? .collapsed : .visible
    }

    /// The harness with its mark (`NewTaskHarnessControl`), whose menu lists the harnesses Yardlet found.
    private func harnessControl() -> Button {
        let harness = chosenHarness
        let button = Button()
        ComposerParts.styleFlat(button)
        button.height = ComposerParts.controlHeight
        button.padding = Thickness(left: 7, top: 0, right: 7, bottom: 0)
        button.verticalAlignment = .center
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 5
        if let harness, let icon = HarnessIcon.element(for: harness) {
            icon.verticalAlignment = .center
            row.children.append(icon)
        }
        row.children.append(ComposerParts.label(harness?.displayName ?? L10n.string("Choose harness"),
                                                color: WindowsTheme.text))
        row.children.append(ComposerParts.glyph(ComposerParts.Glyph.chevronDown, size: 8, color: WindowsTheme.text))
        button.content = row
        try? AutomationProperties.setName(button, L10n.string("Harness"))
        try? ToolTipService.setToolTip(button, harness?.displayName ?? L10n.string("No available harnesses"))
        let menu = MenuFlyout()
        menu.placement = .top
        for kind in harnesses {
            let item = RadioMenuFlyoutItem()
            item.text = kind.displayName
            item.groupName = "harness"
            item.isChecked = kind == harness
            if let icon = HarnessIcon.element(for: kind) { item.icon = icon }
            item.click.addHandler { [weak self] _, _ in self?.choose(kind) }
            menu.items.append(item)
        }
        if !harnesses.isEmpty { button.flyout = menu }
        return button
    }

    private func choose(_ harness: HarnessKind) {
        log.write("new task harness: \(harness.displayName)")
        guard harness != draft.harness else { return }
        draft.harness = harness
        refreshSettings()
    }

    /// The account the next task starts on (`ProviderConnectionPicker`): its name, or that it is not signed in, and a
    /// menu of the harness's accounts, with Sign in for one that needs it.
    private func accountControl(_ harness: HarnessKind) -> Button {
        let connections = model.connections
        let choices = connections.choices(for: [harness])
        let selected = choices.first { $0.connection?.id == connections.selection[harness] }
        let display = ProviderConnectionDisplay(choice: selected, automatic: connections.startsNewTasksAutomatically(for: harness))
        let control = ComposerParts.control(title: display.title, glyph: "\u{E77B}", chevron: true,
                                            name: L10n.string("Choose account"))
        try? ToolTipService.setToolTip(control, display.accessibilityTitle)
        let menu = MenuFlyout()
        menu.placement = .top
        for choice in choices {
            let item = RadioMenuFlyoutItem()
            item.text = choice.title
            item.groupName = "account"
            item.isChecked = choice.connection?.id == selected?.connection?.id
            item.isEnabled = choice.canSelect
            item.click.addHandler { [weak self] _, _ in
                guard let self else { return }
                self.model.connections.choose(choice)
                self.log.write("new task account: \(choice.title)")
                self.refreshSettings()
            }
            menu.items.append(item)
        }
        if signIn.needsSignIn(harness) {
            if !choices.isEmpty { menu.items.append(MenuFlyoutSeparator()) }
            menu.items.append(ComposerParts.menuItem(L10n.string("Sign in")) { [weak self] in self?.signIn.start(harness) })
        }
        control.flyout = menu
        return control
    }

    /// Start is on while there is a harness, a place and a message, and no task is starting.
    private func showSendable() {
        ComposerParts.setEnabled(sendButton, draft.canCreate(runtimeURL: runtimeURL))
    }

    private func textChanged() {
        let text = card.field.text
        if text != textInDraft {
            textInDraft = text
            draft.text = text
        }
        showSendable()
    }

    // MARK: Model, effort and permission

    /// Reads the account's defaults for the harness in the folder, as the Mac's new-task controls do whenever the
    /// harness or the folder changes. Nothing starts.
    private func refreshSettings() {
        settingsGeneration += 1
        let generation = settingsGeneration
        guard let harness = chosenHarness else { return }
        let connection = model.connections.selected(for: harness)
        let folder = draft.workspaceURL
        Task {
            await model.modelCatalogs.refreshDefaults(for: harness, connection: connection, workspaceURL: folder)
            if generation == settingsGeneration { showControls() }
        }
    }

    private func apply(_ value: String, to settingID: String) {
        guard let harness = chosenHarness else { return }
        switch AppModelRemoteBridge.choosing([settingID: value], harness: harness, from: draft.modelChoices[harness],
                                             model: model, connection: model.connections.selected(for: harness),
                                             folder: draft.workspaceURL, allowsConfirmed: true) {
        case let .success(chosen):
            draft.modelChoices[harness] = chosen
            log.write("new task \(settingID): \(value)")
        case let .failure(error):
            card.showNotice(error.message)
        }
    }

    /// The harness's model list, read as opening the Mac's model menu reads it: the CLI starts and lists its models,
    /// and no turn runs.
    private func readModels() async {
        guard let harness = chosenHarness, let runtime = runtimeURL else { return }
        await model.loadNewTaskModels(harness: harness, runtimeURL: runtime,
                                      connection: model.connections.selected(for: harness),
                                      workspaceURL: draft.workspaceURL)
    }

    // MARK: Start

    private func startTask() {
        // The draft takes the text as shown, the syllable being composed included.
        draft.text = card.field.text
        guard let harness = chosenHarness, !draft.refusesAttachments(options: optionsNow()) else { return }
        guard let runtime = runtimeURL else {
            card.showNotice(L10n.format("%@ is not available in Yardlet.", harness.displayName))
            return
        }
        guard let submission = draft.beginSubmission(runtimeURL: runtime,
                                                     connection: model.connections.selected(for: harness)) else { return }
        log.write("new task: \(harness.displayName)\(submission.workspaceURL.map { " in \($0.lastPathComponent)" } ?? "")")
        let previousError = model.bootstrapError
        let existingTasks = Set(model.store.sessions.map(\.id))
        showControls()
        Task {
            do {
                let created = try await model.createTask(submission)
                // A task that came to exist but whose harness did not start: chosen as it was made, it shows, as on
                // the Mac, with the message and why in its conversation, and the message stays here to try again.
                let unstartedError = created == nil ? model.store.selectedSessionID.flatMap { id in
                    existingTasks.contains(id) ? nil : model.errorBySessionID[id]
                } : nil
                let failure = created == nil
                    ? unstartedError ?? (model.bootstrapError != previousError ? model.bootstrapError : nil)
                        ?? L10n.string("The task could not start.")
                    : nil
                draft.complete(submission, succeeded: created != nil, error: failure)
                if created != nil {
                    log.write("new task started")
                    onStarted?()
                } else {
                    log.write("new task failed: \(failure ?? "")")
                    if unstartedError != nil { onStarted?() }
                }
            } catch {
                draft.complete(submission, succeeded: false, error: error.localizedDescription)
            }
            showControls()
        }
    }
}
