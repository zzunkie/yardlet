import Foundation
import UWP
// WinRT's async operations are not marked Sendable; a dialog's answer comes back on the window's thread.
@preconcurrency import WindowsFoundation
import WinUI
import YardletRemote

/// New task, as the Mac's new-task screen starts one: the harnesses whose CLI Yardlet found, where the task works
/// (a project, a folder chosen in Windows' folder dialog, or a chat with no project), the model, effort and permission
/// the harness takes before its task exists, and the message the task starts with. The choices are the Mac's
/// home draft (`ComposerDrafts.home`), so they are remembered as the Mac remembers them, and the menus are the ones
/// the Mac's new-task controls read (`ComposerSessionOptionsProjection.newTask`), as a paired computer's new task
/// lists them (`AppModelRemoteBridge.taskSettings`) and chooses them (`AppModelRemoteBridge.choosing`). A choice the
/// Mac asks about first, such as skipping permission prompts, is asked about here in the Mac's words.
@MainActor
final class NewTaskPane {
    let view = StackPanel()
    /// Called once the task has started and the model has chosen it.
    var onStarted: (() -> Void)?

    private let model: AppModel
    private let log: QAEventLog
    /// The window's handle, which owns the folder dialog.
    private let windowHandle: () -> UInt64
    private let harnessList = ListView()
    private let placeBox = ComboBox()
    private let chooseFolderButton = Button()
    /// The menus, two to a row.
    private let settingsGrid = Grid()
    private let prompt = TextBox()
    private let status = TextBlock()
    /// The harnesses the list shows, in its order.
    private var harnesses: [HarnessKind] = []
    /// What the place menu lists, in its order.
    private var places: [Place] = []
    private var lookedForRuntimes = false
    /// The harnesses whose model list was read for the menus since the pane was made.
    private var preparedModels: Set<HarnessKind> = []
    /// Set while the controls are filled, whose selection changes are then not the person's.
    private var isFilling = false
    private var settingsGeneration = 0

    private enum Place: Equatable {
        case chat
        case project(Project)
        /// A folder chosen directly that no project holds yet; the task's start makes it one.
        case folder(URL)
    }

    init(model: AppModel, log: QAEventLog, windowHandle: @escaping () -> UInt64) {
        self.model = model
        self.log = log
        self.windowHandle = windowHandle
        make()
    }

    private var draft: NewTaskDraft { model.composerDrafts.home }

    private var chosenHarness: HarnessKind? {
        let index = Int(harnessList.selectedIndex)
        return harnesses.indices.contains(index) ? harnesses[index] : nil
    }

    /// The projects the Mac's project menu lists.
    private var visibleProjects: [Project] {
        model.projects.visibleGroups(sessions: model.store.sessions).compactMap(\.project)
    }

    private func make() {
        view.spacing = 12
        view.padding = Thickness(left: 28, top: 28, right: 28, bottom: 28)
        view.maxWidth = 560
        view.horizontalAlignment = .left
        let title = TextBlock()
        title.text = L10n.string("New task")
        title.fontSize = 20
        view.children.append(title)
        let harnessTitle = TextBlock()
        harnessTitle.text = L10n.string("Harness")
        harnessTitle.opacity = 0.7
        view.children.append(harnessTitle)
        harnessList.selectionMode = .single
        harnessList.selectionChanged.addHandler { [weak self] _, _ in
            guard let self, !self.isFilling else { return }
            self.draft.harness = self.chosenHarness
            self.showPrompt()
            self.refreshSettings()
        }
        view.children.append(harnessList)

        let placeRow = StackPanel()
        placeRow.orientation = .horizontal
        placeRow.spacing = 8
        placeBox.header = L10n.string("Project")
        placeBox.minWidth = 240
        try? AutomationProperties.setName(placeBox, L10n.string("Project"))
        placeBox.selectionChanged.addHandler { [weak self] _, _ in
            guard let self, !self.isFilling else { return }
            self.choosePlace(at: Int(self.placeBox.selectedIndex))
        }
        placeRow.children.append(placeBox)
        chooseFolderButton.content = L10n.string("Choose project…")
        chooseFolderButton.verticalAlignment = .bottom
        chooseFolderButton.click.addHandler { [weak self] _, _ in self?.chooseFolder() }
        placeRow.children.append(chooseFolderButton)
        view.children.append(placeRow)

        settingsGrid.columnSpacing = 8
        settingsGrid.rowSpacing = 8
        for _ in 0..<2 {
            let column = ColumnDefinition()
            column.width = GridLength(value: 1, gridUnitType: .star)
            settingsGrid.columnDefinitions.append(column)
        }
        view.children.append(settingsGrid)

        prompt.textWrapping = .wrap
        prompt.keyDown.addHandler { [weak self] _, args in
            guard let self, let args, args.key == .enter else { return }
            args.handled = true
            self.startTask()
        }
        view.children.append(prompt)
        status.textWrapping = .wrap
        status.opacity = 0.7
        view.children.append(status)
    }

