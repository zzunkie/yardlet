import SwiftUI
import YardletRemote

/// The host's home, as the local window's: the host's projects with what their tasks need (`NewTaskHomeLists`, read
/// from the lists the sidebar reads), then the title naming the project the new task starts in, which is its menu, and
/// the composer (docs/REMOTE_PROTOCOL.md §15.5, §15.16): the harness, model, effort and permission mode the host's
/// new-task composer offers, a new worktree where the project is a Git repository, and the first message. The choices
/// apply to this task only; the host's own new-task composer keeps its own. What is chosen and the start are the
/// engine's (`RemoteNewTaskForm`), as the Windows host window's New task reads them.
struct RemoteNewTaskView: View {
    let model: RemoteHostModel
    @Bindable var draft: TaskComposerDraft
    /// The project New task in a project chose from the sidebar, which the screen starts in once.
    @Binding var chosenProjectID: String?
    /// The desk's today: an event shown on the host's calendar, a run's schedule opened among the host's schedules.
    var onOpenEvent: (CalendarEvent) -> Void = { _ in }
    var onOpenSchedule: (UUID) -> Void = { _ in }
    /// The project, harness, account and settings chosen, as the host answers them, and the start (`RemoteNewTaskForm`).
    @State private var form: RemoteNewTaskForm
    @State private var showsAccounts = false
    @State private var showsCommands = false
    @State private var showsTypedCommands = false
    @State private var commandSearch = ""
    @State private var mentionIndex = RemoteComposerMentionIndex()
    @AppStorage(SendShortcut.preferenceKey) private var sendShortcut = SendShortcut.return
    @FocusState private var isFocused: Bool
    @State private var listKeyboard = NewTaskHomeListKeyboard()
    @FocusState private var listFocus: NewTaskHomeLists.Part?
    /// The desk and the remembered view, as the local home's (`DeskPreview`, `NewTaskHomeView.key`).
    @AppStorage(DeskPreview.key, store: .yardlet) private var showsDeskPreview = false
    @AppStorage(NewTaskHomeView.key, store: .yardlet) private var homeView = NewTaskHomeView.now
    /// What the host's projects count, for the header over them.
    @State private var projectFacts = NewTaskHomeProjectFacts()

    init(model: RemoteHostModel, draft: TaskComposerDraft, chosenProjectID: Binding<String?>,
         onOpenEvent: @escaping (CalendarEvent) -> Void = { _ in }, onOpenSchedule: @escaping (UUID) -> Void = { _ in }) {
        self.model = model
        self.draft = draft
        _chosenProjectID = chosenProjectID
        self.onOpenEvent = onOpenEvent
        self.onOpenSchedule = onOpenSchedule
        _form = State(initialValue: RemoteNewTaskForm(model: model, draft: draft))
    }

    private var projects: [RemoteProject] { form.projects }

    /// No project and no task on the host yet: the title and the composer alone, with no view to switch to.
    private var isFirstRun: Bool { model.sidebar.sessions.isEmpty && !projects.contains { $0.kind != .chats } }

    private var showsViewSwitch: Bool { showsDeskPreview && !isFirstRun }

    private var showsDesk: Bool { showsViewSwitch && homeView == .now }

