import AppKit
import SwiftUI

/// What the new-task screen needs to name and offer a harness's models before a task exists: the
/// lists and settings defaults Yardlet keeps, and a way to read a list it does not have yet.
struct NewTaskModelSource {
    let catalogs: HarnessModelCatalogStore
    /// Reads the harness's model list for this account (harness, runtime, account, project).
    let load: (HarnessKind, URL, ProviderConnection?, URL?) async -> Void
}

/// What the new-task screen's lists read beside the draft: the tasks the sidebar lists and their
/// attention (`TaskAttentionProjection`, the definition `⌥⌘A`, the Dock badge and the sidebar marks
/// share), where each task sits, the schedules, what is wrong, and how tall the window is. All of it
/// is what Yardlet already keeps; nothing here asks a harness or a model.
struct NewTaskHomeActivity {
    /// Every task the sidebar can list (`AppModel.sidebarSessions`).
    var sessions: [SessionRecord] = []
    var details: [UUID: TaskAttentionDetail] = [:]
    var shellBusy: Set<UUID> = []
    /// The project, or "Chats", a task is listed under (`AppModel.taskPlaceNames`).
    var placeName: (SessionRecord) -> String = { $0.workspaceURL.lastPathComponent }
    /// The sidebar's groups of those tasks, and the chats with no project.
    var groups: [WorkspaceGroup] = []
    var chats: [SessionRecord] = []
    /// How many agents a task's `run_agent` calls are running (`AppModel.railAgentRuns`).
    var agents: (UUID) -> Int = { _ in 0 }
    /// Each schedule with its next run (`ScheduledTaskCenter.nextRun`).
    var schedules: [(schedule: ScheduledTask, nextRun: Date)] = []
    /// The schedules that turned themselves off (`ScheduledTask.hasStoppedItself`), which a project
    /// left alone for a while names.
    var stoppedSchedules: [ScheduledTask] = []
    /// A suggested task neither started nor dismissed (`TaskSuggestionStore.resolution`).
    var isSuggestionOpen: (TaskAttentionSuggestion, UUID) -> Bool = { _, _ in true }
    /// What is wrong now: accounts nearly out of their limits, the disk, the Mac.
    var notices: [NewTaskHomeNotice] = []
    /// The time "today" and next runs are read against.
    var now = Date()
    /// The window's height, which sets how many rows each list shows. Nil uses the screen's own.
    var windowHeight: CGFloat? = nil
    /// "Mark all as read" and a row's mark-as-read.
    var onMarkRead: ([UUID]) -> Void = { _ in }
    /// Opens a schedule in Scheduled tasks.
    var onOpenSchedule: (UUID) -> Void = { _ in }
    /// Sets a project left alone for a while aside until it is active after the date
    /// (`ProjectStore.setAside`).
    var onSetAside: (UUID, Date) -> Void = { _, _ in }
    /// A task's latest finished message's first line (`AppModel.answerLineBySessionID`).
    var answerLine: (UUID) -> String? = { _ in nil }
    /// When a task's latest turn started and what it suggested (`AppModel.latestTurnBySessionID`).
    var latestTurn: (UUID) -> TaskLatestTurn? = { _ in nil }
}