    /// Fills the pane from the draft and the harnesses found, when New task is chosen.
    func show() {
        let descriptors = model.runtimeSelections.connectedDescriptors
        harnesses = descriptors.map(\.id)
        let projects = visibleProjects
        draft.prepare(defaultProject: projects.first, availableHarnesses: harnesses)
        draft.dropUnavailableProject(visible: projects)
        // With no project to start in, a task starts as a chat, as it did before projects could be chosen here.
        if draft.workspaceURL == nil, !draft.startsChat { draft.chooseChat() }
        if let harness = draft.harness, !harnesses.contains(harness) { draft.harness = harnesses.first }

        isFilling = true
        harnessList.items.clear()
        for harness in harnesses { harnessList.items.append(harnessItem(harness)) }
        harnessList.selectedIndex = Int32(draft.harness.flatMap { harnesses.firstIndex(of: $0) } ?? (harnesses.isEmpty ? -1 : 0))
        isFilling = false
        status.text = descriptors.isEmpty ? L10n.string("Choose or install a runtime first.") : ""
        log.write("new task harnesses: \(descriptors.map(\.displayName).joined(separator: ", "))")
        showPlaces()
        showPrompt()
        refreshSettings()
        // The installs are looked for once, when the list first comes up empty.
        guard descriptors.isEmpty, !lookedForRuntimes else { return }
        lookedForRuntimes = true
        Task {
            await model.runtimeSelections.findNewest()
            if !model.runtimeSelections.connectedDescriptors.isEmpty { show() }
        }
    }

    /// A harness's row: its mark and its name, which also names the row for UI Automation.
    private func harnessItem(_ harness: HarnessKind) -> ListViewItem {
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 8
        if let icon = HarnessIcon.element(for: harness) {
            icon.verticalAlignment = .center
            row.children.append(icon)
        }
        let name = TextBlock()
        name.text = harness.displayName
        name.verticalAlignment = .center
        row.children.append(name)
        let item = ListViewItem()
        item.content = row
        try? AutomationProperties.setName(item, harness.displayName)
        return item
    }

    private func showPrompt() {
        prompt.placeholderText = chosenHarness.map { L10n.format("What should %@ work on?", $0.displayName) } ?? ""
    }

    // MARK: Where the task works

    /// Chat (no project), the projects, and a folder chosen directly, the one the draft names chosen.
    private func showPlaces() {
        let projects = visibleProjects
        places = [.chat] + projects.map(Place.project)
        let current: Place
        if draft.startsChat {
            current = .chat
        } else if let folder = draft.workspaceURL {
            if let project = draft.projectID.flatMap({ id in projects.first { $0.id == id } })
                ?? projects.first(where: { $0.contains(root: folder) }) {
                current = .project(project)
            } else {
                current = .folder(folder)
                places.append(current)
            }
        } else {
            current = .chat
        }
        isFilling = true
        placeBox.items.clear()
        for place in places {
            switch place {
            case .chat: placeBox.items.append(L10n.string("Chat (no project)"))
            case let .project(project): placeBox.items.append(project.name)
            case let .folder(url): placeBox.items.append(url.lastPathComponent)
            }
        }
        placeBox.selectedIndex = Int32(places.firstIndex(of: current) ?? 0)
        isFilling = false
    }

    private func choosePlace(at index: Int) {
        guard places.indices.contains(index) else { return }
        switch places[index] {
        case .chat:
            draft.chooseChat()
            log.write("new task place: chat")
        case let .project(project):
            draft.projectID = project.id
            draft.workspaceURL = project.primaryRoot
            log.write("new task place: \(project.name)")
        case .folder:
            return
        }
        refreshSettings()
    }

    /// Choose project…: a folder from Windows' own dialog, in the project that holds it or as a folder the task's
    /// start makes a project, as the Mac's Choose project… does.
    private func chooseFolder() {
        guard let folder = WindowsFolderPicker.chooseFolder(window: windowHandle(), title: L10n.string("Choose project"))
        else { return }
        draft.workspaceURL = folder
        draft.projectID = visibleProjects.first { $0.contains(root: folder) }?.id
        log.write("new task place: \(folder.lastPathComponent)")
        showPlaces()
        refreshSettings()
    }

    // MARK: Model, effort and permission

    /// Reads the account's defaults for the harness in the folder, as the Mac's new-task controls do whenever the
    /// harness or the folder changes, then shows the menus. Nothing starts.
    private func refreshSettings() {
        settingsGeneration += 1
        let generation = settingsGeneration
        showSettings()
        guard let harness = chosenHarness else { return }
        let connection = model.connections.selected(for: harness)
        let folder = draft.workspaceURL
        Task {
            await model.modelCatalogs.refreshDefaults(for: harness, connection: connection, workspaceURL: folder)
            if generation == settingsGeneration { showSettings() }
        }
    }

