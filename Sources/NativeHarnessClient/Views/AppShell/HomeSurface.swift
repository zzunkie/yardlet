import AppKit
import SwiftUI

/// What the new-task screen needs to name and offer a harness's models before a task exists: the
/// lists and settings defaults Yardlet keeps, and a way to read a list it does not have yet.
struct NewTaskModelSource {
    let catalogs: HarnessModelCatalogStore
    /// Reads the harness's model list for this account (harness, runtime, account, project).
    let load: (HarnessKind, URL, ProviderConnection?, URL?) async -> Void
}

/// The account a new task starts on while its account menu says Automatic: the one the composer names
/// before it is sent, from the readings at hand, and the one it starts on, picked when it is sent
/// (`AppModel.newTaskAccountPreview`, `AppModel.newTaskAccount`). Both take the harness and the model.
struct NewTaskAccountSource {
    let preview: @MainActor (HarnessKind, String?) -> AccountAssignment?
    let pick: @MainActor (HarnessKind, String?) async -> AppModel.AccountStart?
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
    var accounts: NewTaskAccountSource? = nil
    let onSelectSession: (SessionRecord) -> Void
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
    /// Where a recent task is listed, as the sidebar lists it.
    var taskProjectName: (SessionRecord) -> String = { $0.workspaceURL.lastPathComponent }
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
    /// The view the person chose last, kept for the next home (`NewTaskHomeView.key`).
    @AppStorage(NewTaskHomeView.key, store: .yardlet) private var homeView = NewTaskHomeView.now
    /// What the projects count, for the header over them.
    @State private var projectFacts = NewTaskHomeProjectFacts()

    /// How often the screen reads the Mac's condition again while it shows.
    static let conditionInterval: Duration = .seconds(60)

    /// The task the composer answers, while the sidebar still lists it.
    private var replyingSession: SessionRecord? {
        guard reply != nil, let id = replyTaskID else { return nil }
        return activity.sessions.first { $0.id == id }
    }

    /// No project and no task yet: the title and the composer alone, with no view to switch to.
    private var isFirstRun: Bool { projects.isEmpty && activity.sessions.isEmpty }

    /// The header with "Now | Projects" shows once there is a project or a task.
    private var showsViewSwitch: Bool { !isFirstRun }

    private var showsDesk: Bool { showsViewSwitch && homeView == .now }

