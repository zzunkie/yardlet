import AuthenticationServices
import SwiftUI
import YardletRemote

/// Main connected mobile shell: top MacHeader, 3-tab bottom bar (`Tasks · Mail · Calendar`),
/// compact `Home` / `Projects` view switch, monochrome surface-ladder task rows, thumb-reachable
/// `NewTaskBar`, and `MacSheet` for Mac switching, Scheduled Tasks, Host Settings / Connectors,
/// Yardlet Account, and App Settings.
struct HomeView: View {
    @Environment(PhoneModel.self) private var model
    let session: HostSession
    /// Tasks by their ID, and the Schedules screen.
    @State private var path = NavigationPath()
    @State private var selectedTab: MobileTab = .tasks
    @State private var view = ListView.home
    @State private var isSearching = false
    @State private var search = ""
    @FocusState private var isSearchFocused: Bool
    /// The mail tab's search field has the keyboard.
    @State private var isMailSearchFocused = false
    @State private var expanded: Set<String> = []
    @State private var activeSheet: ActiveSheet?
    @State private var pendingSheet: ActiveSheet?
    @State private var pendingSchedules = false
    @State private var mailCalendarStore: MailCalendarStore
    @State private var isWatchingMailCalendarV2 = false

    init(session: HostSession) {
        self.session = session
        _mailCalendarStore = State(initialValue: MailCalendarStore(session: session))
    }

    private var usesMailCalendarV2: Bool {
        session.capabilities.mailCalendarV2 && !session.isDemo
    }

    private var wantsMailCalendarV2Watch: Bool {
        usesMailCalendarV2 && (selectedTab == .mail || selectedTab == .calendar)
    }

    private enum ActiveSheet: String, Identifiable {
        case macSheet
        case settings
        case hostSettings
        case connectors
        case newTask
        case scanQR
        case pasteLink
        case accountMacs

        var id: String { rawValue }
    }

    private var defaultNewTaskProject: RemoteProject? {
        session.projects.first { $0.canCreateTask == true }
    }

