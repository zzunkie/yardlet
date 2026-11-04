import SwiftUI
import YardletRemote

/// The host's home, as the local window's: the host's projects with what their tasks need (`NewTaskHomeLists`, read
/// from the lists the sidebar reads), then the title naming the project the new task starts in, which is its menu, and
/// the composer (docs/REMOTE_PROTOCOL.md §15.5, §15.16): the harness, model, effort and permission mode the host's
/// new-task composer offers, a new worktree where the project is a Git repository, and the first message. The choices
/// apply to this task only; the host's own new-task composer keeps its own.
struct RemoteNewTaskView: View {
    let model: RemoteHostModel
    @Bindable var draft: TaskComposerDraft
    /// The project New task in a project chose from the sidebar, which the screen starts in once.
    @Binding var chosenProjectID: String?
    @State private var projectID: String?
    @State private var options: RemoteResponse?
    @State private var harness: String?
    @State private var picks: [String: String] = [:]
    @State private var worktree: Bool?
    @State private var isStarting = false
    @State private var accountID: String?
    @State private var confirmedChoices: [String: String] = [:]
    @State private var showsAccounts = false
    @State private var startConfirmation: RemoteSetting?
    @State private var showsCommands = false
    @State private var showsTypedCommands = false
    @State private var commandSearch = ""
    @State private var commands: [RemoteComposerCommand] = []
    @State private var commandContext: String?
    @State private var loadingCommands = false
    @State private var optionReadID: UUID?
    @State private var mentionIndex = RemoteComposerMentionIndex()
    @FocusState private var isFocused: Bool
    @State private var listKeyboard = NewTaskHomeListKeyboard()
    @FocusState private var listFocus: NewTaskHomeLists.Part?

    /// The host's projects that take tasks, and Chats, which the host's own new-task menu always offers and which it
    /// takes before it lists any chat (§15.5).
    private var projects: [RemoteProject] {
        var projects = model.projects.filter { $0.canCreateTask == true }
        if !projects.contains(where: { $0.kind == .chats }) {
            projects.append(RemoteProject(id: RemoteTaskProjection.chatsProjectID, name: L10n.string("Chats"), kind: .chats,
                                          canCreateTask: true))
        }
        return projects
    }