    var body: some View {
        GeometryReader { viewport in
            if showsDesk {
                DeskHome(
                    activity: activity, size: viewport.size, replyTaskID: replyingSession?.id, onAction: perform,
                    keyboard: $listKeyboard, focus: $listFocus,
                    onListed: { entries in
                        listed[.desk] = entries
                        relist()
                    },
                    onReturnToComposer: returnToComposer,
                    viewSwitch: { NewTaskHomeViewSwitch(selection: $homeView) },
                    bottom: { bottom(viewport: viewport) })
                    .accessibilitySortPriority(ParityAccessibility.secondary)
            } else {
                projectsView(viewport: viewport)
            }
        }
        .onChange(of: showsDesk) { relist() }
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
            if new == nil {
                // The new task's composer comes back with this update and takes the keyboard once it is there:
                // asked before, the window gives the keyboard to the first control that takes it, the header's view
                // switch.
                DispatchQueue.main.async { returnToComposer() }
            } else {
                returnToComposer()
            }
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

    /// The projects in their columns over the composer, the header with the view switch over them once
    /// there is a project or a task.
    private func projectsView(viewport: GeometryProxy) -> some View {
        let columns = NewTaskHomeLayout.columns(width: viewport.size.width)
        return VStack(spacing: 0) {
            if showsViewSwitch {
                DeskHeader(date: activity.now, summary: projectFacts.summary) { NewTaskHomeViewSwitch(selection: $homeView) }
                    .modifier(DeskHeaderPlacement(width: viewport.size.width))
            }
            // Faded at its foot, as the desk's zones are, so a project cut by the window's edge reads as more to scroll.
            DeskScroll {
                VStack(alignment: .leading, spacing: 22) {
                    if let usage = activity.usage {
                        TokenUsageHomeBand(overview: usage, columns: columns, onOpen: activity.onOpenUsage)
                    }
                    lists(.projects, viewport: viewport, columns: columns)
                }
                    .frame(maxWidth: columns > 1 ? NewTaskHomeLayout.gridWidth : NewTaskHomeLayout.composerWidth)
                    .padding(.horizontal, NewTaskHomeLayout.inset)
                    .padding(.top, showsViewSwitch ? 4 : 28)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                    .accessibilitySortPriority(ParityAccessibility.secondary)
            }
            VStack(spacing: 10) { bottom(viewport: viewport) }
                .frame(maxWidth: NewTaskHomeLayout.composerWidth)
                .padding(.horizontal, NewTaskHomeLayout.inset)
                .padding(.top, 14)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
        }
    }

    /// Under the lists: what is wrong now, then the folder's rows, the title and the composer, or the
    /// composer answering a task.
    @ViewBuilder
    private func bottom(viewport: GeometryProxy) -> some View {
        // The usage band stands over the projects only: on the desk this line names the limits nearly spent.
        NewTaskHomeNoticeLine(accounts: activity.notices, showsUsage: activity.usage == nil || showsDesk,
                              conditions: macConditions)
        if let session = replyingSession, let reply {
            replyPane(session, reply: reply, height: NewTaskHomeLayout.replyHeight(viewport.size.height))
        } else {
            lists(.folder, viewport: viewport, columns: 1)
            hero
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
            recentSessions: recentSessions, projectName: taskProjectName,
            onImportConversation: onImportConversation, onImportFromOtherApps: onImportFromOtherApps,
            onSelectSession: onSelectSession, onAction: perform,
            keyboard: $listKeyboard, focus: $listFocus,
            onListed: { part, entries in
                listed[part] = entries
                relist()
            },
            onReturnToComposer: returnToComposer, readFolderGit: readFolderGit, readLeftWork: readLeftWork,
            onFacts: { facts in if facts != projectFacts { projectFacts = facts } }
        )
    }

    /// The part over the composer that lists lines now: the desk or the projects.
    private var topPart: NewTaskHomeLists.Part { showsDesk ? .desk : .projects }

    private func relist() {
        listKeyboard.list((listed[topPart] ?? []) + (listed[.folder] ?? []))
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

    private var hero: some View {
        VStack(spacing: 0) {
            NewTaskHeroTitle(
                kind: NewTaskHeroTitleKind(startsChat: draft.startsChat, workspaceURL: draft.workspaceURL,
                                            isInRepository: isInRepository, projectName: projectName),
                onClearProject: draft.workspaceURL == nil ? nil : { draft.chooseChat() },
                destination: { NewTaskDestinationMenuItems(draft: draft, projects: projects) }
            )
            .accessibilitySortPriority(ParityAccessibility.mainContent + 1)

            if let parent = draft.parentTask {
                NewTaskParentBadge(title: parent.title) {
                    draft.parentTask = nil
                }
                .padding(.top, 8)
            }

            if draft.workspaceURL == nil {
                NewTaskDestinationButton(title: destinationTitle, systemName: draft.startsChat ? "bubble.left" : "folder") {
                    NewTaskDestinationMenuItems(draft: draft, projects: projects)
                }
                .padding(.top, 8)
            }

            NewTaskComposer(
                draft: draft,
                projects: projects,
                runtimeSelections: runtimeSelections,
                connections: connections,
                models: models,
                accounts: accounts,
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
            (listed[topPart] ?? []).first { entry in
                if case let .row(_, rowID) = entry { return rowID == id.uuidString }
                return false
            }
        }
        guard listKeyboard.enter(at: line) else { return false }
        listFocus = (listed[topPart] ?? []).isEmpty ? .folder : topPart
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
                NewTaskDestination.select(project, draft: draft)
            }
            returnToComposer()
        case .chooseChat:
            replyTaskID = nil
            draft.chooseChat()
            returnToComposer()
        case let .openSchedule(id):
            activity.onOpenSchedule(id)
        case let .openEvent(event):
            activity.onOpenEvent(event)
        }
    }
}

/// What is wrong now, on one line over the title: an account nearly out of its limit (unless the usage
/// band shows the limits), a disk nearly full, a Mac short of memory or slowing down to cool. Nothing
/// while all is well. It reads the accounts' limits in its own body, so a new reading redraws this line
/// alone.
struct NewTaskHomeNoticeLine: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    let accounts: () -> [NewTaskHomeNotice]
    /// The usage band is not shown, so this line names the accounts' limits.
    let showsUsage: Bool
    let conditions: [NewTaskHomeNotice]