    private var tasksBadge: (color: Color, label: String)? {
        if session.tasks.contains(where: { $0.indicator == .awaitingApproval }) {
            return (YardletPalette.Status.approval, String(localized: "Awaiting approval"))
        }
        if session.tasks.contains(where: { $0.indicator == .needsInput }) {
            return (YardletPalette.Status.question, String(localized: "Awaiting an answer"))
        }
        if session.tasks.contains(where: { $0.indicator == .usageLimit }) {
            return (YardletPalette.Status.limit, String(localized: "Stopped at a usage limit"))
        }
        if session.tasks.contains(where: { $0.indicator == .failed }) {
            return (YardletPalette.Status.failed, String(localized: "Failed"))
        }
        if session.tasks.contains(where: { $0.attention == .waiting || $0.unread }) {
            return (YardletPalette.Status.unread, String(localized: "Unread"))
        }
        return nil
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                MacHeaderBar(
                    macName: session.name,
                    connection: session.connection,
                    showsSchedules: session.scheduledTasks,
                    showsSearch: selectedTab == .tasks,
                    isSearchActive: isSearching,
                    onTapMac: { activeSheet = .macSheet },
                    onTapSchedules: { path.append(SchedulesRoute()) },
                    onToggleSearch: toggleSearch
                )
                ConnectionBanner(session: session)
                ZStack {
                    tasksTab
                        .opacity(selectedTab == .tasks ? 1 : 0)
                        .allowsHitTesting(selectedTab == .tasks)
                        .accessibilityHidden(selectedTab != .tasks)
                    if usesMailCalendarV2 {
                        MailTabView(
                            session: session,
                            store: mailCalendarStore,
                            isActive: selectedTab == .mail,
                            onOpenConnectors: { activeSheet = .connectors },
                            onSearchFocusChange: { isMailSearchFocused = $0 }
                        )
                        .opacity(selectedTab == .mail ? 1 : 0)
                        .allowsHitTesting(selectedTab == .mail)
                        .accessibilityHidden(selectedTab != .mail)

                        CalendarTabView(
                            session: session,
                            store: mailCalendarStore,
                            isActive: selectedTab == .calendar,
                            onOpenConnectors: { activeSheet = .connectors }
                        )
                        .opacity(selectedTab == .calendar ? 1 : 0)
                        .allowsHitTesting(selectedTab == .calendar)
                        .accessibilityHidden(selectedTab != .calendar)
                    } else {
                        MailTabPlaceholderView(session: session, onOpenConnectors: { activeSheet = .connectors })
                            .opacity(selectedTab == .mail ? 1 : 0)
                            .allowsHitTesting(selectedTab == .mail)
                            .accessibilityHidden(selectedTab != .mail)
                        CalendarTabPlaceholderView(session: session, onOpenConnectors: { activeSheet = .connectors })
                            .opacity(selectedTab == .calendar ? 1 : 0)
                            .allowsHitTesting(selectedTab == .calendar)
                            .accessibilityHidden(selectedTab != .calendar)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(YardletPalette.background)
            .navigationTitle(session.name)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomChrome
            }
            .navigationDestination(for: String.self) { taskID in
                TaskView(session: session, taskID: taskID)
            }
            .navigationDestination(for: SchedulesRoute.self) { _ in
                SchedulesView(session: session)
            }
            .sheet(item: $activeSheet, onDismiss: handleSheetDismiss) { sheet in
                switch sheet {
                case .macSheet:
                    MacSheet(
                        session: session,
                        onOpenSchedules: {
                            pendingSchedules = true
                            activeSheet = nil
                        },
                        onOpenHostSettings: { transitionSheet(to: .hostSettings) },
                        onOpenConnectors: { transitionSheet(to: .connectors) },
                        onOpenAppSettings: { transitionSheet(to: .settings) },
                        onScanQR: { transitionSheet(to: .scanQR) },
                        onPasteLink: { transitionSheet(to: .pasteLink) },
                        onOpenAccountMacs: { transitionSheet(to: .accountMacs) }
                    )
                case .settings:
                    SettingsView()
                case .hostSettings:
                    HostSettingsView(session: session)
                case .connectors:
                    ConnectorsView(session: session, isPresentedAsSheet: true)
                case .newTask:
                    NewTaskView(session: session, initialProjectID: defaultNewTaskProject?.id) { taskID in
                        activeSheet = nil
                        selectedTab = .tasks
                        path.append(taskID)
                    }
                case .scanQR:
                    PairingScanner { link in
                        activeSheet = nil
                        Task { await model.pair(link) }
                    }
                case .pasteLink:
                    PasteLinkView { link in
                        activeSheet = nil
                        Task { await model.pair(link) }
                    }
                case .accountMacs:
                    AccountMacsView { activeSheet = nil }
                        .onDisappear { model.account.error = nil }
                }
            }
            #if DEBUG
            // Screenshots without touching the screen: `-sheet newTask`, `-sheet settings` or `-sheet schedules` at launch.
            .task {
                guard let sheet = UserDefaults.standard.string(forKey: "sheet") else { return }
                try? await Task.sleep(for: .seconds(1.5))
                if sheet == "newTask" { activeSheet = .newTask }
                if sheet == "settings" { activeSheet = .settings }
                if sheet == "schedules" { path.append(SchedulesRoute()) }
            }
            #endif
            .onChange(of: model.taskToOpen, initial: true) { _, taskID in
                guard let taskID else { return }
                model.taskToOpen = nil
                selectedTab = .tasks
                // Pushed on the main actor's next turn, not while the stack draws its first frame: a notification
                // that launched the app sets the task before the home screen has appeared.
                Task { @MainActor in path = NavigationPath([taskID]) }
            }
            .onChange(of: selectedTab) { _, tab in
                if tab != .tasks && isSearching {
                    isSearching = false
                    search = ""
                    isSearchFocused = false
                }
            }
        }
        .onChange(of: wantsMailCalendarV2Watch, initial: true) { _, shouldWatch in
            if shouldWatch && !isWatchingMailCalendarV2 {
                isWatchingMailCalendarV2 = true
                session.beginWatchingMailCalendarV2()
            } else if !shouldWatch && isWatchingMailCalendarV2 {
                isWatchingMailCalendarV2 = false
                session.endWatchingMailCalendarV2()
            }
        }
        .onChange(of: session.mailCalendarV2State) { _, next in
            mailCalendarStore.syncHostState(next)
        }
        .onChange(of: session.isConnected) { _, connected in
            mailCalendarStore.handleConnectionChanged(isConnected: connected)
            if connected && usesMailCalendarV2 {
                switch selectedTab {
                case .mail: mailCalendarStore.activateMailTab()
                case .calendar: mailCalendarStore.activateCalendarTab()
                case .tasks: break
                }
            }
        }
        .onChange(of: session.mailCalendarV2Changes) { _, _ in
            if wantsMailCalendarV2Watch {
                mailCalendarStore.handleHostDataChanged(activeTab: selectedTab)
            }
        }
        .onAppear {
            if wantsMailCalendarV2Watch && !isWatchingMailCalendarV2 {
                isWatchingMailCalendarV2 = true
                session.beginWatchingMailCalendarV2()
            }
        }
        .onDisappear {
            mailCalendarStore.cancelAllTasks()
            if isWatchingMailCalendarV2 {
                isWatchingMailCalendarV2 = false
                session.endWatchingMailCalendarV2()
            }
        }
        // A task a conversation's link or a schedule's run names opens as the list opens it.
        .environment(\.openTask, OpenTaskAction {
            selectedTab = .tasks
            path.append($0)
        })
    }