    var body: some View {
        GeometryReader { viewport in
            if showsDesk {
                // The host's desk, as the local home's: what the host's tasks wait on, what runs and what finished.
                // Today and the unread mail are the host's, read through it (§15.38).
                DeskHome(
                    activity: activity, size: viewport.size, onAction: perform,
                    keyboard: $listKeyboard, focus: $listFocus,
                    onListed: { listKeyboard.list($0) }, onReturnToComposer: { isFocused = true },
                    viewSwitch: { NewTaskHomeViewSwitch(selection: $homeView) },
                    bottom: { newTask })
            } else {
                projectsView(viewport: viewport)
            }
        }
        .onAppear {
            form.appear()
            isFocused = true
        }
        .onChange(of: chosenProjectID, initial: true) { _, chosen in
            guard let chosen, form.take(chosenProjectID: chosen) else { return }
            chosenProjectID = nil
        }
        .alert(form.startConfirmation?.choices.first { $0.value == form.startConfirmation?.value }?.confirm?.title ?? "",
            isPresented: Binding(get: { form.startConfirmation != nil }, set: { if !$0 { form.startConfirmation = nil } }),
            presenting: form.startConfirmation) { setting in
                Button(L10n.string("Cancel"), role: .cancel) {}
                Button(setting.choices.first { $0.value == setting.value }?.confirm?.button ?? "", role: .destructive) {
                    form.confirmStart()
                }
            } message: { setting in
                Text(setting.choices.first { $0.value == setting.value }?.confirm?.message ?? "")
            }
        .task(id: form.optionsKey) {
            await form.readOptions()
        }
    }

    /// The host's projects with what their tasks need, as the local home lists this Mac's, the header with the
    /// view switch over them while the desk can be chosen.
    private func projectsView(viewport: GeometryProxy) -> some View {
        let columns = NewTaskHomeLayout.columns(width: viewport.size.width)
        return VStack(spacing: 0) {
            if showsViewSwitch {
                DeskHeader(date: Date(), summary: projectFacts.summary) { NewTaskHomeViewSwitch(selection: $homeView) }
                    .modifier(DeskHeaderPlacement(width: viewport.size.width))
            }
            ScrollView {
                homeLists(viewport: viewport, columns: columns)
                    .frame(maxWidth: columns > 1 ? NewTaskHomeLayout.gridWidth : NewTaskHomeLayout.composerWidth)
                    .padding(.horizontal, NewTaskHomeLayout.inset)
                    .padding(.top, showsViewSwitch ? 4 : 28)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.top)
            newTask
                .frame(maxWidth: NewTaskHomeLayout.composerWidth)
                .padding(.horizontal, NewTaskHomeLayout.inset)
                .padding(.top, 14)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
        }
    }

    /// The title naming the project the new task starts in, which is its menu, and the composer.
    private var newTask: some View {
        VStack(spacing: 0) {
            NewTaskHeroTitle(
                kind: form.heroKind,
                onClearProject: isChat ? nil : { form.projectID = RemoteTaskProjection.chatsProjectID }
            ) { destinationMenuItems }
            if isChat {
                NewTaskDestinationButton(title: L10n.string("Chat (no project)"), systemName: "bubble.left") {
                    destinationMenuItems
                }
                .padding(.top, 8)
            }
            composer
                .padding(.top, 20)
        }
    }

