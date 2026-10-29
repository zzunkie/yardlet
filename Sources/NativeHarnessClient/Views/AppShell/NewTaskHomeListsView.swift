import AppKit
import SwiftUI

/// The new-task screen's projects (`NewTaskHomeListsProjection.projectSummaries`), or the folder's
/// rows over the composer. Each project, then the chats, shows its tasks that need the person or run,
/// its latest results, its pull requests and what comes up there; choosing a project starts the new
/// task there, as the title's project menu does. The projects stand side by side in as many columns
/// as fit (`NewTaskHomeLayout.columns`), the one that needs the person most first, and keep their
/// places while the screen shows. When there is no project to show, the recent tasks.
///
/// Both parts share one keyboard (`NewTaskHomeListKeyboard`): ↓ goes from the projects' last line to
/// the folder's rows, and the part holding the highlighted line has the focus. A click does what
/// Return does. A task that waits on the person or holds an unread result is answered in the
/// composer's place (`NewTaskHomeAction.reply`); a double-click, or Return on the line already being
/// answered, opens it. The tasks it reads are asked about by the pull request lookup while it shows
/// (`TaskPullRequestMonitor.showHome`), as a sidebar row's task is.
struct NewTaskHomeLists: View {
    enum Part: Hashable {
        case projects
        /// The folder's rows that start something, over the composer.
        case folder
    }

    let part: Part
    let folder: URL?
    let startsChat: Bool
    /// The folder is in Git and belongs to a project, so New worktree can be chosen.
    let canUseWorktree: Bool
    let startsInNewWorktree: Bool
    let git: NewTaskFolderGitState
    let activity: NewTaskHomeActivity
    let rowLimit: Int
    /// How many projects stand side by side.
    var columns = 1
    /// The project the new task starts in.
    var selectedProjectID: UUID?
    /// The task the composer answers now, whose line stays marked.
    var replyTaskID: UUID?
    var recentSessions: [SessionRecord] = []
    var projectName: (URL) -> String = { $0.lastPathComponent }
    var onImportConversation: (() -> Void)? = nil
    var onImportFromOtherApps: (() -> Void)? = nil
    var onSelectSession: (SessionRecord) -> Void = { _ in }
    let onAction: (NewTaskHomeAction) -> Void
    @Binding var keyboard: NewTaskHomeListKeyboard
    var focus: FocusState<Part?>.Binding
    /// The lines this part lists now, in the keyboard's order.
    let onListed: (Part, [NewTaskHomeListKeyboard.Entry]) -> Void
    let onReturnToComposer: () -> Void
    /// Reads a project's primary folder: its branch and uncommitted files.
    var readFolderGit: @Sendable (URL) async -> NewTaskFolderGitState = { await NewTaskFolderGitState.read($0) }
    /// Reads what a project left alone for a while left unfinished in its folder.
    var readLeftWork: @Sendable (URL) async -> GitLeftWork? = { await GitLeftWork.read($0) }
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    @Environment(TaskPullRequestMonitor.self) private var pullRequests: TaskPullRequestMonitor?
    @State private var expanded: Set<NewTaskHomeSection> = []
    /// The projects' places since the screen appeared (`NewTaskHomeListsProjection.keepingPlaces`).
    @State private var places: [String] = []
    @State private var projectGit: [UUID: NewTaskFolderGitState] = [:]
    /// What the projects left alone for a while left in their folders.
    @State private var leftWork: [UUID: GitLeftWork] = [:]
    /// This screen's own set of tasks in the pull request lookup (a split view can show several).
    @State private var screenID = UUID()

    /// Lines a project shows before "Show {count} more" (the Claude app's projects show three, `pU`).
    static let projectLines = 3
    /// The folder's rows over the composer: the same-folder warning first, then one that starts something.
    static let folderLines = 2

    private func pullRequest(_ id: UUID) -> TaskPullRequest? { pullRequests?.pullRequest(for: id) }

    private var idleCandidates: [(project: Project, latest: SessionRecord)] {
        NewTaskHomeListsProjection.idleCandidates(groups: activity.groups, details: activity.details,
                                                  shellBusy: activity.shellBusy, now: activity.now)
    }