    // MARK: - Tasks Tab

    private var tasksTab: some View {
        VStack(spacing: 0) {
            if isSearching {
                searchBar
            } else if !session.tasks.isEmpty {
                CompactSegmentedSwitch(
                    items: [
                        .init(value: ListView.home, title: "Home"),
                        .init(value: ListView.projects, title: "Projects")
                    ],
                    selection: $view
                )
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)
            }

            List {
                if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if matches.isEmpty {
                        searchEmptyState
                    } else {
                        ForEach(matches, id: \.id) { task in
                            taskRow(task, depth: 0, showsProject: true, isAttention: task.attention == .waiting)
                        }
                    }
                } else if session.hasSnapshot && session.tasks.isEmpty {
                    emptyState
                } else {
                    sections
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Room under the last row, so the list's end clears the bars below it instead of meeting them.
            .contentMargins(.bottom, 24, for: .scrollContent)
            .background(YardletPalette.background)
            .environment(\.defaultMinListHeaderHeight, 28)
            .overlay {
                if !session.hasSnapshot && session.tasks.isEmpty, case .connecting = session.connection {
                    ProgressView()
                }
            }
            .refreshable { await session.refresh() }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                TextField("Search tasks", text: $search, prompt: .placeholder("Search tasks"))
                    .font(.subheadline)
                    .foregroundStyle(YardletPalette.onSurface)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isSearchFocused)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(YardletPalette.surfaceContainer, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75)
            )

            Button("Cancel") {
                toggleSearch()
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(YardletPalette.onSurfaceVariant)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .onAppear { isSearchFocused = true }
    }

    private func transitionSheet(to next: ActiveSheet) {
        pendingSheet = next
        activeSheet = nil
    }

    private func handleSheetDismiss() {
        if pendingSchedules {
            pendingSchedules = false
            path.append(SchedulesRoute())
            return
        }
        if let next = pendingSheet {
            pendingSheet = nil
            activeSheet = next
        }
    }

    private func toggleSearch() {
        withAnimation(.easeInOut(duration: 0.16)) {
            isSearching.toggle()
        }
        if !isSearching {
            search = ""
            isSearchFocused = false
        }
    }

    // MARK: - Bottom Chrome