    var body: some View {
        GeometryReader { viewport in
            let columns = NewTaskHomeLayout.columns(width: viewport.size.width)
            VStack(spacing: 0) {
                // The host's projects with what their tasks need, as the local home lists this Mac's.
                ScrollView {
                    homeLists(viewport: viewport, columns: columns)
                        .frame(maxWidth: columns > 1 ? NewTaskHomeLayout.gridWidth : NewTaskHomeLayout.composerWidth)
                        .padding(.horizontal, NewTaskHomeLayout.inset)
                        .padding(.top, 28)
                        .padding(.bottom, 16)
                        .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.top)
                VStack(spacing: 0) {
                    NewTaskHeroTitle(kind: heroKind) { destinationMenuItems }
                    if projectID == nil || isChat {
                        NewTaskDestinationButton(title: L10n.string(isChat ? "Chat (no project)" : "Choose project"),
                                                 systemName: isChat ? "bubble.left" : "folder") {
                            destinationMenuItems
                        }
                        .padding(.top, 8)
                    }
                    composer
                        .padding(.top, 20)
                }
                .frame(maxWidth: NewTaskHomeLayout.composerWidth)
                .padding(.horizontal, NewTaskHomeLayout.inset)
                .padding(.top, 14)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            if projectID == nil {
                projectID = projects.first(where: { $0.kind != .chats })?.id
            }
            isFocused = true
        }
        .onChange(of: chosenProjectID, initial: true) { _, chosen in
            guard let chosen, projects.contains(where: { $0.id == chosen }) else { return }
            projectID = chosen
            chosenProjectID = nil
        }
        .alert(startConfirmation?.choices.first { $0.value == startConfirmation?.value }?.confirm?.title ?? "",
            isPresented: Binding(get: { startConfirmation != nil }, set: { if !$0 { startConfirmation = nil } }),
            presenting: startConfirmation) { setting in
                Button(L10n.string("Cancel"), role: .cancel) {}
                Button(setting.choices.first { $0.value == setting.value }?.confirm?.button ?? "", role: .destructive) {
                    confirmedChoices[setting.id] = setting.value
                    startConfirmation = nil
                    start()
                }
            } message: { setting in
                Text(setting.choices.first { $0.value == setting.value }?.confirm?.message ?? "")
            }
        .task(id: OptionsKey(projectID: projectID, harness: harness, picks: picks, accountID: accountID, connected: model.isConnected)) {
            await readOptions()
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ComposerEditor(
                draft: draft, placeholder: NewTaskComposerText.placeholder(harnessName: chosenHarness?.harnessName ?? model.newTask?.harnessName),
                accessibilityHint: L10n.string("Press Return to start the task"), metrics: .newTask,
                input: nil, onExternalInput: acceptsAttachments ? { receive($0) } : nil, mentionRoots: [],
                mentionSearch: model.composerExtensions && projectID != nil && !isChat ? { query in
                    guard let projectID else { return .init() }
                    return await mentionIndex.search(query, key: projectID) {
                        await model.response(to: .projectWorkspaceFiles(projectID: projectID))
                    }
                } : nil,
                onInsertMention: { RemoteComposerMentionIndex.insert($0, replacing: $1, into: draft) },
                commands: editorCommands,
                isCommandMenuOpen: showsCommands, isMenuOpen: showsCommands || showsAccounts,
                showsChips: !draft.hostMentions.isEmpty, isFocused: $isFocused, onSubmit: start,
                onCommandQueryChange: { old, query in
                    showsTypedCommands = query != nil
                    if old == nil, query != nil { Task { await loadCommands() } }
                }
            ) {
                EmptyView()
            } chips: {
                RemoteComposerMentionChips(draft: draft)
            } footer: {
                if let line = options?.accountLine {
                    NewTaskAccountExplanation(line: line)
                        .padding(.horizontal, 16).padding(.bottom, 6)
                }
                NewTaskComposerControlRow {
                    commandMenu
                    if let worktree {
                        Toggle(L10n.string("New worktree"), isOn: Binding(get: { worktree }, set: { self.worktree = $0 }))
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                    }
                    harnessMenu
                } secondary: {
                    accountPicker
                    if model.composerExtensions {
                        ComposerSessionControls(options: sessionOptions, placement: .leading,
                            isDisabled: isStarting, onChoose: choose, onPrepare: readOptions)
                    } else {
                        ForEach(options?.settings ?? [], id: \.id) { setting in settingMenu(setting) }
                    }
                } trailing: {
                    if model.composerExtensions {
                        ComposerSessionControls(options: sessionOptions, placement: .trailing,
                            isDisabled: isStarting, onChoose: choose, onPrepare: readOptions)
                    }
                    NewTaskStartControl(canStart: canStart, isStarting: isStarting,
                        commandMenuOpen: showsCommands || showsTypedCommands, onStart: start)
                }
            }
            if let error = model.commandError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: The home's lists

    /// The host's tasks as the local home reads this Mac's (`NewTaskHomeActivity`), from the lists the sidebar reads.
    var activity: NewTaskHomeActivity {
        let mirror = model.sidebar
        let names = Dictionary(mirror.groups.flatMap { group in group.sessions.map { ($0.id, group.displayName) } },
                               uniquingKeysWith: { first, _ in first })
        var activity = NewTaskHomeActivity()
        activity.sessions = mirror.sessions
        activity.details = mirror.details
        activity.groups = mirror.groups
        activity.chats = mirror.chats
        activity.answerLine = { mirror.answerLines[$0] }
        activity.latestTurn = { mirror.latestTurns[$0] }
        activity.placeName = { names[$0.id] ?? L10n.string("Chats") }
        activity.onMarkRead = { [model] ids in for id in ids { model.send(.markRead(taskID: id.uuidString)) } }
        return activity
    }

    private func homeLists(viewport: GeometryProxy, columns: Int) -> NewTaskHomeLists {
        let mirror = model.sidebar
        let names = Dictionary(mirror.groups.map { ($0.workspaceURL, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        return NewTaskHomeLists(
            part: .projects, folder: nil, startsChat: isChat, canUseWorktree: false, startsInNewWorktree: false, git: .none,
            activity: activity, rowLimit: NewTaskHomeListsProjection.rowLimit(windowHeight: viewport.size.height),
            columns: columns, selectedProjectID: isChat ? nil : projectID.flatMap(UUID.init(uuidString:)),
            recentSessions: mirror.sessions.sorted { $0.updatedAt > $1.updatedAt },
            projectName: { names[$0.standardizedFileURL] ?? $0.lastPathComponent },
            onSelectSession: { model.select(.task($0.id.uuidString)) },
            onAction: perform,
            keyboard: $listKeyboard, focus: $listFocus,
            onListed: { _, entries in listKeyboard.list(entries) },
            onReturnToComposer: { isFocused = true },
            // The host's folders are the host's: nothing here reads them.
            readFolderGit: { _ in .none }, readLeftWork: { _ in nil })
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
            if worktree != nil { worktree = true }
            isFocused = true
        case let .chooseProject(id):
            projectID = id.uuidString
            isFocused = true
        case .chooseChat:
            projectID = RemoteTaskProjection.chatsProjectID
            isFocused = true
        case .openSchedule:
            break
        }
    }

    private var isChat: Bool { projects.first { $0.id == projectID }?.kind == .chats }

    /// The title over the composer, as the local home's: what to work on in the chosen project, its name the menu of
    /// the host's projects and Chats.
    private var heroKind: NewTaskHeroTitleKind {
        guard let project = projects.first(where: { $0.id == projectID }), project.kind != .chats else { return .noProject }
        return .workOn(project: NewTaskHeroTitleKind.shortened(project.name))
    }

    @ViewBuilder
    private var destinationMenuItems: some View {
        ForEach(projects.filter { $0.kind != .chats }, id: \.id) { project in
            Button(project.name) { projectID = project.id }
        }
        Divider()
        Button(L10n.string("Chat (no project)")) { projectID = RemoteTaskProjection.chatsProjectID }
    }

    private struct OptionsKey: Equatable {
        var projectID: String?
        var harness: String?
        var picks: [String: String]
        var accountID: String?
        var connected: Bool
    }

    private var canStart: Bool {
        model.isConnected && !isStarting && optionReadID == nil && projectID != nil
            && (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.hostMentions.isEmpty)
    }

    private var chosenHarness: RemoteHarnessOption? {
        options?.harnesses?.first { $0.harness == (harness ?? options?.harness) }
    }

    private var acceptsAttachments: Bool { chosenHarness?.acceptsImages == true || chosenHarness?.acceptsFiles == true }

    private var harnessMenu: some View {
        NewTaskHarnessControl(harness: (harness ?? options?.harness ?? model.newTask?.harness).map(HarnessKind.init(rawValue:))) {
            ForEach(options?.harnesses ?? [], id: \.harness) { option in
                Button {
                    harness = option.harness
                    picks = [:]
                    confirmedChoices = [:]
                    accountID = nil
                } label: {
                    HarnessIdentityLabel(harness: HarnessKind(rawValue: option.harness))
                }
            }
        }
    }

    private var sessionOptions: ComposerSessionOptions {
        RemoteTaskSettingsProjection.options(options?.settings ?? [], task: RemoteTask(
            id: "", title: "", harness: harness ?? options?.harness ?? "claude-code",
            harnessName: chosenHarness?.harnessName ?? "", projectId: projectID, attention: .idle, lastActivityAt: 0))
    }

    private func choose(_ choice: ComposerSessionChoice) {
        guard case let .providerOption(id, value) = choice else { return }
        if options?.settings?.first(where: { $0.id == id })?.choices.first(where: { $0.value == value })?.confirm != nil {
            confirmedChoices[id] = value
        } else {
            confirmedChoices[id] = nil
        }
        picks[id] = value
    }

    @ViewBuilder private var accountPicker: some View {
        if let accounts = options?.accounts, !accounts.isEmpty {
            let title = accounts.first { $0.id == accountID }?.name
                ?? accounts.first { $0.current == true }?.name ?? L10n.string("Account unavailable")
            ProviderConnectionControl(title: title, accessibilityTitle: title) {
                showsAccounts = true
                Task { await readOptions() }
            }
                .fixedSize(horizontal: true, vertical: false)
                .popover(isPresented: $showsAccounts) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(accounts, id: \.id) { account in
                            Button {
                                accountID = account.id
                                picks = [:]
                                confirmedChoices = [:]
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
        commands.map { ProviderComposerCommand(name: $0.name, description: $0.description ?? "",
            argumentHint: $0.argumentHint ?? "", title: $0.title, group: $0.group) }
    }

    private var editorCommands: ComposerEditorCommands? {
        guard model.composerExtensions, chosenHarness?.harness == HarnessKind.claudeCode.rawValue, projectID != nil, !isChat else { return nil }
        return ComposerEditorCommands(commands: commandRows, isLoading: loadingCommands, choose: insertCommand)
    }

    private func insertCommand(_ command: ProviderComposerCommand) {
        showsCommands = false
        ComposerFieldEditor.insert(command, into: draft, isFocused: $isFocused)
    }

    @ViewBuilder private var commandMenu: some View {
        if model.composerExtensions, chosenHarness?.harness == HarnessKind.claudeCode.rawValue {
            Button { commandSearch = ""; showsCommands = true; Task { await loadCommands() } } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary).frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless).parityPointer()
            .accessibilityLabel(L10n.string("Slash commands"))
            .disabled(projectID == nil || isChat || isStarting)
            .popover(isPresented: $showsCommands) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("Slash commands")).font(.callout.weight(.semibold))
                    TextField(L10n.string("Search commands"), text: $commandSearch).textFieldStyle(.roundedBorder)
                    ComposerCommandPicker(commands: commandRows, query: commandSearch, isLoading: loadingCommands, onSelect: insertCommand)
                }.padding(8).frame(width: 340)
            }
        }
    }

    private func settingMenu(_ setting: RemoteSetting) -> some View {
        Menu {
            ForEach(setting.choices, id: \.value) { choice in
                Button(choice.name) { picks[setting.id] = choice.value }
            }
        } label: {
            Text(setting.choices.first { $0.value == (picks[setting.id] ?? setting.value) }?.name ?? setting.value)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(setting.name)
        .accessibilityLabel(setting.name)
    }

    private func readOptions() async {
        guard model.isConnected else { return }
        let requestID = UUID()
        optionReadID = requestID
        defer { if optionReadID == requestID { optionReadID = nil } }
        let response = await model.response(to: .newTaskOptions(projectID: projectID, harness: harness, settings: picks, accountID: accountID, composer: model.composerExtensions))
        guard !Task.isCancelled, optionReadID == requestID else { return }
        guard response.ok else {
            model.commandError = RemoteHostModel.message(for: response.error, host: model.name)
            return
        }
        options = response
        let key = [projectID ?? "", harness ?? response.harness ?? "", accountID ?? ""].joined(separator: "\n")
        if commandContext != key { commands = []; commandContext = nil }
        if worktree == nil || response.worktree == nil { worktree = response.worktree }
    }

    private func loadCommands() async {
        let key = [projectID ?? "", harness ?? options?.harness ?? "", accountID ?? ""].joined(separator: "\n")
        guard !loadingCommands, commandContext != key else { return }
        loadingCommands = true
        defer { loadingCommands = false }
        let reply = await model.response(to: .newTaskOptions(projectID: projectID, harness: harness ?? options?.harness,
            settings: picks, accountID: accountID, composer: true, readCommands: true))
        guard key == [projectID ?? "", harness ?? options?.harness ?? "", accountID ?? ""].joined(separator: "\n"), reply.ok else { return }
        commands = reply.commands ?? []
        commandContext = key
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

    private func start() {
        guard canStart, let projectID else { return }
        if let setting = options?.settings?.first(where: { setting in
            setting.choices.first { $0.value == setting.value }?.confirm != nil
                && confirmedChoices[setting.id] != setting.value
        }) {
            startConfirmation = setting
            return
        }
        let text = RemoteComposerMentionIndex.message(draft.text, mentions: draft.hostMentions).trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = draft.attachments
        let mentions = draft.hostMentions
        let originalText = draft.text
        var settings = picks
        for setting in options?.settings ?? [] where settings[setting.id] == nil { settings[setting.id] = setting.value }
        let selectedHarness = harness ?? options?.harness
        let selectedAccount = accountID
        let selectedWorktree = worktree
        let acceptsImages = chosenHarness?.acceptsImages == true
        let acceptsFiles = chosenHarness?.acceptsFiles == true
        // Confirmed only when a choice that asks was actually shown and accepted; the host checks again.
        let asking = (options?.settings ?? []).filter { setting in
            setting.choices.first { $0.value == settings[setting.id] }?.confirm != nil
        }
        let confirmed = !asking.isEmpty && asking.allSatisfy { confirmedChoices[$0.id] == settings[$0.id] }
        isStarting = true
        Task {
            defer { isStarting = false }
            guard let parts = await RemoteAttachments.prepare(attachments, for: model, acceptsImages: acceptsImages,
                                                             acceptsFiles: acceptsFiles) else { return }
            let response = await model.response(to: .createTask(RemoteTaskStart(
                projectID: projectID, text: text, harness: selectedHarness, settings: settings, worktree: selectedWorktree,
                images: parts.images, files: parts.files, accountID: selectedAccount, confirmed: confirmed)))
            guard response.ok, let taskID = response.taskId else {
                model.commandError = RemoteHostModel.message(for: response.error, host: model.name)
                return
            }
            if draft.text == originalText { draft.text = "" }
            draft.attachments.removeAll { attachments.contains($0) }
            draft.hostMentions.removeAll { mentions.contains($0) }
            RemoteAttachments.discard(attachments)
            model.select(.task(taskID))
        }
    }
}