    private var idleProjects: [NewTaskIdleProject] {
        NewTaskHomeListsProjection.idleProjects(
            groups: activity.groups, details: activity.details, shellBusy: activity.shellBusy,
            work: { leftWork[$0] }, pullRequest: pullRequest, stoppedSchedules: activity.stoppedSchedules,
            isSuggestionOpen: activity.isSuggestionOpen, latestTurn: activity.latestTurn, now: activity.now)
    }

    private func summaries(leaving idle: [NewTaskIdleProject]) -> [NewTaskProjectSummary] {
        NewTaskHomeListsProjection.keepingPlaces(places, of: NewTaskHomeListsProjection.projectSummaries(
            groups: activity.groups, chats: activity.chats, details: activity.details,
            shellBusy: activity.shellBusy, pullRequest: pullRequest, schedules: activity.schedules,
            isSuggestionOpen: activity.isSuggestionOpen, agents: activity.agents, answerLine: activity.answerLine,
            latestTurn: activity.latestTurn, leaving: Set(idle.map(\.id)), now: activity.now))
    }

    /// The folder's rows that start something: the same-folder warning, failing checks, a branch to
    /// continue. A waiting task and the latest one are already the project's own lines.
    private var folderRows: [NewTaskFolderRow] {
        NewTaskHomeListsProjection.folderRows(
            folder: folder, startsChat: startsChat, isInRepository: canUseWorktree,
            startsInNewWorktree: startsInNewWorktree, git: git, sessions: activity.sessions,
            details: activity.details, shellBusy: activity.shellBusy, pullRequest: pullRequest)
        .filter { row in
            switch row {
            case .waiting, .resume: false
            case .runningHere, .failingChecks, .continueBranch: true
            }
        }
    }

    private var pullRequestTargets: [TaskPullRequestTarget] {
        NewTaskHomeListsProjection.pullRequestCandidates(folder: startsChat ? nil : folder, sessions: activity.sessions,
                                                         idle: idleCandidates.map(\.latest))
            .map { TaskPullRequestTarget(session: $0) }
    }

    private func isChosen(_ summary: NewTaskProjectSummary) -> Bool {
        switch summary.place {
        case let .project(project): !startsChat && project.id == selectedProjectID
        case .chats: startsChat
        }
    }

    /// What the part shows now, in the keyboard's order.
    private struct Layout {
        struct Panel {
            let summary: NewTaskProjectSummary
            let isChosen: Bool
            let tasks: [NewTaskProjectTask]
            let upcoming: [NewTaskUpcomingRow]
            let hidden: Int
            let isExpanded: Bool

            var section: NewTaskHomeSection { .project(summary.id) }

            var entries: [NewTaskHomeListKeyboard.Entry] {
                [.row(section, NewTaskHomeListKeyboard.headerID)]
                    + tasks.map { .row(section, $0.id.uuidString) }
                    + upcoming.map { .row(section, $0.id) }
                    + (hidden > 0 || isExpanded ? [.toggle(section)] : [])
            }
        }

        /// The projects left alone for a while, as one more panel among the projects.
        struct Idle {
            let projects: [NewTaskIdleProject]
            let hidden: Int
            let isExpanded: Bool

            var entries: [NewTaskHomeListKeyboard.Entry] {
                projects.map { .row(.idle, $0.id.uuidString) } + (hidden > 0 || isExpanded ? [.toggle(.idle)] : [])
            }
        }

        enum Item: Identifiable {
            case project(Panel)
            case idle(Idle)

            var id: String {
                switch self {
                case let .project(panel): panel.summary.id
                case .idle: "idle"
                }
            }

            var entries: [NewTaskHomeListKeyboard.Entry] {
                switch self {
                case let .project(panel): panel.entries
                case let .idle(idle): idle.entries
                }
            }
        }

        var panels: [Panel] = []
        var idle: Idle?
        /// How many projects stand side by side; the idle panel follows their first row.
        var columns = 1
        /// Projects past the screen's share, behind "Show {count} more".
        var hiddenProjects = 0
        var showsAllProjects = false
        var folderRows: [NewTaskFolderRow] = []