    private var bottomChrome: some View {
        VStack(spacing: 0) {
            if session.commandError != nil {
                CommandErrorBanner(session: session)
                    .padding(.bottom, 8)
            }
            if !isSearching && !(isMailSearchFocused && selectedTab == .mail) {
                if session.isDemo {
                    demoBar
                }
                if selectedTab == .tasks {
                    NewTaskBar(
                        projectName: defaultNewTaskProject?.name,
                        isEnabled: session.newTask != nil && session.isConnected
                    ) {
                        activeSheet = .newTask
                    }
                }
                BottomTabBar(
                    selection: $selectedTab,
                    tasksBadgeColor: tasksBadge?.color,
                    tasksBadgeLabel: tasksBadge?.label
                )
            }
        }
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
            Section {
                ForEach(waiting, id: \.id) { task in
                    taskRow(task, depth: 0, showsProject: true, isAttention: true)
                }
            } header: {
                sectionHeader("Waiting for You", count: waiting.count)
            }
        }
        let rest = session.tasks.filter { $0.attention != .waiting }
        // The sidebar's Pinned is a list of its own, so a pinned task's pinned subtasks fold under it there.
        let pinned = Array(trees(rest.filter(\.pinned)).joined())
        if !pinned.isEmpty {
            Section {
                rows(pinned, showsProject: true)
            } header: {
                sectionHeader("Pinned", count: pinned.count)
            }
        }
        switch view {
        case .home:
            // By time alone: a chat that moved a minute ago comes before a project's task idle since morning.
            let recent = trees(rest.filter { !$0.pinned }).sorted { $0[0].latestActivityAt > $1[0].latestActivityAt }
            if !recent.isEmpty {
                Section {
                    rows(Array(recent.joined()), showsProject: true)
                } header: {
                    sectionHeader("Recent", count: nil)
                }
            }
        case .projects:
            ForEach(projectsWithTasks, id: \.project.id) { entry in
                Section {
                    rows(entry.rows, showsProject: false)
                } header: {
                    sectionHeaderVerbatim(entry.project.name, count: entry.rows.count)
                }
            }
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(YardletPalette.onSurfaceVariant)
            if let count {
                Text(verbatim: "\(count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(YardletPalette.surfaceContainerHigh, in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .textCase(nil)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func sectionHeaderVerbatim(_ title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(YardletPalette.onSurfaceVariant)
            if let count {
                Text(verbatim: "\(count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(YardletPalette.surfaceContainerHigh, in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .textCase(nil)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func rows(_ rows: [Row], showsProject: Bool) -> some View {
        ForEach(rows, id: \.task.id) { row in
            taskRow(row.task, depth: row.depth, showsProject: showsProject && row.depth == 0,
                    children: row.children,
                    activityAt: row.depth == 0 ? row.latestActivityAt : row.task.lastActivityAt,
                    isAttention: false)
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
        let words = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return session.tasks.filter { task in
            task.title.lowercased().contains(words) || task.harnessName.lowercased().contains(words)
                || (session.project(task.projectId)?.name.lowercased().contains(words) ?? false)
        }
    }

    private func taskRow(_ task: RemoteTask, depth: Int, showsProject: Bool, children: Int = 0,
                         activityAt: Int64? = nil, isAttention: Bool) -> some View {
        TaskRow(task: task, session: session, depth: depth, showsProject: showsProject, children: children,
                isExpanded: expanded.contains(task.id), activityAt: activityAt, isAttention: isAttention,
                open: { path.append(task.id) },
                toggle: {
                    if expanded.contains(task.id) { expanded.remove(task.id) } else { expanded.insert(task.id) }
                })
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .swipeActions(edge: .leading) {
            Button {
                session.send(.setPinned(taskID: task.id, pinned: !task.pinned))
            } label: {
                Label(task.pinned ? "Unpin" : "Pin", systemImage: task.pinned ? "pin.slash" : "pin")
            }
            .tint(YardletPalette.swipePrimary)
        }
        .swipeActions(edge: .trailing) {
            Button {
                session.send(.archiveTask(taskID: task.id))
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(YardletPalette.swipeSecondary)
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

    // MARK: - Empty & Demo States

    private var emptyState: some View {
        MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "tray")
                    .font(.title2)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                Text("No Tasks")
                    .font(.headline)
                    .foregroundStyle(YardletPalette.onSurface)
                Text("Tasks you start on \(session.name) or here show up in this list.")
                    .font(.subheadline)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                if session.newTask != nil {
                    Button("New Task") { activeSheet = .newTask }
                        .prominentButton()
                        .padding(.top, 4)
                }
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
    }

    private var searchEmptyState: some View {
        VStack(spacing: 8) {
            Text("No matching tasks")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(YardletPalette.onSurface)
            Text("Try another task title, project, or agent name.")
                .font(.footnote)
                .foregroundStyle(YardletPalette.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var demoBar: some View {
        HStack {
            Text("You're looking at a demo Mac.")
                .font(.footnote)
                .foregroundStyle(YardletPalette.onSurfaceVariant)
            Spacer()
            Button("Leave Demo") { model.leaveDemo() }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(YardletPalette.onSurface)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(YardletPalette.surfaceContainer)
        .overlay(alignment: .top) {
            Rectangle().fill(YardletPalette.outlineVariant).frame(height: 0.5)
        }
    }
}

// MARK: - Task Row

/// One monochrome surface-ladder task card: status mark, title, relative age, pending summary, and harness metadata.
struct TaskRow: View {
    let task: RemoteTask
    let session: HostSession
    var depth = 0
    var showsProject = false
    var children = 0
    var isExpanded = false
    /// When the row says it last moved: a folded parent shows its latest subtask's time.
    var activityAt: Int64?
    var isAttention = false
    var open: () -> Void = {}
    var toggle: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 10) {
                    TaskMark(indicator: task.indicator)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(task.title.isEmpty ? String(localized: "Untitled task") : task.title)
                                .font(.body.weight(task.unread || task.attention == .waiting ? .semibold : .regular))
                                .foregroundStyle(YardletPalette.onSurface)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Text(Formatting.shortAge(session.date(activityAt ?? task.lastActivityAt)))
                                .font(.footnote)
                                .foregroundStyle(YardletPalette.onSurfaceVariant)
                                .monospacedDigit()
                        }
                        if task.attention == .waiting, let summary = task.pendingSummary, !summary.isEmpty {
                            Text(summary)
                                .font(.subheadline)
                                .foregroundStyle(YardletPalette.onSurfaceVariant)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        if children == 0 {
                            metadataRow
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(children > 0 ? Text(subtitle) : Text(verbatim: ""))

            if children > 0 {
                HStack(spacing: 6) {
                    metadataRow
                        .padding(.leading, 22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: open)
                        .accessibilityHidden(true)

                    Button(action: toggle) {
                        HStack(spacing: 3) {
                            Text("\(children) subtasks")
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.semibold))
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(YardletPalette.surfaceContainerHigh, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isAttention ? YardletPalette.surfaceContainer : YardletPalette.surfaceContainerLow,
            in: RoundedRectangle(cornerRadius: YardletMetrics.radiusRow, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: YardletMetrics.radiusRow, style: .continuous)
                .strokeBorder(YardletPalette.outlineVariant, lineWidth: isAttention ? 1 : 0.6)
        )
        .padding(.leading, CGFloat(depth) * 16)
    }

    private var metadataRow: some View {
        HStack(spacing: 6) {
            HarnessMark(harness: task.harness, harnessName: task.harnessName, size: 17)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(YardletPalette.onSurfaceVariant)
                .lineLimit(1)
        }
    }

    /// What it runs on, after its project or Chats where the list mixes them.
    private var subtitle: String {
        var parts = [task.harnessName]
        if showsProject, let project = session.project(task.projectId) { parts.insert(project.name, at: 0) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Bottom New Task Bar

/// Thumb-reachable bar above the 3-tab bottom bar for starting a task in the current default project.
struct NewTaskBar: View {
    let projectName: String?
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Image(systemName: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(YardletPalette.onPrimary)
                    .frame(width: 30, height: 30)
                    .background(YardletPalette.primary, in: Circle())
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(YardletPalette.surfaceContainer, in: Capsule())
            .overlay(Capsule().strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(YardletPalette.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(YardletPalette.outlineVariant).frame(height: 0.5)
        }
        .accessibilityLabel(Text(label))
    }

    private var label: String {
        if let projectName, !projectName.isEmpty {
            return String(localized: "New task in \(projectName)")
        }
        return String(localized: "New Task")
    }
}

// MARK: - Mac Sheet

/// Bottom sheet opened from `MacHeaderBar`: Mac switcher + Add Mac, Scheduled Tasks,
/// Host Settings, Connectors, Yardlet Account, and App Settings.
struct MacSheet: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    let session: HostSession
    let onOpenSchedules: () -> Void
    let onOpenHostSettings: () -> Void
    let onOpenConnectors: () -> Void
    let onOpenAppSettings: () -> Void
    let onScanQR: () -> Void
    let onPasteLink: () -> Void
    let onOpenAccountMacs: () -> Void
    /// The rows' height, for a first detent that shows them all rather than cutting the last one in half.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    macsSection
                    thisMacSection
                    accountAndAppSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .background(YardletPalette.background)
            .navigationTitle("Macs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(YardletPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // The rows and the title bar above them; the sheet still opens to full height for more.
        .presentationDetents(contentHeight > 0 ? [.height(contentHeight + 72), .large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await model.account.refreshProviders() }
    }

    private var macsSection: some View {
        // The sheet's title already says Macs, so the first group goes without a title of its own.
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                ForEach(Array(model.hosts.enumerated()), id: \.element.id) { index, host in
                    if index > 0 { hairline }
                    Button {
                        model.select(host.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            if host.id == session.id && !session.isDemo {
                                ConnectionStatusDot(connection: session.connection, size: 8)
                            } else {
                                StatusDot(color: YardletPalette.outline, size: 8)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name)
                                    .font(.body.weight(host.id == session.id ? .semibold : .regular))
                                    .foregroundStyle(YardletPalette.onSurface)
                                Text(hostStatus(host))
                                    .font(.footnote)
                                    .foregroundStyle(YardletPalette.onSurfaceVariant)
                            }
                            Spacer(minLength: 8)
                            if host.id == session.id && !session.isDemo {
                                Image(systemName: "checkmark")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(YardletPalette.primary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if !model.hosts.isEmpty { hairline }

                Menu {
                    Button(action: onScanQR) {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    }
                    Button(action: onPasteLink) {
                        Label("Paste a Pairing Link", systemImage: "link")
                    }
                    if model.account.account != nil {
                        Button(action: onOpenAccountMacs) {
                            Label("Choose a Mac on Your Account", systemImage: "person.crop.circle")
                        }
                    } else {
                        ForEach(model.account.providers, id: \.self) { provider in
                            Button {
                                Task {
                                    if await model.account.signIn(with: provider, using: webAuthenticationSession) {
                                        onOpenAccountMacs()
                                    }
                                }
                            } label: {
                                Label("Sign in with \(PhoneAccount.providerName(provider))",
                                      systemImage: "person.crop.circle")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(YardletPalette.onSurface)
                            .frame(width: 22)
                        Text("Pair a Mac")
                            .font(.body)
                            .foregroundStyle(YardletPalette.onSurface)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }

                if model.isDemo {
                    hairline
                    Button {
                        model.leaveDemo()
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.subheadline)
                                .foregroundStyle(YardletPalette.onSurfaceVariant)
                                .frame(width: 22)
                            Text("Leave Demo")
                                .font(.body)
                                .foregroundStyle(YardletPalette.onSurface)
                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(YardletPalette.surfaceContainerLow,
                        in: RoundedRectangle(cornerRadius: YardletMetrics.radiusSheetCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: YardletMetrics.radiusSheetCard, style: .continuous)
                    .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75)
            )
        }
    }

    private var thisMacSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sheetSectionTitle(verbatim: session.name)
            VStack(spacing: 0) {
                if session.scheduledTasks {
                    sheetRow(systemImage: "clock", title: "Scheduled Tasks", detail: nil, action: onOpenSchedules)
                    hairline
                }
                sheetRow(
                    systemImage: "slider.horizontal.3",
                    title: "Host Settings",
                    detail: hostSettingsSubtitle,
                    action: onOpenHostSettings
                )
                hairline
                sheetRow(
                    systemImage: "powerplug",
                    title: "Connectors",
                    detail: connectorsSubtitle,
                    action: onOpenConnectors
                )
            }
            .background(YardletPalette.surfaceContainerLow,
                        in: RoundedRectangle(cornerRadius: YardletMetrics.radiusSheetCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: YardletMetrics.radiusSheetCard, style: .continuous)
                    .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75)
            )
        }
    }

    private var accountAndAppSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sheetSectionTitle("Account and App")
            VStack(spacing: 0) {
                if let name = model.account.name {
                    sheetRow(systemImage: "person.crop.circle", title: "Yardlet Account", detail: name,
                             action: onOpenAccountMacs)
                    hairline
                } else if !model.account.providers.isEmpty {
                    Menu {
                        ForEach(model.account.providers, id: \.self) { provider in
                            Button {
                                Task {
                                    if await model.account.signIn(with: provider, using: webAuthenticationSession) {
                                        onOpenAccountMacs()
                                    }
                                }
                            } label: {
                                Label("Sign in with \(PhoneAccount.providerName(provider))",
                                      systemImage: "person.crop.circle")
                            }
                        }
                    } label: {
                        sheetRowLabel(systemImage: "person.crop.circle", title: "Yardlet Account",
                                      detail: String(localized: "Sign in to list your Macs"))
                    }
                    hairline
                }
                sheetRow(systemImage: "gearshape", title: "App Settings", detail: nil, action: onOpenAppSettings)
            }
            .background(YardletPalette.surfaceContainerLow,
                        in: RoundedRectangle(cornerRadius: YardletMetrics.radiusSheetCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: YardletMetrics.radiusSheetCard, style: .continuous)
                    .strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.75)
            )
        }
    }

    private var hostSettingsSubtitle: String {
        if session.capabilities.hostSettings || session.capabilities.hostAccounts {
            return String(localized: "Usage, accounts, instructions and CLI updates")
        }
        return String(localized: "Update Yardlet on \(session.name) to manage")
    }

    private var connectorsSubtitle: String {
        if let connectors = session.hostAccounts?.connectors {
            let connected = connectors.filter { $0.status == "connected" }.count
            if connected > 0 { return String(localized: "\(connected) connected") }
            if !connectors.isEmpty { return String(localized: "\(connectors.count) configured") }
        }
        if session.capabilities.hostAccounts {
            return String(localized: "Manage connected services")
        }
        return String(localized: "Update Yardlet on \(session.name) to manage")
    }

    private func sheetSectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(YardletPalette.onSurfaceVariant)
            .padding(.horizontal, 4)
    }

    private func sheetSectionTitle(verbatim title: String) -> some View {
        Text(verbatim: title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(YardletPalette.onSurfaceVariant)
            .padding(.horizontal, 4)
    }

    private func sheetRow(systemImage: String, title: LocalizedStringKey, detail: String?,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            sheetRowLabel(systemImage: systemImage, title: title, detail: detail)
        }
        .buttonStyle(.plain)
    }

    private func sheetRowLabel(systemImage: String, title: LocalizedStringKey, detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(YardletPalette.onSurfaceVariant)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(YardletPalette.onSurface)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(YardletPalette.onSurfaceVariant)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(YardletPalette.outline)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var hairline: some View {
        Rectangle()
            .fill(YardletPalette.outlineVariant)
            .frame(height: 0.5)
            .padding(.leading, 48)
    }

    private func hostStatus(_ host: RemoteSavedHost) -> String {
        if host.id == session.id {
            switch session.connection {
            case .connected(.relay): return String(localized: "Connected through the relay")
            case .connected: return String(localized: "Connected directly")
            case .connecting: return String(localized: "Connecting…")
            case .removed: return String(localized: "Removed this phone")
            default: return String(localized: "Not reachable")
            }
        }
        if let date = host.lastConnectedAt {
            return String(localized: "Last connected \(date.formatted(.relative(presentation: .named)))")
        }
        return String(localized: "Paired \(host.pairedAt.formatted(date: .abbreviated, time: .omitted))")
    }
}

// MARK: - Mail & Calendar Tab Placeholders (Track C Ready)

/// Mail tab in the unified 3-tab mobile shell, checking live host capabilities and `mailCalendar` permission state.
struct MailTabPlaceholderView: View {
    let session: HostSession
    var onOpenConnectors: () -> Void = {}

    var body: some View {
        MailCalendarPlaceholderView(
            session: session,
            kind: .mail,
            onOpenConnectors: onOpenConnectors
        )
    }
}

/// Calendar tab in the unified 3-tab mobile shell, checking live host capabilities and `mailCalendar` permission state.
struct CalendarTabPlaceholderView: View {
    let session: HostSession
    var onOpenConnectors: () -> Void = {}

    var body: some View {
        MailCalendarPlaceholderView(
            session: session,
            kind: .calendar,
            onOpenConnectors: onOpenConnectors
        )
    }
}

private struct MailCalendarPlaceholderView: View {
    enum Kind {
        case mail
        case calendar

        var symbol: String {
            switch self {
            case .mail: "envelope"
            case .calendar: "calendar"
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .mail: "Mail"
            case .calendar: "Calendar"
            }
        }
    }

    let session: HostSession
    let kind: Kind
    let onOpenConnectors: () -> Void
    @State private var isRefreshing = false

    private var hostSupportsKind: Bool {
        switch kind {
        case .mail: session.capabilities.hostMail
        case .calendar: session.capabilities.hostCalendar
        }
    }

    private var hostHasService: Bool {
        guard let state = session.mailCalendarState else { return false }
        switch kind {
        case .mail: return state.mailbox
        case .calendar: return state.calendar
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                MonochromeCard(fill: YardletPalette.surfaceContainerLow, padding: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: kind.symbol)
                                .font(.title3)
                                .foregroundStyle(YardletPalette.onSurface)
                                .frame(width: 34, height: 34)
                                .background(YardletPalette.surfaceContainerHigh,
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Text(kind.title)
                                .font(.headline)
                                .foregroundStyle(YardletPalette.onSurface)
                            Spacer(minLength: 8)
                            statusBadge
                        }

                        Text(statusMessage)
                            .font(.subheadline)
                            .foregroundStyle(YardletPalette.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)

                        if !session.isConnected {
                            Button("Retry") { session.reconnectNow() }
                                .prominentButton()
                        } else if hostSupportsKind {
                            HStack(spacing: 10) {
                                if let state = session.mailCalendarState,
                                   state.permitted,
                                   !hostHasService,
                                   session.capabilities.hostAccounts {
                                    Button("Manage Connectors", action: onOpenConnectors)
                                        .prominentButton()
                                }
                                Button {
                                    isRefreshing = true
                                    Task {
                                        await session.refreshMailCalendarState()
                                        isRefreshing = false
                                    }
                                } label: {
                                    if isRefreshing {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Text("Refresh Status")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(isRefreshing)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(YardletPalette.background)
        .refreshable {
            if session.isConnected && hostSupportsKind {
                await session.refreshMailCalendarState()
            } else {
                await session.refresh()
            }
        }
        .task(id: session.isConnected) {
            if session.isConnected && !session.capabilities.mailCalendarV2 && hostSupportsKind && session.mailCalendarState == nil {
                await session.refreshMailCalendarState()
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if !session.isConnected {
            badgePill(color: YardletPalette.Status.running, text: "Offline")
        } else if !hostSupportsKind {
            badgePill(color: YardletPalette.Status.running, text: "Unavailable")
        } else if let state = session.mailCalendarState {
            if !state.permitted {
                badgePill(color: YardletPalette.Status.question, text: "Permission Off")
            } else if !hostHasService {
                badgePill(color: YardletPalette.Status.running, text: "Not Set Up")
            } else {
                badgePill(color: YardletPalette.Status.connected, text: "Ready")
            }
        } else {
            ProgressView().controlSize(.mini)
        }
    }

    private func badgePill(color: Color, text: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            StatusDot(color: color, size: 7)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(YardletPalette.onSurfaceVariant)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(YardletPalette.surfaceContainer, in: Capsule())
        .overlay(Capsule().strokeBorder(YardletPalette.outlineVariant, lineWidth: 0.5))
    }

    private var statusMessage: String {
        if !session.isConnected {
            return String(localized: "Connect to \(session.name) to check Mail and Calendar availability.")
        }
        if !hostSupportsKind {
            return switch kind {
            case .mail:
                String(localized: "\(session.name) doesn't offer Mail over remote yet. Update Yardlet on your Mac to enable it.")
            case .calendar:
                String(localized: "\(session.name) doesn't offer Calendar over remote yet. Update Yardlet on your Mac to enable it.")
            }
        }
        guard let state = session.mailCalendarState else {
            return String(localized: "Checking Mail and Calendar access on \(session.name)…")
        }
        if !state.permitted {
            return String(localized: "To use Mail and Calendar from here, allow Mail and Calendar for this device in Settings › Remote › Paired devices on \(session.name).")
        }
        if !hostHasService {
            return switch kind {
            case .mail:
                String(localized: "Connect a mail account in Yardlet on \(session.name) to view your inbox here.")
            case .calendar:
                String(localized: "Connect a calendar account in Yardlet on \(session.name) to view your schedule here.")
            }
        }
        return switch kind {
        case .mail:
            String(localized: "Mail on \(session.name) is permitted and ready. Mobile Mail view is coming soon.")
        case .calendar:
            String(localized: "Calendar on \(session.name) is permitted and ready. Mobile Calendar view is coming soon.")
        }
    }
}