/// The new-task screen, which is Yardlet's home: the projects with what their tasks need, then the
/// title and composer at the bottom, where the Claude app's Code landing and the Codex app's home put
/// theirs and where a task's composer is. The project's name in the title is its menu, and choosing a
/// project on the screen starts the new task there too (`NewTaskHomeLists`). Over the title, what is
/// wrong now and the chosen folder's rows that start something.
///
/// Choosing a task that needs the person answers it here (`reply`): its own conversation and composer
/// take the title's and the composer's place, under a line naming it, and once the person sends or
/// answers there the next task that needs them takes its place, then the new task's composer comes
/// back. Escape or ✕ brings it back sooner. The new task's draft stays as it was throughout.
struct NewTaskHome: View {
    let recentSessions: [SessionRecord]
    let projects: [Project]
    @Bindable var draft: NewTaskDraft
    @Bindable var runtimeSelections: RuntimeSelectionStore
    var connections: ProviderConnectionStore? = nil
    var models: NewTaskModelSource? = nil
    let onSelectSession: (SessionRecord) -> Void
    let onChooseWorkspace: (URL) -> Void
    let onShowHarnesses: () -> Void
    var onManageAccounts: ((HarnessKind) -> Void)? = nil
    var onAddAccount: ((HarnessKind) -> Void)? = nil
    var onConnectAccount: ((AccountChoice) -> Void)? = nil
    /// Starts the submitted task. Throwing means nothing was created and the error is shown
    /// beside the draft; nil means the start failed the way any task start can.
    let onCreate: (NewTaskDraft.Submission) async throws -> SessionRecord?
    var onReadCommands: ((URL, URL, ProviderConnection?) async throws -> [ProviderComposerCommand])? = nil
    var onImportConversation: (() -> Void)? = nil
    var onImportFromOtherApps: (() -> Void)? = nil
    var projectName: (URL) -> String = { $0.lastPathComponent }
    var activity = NewTaskHomeActivity()
    /// Answers a task in the composer's place; nil where the window offers none, and a task's line
    /// opens it.
    var reply: NewTaskHomeReplyServices? = nil
    /// Reads a folder's branch and uncommitted files: the chosen folder's rows and each project's line.
    var readFolderGit: @Sendable (URL) async -> NewTaskFolderGitState = { await NewTaskFolderGitState.read($0) }
    /// Reads what a project left alone for a while left in its folder.
    var readLeftWork: @Sendable (URL) async -> GitLeftWork? = { await GitLeftWork.read($0) }
    /// Reads the disk, memory and heat the notice line names, while the screen shows.
    var readMacConditions: @Sendable () async -> [NewTaskHomeNotice] = { await MacConditionReader.notices() }
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.taskKeyboardFocus) private var keyboardFocus
    @FocusState private var isPromptFocused: Bool
    @FocusState private var listFocus: NewTaskHomeLists.Part?
    @State private var listKeyboard = NewTaskHomeListKeyboard()
    @State private var listed: [NewTaskHomeLists.Part: [NewTaskHomeListKeyboard.Entry]] = [:]
    /// Whether the chosen folder is in a Git checkout, read when the folder changes.
    @State private var isInRepository = false
    @State private var folderGit = NewTaskFolderGitState.none
    @State private var macConditions: [NewTaskHomeNotice] = []
    /// The task the composer answers now, and the one the person just answered there, which the
    /// next task that needs them replaces.
    @State private var replyTaskID: UUID?
    @State private var answeredTaskID: UUID?

    /// How often the screen reads the Mac's condition again while it shows.
    static let conditionInterval: Duration = .seconds(60)

    /// The notices: the accounts' limits, then the Mac's condition.
    private var notices: [NewTaskHomeNotice] { activity.notices + macConditions }

    /// The task the composer answers, while the sidebar still lists it.
    private var replyingSession: SessionRecord? {
        guard reply != nil, let id = replyTaskID else { return nil }
        return activity.sessions.first { $0.id == id }
    }

    var body: some View {
        GeometryReader { viewport in
            let columns = NewTaskHomeLayout.columns(width: viewport.size.width)
            VStack(spacing: 0) {
                ScrollView {
                    lists(.projects, viewport: viewport, columns: columns)
                        .frame(maxWidth: columns > 1 ? NewTaskHomeLayout.gridWidth : NewTaskHomeLayout.composerWidth)
                        .padding(.horizontal, NewTaskHomeLayout.inset)
                        .padding(.top, 28)
                        .padding(.bottom, 16)
                        .frame(maxWidth: .infinity)
                        .accessibilitySortPriority(ParityAccessibility.secondary)
                }
                .defaultScrollAnchor(.top)
                VStack(spacing: 10) {
                    if !notices.isEmpty { noticeLine(notices) }
                    if let session = replyingSession, let reply {
                        replyPane(session, reply: reply, height: NewTaskHomeLayout.replyHeight(viewport.size.height))
                    } else {
                        lists(.folder, viewport: viewport, columns: 1)
                        hero
                    }
                }
                .frame(maxWidth: NewTaskHomeLayout.composerWidth)
                .padding(.horizontal, NewTaskHomeLayout.inset)
                .padding(.top, 14)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: draft.workspaceURL, initial: true) { _, workspace in
            isInRepository = workspace.map { GitWorktreeOriginResolver.isInRepository($0) } ?? false
        }
        .onChange(of: listFocus) { _, focus in
            if focus == nil {
                listKeyboard.leave()
            } else if listKeyboard.highlighted == nil {
                // A click beside the lines, not Tab: the composer keeps the keyboard.
                returnToComposer()
            }
        }
        .onChange(of: replyTaskID) { old, new in
            // Seen and left: an unread result the composer answered reads as read, as a side-panel
            // tab marks it once shown (here once the person moves on, so its line stays put meanwhile).
            if let old, let session = activity.sessions.first(where: { $0.id == old }), session.hasUnreadUpdate {
                let status = SidebarTaskIndicatorProjection.status(
                    of: session, detail: activity.details[old], isShellBusy: activity.shellBusy.contains(old))
                if status != .awaitingApproval, status != .needsInput { activity.onMarkRead([old]) }
            }
            // The folder's rows go while the composer answers a task and come back with the new task.
            if new != nil, listed[.folder] != nil { listed[.folder] = nil; relist() }
            returnToComposer()
        }
        .onChange(of: answeredTaskID) { _, answered in
            // After the send's own event, so its composer finishes before its task's view goes. The
            // next is the one "Next task needing attention" (⌥⌘A) would open.
            guard let answered else { return }
            answeredTaskID = nil
            guard replyTaskID == answered else { return }
            replyTaskID = TaskAttentionProjection.nextSession(
                in: activity.sessions, excluding: answered, details: activity.details, shellBusy: activity.shellBusy)
        }
        .onChange(of: replyTaskID != nil && replyingSession == nil) { _, isGone in
            // The task it answered was archived or removed.
            if isGone { replyTaskID = nil }
        }
        .task {
            while !Task.isCancelled {
                let conditions = await readMacConditions()
                if conditions != macConditions { macConditions = conditions }
                try? await Task.sleep(for: Self.conditionInterval)
            }
        }
        .task(id: draft.workspaceURL) {
            guard let folder = draft.workspaceURL else { folderGit = .none; return }
            if folderGit != .none { folderGit = .none }
            let state = await readFolderGit(folder)
            guard !Task.isCancelled, draft.workspaceURL == folder else { return }
            folderGit = state
        }
    }

    private func lists(_ part: NewTaskHomeLists.Part, viewport: GeometryProxy, columns: Int) -> NewTaskHomeLists {
        NewTaskHomeLists(
            part: part, folder: draft.workspaceURL, startsChat: draft.startsChat,
            canUseWorktree: isInRepository && selectedProject != nil,
            startsInNewWorktree: startsInNewWorktree, git: folderGit, activity: activity,
            rowLimit: NewTaskHomeListsProjection.rowLimit(windowHeight: activity.windowHeight ?? viewport.size.height),
            columns: columns, selectedProjectID: draft.startsChat ? nil : selectedProject?.id,
            replyTaskID: replyingSession?.id,
            recentSessions: recentSessions, projectName: projectName,
            onImportConversation: onImportConversation, onImportFromOtherApps: onImportFromOtherApps,
            onSelectSession: onSelectSession, onAction: perform,
            keyboard: $listKeyboard, focus: $listFocus,
            onListed: { part, entries in
                listed[part] = entries
                relist()
            },
            onReturnToComposer: returnToComposer, readFolderGit: readFolderGit, readLeftWork: readLeftWork
        )
    }

    private func relist() {
        listKeyboard.list((listed[.projects] ?? []) + (listed[.folder] ?? []))
    }

    /// The task the composer answers: the line naming it, then its own conversation and composer.
    private func replyPane(_ session: SessionRecord, reply: NewTaskHomeReplyServices, height: CGFloat) -> some View {
        let status = SidebarTaskIndicatorProjection.status(
            of: session, detail: activity.details[session.id], isShellBusy: activity.shellBusy.contains(session.id))
        return VStack(spacing: 4) {
            NewTaskHomeReplyHeader(
                session: session, place: activity.placeName(session), status: status?.accessibilityName,
                onOpen: { perform(.openTask(session.id)) }, onClose: leaveReply)
            reply.content(session, NewTaskHomeReplyHooks(
                leave: leaveReply, enterLists: { enterLists(at: replyTaskID) }, replied: replied))
                .frame(height: height)
                .id(session.id)
        }
    }

    /// Back to the new task's composer, its draft as it was.
    private func leaveReply() {
        replyTaskID = nil
    }

    /// The person sent or answered in the task's composer: the next task that needs them takes its
    /// place, else the new task does (`answeredTaskID`).
    private func replied() {
        answeredTaskID = replyTaskID
    }

    /// What is wrong now, on one line over the title: an account nearly out of its limit, a disk
    /// nearly full, a Mac short of memory or slowing down to cool.
    private func noticeLine(_ notices: [NewTaskHomeNotice]) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.orange)
            Text(notices.map(\.text).joined(separator: " · "))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .help(notices.map(\.text).joined(separator: "\n"))
        .accessibilityElement(children: .combine)
    }

    private var hero: some View {
        VStack(spacing: 0) {
            NewTaskHeroTitle(
                kind: NewTaskHeroTitleKind(startsChat: draft.startsChat, workspaceURL: draft.workspaceURL,
                                            isInRepository: isInRepository, projectName: projectName),
                destination: { NewTaskDestinationMenuItems(draft: draft, projects: projects, onChooseWorkspace: onChooseWorkspace) }
            )
            .accessibilitySortPriority(ParityAccessibility.mainContent + 1)

            if draft.workspaceURL == nil {
                NewTaskDestinationButton(title: destinationTitle, systemName: draft.startsChat ? "bubble.left" : "folder") {
                    NewTaskDestinationMenuItems(draft: draft, projects: projects, onChooseWorkspace: onChooseWorkspace)
                }
                .padding(.top, 8)
            }

            NewTaskComposer(
                draft: draft,
                projects: projects,
                runtimeSelections: runtimeSelections,
                connections: connections,
                models: models,
                onChooseWorkspace: onChooseWorkspace,
                onShowHarnesses: onShowHarnesses,
                onManageAccounts: onManageAccounts,
                onAddAccount: onAddAccount,
                onConnectAccount: onConnectAccount,
                onCreate: onCreate,
                onReadCommands: onReadCommands,
                isInRepository: isInRepository,
                isPromptFocused: $isPromptFocused,
                onTab: { enterLists() }
            )
            .padding(.top, 20)
            .accessibilitySortPriority(ParityAccessibility.mainContent)
        }
    }

    private var destinationTitle: String {
        draft.startsChat ? L10n.string("Chat (no project)") : L10n.string("Choose project")
    }

    /// The project whose roots the primary-folder picker offers, as the composer reads it.
    private var selectedProject: Project? {
        NewTaskDestination.project(for: draft, in: projects)
    }

    private var startsInNewWorktree: Bool {
        isInRepository && draft.startsInNewWorktree(projectID: selectedProject?.id)
    }

    /// Tab in the composer with no list open: the line of the task it answers, else the first row of
    /// the lists, when there is one.
    private func enterLists(at taskID: UUID? = nil) -> Bool {
        let line = taskID.flatMap { id in
            (listed[.projects] ?? []).first { entry in
                if case let .row(_, rowID) = entry { return rowID == id.uuidString }
                return false
            }
        }
        guard listKeyboard.enter(at: line) else { return false }
        listFocus = (listed[.projects] ?? []).isEmpty ? .folder : .projects
        return true
    }

    /// The keyboard back to the composer on screen: the answered task's, else the new task's.
    private func returnToComposer() {
        if let id = replyTaskID, let reply {
            reply.focus(id)
        } else if let keyboardFocus {
            keyboardFocus.move(to: .chat)
        } else {
            isPromptFocused = true
        }
    }

    private func perform(_ action: NewTaskHomeAction) {
        switch action {
        case let .openTask(id):
            if replyTaskID == id { replyTaskID = nil }
            if let session = activity.sessions.first(where: { $0.id == id }) { onSelectSession(session) }
        case let .reply(id):
            // A task on screen in another pane is answered there, where its draft already is.
            guard let reply, !reply.isShownElsewhere(id) else { return perform(.openTask(id)) }
            if replyTaskID == id { returnToComposer() } else { replyTaskID = id }
        case let .draft(prompt):
            draft.insertPrompt(prompt)
            returnToComposer()
        case .useNewWorktree:
            if let project = selectedProject { draft.setStartsInNewWorktree(true, projectID: project.id) }
            returnToComposer()
        case let .chooseProject(id):
            // Where the new task starts: its composer comes back, as for a chat.
            replyTaskID = nil
            if let project = projects.first(where: { $0.id == id }) {
                NewTaskDestination.select(project, draft: draft, onChooseWorkspace: onChooseWorkspace)
            }
            returnToComposer()
        case .chooseChat:
            replyTaskID = nil
            draft.chooseChat()
            returnToComposer()
        case let .openSchedule(id):
            activity.onOpenSchedule(id)
        }
    }
}

