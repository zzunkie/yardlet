import Foundation
import Observation
import YardletRemote

/// What a host's New task chooses and starts with (docs/REMOTE_PROTOCOL.md §15.5, §15.16), as the Mac's
/// `RemoteNewTaskView` and the Windows host window draw it: the project the task starts in, and the harness, account,
/// settings and new worktree the host's new-task composer offers there, read from the host again whenever one of them
/// changes (`optionsKey`), then the start itself with the draft's words and attachments. The choices apply to this task
/// only; the host's own new-task composer keeps its own. A screen keeps one form while it shows.
@MainActor
@Observable
final class RemoteNewTaskForm {
    let model: RemoteHostModel
    let draft: TaskComposerDraft
    /// The project the task starts in, Chats, or nil before one is chosen (a chat).
    var projectID: String?
    /// The host's answer for the choices now: its harnesses, settings, accounts and whether a worktree can be made.
    private(set) var options: RemoteResponse?
    private(set) var harness: String?
    private(set) var picks: [String: String] = [:]
    /// New worktree, while the host can make one for the project.
    var worktree: Bool?
    private(set) var isStarting = false
    private(set) var accountID: String?
    /// The choices that ask first, as the person confirmed them.
    private(set) var confirmedChoices: [String: String] = [:]
    /// A choice that asks first and stands chosen, asked about before the task starts.
    var startConfirmation: RemoteSetting?
    /// The host's slash commands for the first message, read when the person asks for them.
    private(set) var commands: [RemoteComposerCommand] = []
    private(set) var loadingCommands = false
    @ObservationIgnored private var commandContext: String?
    private(set) var optionReadID: UUID?

    init(model: RemoteHostModel, draft: TaskComposerDraft) {
        self.model = model
        self.draft = draft
    }

    /// What the host's choices are read for; a change reads them again.
    struct OptionsKey: Equatable {
        var projectID: String?
        var harness: String?
        var picks: [String: String]
        var accountID: String?
        var connected: Bool
    }

    var optionsKey: OptionsKey {
        OptionsKey(projectID: projectID, harness: harness, picks: picks, accountID: accountID, connected: model.isConnected)
    }

    /// The host's projects that take tasks, and Chats, which the host's own new-task menu always offers and which it
    /// takes before it lists any chat (§15.5).
    var projects: [RemoteProject] {
        var projects = model.projects.filter { $0.canCreateTask == true }
        if !projects.contains(where: { $0.kind == .chats }) {
            projects.append(RemoteProject(id: RemoteTaskProjection.chatsProjectID, name: L10n.string("Chats"), kind: .chats,
                                          canCreateTask: true))
        }
        return projects
    }

    /// The new task starts as a chat: Chats chosen, or no project to start in, as on the local home
    /// (`NewTaskDraft.startsChat`).
    var isChat: Bool { projectID == nil || projects.first { $0.id == projectID }?.kind == .chats }

    /// The title over the composer, as the local home's: what to work on in the chosen project, its name the menu of
    /// the host's projects and Chats.
    var heroKind: NewTaskHeroTitleKind {
        guard let project = projects.first(where: { $0.id == projectID }), project.kind != .chats else { return .noProject }
        return .workOn(project: NewTaskHeroTitleKind.shortened(project.name))
    }

    var chosenHarness: RemoteHarnessOption? {
        options?.harnesses?.first { $0.harness == (harness ?? options?.harness) }
    }

    /// The harness the task starts on: the one chosen, the host's answer, or what the host's list said it starts on.
    var harnessID: String? { harness ?? options?.harness ?? model.newTask?.harness }

    /// The harness's name, as the composer's placeholder names it.
    var harnessName: String? { chosenHarness?.harnessName ?? model.newTask?.harnessName }

    var acceptsAttachments: Bool { chosenHarness?.acceptsImages == true || chosenHarness?.acceptsFiles == true }

    var canStart: Bool {
        model.isConnected && !isStarting && optionReadID == nil
            && (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.hostMentions.isEmpty)
    }

    /// The host's settings as the composer's controls read them, where the host names their roles.
    var sessionOptions: ComposerSessionOptions {
        RemoteTaskSettingsProjection.options(options?.settings ?? [], task: RemoteTask(
            id: "", title: "", harness: harness ?? options?.harness ?? "claude-code",
            harnessName: chosenHarness?.harnessName ?? "", projectId: projectID, attention: .idle, lastActivityAt: 0))
    }

    // MARK: Choosing

    /// The screen came up: it starts in the host's first project, as the host's own new-task screen does.
    func appear() {
        if projectID == nil {
            projectID = projects.first(where: { $0.kind != .chats })?.id
        }
    }

