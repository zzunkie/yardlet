import SwiftUI
import YardletRemote

/// A Mac's tasks: what waits for the person first, then Pinned, then either every other task by when it last moved
/// (Home, as the Claude and ChatGPT phone apps list them) or each project and Chats as the Mac's sidebar groups them
/// (Projects), with subtasks folded under their parents (docs/REMOTE_PROTOCOL.md §4.1). Its scheduled tasks open from
/// the bar when the Mac offers them (§15.21).
struct HomeView: View {
    @Environment(PhoneModel.self) private var model
    let session: HostSession
    /// Tasks by their ID, and the Schedules screen.
    @State private var path = NavigationPath()
    @State private var view = ListView.home
    @State private var search = ""
    @State private var expanded: Set<String> = []
    @State private var isShowingSettings = false
    @State private var isStartingTask = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !search.isEmpty {
                    ForEach(matches, id: \.id) { task in
                        link(task, depth: 0, showsProject: true)
                    }
                } else if session.hasSnapshot && session.tasks.isEmpty {
                    emptyState
                } else {
                    if !session.tasks.isEmpty {
                        Picker("View", selection: $view) {
                            Text("Home").tag(ListView.home)
                            Text("Projects").tag(ListView.projects)
                        }
                        .pickerStyle(.segmented)
                        .listRowSeparator(.hidden)
                    }
                    sections
                }
            }
            .listStyle(.plain)
            .overlay {
                if !session.hasSnapshot && session.tasks.isEmpty, case .connecting = session.connection {
                    ProgressView()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner(session: session) }
            .safeAreaInset(edge: .bottom, spacing: 0) { CommandErrorBanner(session: session).padding(.bottom, 8) }
            .refreshable { await session.refresh() }
            .searchable(text: $search, prompt: Text("Search tasks"))
            .navigationTitle(session.name)
            .toolbarTitleMenu { macMenu }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                if session.scheduledTasks {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            path.append(SchedulesRoute())
                        } label: {
                            Image(systemName: "clock")
                        }
                        .accessibilityLabel("Scheduled Tasks")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isStartingTask = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New Task")
                    .disabled(session.newTask == nil || !session.isConnected)
                }
            }
            .navigationDestination(for: String.self) { taskID in
                TaskView(session: session, taskID: taskID)
            }
            .navigationDestination(for: SchedulesRoute.self) { _ in
                SchedulesView(session: session)
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $isStartingTask) {
                NewTaskView(session: session) { taskID in
                    isStartingTask = false
                    path.append(taskID)
                }
            }
            #if DEBUG
            // Screenshots without touching the screen: `-sheet newTask`, `-sheet settings` or `-sheet schedules` at launch.
            .task {
                guard let sheet = UserDefaults.standard.string(forKey: "sheet") else { return }
                try? await Task.sleep(for: .seconds(1.5))
                if sheet == "newTask" { isStartingTask = true }
                if sheet == "settings" { isShowingSettings = true }
                if sheet == "schedules" { path.append(SchedulesRoute()) }
            }
            #endif
            .onChange(of: model.taskToOpen, initial: true) { _, taskID in
                guard let taskID else { return }
                model.taskToOpen = nil
                path = NavigationPath([taskID])
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if session.isDemo { demoBar }
            }
        }
        // A task a conversation's link or a schedule's run names opens as the list opens it.
        .environment(\.openTask, OpenTaskAction { path.append($0) })
    }

    // MARK: - Sections

    enum ListView: Hashable {
        case home
        case projects
    }

    @ViewBuilder
    private var sections: some View {
        let waiting = session.tasks.filter { $0.attention == .waiting }
        if !waiting.isEmpty {
            Section("Waiting for You") {
                ForEach(waiting, id: \.id) { task in
                    link(task, depth: 0, showsProject: true)
                }
            }
        }
        let rest = session.tasks.filter { $0.attention != .waiting }
        // The sidebar's Pinned is a list of its own, so a pinned task's pinned subtasks fold under it there.
        let pinned = Array(trees(rest.filter(\.pinned)).joined())
        if !pinned.isEmpty {
            Section("Pinned") {
                rows(pinned, showsProject: true)
            }
        }
        switch view {
        case .home:
            // By time alone: a chat that moved a minute ago comes before a project's task idle since morning.
            let recent = trees(rest.filter { !$0.pinned }).sorted { $0[0].latestActivityAt > $1[0].latestActivityAt }
            if !recent.isEmpty {
                Section("Recent") {
                    rows(Array(recent.joined()), showsProject: true)
                }
            }
        case .projects:
            ForEach(projectsWithTasks, id: \.project.id) { entry in
                Section(entry.project.name) {
                    rows(entry.rows, showsProject: false)
                }
            }
        }
    }

    private func rows(_ rows: [Row], showsProject: Bool) -> some View {
        ForEach(rows, id: \.task.id) { row in
            link(row.task, depth: row.depth, showsProject: showsProject && row.depth == 0, children: row.children,
                 activityAt: row.depth == 0 ? row.latestActivityAt : row.task.lastActivityAt)
        }
    }

    private struct Row {
        var task: RemoteTask
        var depth: Int
        var children: Int
        /// When this task or one folded under it last moved, which places a parent in Recent.
        var latestActivityAt: Int64
    }

    /// `tasks` with each one whose parent is among them folded under that parent: one group of rows per top-level
    /// task, in the order given, with a parent's subtasks listed while it is opened.
    private func trees(_ tasks: [RemoteTask]) -> [[Row]] {
        let ids = Set(tasks.map(\.id))
        var children: [String: [RemoteTask]] = [:]
        for task in tasks {
            if let parent = task.parentTaskId, ids.contains(parent) { children[parent, default: []].append(task) }
        }
        let expanded = expanded
        func latest(_ task: RemoteTask, depth: Int) -> Int64 {
            guard depth < 8 else { return task.lastActivityAt }
            return (children[task.id] ?? []).reduce(task.lastActivityAt) { max($0, latest($1, depth: depth + 1)) }
        }
        func add(_ task: RemoteTask, depth: Int, to rows: inout [Row]) {
            let kids = children[task.id] ?? []
            rows.append(Row(task: task, depth: depth, children: kids.count,
                            latestActivityAt: depth == 0 ? latest(task, depth: 0) : task.lastActivityAt))
            guard expanded.contains(task.id), depth < 8 else { return }
            for child in kids { add(child, depth: depth + 1, to: &rows) }
        }
        return tasks.filter { !($0.parentTaskId.map(ids.contains) ?? false) }.map { task in
            var rows: [Row] = []
            add(task, depth: 0, to: &rows)
            return rows
        }
    }

    /// Each project's tasks in the Mac's sidebar order, top-level ones by recent activity.
    private var projectsWithTasks: [(project: RemoteProject, rows: [Row])] {
        let listed = session.tasks.filter { !$0.pinned && $0.attention != .waiting }
        var projects = session.projects
        // A task under a project the snapshot did not name still shows.
        let named = Set(projects.map(\.id))
        for task in listed where !named.contains(task.projectId ?? "") {
            if !projects.contains(where: { $0.id == (task.projectId ?? "") }) {
                projects.append(RemoteProject(id: task.projectId ?? "", name: String(localized: "Other"), kind: .folder))
            }
        }
        return projects.compactMap { project in
            let rows = Array(trees(listed.filter { ($0.projectId ?? "") == project.id }).joined())
            return rows.isEmpty ? nil : (project, rows)
        }
    }

    private var matches: [RemoteTask] {
        let words = search.lowercased()
        return session.tasks.filter { task in
            task.title.lowercased().contains(words) || task.harnessName.lowercased().contains(words)
                || (session.project(task.projectId)?.name.lowercased().contains(words) ?? false)
        }
    }

    private func link(_ task: RemoteTask, depth: Int, showsProject: Bool, children: Int = 0,
                      activityAt: Int64? = nil) -> some View {
        NavigationLink(value: task.id) {
            TaskRow(task: task, session: session, depth: depth, showsProject: showsProject, children: children,
                    isExpanded: expanded.contains(task.id), activityAt: activityAt) {
                if expanded.contains(task.id) { expanded.remove(task.id) } else { expanded.insert(task.id) }
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                session.send(.setPinned(taskID: task.id, pinned: !task.pinned))
            } label: {
                Label(task.pinned ? "Unpin" : "Pin", systemImage: task.pinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            Button {
                session.send(.archiveTask(taskID: task.id))
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.indigo)
        }
        .contextMenu {
            Button {
                session.send(.setPinned(taskID: task.id, pinned: !task.pinned))
            } label: {
                Label(task.pinned ? "Unpin" : "Pin", systemImage: task.pinned ? "pin.slash" : "pin")
            }
            if task.running {
                Button(role: .destructive) {
                    session.send(.stopTurn(taskID: task.id))
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
            }
            Button {
                session.send(.archiveTask(taskID: task.id))
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }
    }

    // MARK: - Pieces

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Tasks", systemImage: "tray")
        } description: {
            Text("Tasks you start on \(session.name) or here show up in this list.")
        } actions: {
            if session.newTask != nil {
                Button("New Task") { isStartingTask = true }
            }
        }
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var macMenu: some View {
        if model.hosts.count > 1 || session.isDemo {
            ForEach(model.hosts) { host in
                Button {
                    model.select(host.id)
                } label: {
                    if host.id == session.id { Label(host.name, systemImage: "checkmark") } else { Text(host.name) }
                }
            }
        }
        Button {
            isShowingSettings = true
        } label: {
            Label("Macs and Settings", systemImage: "desktopcomputer")
        }
    }

    private var demoBar: some View {
        HStack {
            Text("You're looking at a demo Mac.").font(.footnote)
            Spacer()
            Button("Leave Demo") { model.leaveDemo() }.font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// One task in the list: its mark, title, and what it runs on or what waits.
struct TaskRow: View {
    let task: RemoteTask
    let session: HostSession
    var depth = 0
    var showsProject = false
    var children = 0
    var isExpanded = false
    /// When the row says it last moved: a folded parent shows its latest subtask's time.
    var activityAt: Int64?
    var toggle: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TaskMark(indicator: task.indicator)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(task.title.isEmpty ? String(localized: "Untitled task") : task.title)
                        .font(.body.weight(task.unread || task.attention == .waiting ? .semibold : .regular))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(Formatting.shortAge(session.date(activityAt ?? task.lastActivityAt)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if task.attention == .waiting, let summary = task.pendingSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if children > 0 {
                        Button(action: toggle) {
                            HStack(spacing: 2) {
                                Text("\(children) subtasks")
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2.weight(.semibold))
                            }
                            .font(.footnote)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.leading, CGFloat(depth) * 18)
        .padding(.vertical, 2)
    }

    /// What it runs on, after its project or Chats where the list mixes them.
    private var subtitle: String {
        var parts = [task.harnessName]
        if showsProject, let project = session.project(task.projectId) { parts.insert(project.name, at: 0) }
        return parts.joined(separator: " · ")
    }
}