/// The new-task screen's measures: the composer as wide as a conversation, and the projects in as
/// many columns of at least `columnWidth` as fit, up to three.
enum NewTaskHomeLayout {
    static let composerWidth: CGFloat = 760
    static let gridWidth: CGFloat = 1360
    static let columnWidth: CGFloat = 400
    static let columnSpacing: CGFloat = 40
    static let inset: CGFloat = 28

    /// How tall the answered task's conversation and composer stand: half the screen, at least room
    /// for a request card and the composer, and never so tall that the projects lose their first lines.
    static func replyHeight(_ height: CGFloat) -> CGFloat {
        max(min(height * 0.5, 560), min(320, height - 260))
    }

    static func columns(width: CGFloat) -> Int {
        let room = min(width - 2 * inset, gridWidth)
        return max(1, min(3, Int((room + columnSpacing) / (columnWidth + columnSpacing))))
    }
}

/// Which of the Codex app's titles the new-task screen shows (`NewTaskHeroTitle`).
enum NewTaskHeroTitleKind: Equatable {
    case build(project: String)
    case workOn(project: String)
    case noProject

    init(startsChat: Bool, workspaceURL: URL?, isInRepository: Bool, projectName: (URL) -> String) {
        guard !startsChat, let workspaceURL else { self = .noProject; return }
        let name = Self.shortened(projectName(workspaceURL))
        self = isInRepository ? .build(project: name) : .workOn(project: name)
    }

