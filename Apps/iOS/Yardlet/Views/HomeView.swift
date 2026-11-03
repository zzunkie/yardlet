import SwiftUI
import YardletRemote

/// A Mac's tasks, as its sidebar lists them: what waits for the person first, then Pinned, then each project and
/// Chats with their subtasks folded under them (docs/REMOTE_PROTOCOL.md §4.1).
struct HomeView: View {
    @Environment(PhoneModel.self) private var model
    let session: HostSession
    @State private var path: [String] = []
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
            // Screenshots without touching the screen: `-sheet newTask` or `-sheet settings` at launch.
            .task {
                guard let sheet = UserDefaults.standard.string(forKey: "sheet") else { return }
                try? await Task.sleep(for: .seconds(1.5))
                if sheet == "newTask" { isStartingTask = true }
                if sheet == "settings" { isShowingSettings = true }
            }
            #endif
            .onChange(of: model.taskToOpen, initial: true) { _, taskID in
                guard let taskID else { return }
                model.taskToOpen = nil
                path = [taskID]
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if session.isDemo { demoBar }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var sections: some View {
        let waiting = session.tasks.filter { $0.attention == .waiting }
        let waitingIDs = Set(waiting.map(\.id))
        if !waiting.isEmpty {
            Section("Waiting for You") {
                ForEach(waiting, id: \.id) { task in
                    link(task, depth: 0, showsProject: true)
                }
            }
        }
        let pinned = session.tasks.filter { $0.pinned && !waitingIDs.contains($0.id) }
        if !pinned.isEmpty {
            Section("Pinned") {
                ForEach(pinned, id: \.id) { task in
                    link(task, depth: 0, showsProject: true)
                }
            }
        }
        ForEach(projectsWithTasks, id: \.project.id) { entry in
            Section(entry.project.name) {
                ForEach(entry.rows, id: \.task.id) { row in
                    link(row.task, depth: row.depth, showsProject: false, children: row.children)
                }
            }
        }
    }

    private struct Row {
        var task: RemoteTask
        var depth: Int
        var children: Int
    }

    /// Each project's tasks, top-level ones by recent activity, a task's subtasks under it when opened.
    private var projectsWithTasks: [(project: RemoteProject, rows: [Row])] {
        let listed = session.tasks.filter { !$0.pinned && $0.attention != .waiting }
        let ids = Set(listed.map(\.id))
        var children: [String: [RemoteTask]] = [:]
        for task in listed {
            if let parent = task.parentTaskId, ids.contains(parent) { children[parent, default: []].append(task) }
        }
        var projects = session.projects
        // A task under a project the snapshot did not name still shows.
        let named = Set(projects.map(\.id))
        for task in listed where !named.contains(task.projectId ?? "") {
            if !projects.contains(where: { $0.id == (task.projectId ?? "") }) {
                projects.append(RemoteProject(id: task.projectId ?? "", name: String(localized: "Other"), kind: .folder))
            }
        }
        let expanded = expanded
        return projects.compactMap { project in
            let top = listed.filter { ($0.projectId ?? "") == project.id && !($0.parentTaskId.map(ids.contains) ?? false) }
            guard !top.isEmpty else { return nil }
            var rows: [Row] = []
            func add(_ task: RemoteTask, depth: Int) {
                let kids = children[task.id] ?? []
                rows.append(Row(task: task, depth: depth, children: kids.count))
                guard expanded.contains(task.id), depth < 8 else { return }
                for child in kids { add(child, depth: depth + 1) }
            }
            for task in top { add(task, depth: 0) }
            return (project, rows)
        }
    }

    private var matches: [RemoteTask] {
        let words = search.lowercased()
        return session.tasks.filter { task in
            task.title.lowercased().contains(words) || task.harnessName.lowercased().contains(words)
                || (session.project(task.projectId)?.name.lowercased().contains(words) ?? false)
        }
    }

    private func link(_ task: RemoteTask, depth: Int, showsProject: Bool, children: Int = 0) -> some View {
        NavigationLink(value: task.id) {
            TaskRow(task: task, session: session, depth: depth, showsProject: showsProject, children: children,
                    isExpanded: expanded.contains(task.id)) {
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
                    Text(Formatting.shortAge(session.date(task.lastActivityAt)))
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

    private var subtitle: String {
        var parts = [task.harnessName]
        if showsProject, let project = session.project(task.projectId) { parts.append(project.name) }
        return parts.joined(separator: " · ")
    }
}