    private func showSettings() {
        settingsGrid.children.clear()
        settingsGrid.rowDefinitions.clear()
        guard let harness = chosenHarness else { return }
        let settings = AppModelRemoteBridge.taskSettings(options(for: harness)).filter { !$0.choices.isEmpty }
        isFilling = true
        for (index, setting) in settings.enumerated() {
            if index % 2 == 0 {
                let row = RowDefinition()
                row.height = GridLength(value: 0, gridUnitType: .auto)
                settingsGrid.rowDefinitions.append(row)
            }
            let box = settingBox(setting, harness: harness)
            try? Grid.setRow(box, Int32(index / 2))
            try? Grid.setColumn(box, Int32(index % 2))
            settingsGrid.children.append(box)
        }
        isFilling = false
        if settings.contains(where: { $0.prepare == true }) { readModels(for: harness) }
    }

    private func options(for harness: HarnessKind) -> ComposerSessionOptions {
        ComposerSessionOptionsProjection.newTask(harness: harness, choice: draft.modelChoices[harness],
                                                 catalogs: model.modelCatalogs,
                                                 connection: model.connections.selected(for: harness),
                                                 workspaceURL: draft.workspaceURL)
    }

    /// One menu: its name, its choices, the value now, which is shown even before the list that names it is read.
    private func settingBox(_ setting: RemoteSetting, harness: HarnessKind) -> ComboBox {
        // The value now leads when the list does not name it yet.
        let leads = !setting.value.isEmpty && !setting.choices.contains { $0.value == setting.value }
        let values = (leads ? [setting.value] : []) + setting.choices.map(\.value)
        let names = (leads ? [setting.title ?? setting.value] : []) + setting.choices.map(\.name)
        let box = ComboBox()
        box.header = setting.name
        box.horizontalAlignment = .stretch
        try? AutomationProperties.setName(box, setting.name)
        for name in names { box.items.append(name) }
        box.selectedIndex = Int32(values.firstIndex(of: setting.value) ?? -1)
        box.selectionChanged.addHandler { [weak self, weak box] _, _ in
            guard let self, let box, !self.isFilling else { return }
            let index = Int(box.selectedIndex)
            guard values.indices.contains(index), values[index] != setting.value else { return }
            self.choose(values[index], in: setting, harness: harness)
        }
        return box
    }

    private func choose(_ value: String, in setting: RemoteSetting, harness: HarnessKind) {
        guard let confirmation = setting.choices.first(where: { $0.value == value })?.confirm else {
            apply(value, to: setting.id, harness: harness)
            return
        }
        let dialog = ContentDialog()
        dialog.title = confirmation.title
        dialog.content = confirmation.message
        dialog.primaryButtonText = confirmation.button
        dialog.closeButtonText = L10n.string("Cancel")
        dialog.xamlRoot = view.xamlRoot
        Task {
            guard let result = try? await dialog.showAsync()?.get(), result == .primary else {
                showSettings()
                return
            }
            apply(value, to: setting.id, harness: harness)
        }
    }

    private func apply(_ value: String, to settingID: String, harness: HarnessKind) {
        switch AppModelRemoteBridge.choosing([settingID: value], harness: harness, from: draft.modelChoices[harness],
                                             model: model, connection: model.connections.selected(for: harness),
                                             folder: draft.workspaceURL, allowsConfirmed: true) {
        case let .success(chosen):
            draft.modelChoices[harness] = chosen
            log.write("new task \(settingID): \(value)")
        case let .failure(error):
            status.text = error.message
        }
        // Drawn again after the menu that changed has finished its own change.
        Task { showSettings() }
    }

    /// The harness's model list, read once as opening the Mac's model menu reads it: the CLI starts and lists its
    /// models, and no turn runs.
    private func readModels(for harness: HarnessKind) {
        guard preparedModels.insert(harness).inserted, let runtime = model.runtimeSelections.selectedURL(for: harness)
        else { return }
        let connection = model.connections.selected(for: harness)
        let folder = draft.workspaceURL
        Task {
            await model.loadNewTaskModels(harness: harness, runtimeURL: runtime, connection: connection, workspaceURL: folder)
            if chosenHarness == harness { showSettings() }
        }
    }

    // MARK: Start

    private func startTask() {
        let text = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let harness = chosenHarness else { return }
        guard let runtime = model.runtimeSelections.selectedURL(for: harness) else {
            status.text = L10n.format("%@ is not available in Yardlet.", harness.displayName)
            return
        }
        draft.harness = harness
        draft.text = text
        guard let submission = draft.beginSubmission(runtimeURL: runtime,
                                                     connection: model.connections.selected(for: harness)) else { return }
        status.text = ""
        prompt.isEnabled = false
        log.write("new task: \(harness.displayName)\(submission.workspaceURL.map { " in \($0.lastPathComponent)" } ?? "")")
        let previousError = model.bootstrapError
        Task {
            defer { prompt.isEnabled = true }
            do {
                let created = try await model.createTask(submission)
                let failure = created == nil
                    ? (model.bootstrapError != previousError ? model.bootstrapError : nil) ?? L10n.string("The task could not start.")
                    : nil
                draft.complete(submission, succeeded: created != nil, error: failure)
                if created != nil {
                    prompt.text = ""
                    log.write("new task started")
                    onStarted?()
                } else {
                    status.text = failure ?? ""
                }
            } catch {
                draft.complete(submission, succeeded: false, error: error.localizedDescription)
                status.text = error.localizedDescription
            }
        }
    }
}