    /// A project's name as the title shows it: up to 40 characters, a long one shortened in the middle.
    static func shortened(_ name: String, limit: Int = 40) -> String {
        guard name.count > limit else { return name }
        let half = (limit - 1) / 2
        return String(name.prefix(half)) + "…" + String(name.suffix(limit - 1 - half))
    }

    /// The sentence around the project's name, in the reader's language: what comes before it,
    /// the name, and what follows.
    var parts: (before: String, project: String?, after: String) {
        let sentence: String
        let project: String
        switch self {
        case .noProject: return (L10n.string("What should we build?"), nil, "")
        case let .build(name): (sentence, project) = (L10n.string("What should we build in %@?"), name)
        case let .workOn(name): (sentence, project) = (L10n.string("What should we work on in %@?"), name)
        }
        return Self.split(sentence, around: project)
    }

    /// A localized sentence split where its `%@` names the project.
    static func split(_ sentence: String, around project: String) -> (before: String, project: String?, after: String) {
        guard let range = sentence.range(of: "%@") else { return (sentence, project, "") }
        return (String(sentence[..<range.lowerBound]), project, String(sentence[range.upperBound...]))
    }

    /// The whole sentence, as assistive technologies read it.
    var sentence: String {
        let parts = parts
        return parts.before + (parts.project ?? "") + parts.after
    }
}

/// The Codex app's title (`home.hero.*`): "What should we build in {project}?" for a project in
/// Git, "What should we work on in {project}?" for one outside it, and "What should we build?" for a
/// chat or before a project is chosen. The project's name is the project menu, underlined with dots
/// as the Codex app's `projectSelect` is.
struct NewTaskHeroTitle<Destination: View>: View {
    let kind: NewTaskHeroTitleKind
    @ViewBuilder let destination: () -> Destination
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        let parts = kind.parts
        ViewThatFits(in: .horizontal) {
            line(parts, size: 28)
            line(parts, size: 22)
            VStack(spacing: 2) {
                if !parts.before.isEmpty { text(parts.before, size: 22) }
                if let project = parts.project { projectMenu(project, size: 22) }
                if !parts.after.isEmpty { text(parts.after, size: 22) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.sentence)
        .accessibilityAddTraits(.isHeader)
    }

    private func line(_ parts: (before: String, project: String?, after: String), size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if !parts.before.isEmpty { text(parts.before, size: size) }
            if let project = parts.project { projectMenu(project, size: size) }
            if !parts.after.isEmpty { text(parts.after, size: size) }
        }
    }

    private func text(_ value: String, size: CGFloat) -> some View {
        Text(value)
            .font(.system(size: size * interfaceScale, weight: .semibold))
            .tracking(-0.45)
            .lineLimit(1)
            .fixedSize()
    }

    private func projectMenu(_ name: String, size: CGFloat) -> some View {
        NewTaskProjectNameMenu(name: name, size: size * interfaceScale, items: destination)
    }
}

/// The project's name in the title, which opens the project menu: underlined with dots, brighter
/// while the pointer is on it.
private struct NewTaskProjectNameMenu<Items: View>: View {
    let name: String
    let size: CGFloat
    @ViewBuilder let items: () -> Items
    @State private var isHovering = false