    /// Starts in the project New task in a project chose, once; false when the host does not list it.
    func take(chosenProjectID chosen: String) -> Bool {
        guard projects.contains(where: { $0.id == chosen }) else { return false }
        projectID = chosen
        return true
    }

    /// Another harness: its own settings and accounts are read again from the host's defaults.
    func chooseHarness(_ id: String) {
        harness = id
        picks = [:]
        confirmedChoices = [:]
        accountID = nil
    }

    func chooseAccount(_ id: String) {
        accountID = id
        picks = [:]
        confirmedChoices = [:]
    }

    /// A choice made in the composer's controls; one that asks first was asked about there.
    func choose(_ choice: ComposerSessionChoice) {
        guard case let .providerOption(id, value) = choice else { return }
        if options?.settings?.first(where: { $0.id == id })?.choices.first(where: { $0.value == value })?.confirm != nil {
            confirmedChoices[id] = value
        } else {
            confirmedChoices[id] = nil
        }
        picks[id] = value
    }

    /// A choice from a setting's own menu, where the host names no roles.
    func pick(_ settingID: String, _ value: String) {
        picks[settingID] = value
    }

    /// The choice the host's default stands on, confirmed: the task starts.
    func confirmStart() {
        guard let setting = startConfirmation else { return }
        confirmedChoices[setting.id] = setting.value
        startConfirmation = nil
        start()
    }

    // MARK: Reading the host

    /// Reads the host's choices for the project, harness, account and picks now; an answer to an older read is dropped.
    func readOptions() async {
        guard model.isConnected else { return }
        let requestID = UUID()
        optionReadID = requestID
        defer { if optionReadID == requestID { optionReadID = nil } }
        let response = await model.response(to: .newTaskOptions(projectID: projectID, harness: harness, settings: picks,
                                                                 accountID: accountID, composer: model.composerExtensions))
        guard !Task.isCancelled, optionReadID == requestID else { return }
        guard response.ok else {
            model.commandError = RemoteHostModel.message(for: response.error, host: model.name)
            return
        }
        options = response
        if commandContext != commandKey { commands = []; commandContext = nil }
        if worktree == nil || response.worktree == nil { worktree = response.worktree }
    }

    private var commandKey: String {
        [projectID ?? "", harness ?? options?.harness ?? "", accountID ?? ""].joined(separator: "\n")
    }

    /// Reads the host's slash commands for the project, harness and account now, once for each.
    func loadCommands() async {
        let key = commandKey
        guard !loadingCommands, commandContext != key else { return }
        loadingCommands = true
        defer { loadingCommands = false }
        let reply = await model.response(to: .newTaskOptions(projectID: projectID, harness: harness ?? options?.harness,
            settings: picks, accountID: accountID, composer: true, readCommands: true))
        guard key == commandKey, reply.ok else { return }
        commands = reply.commands ?? []
        commandContext = key
    }

    // MARK: Starting

    /// Starts the task on the host with the draft's words and attachments, a choice that asks first asked about
    /// before (`startConfirmation`). Once the host started it, what was sent leaves the draft and the window shows the
    /// task; what the host refused stays, with why (`RemoteHostModel.commandError`).
    func start() {
        guard canStart else { return }
        let projectID = projectID ?? RemoteTaskProjection.chatsProjectID
        if let setting = options?.settings?.first(where: { setting in
            setting.choices.first { $0.value == setting.value }?.confirm != nil
                && confirmedChoices[setting.id] != setting.value
        }) {
            startConfirmation = setting
            return
        }
        let draft = draft
        let model = model
        let text = RemoteComposerMentionIndex.message(draft.text, mentions: draft.hostMentions)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

extension RemoteHostModel {
    /// The host's tasks as the local home reads this computer's (`NewTaskHomeActivity`), from the lists the sidebar
    /// reads; marking one read goes to the host.
    func newTaskHomeActivity() -> NewTaskHomeActivity {
        let mirror = sidebar
        let names = Dictionary(mirror.groups.flatMap { group in group.sessions.map { ($0.id, group.displayName) } },
                               uniquingKeysWith: { first, _ in first })
        var activity = NewTaskHomeActivity()
        activity.sessions = mirror.sessions
        activity.details = mirror.details
        activity.groups = mirror.groups
        activity.chats = mirror.chats
        activity.answerLine = { mirror.answerLines[$0] }
        activity.latestTurn = { mirror.latestTurns[$0] }
        activity.pullRequest = { mirror.pullRequests[$0] }
        activity.placeName = { names[$0.id] ?? L10n.string("Chats") }
        activity.onMarkRead = { [weak self] ids in for id in ids { self?.send(.markRead(taskID: id.uuidString)) } }
        return activity
    }
}