    /// The project's files on the host for an @ mention, when the host offers them.
    private var mentionSearch: (@MainActor (String) async -> WorkspaceFileSearchResult)? {
        guard model.composerExtensions, let projectID = form.projectID, !isChat else { return nil }
        return { query in
            await mentionIndex.search(query, key: projectID) {
                await model.response(to: .projectWorkspaceFiles(projectID: projectID))
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ComposerEditor(
                draft: draft, placeholder: NewTaskComposerText.placeholder(harnessName: form.harnessName),
                accessibilityHint: sendShortcut.sendKeyName.isEmpty ? nil : L10n.format("Press %@ to start the task", sendShortcut.sendKeyName), metrics: .newTask,
                input: nil, onExternalInput: form.acceptsAttachments ? { receive($0) } : nil, mentionRoots: [],
                mentionSearch: mentionSearch,
                onInsertMention: { RemoteComposerMentionIndex.insert($0, replacing: $1, into: draft) },
                commands: editorCommands,
                isCommandMenuOpen: showsCommands, isMenuOpen: showsCommands || showsAccounts,
                showsChips: !draft.hostMentions.isEmpty, isFocused: $isFocused, onSubmit: form.start,
                onCommandQueryChange: { old, query in
                    showsTypedCommands = query != nil
                    if old == nil, query != nil { Task { await form.loadCommands() } }
                }
            ) {
                EmptyView()
            } chips: {
                RemoteComposerMentionChips(draft: draft)
            } footer: {
                if let line = form.options?.accountLine {
                    NewTaskAccountExplanation(line: line)
                        .padding(.horizontal, 16).padding(.bottom, 6)
                }
                NewTaskComposerControlRow {
                    commandMenu
                    if let worktree = form.worktree {
                        Toggle(L10n.string("New worktree"), isOn: Binding(get: { worktree }, set: { form.worktree = $0 }))
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                    }
                    harnessMenu
                } secondary: {
                    accountPicker
                    if model.composerExtensions {
                        ComposerSessionControls(options: form.sessionOptions, placement: .leading,
                            isDisabled: form.isStarting, onChoose: form.choose, onPrepare: form.readOptions)
                    } else {
                        ForEach(form.options?.settings ?? [], id: \.id) { setting in settingMenu(setting) }
                    }
                } trailing: {
                    if model.composerExtensions {
                        ComposerSessionControls(options: form.sessionOptions, placement: .trailing,
                            isDisabled: form.isStarting, onChoose: form.choose, onPrepare: form.readOptions,
                            shortensModelToFit: true)
                    }
                    NewTaskStartControl(canStart: form.canStart, isStarting: form.isStarting,
                        commandMenuOpen: showsCommands || showsTypedCommands, onStart: form.start)
                }
            }
            if let error = model.commandError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: The home's lists

    /// The host's tasks as the local home reads this Mac's (`RemoteHostModel.newTaskHomeActivity`).
    private var activity: NewTaskHomeActivity { model.newTaskHomeActivity() }

    private func homeLists(viewport: GeometryProxy, columns: Int) -> NewTaskHomeLists {
        let mirror = model.sidebar
        let names = Dictionary(mirror.groups.map { ($0.workspaceURL, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        return NewTaskHomeLists(
            part: .projects, folder: nil, startsChat: isChat, canUseWorktree: false, startsInNewWorktree: false, git: .none,
            activity: activity, rowLimit: NewTaskHomeListsProjection.rowLimit(windowHeight: viewport.size.height),
            columns: columns, selectedProjectID: isChat ? nil : form.projectID.flatMap(UUID.init(uuidString:)),
            recentSessions: mirror.sessions.sorted { $0.updatedAt > $1.updatedAt },
            projectName: { names[$0.workspaceURL.standardizedFileURL] ?? $0.workspaceURL.lastPathComponent },
            onSelectSession: { model.select(.task($0.id.uuidString)) },
            onAction: perform,
            keyboard: $listKeyboard, focus: $listFocus,
            onListed: { _, entries in listKeyboard.list(entries) },
            onReturnToComposer: { isFocused = true },
            // The host's folders are the host's: nothing here reads them.
            readFolderGit: { _ in .none }, readLeftWork: { _ in nil },
            onFacts: { facts in if facts != projectFacts { projectFacts = facts } })
    }

    private func perform(_ action: NewTaskHomeAction) {
        switch action {
        // The host's task opens here; answering it in the composer's place is the local home's alone for now.
        case let .openTask(id), let .reply(id):
            model.select(.task(id.uuidString))
        case let .draft(prompt):
            draft.text = draft.text.isEmpty ? prompt : draft.text + "\n\n" + prompt
            isFocused = true
        case .useNewWorktree:
            if form.worktree != nil { form.worktree = true }
            isFocused = true
        case let .chooseProject(id):
            form.projectID = id.uuidString
            isFocused = true
        case .chooseChat:
            form.projectID = RemoteTaskProjection.chatsProjectID
            isFocused = true
        case let .openSchedule(id):
            onOpenSchedule(id)
        case let .openEvent(event):
            onOpenEvent(event)
        }
    }

    private var isChat: Bool { form.isChat }

    @ViewBuilder
    private var destinationMenuItems: some View {
        ForEach(projects.filter { $0.kind != .chats }, id: \.id) { project in
            Button(project.name) { form.projectID = project.id }
        }
        Divider()
        Button(L10n.string("Chat (no project)")) { form.projectID = RemoteTaskProjection.chatsProjectID }
    }

    private var harnessMenu: some View {
        NewTaskHarnessControl(harness: form.harnessID.map(HarnessKind.init(rawValue:))) {
            ForEach(form.options?.harnesses ?? [], id: \.harness) { option in
                Button {
                    form.chooseHarness(option.harness)
                } label: {
                    HarnessIdentityLabel(harness: HarnessKind(rawValue: option.harness))
                }
            }
        }
    }

    @ViewBuilder private var accountPicker: some View {
        if let accounts = form.options?.accounts, !accounts.isEmpty {
            let title = accounts.first { $0.id == form.accountID }?.name
                ?? accounts.first { $0.current == true }?.name ?? L10n.string("Account unavailable")
            ProviderConnectionControl(title: title, accessibilityTitle: title) {
                showsAccounts = true
                Task { await form.readOptions() }
            }
                .fixedSize(horizontal: true, vertical: false)
                .popover(isPresented: $showsAccounts) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(accounts, id: \.id) { account in
                            Button {
                                form.chooseAccount(account.id)
                                showsAccounts = false
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(account.name)
                                    if let detail = account.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain).padding(6)
                            .disabled(account.available != true)
                        }
                    }.padding(8).frame(width: 300)
                }
        }
    }

    private var commandRows: [ProviderComposerCommand] {
        form.commands.map { ProviderComposerCommand(name: $0.name, description: $0.description ?? "",
            argumentHint: $0.argumentHint ?? "", title: $0.title, group: $0.group) }
    }

    private var editorCommands: ComposerEditorCommands? {
        guard model.composerExtensions, form.chosenHarness?.harness == HarnessKind.claudeCode.rawValue, !isChat else { return nil }
        return ComposerEditorCommands(commands: commandRows, isLoading: form.loadingCommands, choose: insertCommand)
    }

    private func insertCommand(_ command: ProviderComposerCommand) {
        showsCommands = false
        ComposerFieldEditor.insert(command, into: draft, isFocused: $isFocused)
    }

    @ViewBuilder private var commandMenu: some View {
        if model.composerExtensions, form.chosenHarness?.harness == HarnessKind.claudeCode.rawValue {
            Button { commandSearch = ""; showsCommands = true; Task { await form.loadCommands() } } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary).frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless).parityPointer()
            .accessibilityLabel(L10n.string("Slash commands"))
            .disabled(isChat || form.isStarting)
            .popover(isPresented: $showsCommands) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("Slash commands")).font(.callout.weight(.semibold))
                    TextField(L10n.string("Search commands"), text: $commandSearch).textFieldStyle(.roundedBorder)
                    ComposerCommandPicker(commands: commandRows, query: commandSearch, isLoading: form.loadingCommands,
                                          onSelect: insertCommand)
                }.padding(8).frame(width: 340)
            }
        }
    }

    private func settingMenu(_ setting: RemoteSetting) -> some View {
        Menu {
            ForEach(setting.choices, id: \.value) { choice in
                Button(choice.name) { form.pick(setting.id, choice.value) }
            }
        } label: {
            Text(setting.choices.first { $0.value == (form.picks[setting.id] ?? setting.value) }?.name ?? setting.value)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(setting.name)
        .accessibilityLabel(setting.name)
    }

    private func receive(_ input: ComposerExternalInput) {
        switch input {
        case let .files(urls):
            for url in urls { RemoteAttachments.add(url, to: draft) }
        case let .image(data, type):
            guard let png = ComposerExternalInput.pngData(data, type: type), let url = RemoteAttachments.write(png) else { return }
            draft.attachments.append(.localImage(url))
        }
    }
}