    var body: some View {
        Menu {
            items()
        } label: {
            // The dots are drawn under the name rather than as an underline style: a styled title
            // reaches assistive technologies as an attributed string where a plain one is expected.
            Text(name)
                .font(.system(size: size, weight: .semibold))
                .tracking(-0.45)
                .foregroundStyle(isHovering ? Color.primary : Color.primary.opacity(0.88))
                .lineLimit(1)
                .padding(.bottom, max(2, size * 0.08))
                .overlay(alignment: .bottom) {
                    NewTaskDottedLine()
                        .stroke(Color.secondary.opacity(isHovering ? 0.9 : 0.6),
                                style: StrokeStyle(lineWidth: max(1, size / 18), lineCap: .round,
                                                   dash: [max(1, size / 18), max(3, size / 7)]))
                        .frame(height: max(1, size / 18))
                }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .parityPointer()
        .onHover { isHovering = $0 }
        .help(L10n.string("Project"))
        .accessibilityLabel(L10n.string("Project"))
        .accessibilityValue(name)
    }
}

/// A horizontal line through the middle of its frame, dashed by its stroke.
private struct NewTaskDottedLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

/// Under a title without a project: a small button naming where the task starts, which opens the
/// same project menu.
private struct NewTaskDestinationButton<Items: View>: View {
    let title: String
    let systemName: String
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            ParityComposerControl(title: title, systemName: systemName, showsChevron: true)
        }
        .menuStyle(.borderlessButton)
        .parityPointer()
        .fixedSize()
        .help(title)
        .accessibilityLabel(L10n.string("Project"))
        .accessibilityValue(title)
    }
}

/// Where a new task starts, whichever control opens the menu: a folder chosen from disk, a chat with
/// no project (in a folder made for it when it starts, as the Codex app starts a chat), or a project.
enum NewTaskDestination {
    /// The project the draft starts in. A folder chosen directly still resolves to the project
    /// that owns it.
    @MainActor
    static func project(for draft: NewTaskDraft, in projects: [Project]) -> Project? {
        if let id = draft.projectID, let match = projects.first(where: { $0.id == id }) { return match }
        guard let workspaceURL = draft.workspaceURL else { return nil }
        return projects.first { $0.contains(root: workspaceURL) }
    }

    @MainActor
    static func select(_ project: Project, draft: NewTaskDraft, onChooseWorkspace: (URL) -> Void) {
        draft.projectID = project.id
        draft.workspaceURL = project.primaryRoot
        onChooseWorkspace(project.primaryRoot)
    }

    @MainActor
    static func chooseFolder(draft: NewTaskDraft, projects: [Project], onChooseWorkspace: (URL) -> Void) {
        guard let selectedURL = askForFolder() else { return }
        draft.workspaceURL = selectedURL
        draft.projectID = projects.first { $0.contains(root: selectedURL) }?.id
        onChooseWorkspace(selectedURL)
    }

    /// "Choose project…": the folder the person picks, or nil when they cancel.
    @MainActor
    static func askForFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.string("Choose project")
        return panel.runModal() == .OK ? panel.url?.standardizedFileURL : nil
    }
}

/// The project menu's items: Choose project…, Chat (no project), then the projects, the current
/// one checked.
struct NewTaskDestinationMenuItems: View {
    @Bindable var draft: NewTaskDraft
    let projects: [Project]
    let onChooseWorkspace: (URL) -> Void

    var body: some View {
        Button(L10n.string("Choose project…")) {
            NewTaskDestination.chooseFolder(draft: draft, projects: projects, onChooseWorkspace: onChooseWorkspace)
        }
        Button {
            draft.chooseChat()
        } label: {
            if draft.startsChat {
                Label(L10n.string("Chat (no project)"), systemImage: "checkmark")
            } else {
                Text(L10n.string("Chat (no project)"))
            }
        }
        if !projects.isEmpty {
            Divider()
            let current = NewTaskDestination.project(for: draft, in: projects)?.id
            ForEach(projects) { project in
                Button {
                    NewTaskDestination.select(project, draft: draft, onChooseWorkspace: onChooseWorkspace)
                } label: {
                    if project.id == current {
                        Label(project.name, systemImage: "checkmark")
                    } else {
                        Text(project.name)
                    }
                }
            }
        }
    }
}