        /// The panels in the order they are dealt into the columns: the first row of projects, the
        /// projects left alone for a while, then the rest, so what needs the person keeps the top and
        /// what was left stays in sight.
        var items: [Item] {
            var items = panels.map(Item.project)
            if let idle { items.insert(.idle(idle), at: min(columns, items.count)) }
            return items
        }

        var entries: [NewTaskHomeListKeyboard.Entry] {
            items.flatMap(\.entries)
                + (hiddenProjects > 0 || showsAllProjects ? [.toggle(.moreProjects)] : [])
                + folderRows.map { .row(.folder, $0.id) }
        }
    }

    /// Projects left alone for a while the panel names before "Show {count} more".
    static let idleLines = 3

    private func layout(_ summaries: [NewTaskProjectSummary], idle: [NewTaskIdleProject] = []) -> Layout {
        guard part == .projects else { return Layout(folderRows: Array(folderRows.prefix(Self.folderLines))) }
        let idleExpanded = expanded.contains(.idle)
        let idlePanel = idle.isEmpty ? nil : Layout.Idle(
            projects: idleExpanded ? idle : Array(idle.prefix(Self.idleLines)),
            hidden: idleExpanded ? 0 : max(0, idle.count - Self.idleLines),
            isExpanded: idleExpanded && idle.count > Self.idleLines)
        /// A project's tasks and then what comes up there, `projectLines` of them before "Show more".
        func panel(_ summary: NewTaskProjectSummary) -> Layout.Panel {
            let isExpanded = expanded.contains(.project(summary.id))
            let total = summary.tasks.count + summary.upcoming.count
            let shown = isExpanded ? total : min(total, Self.projectLines)
            let tasks = Array(summary.tasks.prefix(shown))
            return Layout.Panel(summary: summary, isChosen: isChosen(summary), tasks: tasks,
                                upcoming: Array(summary.upcoming.prefix(shown - tasks.count)),
                                hidden: total - shown, isExpanded: isExpanded && total > Self.projectLines)
        }
        // As many projects as the window's height gives each column lines for (the Claude app's
        // section limit, `dU`), the rest behind "Show more".
        let share = rowLimit * max(1, columns)
        let showsAll = expanded.contains(.moreProjects)
        let shown = showsAll ? summaries : Array(summaries.prefix(share))
        return Layout(panels: shown.map(panel), idle: idlePanel, columns: max(1, columns),
                      hiddenProjects: summaries.count - shown.count,
                      showsAllProjects: showsAll && summaries.count > share)
    }