    var body: some View {
        let notices = accounts().filter { notice in
            if case .usage = notice { return showsUsage } else { return true }
        } + conditions
        if !notices.isEmpty {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5 * interfaceScale, weight: .medium))
                    .foregroundStyle(.orange)
                Text(notices.map(\.text).joined(separator: " · "))
                    .font(.system(size: 12 * interfaceScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .help(notices.map(\.text).joined(separator: "\n"))
            .accessibilityElement(children: .combine)
        }
    }
}

/// The Codex app's title (`home.hero.*`): "What should we build in {project}?" for a project in
/// Git, "What should we work on in {project}?" for one outside it, and "What should we build?" for a
/// chat or before a project is chosen. The project's name is the project menu, underlined with dots
/// as the Codex app's `projectSelect` is. The button that clears the project ends the sentence rather
/// than standing inside it, where it would part the name from a particle written right after it, as in Korean.
struct NewTaskHeroTitle<Destination: View>: View {
    let kind: NewTaskHeroTitleKind
    /// Switches from the selected project to a chat with no project; nil hides the clear button.
    var onClearProject: (() -> Void)? = nil
    @ViewBuilder let destination: () -> Destination
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        let parts = kind.parts
        ViewThatFits(in: .horizontal) {
            line(parts, size: 28)
            line(parts, size: 22)
            VStack(spacing: 2) {
                if !parts.before.isEmpty { text(parts.before, size: 22) }
                line((before: "", project: parts.project, after: parts.after), size: 22)
            }
            // Narrowest: a line each, the clear button still ending the sentence's last line.
            VStack(spacing: 2) {
                if !parts.before.isEmpty { text(parts.before, size: 22) }
                if parts.after.isEmpty {
                    line((before: "", project: parts.project, after: ""), size: 22)
                } else {
                    if let project = parts.project { projectMenu(project, size: 22) }
                    line((before: "", project: nil, after: parts.after), size: 22)
                }
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
            clearButton(size: size)
        }
    }