private struct NewTaskComposer: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Bindable var draft: NewTaskDraft
    let projects: [Project]
    @Bindable var runtimeSelections: RuntimeSelectionStore
    var connections: ProviderConnectionStore? = nil
    var models: NewTaskModelSource? = nil
    let onChooseWorkspace: (URL) -> Void
    let onShowHarnesses: () -> Void
    var onManageAccounts: ((HarnessKind) -> Void)? = nil
    var onAddAccount: ((HarnessKind) -> Void)? = nil
    var onConnectAccount: ((AccountChoice) -> Void)? = nil
    let onCreate: (NewTaskDraft.Submission) async throws -> SessionRecord?
    var onReadCommands: ((URL, URL, ProviderConnection?) async throws -> [ProviderComposerCommand])? = nil
    /// Whether the chosen folder is in a Git checkout (`NewTaskHome` reads it when the folder changes).
    let isInRepository: Bool
    var isPromptFocused: FocusState<Bool>.Binding
    /// Tab with no typed list open; true when the keyboard moved to the lists.
    let onTab: () -> Bool
    @State private var commands: [ProviderComposerCommand] = []
    @State private var commandSearch = ""
    @State private var commandError: String?
    @State private var isLoadingCommands = false
    @State private var isShowingCommands = false
    /// The editor's typed `/` list is showing; Start waits until it closes.
    @State private var showsTypedCommands = false
    @State private var commandLoad: Task<Void, Never>?
    @State private var commandRequestID: UUID?
    @State private var hasReadCommandCatalog = false

    private var availableHarnesses: [HarnessDescriptor] {
        runtimeSelections.connectedDescriptors
    }
    private var availableHarnessIDs: [String] {
        availableHarnesses.map(\.id.rawValue)
    }
    private var runtimeURL: URL? {
        draft.harness.flatMap { runtimeSelections.selectedURL(for: $0) }
    }
    private var canCreate: Bool {
        guard draft.canCreate(runtimeURL: runtimeURL) else { return false }
        guard let harness = draft.harness, let connections else { return true }
        guard let choice = connections.choices(for: [harness]).first(where: { $0.connection?.id == connections.selection[harness] }) else { return false }
        return choice.canSelect
    }

    private struct ModelSettingsContext: Equatable {
        let harness: HarnessKind
        let connection: ProviderConnection?
        let workspace: URL?
    }

    private var modelSettingsContext: ModelSettingsContext? {
        draft.harness.map { ModelSettingsContext(harness: $0, connection: selectedConnection, workspace: draft.workspaceURL) }
    }

    private var selectedConnection: ProviderConnection? {
        draft.harness.flatMap { connections?.selected(for: $0) }
    }

    /// What the chosen harness can take before its task exists, as the task composer offers it.
    private var sessionOptions: ComposerSessionOptions? {
        draft.harness.map { harness in
            ComposerSessionOptionsProjection.newTask(harness: harness, choice: draft.modelChoices[harness],
                catalogs: models?.catalogs, connection: selectedConnection, workspaceURL: draft.workspaceURL)
        }
    }

    /// The task composer's session controls, for what the new task starts with: the model and
    /// effort beside Start, and the permission mode where the harness launches in one. Choices
    /// are remembered for the harness and become the task's own.
    @ViewBuilder private func sessionControls(_ placement: ComposerSessionControls.Placement) -> some View {
        if let harness = draft.harness, let options = sessionOptions {
            ComposerSessionControls(options: options, placement: placement, isDisabled: draft.isCreating,
                onChoose: { choose($0, for: harness) },
                onPrepare: {
                    guard let models, let runtimeURL else { return }
                    await models.load(harness, runtimeURL, selectedConnection, draft.workspaceURL)
                })
        }
    }

    private func choose(_ choice: ComposerSessionChoice, for harness: HarnessKind) {
        guard let models, case let .providerOption(id, value) = choice,
              let chosen = NewTaskModelProjection.choosing(id, value: value, harness: harness,
                  choice: draft.modelChoices[harness], catalogs: models.catalogs,
                  connection: selectedConnection, workspaceURL: draft.workspaceURL) else { return }
        draft.modelChoices[harness] = chosen
    }

    @ViewBuilder private var accountPicker: some View {
        if let connections, let harness = draft.harness {
                ProviderConnectionPicker(store: connections, harness: harness,
                    runtimeSelections: runtimeSelections,
                    onManage: { onManageAccounts?(harness) ?? onShowHarnesses() },
                    onAdd: { onAddAccount?(harness) ?? onShowHarnesses() },
                    onConnect: { onConnectAccount?($0) ?? onShowHarnesses() })
                    // As wide as the account's name (up to the picker's own limit), so the
                    // permission control that follows sits beside it.
                    .fixedSize(horizontal: true, vertical: false)
            }
    }

    var body: some View {
        ComposerEditor(
            draft: draft, placeholder: placeholder, metrics: .newTask,
            input: inputPolicy, mentionRoots: mentionRoots, commands: editorCommands,
            isCommandMenuOpen: isShowingCommands, isMenuOpen: isShowingCommands,
            isFocused: isPromptFocused, onSubmit: create, onTab: onTab,
            onCommandQueryChange: { _, query in showsTypedCommands = query != nil }
        ) {
            if draft.creationFailed {
                Text(draft.creationError ?? L10n.string("The task could not start. Your draft is still here."))
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
            // Where the task starts is the title's project menu (`NewTaskHeroTitle`), and the
            // same-folder warning is a row under the composer (`NewTaskFolderRow.runningHere`).
            if draft.harness != nil && runtimeURL == nil {
                homeGuidance("The selected harness is unavailable. Choose another harness or manage harnesses.",
                             action: "Manage harnesses", perform: onShowHarnesses)
            } else if availableHarnesses.isEmpty {
                homeGuidance("Add a harness to start a task.", action: "Manage harnesses", perform: onShowHarnesses)
            }

            HStack(alignment: .newTaskControlRow, spacing: 7) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 7) {
                        commandMenu
                        primaryRootMenu
                        worktreeMenu
                        harnessMenu
                        accountPicker
                        sessionControls(.leading)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            commandMenu
                            primaryRootMenu
                            worktreeMenu
                            harnessMenu
                        }
                        HStack(spacing: 7) {
                            accountPicker
                            sessionControls(.leading)
                        }
                        // Start and the model menu line up with this row.
                        .alignmentGuide(.newTaskControlRow) { $0[VerticalAlignment.center] }
                    }
                }
                Spacer(minLength: 8)
                // Outside the two arrangements above: each arrangement has views of its own, so a
                // model menu inside them lost its open popover when the list it was reading
                // arrived and the longer model name moved the row onto two lines.
                sessionControls(.trailing)
                startAction
            }
            .task(id: modelSettingsContext) {
                // Files only: the account's settings name its default model. Nothing starts.
                guard let context = modelSettingsContext, let models else { return }
                await models.catalogs.refreshDefaults(for: context.harness, connection: context.connection,
                                                      workspaceURL: context.workspace)
            }
            .padding(.leading, 11)
            .padding(.trailing, 10)
            .padding(.bottom, 9)
        }
        .onChange(of: commandContext) { _, _ in
            commandLoad?.cancel()
            commandRequestID = nil
            hasReadCommandCatalog = false
            commands = []
            commandError = nil
            isLoadingCommands = false
            isShowingCommands = false
        }
        .onDisappear { commandRequestID = nil; commandLoad?.cancel() }
        .shadow(color: .black.opacity(0.055), radius: 12, y: 4)
        .onChange(of: availableHarnessIDs, initial: true) { _, _ in
            draft.prepare(
                defaultProject: projects.first,
                availableHarnesses: availableHarnesses.map(\.id)
            )
        }
        .onChange(of: projects.map(\.id), initial: true) { _, _ in
            draft.dropUnavailableProject(visible: projects)
        }
    }

    /// The Codex app's placeholder in the chosen harness's name (`composer.placeholder.newTask.doAnything`).
    private var placeholder: String {
        draft.harness.map { L10n.format("Ask %@ to do anything", $0.displayName) } ?? L10n.string("Describe a task…")
    }

    /// The project whose roots the primary-folder picker offers. A folder chosen directly still
    /// resolves to the project that owns it, so the picker stays correct either way.
    private var selectedProject: Project? {
        NewTaskDestination.project(for: draft, in: projects)
    }

    /// One root means there is nothing to choose, so no control appears.
    @ViewBuilder
    private var primaryRootMenu: some View {
        if let project = selectedProject, project.hasMultipleRoots {
            Menu {
                ForEach(project.roots, id: \.self) { root in
                    Button {
                        draft.workspaceURL = root
                        onChooseWorkspace(root)
                    } label: {
                        if draft.workspaceURL.map({ Project.isSamePath($0, root) }) == true {
                            Label(root.lastPathComponent, systemImage: "checkmark")
                        } else {
                            Text(root.lastPathComponent)
                        }
                    }
                }
            } label: {
                ParityComposerControl(
                    title: draft.workspaceURL?.lastPathComponent ?? project.primaryRoot.lastPathComponent,
                    systemName: "location",
                    showsChevron: true
                )
            }
            .menuStyle(.borderlessButton)
            .parityPointer()
            .help(L10n.string("Primary folder"))
            .accessibilityLabel(L10n.string("Primary folder"))
            .accessibilityValue(draft.workspaceURL?.lastPathComponent ?? "")
            .frame(maxWidth: 160 * interfaceScale)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// Whether the task starts in the chosen folder or in a new worktree of its repository. Only a
    /// folder in Git can have a worktree, so a folder outside Git shows no control and starts
    /// locally, as in the Codex app.
    private var startsInNewWorktree: Bool {
        isInRepository && draft.startsInNewWorktree(projectID: selectedProject?.id)
    }

    @ViewBuilder
    private var worktreeMenu: some View {
        if isInRepository, let project = selectedProject {
            Menu {
                Button {
                    draft.setStartsInNewWorktree(false, projectID: project.id)
                } label: {
                    if startsInNewWorktree {
                        Text(L10n.string("Work locally"))
                    } else {
                        Label(L10n.string("Work locally"), systemImage: "checkmark")
                    }
                }
                Button {
                    draft.setStartsInNewWorktree(true, projectID: project.id)
                } label: {
                    if startsInNewWorktree {
                        Label(L10n.string("New worktree"), systemImage: "checkmark")
                    } else {
                        Text(L10n.string("New worktree"))
                    }
                }
            } label: {
                ParityComposerControl(
                    title: L10n.string(startsInNewWorktree ? "New worktree" : "Local"),
                    systemName: startsInNewWorktree ? "arrow.triangle.branch" : "laptopcomputer",
                    showsChevron: true
                )
            }
            .menuStyle(.borderlessButton)
            .parityPointer()
            .help(L10n.string("Select where to run the task"))
            .accessibilityLabel(L10n.string("Where to run"))
            .accessibilityValue(L10n.string(startsInNewWorktree ? "New worktree" : "Local"))
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var harnessMenu: some View {
        Menu {
            if availableHarnesses.isEmpty {
                Text(L10n.string("No available harnesses"))
            } else {
                ForEach(availableHarnesses) { descriptor in
                    Button {
                        draft.harness = descriptor.id
                    } label: {
                        HarnessIdentityLabel(harness: descriptor.id)
                    }
                }
            }
            Divider()
            Button(L10n.string("Manage harnesses"), action: onShowHarnesses)
        } label: {
            HStack(spacing: 5) {
                if let harness = draft.harness {
                    HarnessIdentityLabel(harness: harness)
                } else {
                    Label(L10n.string("Choose harness"), systemImage: "square.stack.3d.up")
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 13 * interfaceScale, weight: .medium))
            .padding(.horizontal, 7)
            .frame(height: 28 * interfaceScale)
        }
        .menuStyle(.borderlessButton)
        .parityPointer()
        .layoutPriority(1)
        .help(draft.harness?.displayName ?? L10n.string("No available harnesses"))
        .accessibilityLabel(L10n.string("Harness"))
        .accessibilityValue(draft.harness?.displayName ?? L10n.string("No available harnesses"))
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var startAction: some View {
        if draft.isCreating {
            ProgressView().controlSize(.small)
        }
        ParityIconButton(
            systemName: "arrow.up",
            help: L10n.string(draft.isCreating ? "Starting task…" : "Start task"),
            isProminent: true,
            action: create
        )
        .disabled(!canCreate || showsTypedCommands || isShowingCommands)
        .opacity(canCreate ? 1 : 0.4)
        .keyboardShortcut(.return, modifiers: .command)
    }

    private func create() {
        guard canCreate else { return }
        // A harness switched after an image was attached is told so instead of starting without
        // it. Codex keeps its own typed envelopes, as the task composer's Codex send does.
        if !draft.attachments.isEmpty, sessionOptions?.submission == .providerInput, let inputPolicy,
           case let .refuse(notice) = inputPolicy.submission(for: .init(inputs: [.text(draft.text)] + draft.attachments)) {
            draft.notice = notice
            return
        }
        guard let submission = draft.beginSubmission(runtimeURL: runtimeURL,
            connection: draft.harness.flatMap { connections?.selected(for: $0) },
            startsInNewWorktree: startsInNewWorktree) else { return }
        Task {
            do {
                let created = try await onCreate(submission)
                draft.complete(submission, succeeded: created != nil)
            } catch {
                draft.complete(submission, succeeded: false, error: error.localizedDescription)
            }
        }
    }

    private struct CommandContext: Equatable {
        let workspace: URL
        let runtime: URL
        let connection: ProviderConnection?
    }

    /// Where the home list reads its commands, for a harness whose new task has a slash list.
    private var commandContext: CommandContext? {
        guard let harness = draft.harness, sessionOptions?.commands != nil, let workspace = draft.workspaceURL,
              let runtime = runtimeURL else { return nil }
        return CommandContext(workspace: workspace, runtime: runtime, connection: connections?.selected(for: harness))
    }

    /// The typed `/` list, read once per project, runtime and account from a session that sends
    /// nothing, when a slash is first typed.
    private var editorCommands: ComposerEditorCommands? {
        guard commandContext != nil, onReadCommands != nil else { return nil }
        return ComposerEditorCommands(
            commands: commands, isLoading: isLoadingCommands, error: commandError, choose: insertCommand,
            textEdited: {
                guard !isLoadingCommands, !hasReadCommandCatalog else { return }
                loadCommands()
            })
    }

    @ViewBuilder private var commandMenu: some View {
        if sessionOptions?.commands != nil, onReadCommands != nil {
            Button {
                commandSearch = ""
                isShowingCommands = true
                loadCommands()
            } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary).frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless).parityPointer()
            .accessibilityLabel(L10n.string("Slash commands"))
            .disabled(commandContext == nil || draft.isCreating)
            .popover(isPresented: $isShowingCommands) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("Slash commands")).font(.callout.weight(.semibold))
                    TextField(L10n.string("Search commands"), text: $commandSearch).textFieldStyle(.roundedBorder)
                        .onSubmit {
                            if let command = ComposerCommands.matching(commands, query: commandSearch).first { insertCommand(command) }
                        }
                    ComposerCommandPicker(commands: commands, query: commandSearch, isLoading: isLoadingCommands,
                                          error: commandError, onSelect: insertCommand)
                }
                .padding(8).frame(width: 340)
                .onExitCommand { isShowingCommands = false }
            }
        }
    }

    private func loadCommands() {
        guard !isLoadingCommands, let context = commandContext, let onReadCommands else { return }
        isLoadingCommands = true
        hasReadCommandCatalog = true
        let requestID = UUID()
        commandRequestID = requestID
        commandError = nil
        commandLoad = Task { @MainActor in
            defer { if commandRequestID == requestID { isLoadingCommands = false } }
            do {
                let value = try await onReadCommands(context.workspace, context.runtime, context.connection)
                guard !Task.isCancelled, commandRequestID == requestID, commandContext == context else { return }
                commands = value
            } catch {
                guard !Task.isCancelled, commandRequestID == requestID, commandContext == context else { return }
                commandError = error.localizedDescription
            }
        }
    }

    private func insertCommand(_ command: ProviderComposerCommand) {
        isShowingCommands = false
        ComposerFieldEditor.insert(command, into: draft, isFocused: isPromptFocused)
    }

    private var inputPolicy: HarnessComposerInputPolicy? {
        sessionOptions?.input
    }

    /// The chosen folder first, then the project's other roots, as the task will receive them.
    private var mentionRoots: [URL] {
        guard let workspace = draft.workspaceURL else { return [] }
        let others = selectedProject.map { project in
            project.contains(root: workspace) ? project.roots.filter { !Project.isSamePath($0, workspace) } : []
        } ?? []
        return [workspace] + others
    }

    private func homeGuidance(_ message: String, action: String, perform: @escaping () -> Void) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Text(L10n.string(message)).foregroundStyle(.secondary)
                Button(L10n.string(action), action: perform).parityPointer()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string(message)).foregroundStyle(.secondary)
                Button(L10n.string(action), action: perform).parityPointer()
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.bottom, 12)
    }
}

/// The new-task composer's control row: the controls beside Start line up with the row of
/// controls before them, the second of two rows when the composer is narrow.
private enum NewTaskControlRowAlignment: AlignmentID {
    static func defaultValue(in dimensions: ViewDimensions) -> CGFloat { dimensions[VerticalAlignment.center] }
}

private extension VerticalAlignment {
    static let newTaskControlRow = VerticalAlignment(NewTaskControlRowAlignment.self)
}