    var body: some View {
        let idle = part == .projects ? idleProjects : []
        let summaries = part == .projects ? summaries(leaving: idle) : []
        let layout = layout(summaries, idle: idle)

        Group {
            switch part {
            case .folder:
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(layout.folderRows) { row in
                        NewTaskHomeRow(isHighlighted: isHighlighted(.row(.folder, row.id)),
                                       action: { onAction(row.action) }) {
                            folderRow(row)
                        }
                    }
                }
            case .projects:
                if summaries.isEmpty && idle.isEmpty {
                    if !recentSessions.isEmpty || onImportConversation != nil { recentTasks }
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        columns(layout)
                        if layout.hiddenProjects > 0 || layout.showsAllProjects {
                            NewTaskHomeRow(isHighlighted: isHighlighted(.toggle(.moreProjects)), showsChevron: false,
                                           action: { toggle(.moreProjects) }) {
                                Text(layout.showsAllProjects ? L10n.string("Show less")
                                     : L10n.format("Show %lld more", layout.hiddenProjects))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .task(id: summaries.compactMap(\.project?.primaryRoot)) { await readGit(of: summaries) }
                }
            }
        }
        .task(id: part == .projects ? idleCandidates.map(\.project.primaryRoot) : []) {
            guard part == .projects else { return }
            await readLeftWork(of: idleCandidates.map(\.project))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusable(!layout.entries.isEmpty, interactions: .edit)
        .focused(focus, equals: part)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { handle(.up, layout: layout) }
        .onKeyPress(.downArrow) { handle(.down, layout: layout) }
        .onKeyPress(.return) { handle(.return, layout: layout) }
        .onKeyPress(keys: [.tab, KeyEquivalent(Character(UnicodeScalar(NSBackTabCharacter)!))]) { _ in
            handle(.tab, layout: layout)
        }
        .onChange(of: layout.entries, initial: true) { _, entries in onListed(part, entries) }
        .onChange(of: summaries.map(\.id), initial: true) { _, ids in
            places = NewTaskHomeListsProjection.places(places, listing: ids)
        }
        .task(id: part == .projects ? pullRequestTargets : []) {
            guard part == .projects else { return }
            pullRequests?.showHome(pullRequestTargets, screen: screenID)
        }
        .onDisappear { if part == .projects { pullRequests?.showHome([], screen: screenID) } }
    }

    /// The projects in columns that stack on their own, so a long project leaves no gap beside it;
    /// they are dealt left to right, the one that needs the person most first.
    private func columns(_ layout: Layout) -> some View {
        let count = max(1, columns)
        let items = layout.items
        return HStack(alignment: .top, spacing: NewTaskHomeLayout.columnSpacing) {
            ForEach(0..<count, id: \.self) { column in
                VStack(alignment: .leading, spacing: 34) {
                    ForEach(Array(items.enumerated()).filter { $0.offset % count == column }, id: \.element.id) { item in
                        switch item.element {
                        case let .project(project): panel(project)
                        case let .idle(idle): idlePanel(idle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    /// Each shown project's primary folder, read once per screen and project.
    private func readGit(of summaries: [NewTaskProjectSummary]) async {
        for project in summaries.compactMap(\.project) where projectGit[project.id] == nil {
            let state = await readFolderGit(project.primaryRoot)
            guard !Task.isCancelled else { return }
            projectGit[project.id] = state
        }
    }

    /// What each project that may have been left holds in its folder, read once per screen and project
    /// (and at most every few minutes across screens, `GitLeftWork.readingLifetime`).
    private func readLeftWork(of projects: [Project]) async {
        for project in projects where leftWork[project.id] == nil {
            let work = await readLeftWork(project.primaryRoot)
            guard !Task.isCancelled else { return }
            leftWork[project.id] = work ?? GitLeftWork()
        }
    }

    // MARK: - Projects left alone for a while

    /// The projects left alone for a while that still hold unfinished work: the name, when it was last
    /// active and what it left. Choosing one starts the new task there; a double-click opens the task
    /// it was left at; its ✕ sets it aside until it is active again.
    private func idlePanel(_ idle: Layout.Idle) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(L10n.string("Left for a while"))
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 32, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ForEach(idle.projects) { project in
                NewTaskHomeRow(isHighlighted: isHighlighted(.row(.idle, project.id.uuidString)),
                               markRead: { activity.onSetAside(project.id, project.lastActive) },
                               markReadLabel: L10n.string("Dismiss until it is active again"), action: {
                    if NSEvent.modifierFlags.contains(.command), let pr = project.pullRequests.first {
                        openURL(pr.pullRequest.url)
                    } else {
                        onAction(Self.action(project, opens: (NSApp.currentEvent?.clickCount ?? 1) > 1))
                    }
                }) {
                    idleLine(project)
                }
                .help(L10n.format("Start a task in %@", project.project.name) + "\n"
                      + L10n.format("Double-click to open “%@”", project.latestTask.title))
            }
            if idle.hidden > 0 || idle.isExpanded {
                NewTaskHomeRow(isHighlighted: isHighlighted(.toggle(.idle)), showsChevron: false,
                               action: { toggle(.idle) }) {
                    Text(idle.isExpanded ? L10n.string("Show less") : L10n.format("Show %lld more", idle.hidden))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 23)
                }
            }
        }
    }

    /// A project left alone: its name and how long ago, and what it left under them.
    private func idleLine(_ idle: NewTaskIdleProject) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Text(idle.project.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    NewTaskHomeTime(date: idle.lastActive)
                }
                Text(idle.workLeft.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 5)
    }

    // MARK: - A project

    private func panel(_ panel: Layout.Panel) -> some View {
        let summary = panel.summary
        let section = panel.section
        return VStack(alignment: .leading, spacing: 1) {
            NewTaskHomeRow(isHighlighted: isHighlighted(.row(section, NewTaskHomeListKeyboard.headerID)),
                           showsChevron: false, action: {
                // ⌘-click opens the project's pull request on GitHub, as a pull request line did.
                if NSEvent.modifierFlags.contains(.command), let pr = summary.pullRequests.first {
                    openURL(pr.pullRequest.url)
                } else {
                    onAction(Self.choose(summary))
                }
            }) {
                header(summary, isChosen: panel.isChosen)
            }
            .help(Self.chooseHelp(summary))
            .accessibilityValue(panel.isChosen ? L10n.string("New tasks start here") : "")
            ForEach(panel.tasks) { task in
                let answers = Self.answersInPlace(task)
                NewTaskHomeRow(isHighlighted: isHighlighted(.row(section, task.id.uuidString)),
                               isAnswering: replyTaskID == task.id,
                               symbol: answers ? "arrowshape.turn.up.left" : "chevron.right",
                               markRead: Self.canMarkRead(task) ? { activity.onMarkRead([task.id]) } : nil,
                               action: {
                    // ⌘-click opens the task's pull request on GitHub; a double-click opens the task.
                    if NSEvent.modifierFlags.contains(.command), let pr = pullRequest(task.id), pr.hasState {
                        openURL(pr.url)
                    } else {
                        onAction(Self.action(task, opens: (NSApp.currentEvent?.clickCount ?? 1) > 1))
                    }
                }) {
                    taskLine(task)
                }
                .accessibilityAddTraits(replyTaskID == task.id ? .isSelected : [])
            }
            ForEach(panel.upcoming) { row in
                NewTaskHomeRow(isHighlighted: isHighlighted(.row(section, row.id)),
                               action: { onAction(Self.action(row)) }) {
                    upcomingLine(row)
                }
            }
            if panel.hidden > 0 || panel.isExpanded {
                NewTaskHomeRow(isHighlighted: isHighlighted(.toggle(section)), showsChevron: false,
                               action: { toggle(section) }) {
                    Text(panel.isExpanded ? L10n.string("Show less") : L10n.format("Show %lld more", panel.hidden))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 23)
                }
            }
        }
    }

    /// The project's name (the chosen one tinted), what its folder is on and what it finished
    /// today, and its open pull requests.
    private func header(_ summary: NewTaskProjectSummary, isChosen: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: summary.project == nil ? "bubble.left" : (isChosen ? "folder.fill" : "folder"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isChosen ? AnyShapeStyle(ParityTheme.accent) : AnyShapeStyle(.secondary))
                .frame(width: 16)
            Text(summary.name)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(isChosen ? AnyShapeStyle(ParityTheme.accent) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .layoutPriority(1)
            if let facts = facts(summary, isChosen: isChosen) {
                Text(facts)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if let first = summary.pullRequests.first {
                pill(first)
                if summary.pullRequests.count > 1 {
                    Text(verbatim: "+\(summary.pullRequests.count - 1)")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .help(summary.pullRequests.dropFirst().map { "#\($0.pullRequest.number) \($0.pill.title)" }
                            .joined(separator: "\n"))
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// What the project's folder is on, when it is not the default branch, and what finished today.
    /// The chosen project's folder is the one the composer read.
    private func facts(_ summary: NewTaskProjectSummary, isChosen: Bool) -> String? {
        var parts: [String] = []
        if let project = summary.project {
            let state = isChosen && folder.map({ Project.isSamePath($0, project.primaryRoot) }) == true
                ? git : projectGit[project.id]
            if let state, let branch = state.branch, !state.isDefaultBranch {
                parts.append(branch)
                if let count = state.uncommittedFiles, count > 0 {
                    parts.append(count == 1 ? L10n.string("1 uncommitted file")
                                 : L10n.format("%lld uncommitted files", count))
                }
            }
        }
        if summary.finishedToday > 0 { parts.append(L10n.format("%lld finished today", summary.finishedToday)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func taskLine(_ task: NewTaskProjectTask) -> some View {
        switch task {
        case let .attention(row) where row.waitsOnPerson:
            SidebarTaskStatusView(status: row.status)
                .accessibilityHidden(true)
            Text(row.status.homeName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            taskName(row.session, weight: .medium)
            if let detail = row.status.homeDetail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            pullRequestNumber(row.session)
            Spacer(minLength: 8)
            NewTaskHomeTime(date: row.session.updatedAt)
        case let .attention(row):
            SidebarTaskStatusView(status: row.status)
                .accessibilityHidden(true)
            withAnswer(row.answerLine) {
                taskName(row.session, weight: .semibold)
                pullRequestNumber(row.session)
                Spacer(minLength: 8)
                NewTaskHomeTime(date: row.session.updatedAt)
            }
        case let .running(row):
            SidebarTaskStatusView(status: .running)
                .accessibilityHidden(true)
            taskName(row.session, weight: .medium)
            if row.subtasks > 0 {
                Text(row.subtasks == 1 ? L10n.string("1 subtask") : L10n.format("%lld subtasks", row.subtasks))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .fixedSize()
            }
            Spacer(minLength: 8)
            NewTaskHomeElapsed(since: row.since)
        case let .recent(session, answerLine):
            Color.clear.frame(width: 14, height: 14)
            withAnswer(answerLine) {
                taskName(session, weight: .regular)
                pullRequestNumber(session)
                Spacer(minLength: 8)
                NewTaskHomeTime(date: session.updatedAt)
            }
        }
    }

    /// A line of a task's name and time, with its latest answer's first line under it.
    private func withAnswer<Line: View>(_ answer: String?, @ViewBuilder line: () -> Line) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) { line() }
            if let answer {
                Text(answer)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 21)
            }
        }
        .padding(.vertical, answer == nil ? 0 : 5)
    }

    @ViewBuilder
    private func upcomingLine(_ row: NewTaskUpcomingRow) -> some View {
        switch row {
        case let .schedule(schedule, nextRun):
            Image(systemName: "clock")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
            HarnessIdentityIcon(harness: schedule.destination.harness, size: 14)
                .accessibilityLabel(schedule.destination.harness.displayName)
            Text(schedule.name)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Text(Self.nextRunText(nextRun, now: activity.now))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        case let .suggestion(suggestion, task):
            Image(systemName: "lightbulb")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
            Text(suggestion.title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)
            Text(L10n.format("Suggested in %@", task.title))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
        }
    }

    @ViewBuilder
    private func folderRow(_ row: NewTaskFolderRow) -> some View {
        Image(systemName: row.systemImage)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(row.tint)
            .frame(width: 14, height: 14)
        Text(row.title)
            .foregroundStyle(.primary)
            .font(.system(size: 13))
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(1)
        if let detail = row.detail {
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        Spacer(minLength: 8)
    }

    private func taskName(_ session: SessionRecord, weight: Font.Weight) -> some View {
        HStack(spacing: 7) {
            HarnessIdentityIcon(harness: session.harness, size: 14)
                .accessibilityHidden(false)
                .accessibilityLabel(session.harness.displayName)
            Text(session.title)
                .foregroundStyle(.primary)
                .font(.system(size: 13, weight: weight))
                .lineLimit(1)
        }
        .layoutPriority(1)
    }

    @ViewBuilder
    private func pullRequestNumber(_ session: SessionRecord) -> some View {
        if let pr = pullRequests?.pullRequest(for: session.id), pr.hasState {
            Text(verbatim: "#\(pr.number)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    /// An open pull request's Claude-app pill with its number. ⌘-clicking the project's line opens it.
    private func pill(_ row: NewTaskPullRequestRow) -> some View {
        let pill = row.pill
        return HStack(spacing: 4) {
            Text(verbatim: "#\(row.pullRequest.number)").monospacedDigit()
            Text(pill.title)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(TaskPullRequestBadgeView.color(pill.tone))
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(TaskPullRequestBadgeView.color(pill.tone).opacity(0.12), in: Capsule())
        .fixedSize()
        .help(row.pullRequest.url.absoluteString)
    }

    private var recentTasks: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                ParitySectionTitle(title: L10n.string("Recent tasks"))
                if let onImportConversation {
                    Button(L10n.string("Import conversation…"), action: onImportConversation)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(L10n.string("Continue a conversation started in the Claude or Codex app or in Antigravity CLI."))
                }
                if let onImportFromOtherApps {
                    Button(L10n.string("Import Conversations from Other Apps…"), action: onImportFromOtherApps)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(L10n.string("Bring in the conversations open in the Claude and Codex apps."))
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            ForEach(recentSessions) { session in
                RecentTaskButton(session: session, projectName: projectName(session.workspaceURL)) {
                    onSelectSession(session)
                }
            }
        }
    }

    // MARK: - Words

    /// "Today 3:00 PM" or "Tomorrow 9:00 AM": a schedule's next run within the coming day.
    static func nextRunText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return L10n.format("Today %@", time) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return L10n.format("Tomorrow %@", time)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func chooseHelp(_ summary: NewTaskProjectSummary) -> String {
        summary.project == nil ? L10n.string("Start a chat with no project") : L10n.format("Start a task in %@", summary.name)
    }

    // MARK: - Choosing

    static func choose(_ summary: NewTaskProjectSummary) -> NewTaskHomeAction {
        summary.project.map { .chooseProject($0.id) } ?? .chooseChat
    }

    static func canMarkRead(_ task: NewTaskProjectTask) -> Bool {
        if case let .attention(row) = task { return row.canMarkRead }
        return false
    }

    /// A task that waits on the person or holds an unread result is answered in the composer's place.
    static func answersInPlace(_ task: NewTaskProjectTask) -> Bool {
        if case .attention = task { return true }
        return false
    }

    /// What choosing a task's line does: one that needs the person is answered in the composer's
    /// place unless `opens` (a double-click, or Return on the line already answered); any other opens.
    static func action(_ task: NewTaskProjectTask, opens: Bool) -> NewTaskHomeAction {
        answersInPlace(task) && !opens ? .reply(task.id) : .openTask(task.id)
    }

    private func isHighlighted(_ entry: NewTaskHomeListKeyboard.Entry) -> Bool {
        focus.wrappedValue == part && keyboard.highlightedEntry == entry
    }

    private func toggle(_ section: NewTaskHomeSection) {
        if expanded.contains(section) { expanded.remove(section) } else { expanded.insert(section) }
    }

    private func handle(_ key: NewTaskHomeListKeyboard.Key, layout: Layout) -> KeyPress.Result {
        switch keyboard.press(key) {
        case .handled:
            // The highlight moved to the other part's lines: that part takes the keyboard.
            if let entry = keyboard.highlightedEntry, entry.part != part { focus.wrappedValue = entry.part }
            return .handled
        case .ignored: return .ignored
        case .returnToComposer:
            onReturnToComposer()
            return .handled
        case let .perform(entry):
            switch entry {
            case let .toggle(section):
                toggle(section)
            case let .row(section, id):
                guard let action = action(section: section, id: id, layout: layout) else { return .ignored }
                onAction(action)
            }
            return .handled
        }
    }

    private func action(section: NewTaskHomeSection, id: String, layout: Layout) -> NewTaskHomeAction? {
        switch section {
        case .folder:
            return layout.folderRows.first { $0.id == id }?.action
        case .moreProjects:
            return nil
        case .idle:
            return layout.idle?.projects.first { $0.id.uuidString == id }.map { Self.action($0, opens: false) }
        case let .project(projectID):
            guard let panel = layout.panels.first(where: { $0.summary.id == projectID }) else { return nil }
            if id == NewTaskHomeListKeyboard.headerID { return Self.choose(panel.summary) }
            if let task = panel.tasks.first(where: { $0.id.uuidString == id }) {
                return Self.action(task, opens: task.id == replyTaskID)
            }
            return panel.upcoming.first { $0.id == id }.map(Self.action)
        }
    }

    /// A project left alone for a while: choosing it starts the new task there, as a project's name
    /// does; `opens` (a double-click) opens the task it was left at.
    static func action(_ idle: NewTaskIdleProject, opens: Bool) -> NewTaskHomeAction {
        opens ? .openTask(idle.latestTask.id) : .chooseProject(idle.project.id)
    }

    /// A schedule opens Scheduled tasks; a suggestion opens the task whose conversation shows its chip.
    static func action(_ row: NewTaskUpcomingRow) -> NewTaskHomeAction {
        switch row {
        case let .schedule(schedule, _): .openSchedule(schedule.id)
        case let .suggestion(_, task): .openTask(task.id)
        }
    }
}

private extension NewTaskHomeListKeyboard.Entry {
    /// The part of the screen that lists the line.
    var part: NewTaskHomeLists.Part {
        switch self {
        case .row(.folder, _), .toggle(.folder): .folder
        default: .projects
        }
    }
}

private extension SidebarTaskStatus {
    /// The state's name on a waiting task's line: the sidebar's words, shorter for a failed turn and a
    /// plan limit, whose error or reset follows the title (`homeDetail`).
    var homeName: String {
        switch self {
        case .failed: L10n.string("Failed")
        case .usageLimit: L10n.string("Usage limit")
        default: accessibilityName
        }
    }

    var homeDetail: String? {
        switch self {
        case let .failed(message?):
            let summary = TranscriptRecoveryProjection.errorSummary(message)
            return summary.isEmpty ? nil : ConversationLineWording.oneLine(summary)
        case let .usageLimit(limit):
            return ProviderNoticeText.limitReset(limit)
        default:
            return nil
        }
    }
}

private extension NewTaskFolderRow {
    var tint: Color {
        switch self {
        case .waiting(_, .approval): .green
        case .waiting(_, .input): .orange
        case .runningHere: .orange
        case .failingChecks: .red
        case .continueBranch, .resume: .secondary
        }
    }
}

/// When a row's task was last active, as a short relative time ("3 min. ago").
private struct NewTaskHomeTime: View {
    let date: Date

    var body: some View {
        Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
            .font(.system(size: 11.5).monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// How long a running task's turn has run ("12 min"), redrawn each minute.
private struct NewTaskHomeElapsed: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 60)) { context in
            Text(L10n.format("%@ so far", Self.duration(from: since, to: context.date)))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    static func duration(from start: Date, to end: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = end.timeIntervalSince(start) < 3600 ? [.minute] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(60, end.timeIntervalSince(start))) ?? ""
    }
}

/// One row of the new-task lists: its content in a line, a chevron (a reply arrow where the task is
/// answered in the composer's place), the keyboard's highlight or the pointer's, the mark of the task
/// the composer answers, and, for an unread result, a mark-as-read button while the pointer is on it
/// (for a project left alone for a while, its Dismiss).
private struct NewTaskHomeRow<Content: View>: View {
    var isHighlighted = false
    /// The composer answers this row's task.
    var isAnswering = false
    var showsChevron = true
    var symbol = "chevron.right"
    var markRead: (() -> Void)? = nil
    /// What the ✕ that `markRead` puts on the row says.
    var markReadLabel = L10n.string("Mark task as read")
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var isHovering = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: action) {
                HStack(spacing: 7) {
                    content
                    if showsChevron {
                        Image(systemName: symbol)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isAnswering ? AnyShapeStyle(ParityTheme.accent) : AnyShapeStyle(.tertiary))
                            .opacity(isHovering && markRead != nil ? 0 : 1)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 32 * interfaceScale)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .parityPointer()

            if isHovering, let markRead {
                Button(action: markRead) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .parityPointer()
                .help(markReadLabel)
                .accessibilityLabel(markReadLabel)
                .padding(.trailing, 6)
            }
        }
        .background(
            isHighlighted || isAnswering ? ParityTheme.selectedFill : (isHovering ? ParityTheme.hoverFill : .clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .onHover { isHovering = $0 }
    }
}

/// A recent task, listed when there is nothing that needs the person and no open pull request.
private struct RecentTaskButton: View {
    let session: SessionRecord
    let projectName: String
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                HarnessIdentityIcon(harness: session.harness, size: 16 * interfaceScale)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(projectName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("· \(session.harness.displayName)")
                            .fixedSize()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(session.status.displayName)
                    .font(.caption)
                    .foregroundStyle(session.status == .failed ? .red : .secondary)
                    .fixedSize()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 48 * interfaceScale)
            .contentShape(Rectangle())
            .background(
                isHovering ? ParityTheme.hoverFill : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .onHover { isHovering = $0 }
    }
}
