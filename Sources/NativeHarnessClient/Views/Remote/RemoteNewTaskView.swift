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
            if projectID == nil { projectID = projects.first(where: { $0.kind != .chats })?.id ?? projects.first?.id }
            isFocused = true
        }
        .onChange(of: chosenProjectID, initial: true) { _, chosen in
            guard let chosen, projects.contains(where: { $0.id == chosen }) else { return }
            projectID = chosen
            chosenProjectID = nil
        }
        .task(id: OptionsKey(projectID: projectID, harness: harness, picks: picks, connected: model.isConnected)) {
            await readOptions()
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ComposerEditor(
                draft: draft, placeholder: L10n.string("Describe the task"),
                accessibilityHint: L10n.string("Press Return to start the task"), metrics: .newTask,
                input: nil, onExternalInput: acceptsAttachments ? { receive($0) } : nil, mentionRoots: [], commands: nil,
                isCommandMenuOpen: false, isMenuOpen: false, isFocused: $isFocused, onSubmit: start
            ) {
                EmptyView()
            } chips: {
                EmptyView()
            } footer: {
                HStack(spacing: 8) {
                    harnessMenu
                    ForEach(options?.settings ?? [], id: \.id) { setting in settingMenu(setting) }
                    if let worktree {
                        Toggle(L10n.string("New worktree"), isOn: Binding(get: { worktree }, set: { self.worktree = $0 }))
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                    }
                    Spacer()
                    if isStarting { ProgressView().controlSize(.small) }
                    ParityIconButton(systemName: "arrow.up", help: L10n.string("Start task"), isProminent: true, action: start)
                        .accessibilityLabel(L10n.string("Start task"))
                        .disabled(!canStart)
                }
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
            if let error = model.commandError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: The home's lists

    /// The host's tasks as the local home reads this Mac's (`NewTaskHomeActivity`), from the lists the sidebar reads.
    private var activity: NewTaskHomeActivity {
        let mirror = model.sidebar
        let names = Dictionary(mirror.groups.flatMap { group in group.sessions.map { ($0.id, group.displayName) } },
                               uniquingKeysWith: { first, _ in first })
        var activity = NewTaskHomeActivity()
        activity.sessions = mirror.sessions
        activity.details = mirror.details
        activity.groups = mirror.groups
        activity.chats = mirror.chats
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
        var connected: Bool
    }

    private var canStart: Bool {
        model.isConnected && !isStarting && projectID != nil
            && !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var chosenHarness: RemoteHarnessOption? {
        options?.harnesses?.first { $0.harness == (harness ?? options?.harness) }
    }

    private var acceptsAttachments: Bool { chosenHarness?.acceptsImages == true || chosenHarness?.acceptsFiles == true }

    private var harnessMenu: some View {
        Menu {
            ForEach(options?.harnesses ?? [], id: \.harness) { option in
                Button(option.harnessName) {
                    harness = option.harness
                    picks = [:]
                }
            }
        } label: {
            Text(chosenHarness?.harnessName ?? model.newTask?.harnessName ?? L10n.string("Harness"))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled((options?.harnesses ?? []).count < 2)
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
        let response = await model.response(to: .newTaskOptions(projectID: projectID, harness: harness, settings: picks))
        guard response.ok else { return }
        options = response
        if worktree == nil || response.worktree == nil { worktree = response.worktree }
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
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = draft.attachments
        isStarting = true
        Task {
            defer { isStarting = false }
            guard let parts = await RemoteAttachments.prepare(attachments, for: model, acceptsImages: chosenHarness?.acceptsImages == true,
                                                             acceptsFiles: chosenHarness?.acceptsFiles == true) else { return }
            var settings = picks
            for setting in options?.settings ?? [] where settings[setting.id] == nil { settings[setting.id] = setting.value }
            let response = await model.response(to: .createTask(RemoteTaskStart(
                projectID: projectID, text: text, harness: harness ?? options?.harness, settings: settings, worktree: worktree,
                images: parts.images, files: parts.files)))
            guard response.ok, let taskID = response.taskId else {
                model.commandError = RemoteHostModel.message(for: response.error, host: model.name)
                return
            }
            draft.text = ""
            draft.attachments = []
            RemoteAttachments.discard(attachments)
            model.select(.task(taskID))
        }
    }
}