    /// Only a title that names a project offers to clear it.
    @ViewBuilder
    private func clearButton(size: CGFloat) -> some View {
        if kind.parts.project != nil, let onClearProject {
            NewTaskProjectClearButton(size: size * interfaceScale, onClear: onClearProject)
                .padding(.leading, 4)
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

/// The small button at the title's end that switches from the chosen project directly to a chat.
private struct NewTaskProjectClearButton: View {
    let size: CGFloat
    let onClear: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onClear) {
            Image(systemName: "xmark")
                .font(.system(size: max(10, size * 0.42), weight: .semibold))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .frame(width: max(18, size * 0.72), height: max(18, size * 0.72))
                .background(isHovering ? ParityTheme.hoverFill : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .onHover { isHovering = $0 }
        .centeredOnCapHeight(ofTextSize: size)
        .help(L10n.string("Switch to chat"))
        .accessibilityLabel(L10n.string("Switch to chat"))
    }
}

/// Shown under the title while the draft starts a nested task under an existing sidebar task.
private struct NewTaskParentBadge: View {
    let title: String
    let onClear: () -> Void
    @State private var isHoveringClear = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10.5 * interfaceScale, weight: .medium))
                .foregroundStyle(.secondary)
            Text(L10n.format("Nested under %@", title))
                .font(.system(size: 12 * interfaceScale))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5 * interfaceScale, weight: .semibold))
                    .foregroundStyle(isHoveringClear ? Color.primary : Color.secondary)
                    .frame(width: 16, height: 16)
                    .background(isHoveringClear ? ParityTheme.hoverFill : .clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .parityPointer()
            .onHover { isHoveringClear = $0 }
            .help(L10n.string("Clear parent task"))
            .accessibilityLabel(L10n.string("Clear parent task"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(ParityTheme.subtleFill, in: Capsule())
        .frame(maxWidth: 420 * interfaceScale)
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
struct NewTaskDestinationButton<Items: View>: View {
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
    static func select(_ project: Project, draft: NewTaskDraft) {
        draft.parentTask = nil
        draft.projectID = project.id
        draft.workspaceURL = project.primaryRoot
    }

    /// A folder chosen from disk is where the task starts and is made no project: the task joins
    /// a shown project that holds the folder, else it is a chat there. Add project registers one.
    @MainActor
    static func chooseFolder(draft: NewTaskDraft, projects: [Project]) {
        guard let selectedURL = askForFolder() else { return }
        draft.parentTask = nil
        draft.workspaceURL = selectedURL
        draft.projectID = projects.first { $0.contains(root: selectedURL) }?.id
    }

    /// "Choose folder…": the folder the person picks, or nil when they cancel.
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

/// The project menu's items: Choose folder…, Chat (no project), then the projects, the current
/// one checked.
struct NewTaskDestinationMenuItems: View {
    @Bindable var draft: NewTaskDraft
    let projects: [Project]

    var body: some View {
        Button(L10n.string("Choose folder…")) {
            NewTaskDestination.chooseFolder(draft: draft, projects: projects)
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
                    NewTaskDestination.select(project, draft: draft)
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

/// Which account the next task starts on while its account menu says Automatic, and why, in the words
/// a task's hover card uses: "name · Chosen automatically · 5 hour limit 12% used · Resets 3:00 PM".
/// Before the task is sent it is the account the readings at hand pick; once it is sent, the one it
/// was given. Its own view, so the tasks and readings the pick reads redraw only this line.
private struct NewTaskAutomaticAccountLine: View {
    let assignment: AccountAssignment?
    let preview: () -> AccountAssignment?

    var body: some View {
        if let assignment = assignment ?? preview() {
            NewTaskAccountExplanation(line: assignment.accountName + " · " + assignment.reasonLine())
        }
    }
}

/// The automatic account's explanation, drawn identically for local and host-projected choices.
struct NewTaskAccountExplanation: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    let line: String

    var body: some View {
        Text(line)
            .font(.yardlet(.caption, scale: interfaceScale)).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(line)
    }
}

private struct NewTaskComposer: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.yardletReportProblem) private var reportProblem
    @Environment(\.yardletSendFeedback) private var sendFeedback
    @Bindable var draft: NewTaskDraft
    let projects: [Project]
    @Bindable var runtimeSelections: RuntimeSelectionStore
    var connections: ProviderConnectionStore? = nil
    var models: NewTaskModelSource? = nil
    var accounts: NewTaskAccountSource? = nil
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
    /// The "+" menu's open page: what can be added, or the slash commands it leads to.
    @State private var addMenuPage: AddMenuPage?
    /// The "+" menu was opened from the keyboard: its first row starts highlighted.
    @State private var addMenuOpenedFromKeyboard = false
    /// The editor's typed `/` list is showing; Start waits until it closes.
    @State private var showsTypedCommands = false
    @State private var commandLoad: Task<Void, Never>?
    @State private var commandRequestID: UUID?
    @State private var hasReadCommandCatalog = false
    /// The account a task being sent on Automatic was given, and why, until it has started.
    @State private var startingAccount: AccountAssignment?

    private var availableHarnesses: [HarnessDescriptor] {
        runtimeSelections.connectedDescriptors
    }
    private var availableHarnessIDs: [String] {
        availableHarnesses.map(\.id.rawValue)
    }
    private var runtimeURL: URL? {
        draft.harness.flatMap { runtimeSelections.knownURL(for: $0) }
    }
    private var canCreate: Bool {
        guard draft.canCreate(runtimeURL: runtimeURL) else { return false }
        guard let harness = draft.harness, let connections else { return true }
        // Automatic is offered only with more than one account a task can start on.
        if startsOnAutomaticAccount { return true }
        guard let choice = connections.choices(for: [harness]).first(where: { $0.connection?.id == connections.selection[harness] }) else { return false }
        return choice.canSelect
    }

    /// The account the next task starts on, when it has to be signed in to first. Said before the
    /// first message rather than as that message's failure. Start stays on: a sign-in made in
    /// Terminal is not known here yet, and `AppModel.createTask` reads the login again and keeps the
    /// person on this screen when it is still missing.
    private var accountNeedingSignIn: AccountChoice? {
        guard let harness = draft.harness, let connections, runtimeURL != nil, !startsOnAutomaticAccount,
              let choice = connections.choices(for: [harness]).first(where: { $0.connection?.id == connections.selection[harness] }),
              choice.snapshot?.state == .signedOut,
              AccountListProjection.offersConnect(choice, mode: .newTask(harness)) else { return nil }
        return choice
    }

    /// The next task starts on the account automatic assignment picks when it is sent.
    private var startsOnAutomaticAccount: Bool {
        guard let harness = draft.harness else { return false }
        return connections?.startsNewTasksAutomatically(for: harness) == true
    }

    /// The model the next task names, for the limits of one model.
    private var chosenModel: String? {
        draft.harness.flatMap { harness in
            draft.modelChoices[harness].flatMap { AppModel.modelOption($0.providerOptions(for: harness), harness: harness) }
        }
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
    /// effort beside Start, and the permission where the harness takes one at its start. Choices
    /// are remembered for the harness and become the task's own.
    @ViewBuilder private func sessionControls(_ placement: ComposerSessionControls.Placement) -> some View {
        if let harness = draft.harness, let options = sessionOptions {
            ComposerSessionControls(options: options, placement: placement, isDisabled: draft.isCreating,
                onChoose: { choose($0, for: harness) },
                onPrepare: {
                    guard let models, let runtimeURL = runtimeSelections.selectedURL(for: harness) else { return }
                    await models.load(harness, runtimeURL, selectedConnection, draft.workspaceURL)
                },
                shortensModelToFit: true)
        }
    }

    private func choose(_ choice: ComposerSessionChoice, for harness: HarnessKind) {
        guard let models,
              let chosen = NewTaskModelProjection.choosing(choice, harness: harness,
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
            isCommandMenuOpen: addMenuPage == .commands, isMenuOpen: addMenuPage != nil,
            isFocused: isPromptFocused, onSubmit: create, onTab: onTab,
            onCommandQueryChange: { _, query in showsTypedCommands = query != nil }
        ) {
            if draft.creationFailed {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // The mark carries the red; the sentence stays readable text.
                    Label {
                        Text(draft.creationError ?? L10n.string("The task could not start. Your draft is still here."))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    if let sendFeedback {
                        Button(L10n.string("Send problem report")) {
                            sendFeedback(.problem(surface: .home, harness: draft.harness, failure: .init(
                                kind: "taskStart", code: PrivateFeedbackContext.errorCode(in: draft.creationError))))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(ParityTheme.accentText)
                        .parityPointer()
                    }
                    if let reportProblem {
                        Button(L10n.string("Report a Problem…")) {
                            reportProblem(harness: draft.harness, message: draft.creationError)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(ParityTheme.accentText)
                        .parityPointer()
                    }
                }
                .font(.yardlet(.caption, scale: interfaceScale))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 10)
            }
            // Where the task starts is the title's project menu (`NewTaskHeroTitle`), and the
            // same-folder warning is a row under the composer (`NewTaskFolderRow.runningHere`).
            if draft.harness != nil && runtimeURL == nil {
                homeGuidance("The selected harness is unavailable. Choose another harness or manage harnesses.",
                             action: "Manage harnesses", perform: onShowHarnesses)
            } else if availableHarnesses.isEmpty {
                homeGuidance("Connect a harness, such as Claude Code or Codex, to start a task.",
                             action: "Manage harnesses", prominent: true, perform: onShowHarnesses)
            }

            if let signIn = accountNeedingSignIn {
                homeGuidance(signIn.snapshot?.detail ?? ProviderSignIn.neededHere(signIn.harness), action: AccountConnectionPresentation.connectAction(for: signIn.harness)) {
                    onConnectAccount?(signIn) ?? onShowHarnesses()
                }
            }

            if startsOnAutomaticAccount, let harness = draft.harness, let accounts {
                NewTaskAutomaticAccountLine(assignment: startingAccount, preview: { accounts.preview(harness, chosenModel) })
                    .padding(.horizontal, 16).padding(.bottom, 6)
            }

            NewTaskComposerControlRow {
                addMenu
                primaryRootMenu
                worktreeMenu
                // With no harness connected the guidance's button is the way on; the menu would only repeat it.
                if !availableHarnesses.isEmpty { harnessMenu }
            } secondary: {
                accountPicker
                sessionControls(.leading)
            } trailing: {
                sessionControls(.trailing)
                startAction
            }
            .task(id: modelSettingsContext) {
                // Files only: the account's settings name its default model. Nothing starts.
                guard let context = modelSettingsContext, let models else { return }
                await models.catalogs.refreshDefaults(for: context.harness, connection: context.connection,
                                                      workspaceURL: context.workspace)
            }
        }
        .onChange(of: commandContext) { _, _ in
            commandLoad?.cancel()
            commandRequestID = nil
            hasReadCommandCatalog = false
            commands = []
            commandError = nil
            isLoadingCommands = false
            if addMenuPage == .commands { addMenuPage = nil }
        }
        .onDisappear { commandRequestID = nil; commandLoad?.cancel() }
        .onChange(of: availableHarnessIDs, initial: true) { _, _ in
            draft.prepare(
                defaultProject: projects.first,
                availableHarnesses: availableHarnesses.map(\.id)
            )
        }
        .onChange(of: projects.map(\.id), initial: true) { _, _ in
            draft.dropUnavailableProject(visible: projects)
        }
        // A start stopped for its sign-in is over once the sign-in is done or another account chosen.
        .onChange(of: accountNeedingSignIn == nil) { _, needsNone in
            if needsNone { draft.clearFailure() }
        }
    }

    /// The Codex app's placeholder in the chosen harness's name (`composer.placeholder.newTask.doAnything`).
    private var placeholder: String {
        NewTaskComposerText.placeholder(harnessName: draft.harness?.displayName)
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
        NewTaskHarnessControl(harness: draft.harness) {
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
        }
    }

    private var startAction: some View {
        NewTaskStartControl(canStart: canCreate, isStarting: draft.isCreating,
            commandMenuOpen: showsTypedCommands || addMenuPage != nil, onStart: create)
    }

    private func create() {
        guard canCreate else { return }
        guard !draft.refusesAttachments(options: sessionOptions) else { return }
        // The runtime's file is looked at as the task starts; the screen reads what was last found (`knownURL(for:)`).
        guard let begun = draft.beginSubmission(runtimeURL: draft.harness.flatMap { runtimeSelections.selectedURL(for: $0) },
            connection: draft.harness.flatMap { connections?.selected(for: $0) },
            startsInNewWorktree: startsInNewWorktree) else { return }
        let picksAccount = startsOnAutomaticAccount ? accounts?.pick : nil
        let model = chosenModel
        Task {
            var submission = begun
            if let picksAccount, let account = await picksAccount(submission.harness, model) {
                submission.connection = account.connection
                submission.accountAssignment = account.assignment
                startingAccount = account.assignment
            }
            defer { startingAccount = nil }
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

    private enum AddMenuPage { case additions, commands }

    /// One "+" for everything that is added to a message, as the task composer has it and as the
    /// Codex and Claude apps have it in a new chat: files or photos and a folder, then the slash
    /// commands where the harness lists them. A typed `@` still searches the project's files.
    @ViewBuilder private var addMenu: some View {
        if let input = inputPolicy, input.showsMentionControl {
            Button {
                addMenuOpenedFromKeyboard = ParityInteraction.currentEventIsKeyboard
                addMenuPage = .additions
            } label: {
                Image(systemName: "plus").font(.system(size: 12 * interfaceScale, weight: .medium))
                    .foregroundStyle(.secondary).frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless).parityPointer()
            .accessibilityLabel(L10n.string("Add files and more"))
            .help(L10n.string("Add files and more · Type @ to mention a file"))
            .disabled(draft.isCreating)
            .popover(isPresented: Binding(get: { addMenuPage != nil }, set: { if !$0 { addMenuPage = nil } })) {
                switch addMenuPage {
                case .commands?:
                    commandsPage
                default:
                    ComposerMenuList(
                        entries: ComposerPlusMenu.entries(carriesImages: input.carriesImages, connectors: nil,
                                                          actions: addMenuActions(input)),
                        highlightsFirstRow: addMenuOpenedFromKeyboard,
                        onDismiss: { addMenuPage = nil })
                }
            }
        }
    }

    private func addMenuActions(_ input: HarnessComposerInputPolicy) -> ComposerPlusMenu.Actions {
        ComposerPlusMenu.Actions(
            addFiles: {
                addMenuPage = nil
                if let chosen = ComposerFilePicker.chooseFiles(policy: input) { draft.add(chosen: chosen) }
            },
            addFolder: {
                addMenuPage = nil
                if let chosen = ComposerFilePicker.chooseFolders() { draft.add(chosen: chosen) }
            },
            openCommands: commandContext == nil || onReadCommands == nil ? nil : {
                commandSearch = ""
                addMenuPage = .commands
                loadCommands()
            },
            openConnectors: nil)
    }

    /// "+" → "Slash commands": the search and the list, with the way back.
    private var commandsPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            ComposerMenuBackHeader(title: L10n.string("Slash commands")) { addMenuPage = .additions }
            TextField(L10n.string("Search commands"), text: $commandSearch).textFieldStyle(.roundedBorder)
                .onSubmit {
                    if let command = ComposerCommands.matching(commands, query: commandSearch).first { insertCommand(command) }
                }
                .padding(.horizontal, 3)
            ComposerCommandPicker(commands: commands, query: commandSearch, isLoading: isLoadingCommands,
                                  error: commandError, onSelect: insertCommand)
        }
        .padding(5).frame(width: 340)
        .onMacShortcutExit { addMenuPage = nil }
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
        addMenuPage = nil
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

    /// A line in the composer that says what is missing, with the button that fixes it; `prominent` when that
    /// button is the only way on.
    private func homeGuidance(_ message: String, action: String, prominent: Bool = false,
                              perform: @escaping () -> Void) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Text(L10n.string(message)).foregroundStyle(.secondary)
                guidanceButton(action, prominent: prominent, perform: perform)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string(message)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                guidanceButton(action, prominent: prominent, perform: perform)
            }
        }
        .font(.parity(.control, scale: interfaceScale))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    @ViewBuilder
    private func guidanceButton(_ title: String, prominent: Bool, perform: @escaping () -> Void) -> some View {
        if prominent {
            Button(L10n.string(title), action: perform).parityProminentButton().parityPointer()
        } else {
            Button(L10n.string(title), action: perform).parityPointer()
        }
    }
}
