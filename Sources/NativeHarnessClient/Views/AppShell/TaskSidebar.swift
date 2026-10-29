import AppKit
import SwiftUI

private struct ShellBusyTaskIDsKey: EnvironmentKey {
    static let defaultValue: Set<UUID> = []
}

private struct TaskAttentionDetailsKey: EnvironmentKey {
    static let defaultValue: [UUID: TaskAttentionDetail] = [:]
}

private struct ScheduledTaskIDsKey: EnvironmentKey {
    static let defaultValue: Set<UUID> = []
}

/// Opens a sidebar row's item in a new window tab (the row menu's "Open in New Tab"). The window
/// hands down one action, so its redraws leave the rows that read it alone.
struct WindowItemNewTabAction: Equatable {
    let open: @MainActor (WindowItem) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

private struct OpenWindowItemInNewTabKey: EnvironmentKey {
    static let defaultValue: WindowItemNewTabAction? = nil
}

extension EnvironmentValues {
    var openWindowItemInNewTab: WindowItemNewTabAction? {
        get { self[OpenWindowItemInNewTabKey.self] }
        set { self[OpenWindowItemInNewTabKey.self] = newValue }
    }
}

/// Opens a sidebar task row's task beside the focused pane (the row menu's "Open in Split View",
/// the Claude app's "Open in split view"). One action from the window, as for new tabs.
struct TaskSplitViewAction: Equatable {
    let open: @MainActor (UUID) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

private struct OpenTaskInSplitViewKey: EnvironmentKey {
    static let defaultValue: TaskSplitViewAction? = nil
}

extension EnvironmentValues {
    var openTaskInSplitView: TaskSplitViewAction? {
        get { self[OpenTaskInSplitViewKey.self] }
        set { self[OpenTaskInSplitViewKey.self] = newValue }
    }
}

/// Opens a sidebar task row's conversation as a tab in the side panel of the task the window shows
/// (the row menu's "Open in Side Panel"). One action from the window, as for split views.
struct TaskSidePanelAction: Equatable {
    let open: @MainActor (UUID) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

private struct OpenTaskInSidePanelKey: EnvironmentKey {
    static let defaultValue: TaskSidePanelAction? = nil
}

extension EnvironmentValues {
    var openTaskInSidePanel: TaskSidePanelAction? {
        get { self[OpenTaskInSidePanelKey.self] }
        set { self[OpenTaskInSidePanelKey.self] = newValue }
    }
}

private struct PrefetchTaskConversationKey: EnvironmentKey {
    static let defaultValue = TaskConversationPrefetch()
}

/// Reads a task's saved conversation before it is opened (`AppModel.prefetchSavedConversation`).
/// The same model's prefetch is one value, so a window redraw that hands it down again leaves
/// every sidebar row that reads it alone.
struct TaskConversationPrefetch: Equatable {
    private let owner: ObjectIdentifier?
    private let read: @MainActor (UUID) -> Void

    init() {
        owner = nil
        read = { _ in }
    }

    init(model: AppModel) {
        owner = ObjectIdentifier(model)
        read = { [weak model] id in model?.prefetchSavedConversation(of: id) }
    }

    @MainActor func callAsFunction(_ id: UUID) { read(id) }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.owner == rhs.owner }
}

extension EnvironmentValues {
    /// Tasks running a bash-mode command, which the sidebar shows as running.
    var shellBusyTaskIDs: Set<UUID> {
        get { self[ShellBusyTaskIDsKey.self] }
        set { self[ShellBusyTaskIDsKey.self] = newValue }
    }

    /// What each task's latest turn waits on and how it ended (`AppModel.taskAttentionDetails`).
    var taskAttentionDetails: [UUID: TaskAttentionDetail] {
        get { self[TaskAttentionDetailsKey.self] }
        set { self[TaskAttentionDetailsKey.self] = newValue }
    }

    /// Tasks a schedule's run started, which the sidebar marks with a clock as the Claude app does.
    var scheduledTaskIDs: Set<UUID> {
        get { self[ScheduledTaskIDsKey.self] }
        set { self[ScheduledTaskIDsKey.self] = newValue }
    }

    /// The pointer rests on a task's row: its saved conversation can be read before it is opened
    /// (`AppModel.prefetchSavedConversation`).
    var prefetchTaskConversation: TaskConversationPrefetch {
        get { self[PrefetchTaskConversationKey.self] }
        set { self[PrefetchTaskConversationKey.self] = newValue }
    }
}

/// The sidebar's activity view (the Codex app's priority threads): one list of the tasks that are
/// waiting, unread or working, across projects and chats, in place of the task list.
struct SidebarActivity {
    /// The listed tasks, in attention order (`TaskAttentionProjection.activityList`).
    var sessions: [SessionRecord]
    /// The task the window shows (the focused pane's in a split view).
    var selectedSessionID: UUID?
    /// The project or "Chats" line under each task's title.
    var subtitle: (SessionRecord) -> String = { _ in "" }
    var onMarkAllRead: () -> Void = {}

    var rows: [SidebarRow] { sessions.map { SidebarRow(content: .session($0)) } }

    /// The rows arrow keys and Previous/Next task move through while the view is open.
    var layout: SidebarProjection.Layout { .list(rows) }

    var selection: WindowItem {
        guard let selectedSessionID, sessions.contains(where: { $0.id == selectedSessionID }) else { return .home }
        return .session(selectedSessionID)
    }

    var canMarkAllRead: Bool { sessions.contains(where: \.hasUnreadUpdate) }
}

/// The sidebar's geometry. Rows are the Codex app's (ChatGPT.app `app.asar`, `.sidebar-navigation`):
/// 30pt with 10pt corners and 1pt between them, the harness mark centred in a 32pt leading gutter,
/// and 8pt under an expanded project. Since 2026-10-16 (the person asked for it) a project is a
/// faint, small label over its tasks, and its tasks sit flush under it with the mark in the same
/// gutter as in Pinned and Chats, as the Claude app's Code list groups sessions
/// (`[data-sidebar-group-label]`: 12px muted text, `--df-row-indent: 0`).
enum SidebarMetrics {
    static let rowHeight: CGFloat = 30
    /// A row with its project under the title, as the activity view lists tasks.
    static let twoLineRowHeight: CGFloat = 42
    static let rowCornerRadius: CGFloat = 10
    static let rowSpacing: CGFloat = 1
    static let gutterWidth: CGFloat = 32
    static let rowTrailingPadding: CGFloat = 8
    /// A task row's harness mark.
    static let nestedIconSize: CGFloat = 16
    /// The space each row keeps from the sidebar's edges.
    static let rowInset: CGFloat = 4
    /// A project's label: the Claude app's group label (`--df-group-font` 12px, a row's height,
    /// 8px above it — here 4 above, as an expanded project already leaves 8 under its rows), its
    /// text where the section titles start.
    static let projectHeaderHeight: CGFloat = 28
    static let projectHeaderTopSpacing: CGFloat = 4
    static let projectHeaderFontSize: CGFloat = 12
    static let projectHeaderLeading: CGFloat = 13
    /// Space under an expanded project's rows (Codex `pb-2`).
    static let groupBottomSpacing: CGFloat = 8
    /// The "No chats" and "Show more" lines (Codex `py-1` around a 20pt line).
    static let secondaryLineHeight: CGFloat = 28
    /// How far a task started from another sits in from it (Claude `--df-row-indent`, 20 px), and
    /// the guide joining them (Claude `.df-family:after`: 10 px across, 6 px corner).
    static let familyIndent: CGFloat = 20
    static let familyGuideLength: CGFloat = 10
    static let familyGuideRadius: CGFloat = 6

    static func rowShape() -> RoundedRectangle {
        RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
    }
}

/// Actions a split view's sidebar row offers, and the drops that create or grow one.
struct SidebarSplitActions {
    var togglePinned: (SplitGroup) -> Void = { _ in }
    var rename: (SplitGroup) -> Void = { _ in }
    var dissolve: (SplitGroup) -> Void = { _ in }
    var archive: (SplitGroup) -> Void = { _ in }
    /// A task dropped on another task's row: `(dropped, target)`.
    var combine: (UUID, UUID) -> Void = { _, _ in }
    /// A task dropped on a split view's row.
    var add: (UUID, SplitGroup) -> Void = { _, _ in }
}

struct TaskSidebar: View {
    let layout: SidebarProjection.Layout
    let allGroups: [WorkspaceGroup]
    let isRestoring: Bool
    /// The row the window shows. A task inside a split selects the split's row.
    let selection: WindowItem
    @Binding var searchText: String
    let onNewTask: () -> Void
    /// Opens the scheduled tasks in the task list's place.
    var onShowSchedules: (() -> Void)? = nil
    /// Opens the personal agents in the task list's place.
    var onShowPersonalAgents: (() -> Void)? = nil
    let onActivate: (WindowItem) -> Void
    let onNewTaskInProject: (URL) -> Void
    var onAddProject: (() -> Void)? = nil
    @Bindable var projects: ProjectStore
    let onEditProject: (WorkspaceGroup) -> Void
    let onArchiveProjectChats: (WorkspaceGroup) -> Void
    let onRemoveProject: (WorkspaceGroup) -> Void
    let onTogglePinned: (SessionRecord) -> Void
    let onArchive: (SessionRecord) -> Void
    let onDelete: (SessionRecord) -> Void
    let onRename: (SessionRecord) -> Void
    let onMarkRead: (SessionRecord) -> Void
    var onMarkUnread: (SessionRecord) -> Void = { _ in }
    /// Moves a task to a project, or back to Chats (nil), from its row's context menu.
    var onMoveToProject: (SessionRecord, Project?) -> Void = { _, _ in }
    /// Takes a task out of the family it is listed in, to the top level, from its row's menu.
    var onDetachFromParent: (SessionRecord) -> Void = { _ in }
    var splitActions = SidebarSplitActions()
    /// The account button at the bottom and the app-wide places its menu opens.
    var accountMenu = SidebarAccountMenuContext()
    /// Collapsed projects and "Show more"; the layout above already reflects it.
    var disclosure: SidebarDisclosureStore? = nil
    /// The activity view, shown in place of the task list while it is on.
    var activity: SidebarActivity? = nil
    /// Told when the list comes to its top or leaves it, where the shown task's place is held
    /// (`SidebarOrderHold`).
    var onListAtTopChange: (Bool) -> Void = { _ in }
    @FocusState private var isTaskListFocused: Bool
    /// The row last picked in the list, which is in view: the list does not scroll to it.
    @State private var pickedInList: WindowItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sidebarHoverCard) private var hoverCard

    /// The shown row and whether it is pinned, which moves it between the pinned rows and its project.
    private struct ShownRowPin: Equatable {
        let item: WindowItem
        let isPinned: Bool?
    }

    private var shownRowPin: ShownRowPin {
        ShownRowPin(item: selection, isPinned: layout.rows.first { $0.id == selection }?.isPinned)
    }

    /// The rows arrow keys move through and the row Return opens: the activity list's while it is on.
    private var navigationLayout: SidebarProjection.Layout { activity?.layout ?? layout }
    private var navigationSelection: WindowItem { activity?.selection ?? selection }

    var body: some View {
        VStack(spacing: 0) {
            // The new task's page is the home: its projects, the tasks that wait and the composer.
            // ⌘N and the title bar's button keep the name New task.
            Button(action: onNewTask) {
                SidebarActionRow(systemName: "house", title: L10n.string("Home"), symbolWeight: .bold,
                                 titleWeight: .medium, height: 32, isFilled: true)
            }
            .buttonStyle(.borderless)
            .parityPointer()
            .padding(.horizontal, SidebarMetrics.rowInset)
            .accessibilitySortPriority(ParityAccessibility.sidebarPrimary)

            if let onShowSchedules {
                Button(action: onShowSchedules) {
                    SidebarActionRow(systemName: "clock", title: L10n.string("Scheduled tasks"))
                }
                .buttonStyle(.borderless)
                .parityPointer()
                .padding(.horizontal, SidebarMetrics.rowInset)
                .padding(.top, 2)
                .accessibilitySortPriority(ParityAccessibility.sidebarPrimary - 0.5)
            }

            if let onShowPersonalAgents {
                Button(action: onShowPersonalAgents) {
                    SidebarActionRow(systemName: "person.crop.circle", title: L10n.string("Personal agents"))
                }
                .buttonStyle(.borderless)
                .parityPointer()
                .padding(.horizontal, SidebarMetrics.rowInset)
                .padding(.top, 2)
                .accessibilitySortPriority(ParityAccessibility.sidebarPrimary - 0.75)
            }

            SidebarSearchField(placeholder: L10n.string("Search tasks"), text: $searchText)
                .padding(.horizontal, SidebarMetrics.rowInset)
            .padding(.top, 8)
            .accessibilitySortPriority(ParityAccessibility.sidebarPrimary - 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SidebarMetrics.rowSpacing) {
                        if isRestoring {
                            ParitySectionTitle(title: L10n.string("Projects"), trailingAction: onAddProject ?? onNewTask,
                                trailingLabel: L10n.string(onAddProject == nil ? "New task" : "Add project…"))
                                .padding(.horizontal, 13)

                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(L10n.string("Restoring tasks…"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 13)
                            .accessibilityElement(children: .combine)
                        } else if let activity {
                            activityEntry(activity)
                        } else {
                            if !layout.pinned.isEmpty {
                                ParitySectionTitle(title: L10n.string("Pinned"))
                                    .padding(.horizontal, 13)
                                    .padding(.bottom, 2)
                                ForEach(layout.pinned) { row in
                                    familyEntry(row, under: nil)
                                }
                            }

                            if let chats = layout.chats {
                                chatsEntry(chats)
                            }

                            if !layout.sections.isEmpty || (layout.pinned.isEmpty && layout.chats == nil) {
                                ParitySectionTitle(title: L10n.string("Projects"), trailingAction: onAddProject ?? onNewTask,
                                trailingLabel: L10n.string(onAddProject == nil ? "New task" : "Add project…"))
                                    .padding(.horizontal, 13)
                                    .padding(.top, layout.pinned.isEmpty && layout.chats == nil ? 0 : 16)
                            }

                            if layout.sections.isEmpty, layout.pinned.isEmpty, layout.chats == nil, !searchText.isEmpty {
                                Text(L10n.string("No matching tasks."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 13)
                            } else {
                                ForEach(layout.sections) { section in
                                    projectEntry(section)
                                }
                            }
                        }
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                }
                // A row's hover card closes as the list scrolls under it.
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { old, new in
                    if old != new { hoverCard?.sidebarScrolled() }
                }
                .onScrollGeometryChange(for: Bool.self) {
                    $0.contentOffset.y + $0.contentInsets.top <= 1
                } action: { _, atTop in
                    onListAtTopChange(atTop)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($isTaskListFocused)
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard navigationSelection != .home else { return .ignored }
                    onActivate(navigationSelection)
                    return .handled
                }
                // The list follows a task shown from elsewhere (the keyboard, a notification, a tab). A row
                // picked in the list is in view already, and scrolling to it moved the list under the
                // pointer: the lazy list scrolls to its estimate of the row's place first.
                .onChange(of: selection, initial: true) { _, item in
                    let picked = pickedInList
                    pickedInList = nil
                    if item != .home, item != picked { proxy.scrollTo(item) }
                }
                // Going to a task in a collapsed project opens the project, as the Codex app does
                // when its sidebar sees a new current chat (also when the sidebar appears); a
                // project collapsed around the shown task stays so until another task is shown.
                .onChange(of: selection, initial: true) { _, item in
                    guard let disclosure, item != .home,
                          let section = SidebarProjection.section(holding: item, in: layout),
                          disclosure.isCollapsed(section.disclosureKey) else { return }
                    disclosure.expand(section.disclosureKey)
                }
                // Pinning or unpinning the shown row moves it: the list follows it there. Another row
                // shown is the selection's to follow, or not.
                .onChange(of: shownRowPin) { old, new in
                    guard new.item != .home, old.item == new.item, old.isPinned != nil, new.isPinned != nil else { return }
                    proxy.scrollTo(new.item)
                }
                .onChange(of: searchText) { _, _ in
                    let ids = navigationLayout.rows.map(\.id)
                    let target = ids.contains(navigationSelection) ? navigationSelection : ids.first
                    if let target { proxy.scrollTo(target) }
                }
            }

            Rectangle().fill(ParityTheme.separator).frame(height: 1)

            // A staged build ready to install, over the account button as the Claude app's update strip is.
            if let update = accountMenu.update() {
                SidebarUpdateStrip(line: update) { accountMenu.onSelect(.installUpdate) }
                    .padding(.horizontal, 4)
                    .padding(.top, 6)
            }
            // One account button, as the Claude and Codex apps end their sidebars; its menu holds
            // Settings, the accounts, archived tasks and the other app-wide places.
            SidebarAccountButton(context: accountMenu)
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
                .accessibilitySortPriority(ParityAccessibility.secondary)
        }
        .background(ParityTheme.sidebar)
        .focusSection()
    }

    /// A project's label and, while it is expanded, its task rows flush under it, the "No chats"
    /// line when it has none, and "Show more" when it holds more than it lists.
    @ViewBuilder
    private func projectEntry(_ section: SidebarSection) -> some View {
        let group = section.group
        let completeGroup = allGroups.first { $0.workspaceURL == group.workspaceURL } ?? group
        ProjectTaskHeader(
            group: group,
            completeGroup: completeGroup,
            nestedSessions: section.allRows.flatMap(\.familySessions),
            isCollapsed: section.isCollapsed,
            projects: projects,
            onToggle: { toggle(section) },
            onNewTask: { onNewTaskInProject(group.workspaceURL) },
            onEditProject: { onEditProject(completeGroup) },
            onArchiveChats: { onArchiveProjectChats(completeGroup) },
            onRemoveProject: { onRemoveProject(completeGroup) }
        )
        if !section.isCollapsed {
            ForEach(section.rows) { row in
                familyEntry(row, under: completeGroup)
            }
            if section.showsEmptyState {
                SidebarNestedLine {
                    Text(L10n.string("No chats"))
                        .foregroundStyle(.secondary)
                        .opacity(0.5)
                }
            }
            if section.hiddenRowCount > 0 {
                SidebarShowMoreButton { disclosure?.showMore(section.disclosureKey) }
                    .padding(.horizontal, 4)
            }
            Color.clear
                .frame(height: SidebarMetrics.groupBottomSpacing - SidebarMetrics.rowSpacing)
                .accessibilityHidden(true)
        }
    }

    /// The Chats section, above the projects as in the Codex app: its rows read and act like the
    /// rows under a project, with "Show more" when it holds more than it lists.
    @ViewBuilder
    private func chatsEntry(_ chats: SidebarChats) -> some View {
        ParitySectionTitle(title: L10n.string("Chats"))
            .padding(.horizontal, 13)
            .padding(.top, layout.pinned.isEmpty ? 0 : 16)
            .padding(.bottom, 2)
        ForEach(chats.rows) { row in
            familyEntry(row, under: nil, inChats: true)
        }
        if chats.hiddenRowCount > 0 {
            SidebarShowMoreButton { disclosure?.showMore(SidebarChats.disclosureKey) }
                .padding(.horizontal, 4)
        }
    }

    private func toggle(_ section: SidebarSection) {
        guard let disclosure else { return }
        withAnimation(ParityMotion.easeInOut(reduceMotion: reduceMotion)) {
            disclosure.toggle(section.disclosureKey)
        }
    }

    /// A row and the tasks nested under it (`SidebarRow.children`), as the Claude app lists a
    /// family: each nested task a level in from the task it was started from
    /// (`SidebarRow.familyPlace`), joined by a guide, and, while the family is collapsed, a line
    /// counting the nested tasks it hides that opens it again.
    @ViewBuilder
    private func familyEntry(_ row: SidebarRow, under group: WorkspaceGroup?, inChats: Bool = false) -> some View {
        rowEntry(row, under: group, title: inChats ? SidebarProjection.chatRowTitle(for: row) : nil)
        ForEach(row.children) { child in
            rowEntry(child, under: group, title: inChats ? SidebarProjection.chatRowTitle(for: child) : nil)
        }
        if !row.hiddenChildren.isEmpty, case let .session(parent) = row.content {
            SidebarFamilySummaryLine(
                hidden: row.hiddenChildren, showsMore: !row.children.isEmpty,
                onExpand: { toggleFamily(of: parent.id) }
            )
            .padding(.horizontal, 4)
            .accessibilitySortPriority(ParityAccessibility.sidebarPrimary - 2)
        }
    }

    private func toggleFamily(of sessionID: UUID) {
        guard let disclosure else { return }
        withAnimation(ParityMotion.easeInOut(reduceMotion: reduceMotion)) {
            disclosure.toggle(SidebarProjection.familyKey(for: sessionID))
        }
    }

    /// "Hide nested sessions" or "Show nested sessions" on a row with tasks nested under it.
    private func familyToggle(for row: SidebarRow) -> SidebarFamilyToggle? {
        guard row.hasFamily, disclosure != nil, case let .session(session) = row.content else { return nil }
        let collapsed = disclosure?.isCollapsed(SidebarProjection.familyKey(for: session.id)) ?? false
        return SidebarFamilyToggle(isCollapsed: collapsed) { toggleFamily(of: session.id) }
    }

    /// A task or split row; under a project when `group` is set, in Pinned or Chats otherwise.
    /// `title` replaces the row's own title where a section names it differently (Chats).
    @ViewBuilder
    private func rowEntry(_ row: SidebarRow, under group: WorkspaceGroup?, title: String? = nil) -> some View {
        Group {
            switch row.content {
            case let .session(session):
                SidebarTaskEntry(
                    session: session,
                    title: title ?? group.map { SidebarProjection.rowTitle(for: session, under: $0) } ?? session.title,
                    projectName: group.map { $0.project?.name } ?? projectName(of: session),
                    familyPlace: row.familyPlace,
                    familyToggle: familyToggle(for: row),
                    isSelected: selection == row.id,
                    onSelect: { pick(row.id) },
                    onTogglePinned: onTogglePinned,
                    onArchive: onArchive,
                    onDelete: onDelete,
                    onRename: onRename,
                    onMarkRead: onMarkRead,
                    onMarkUnread: onMarkUnread,
                    projectMove: TaskProjectMove.options(
                        for: session, visibleProjects: allGroups.compactMap(\.project),
                        projects: projects.projects, home: projects.chatWorkspaceHome),
                    onMoveToProject: { onMoveToProject(session, $0) },
                    onDropTask: { dropped in splitActions.combine(dropped, session.id) },
                    onDetach: onDetachFromParent
                )
                .equatable()
            case let .split(split, members):
                SidebarSplitEntry(
                    split: split,
                    members: members,
                    title: title ?? group.map { SidebarProjection.rowTitle(for: row, under: $0) } ?? row.title,
                    isSelected: selection == row.id,
                    onSelect: { pick(row.id) },
                    actions: splitActions
                )
            }
        }
        .padding(.horizontal, 4)
        .id(row.id)
        .accessibilitySortPriority(ParityAccessibility.sidebarPrimary - 2)
    }

    /// The project a task listed outside its project's section belongs to (a pinned row, the activity
    /// view); nil for a chat.
    private func projectName(of session: SessionRecord) -> String? {
        allGroups.first { $0.sessions.contains { $0.id == session.id } }?.project?.name
    }

    /// Shows a row the person picked in the list.
    private func pick(_ item: WindowItem) {
        pickedInList = item
        onActivate(item)
    }

    private func moveSelection(by offset: Int) {
        guard let target = SidebarProjection.targetRow(
            in: navigationLayout, selected: navigationSelection, offset: offset
        ) else { return }
        onActivate(target)
    }

    /// The activity view: the "Priority" heading with its options, then one row per task, each
    /// with its project under the title, as the Codex app's priority list has them.
    @ViewBuilder
    private func activityEntry(_ activity: SidebarActivity) -> some View {
        SidebarActivityHeader(canMarkAllRead: activity.canMarkAllRead, onMarkAllRead: activity.onMarkAllRead)
            .padding(.leading, 13)
            .padding(.trailing, 8)
            .padding(.bottom, 2)
        if activity.sessions.isEmpty {
            Text(L10n.string(searchText.isEmpty ? "Nothing needs attention" : "No matching tasks."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .opacity(searchText.isEmpty ? 0.7 : 1)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
        }
        ForEach(activity.sessions) { session in
            let subtitle = activity.subtitle(session)
            SidebarTaskEntry(
                session: session,
                title: activityTitle(for: session),
                subtitle: subtitle.isEmpty ? nil : subtitle,
                projectName: projectName(of: session),
                isSelected: activity.selectedSessionID == session.id,
                onSelect: { pick(.session(session.id)) },
                onTogglePinned: onTogglePinned,
                onArchive: onArchive,
                onDelete: onDelete,
                onRename: onRename,
                onMarkRead: onMarkRead,
                onMarkUnread: onMarkUnread,
                projectMove: TaskProjectMove.options(
                    for: session, visibleProjects: allGroups.compactMap(\.project),
                    projects: projects.projects, home: projects.chatWorkspaceHome),
                onMoveToProject: { onMoveToProject(session, $0) },
                onDropTask: { dropped in splitActions.combine(dropped, session.id) }
            )
            .equatable()
            .padding(.horizontal, 4)
            .id(WindowItem.session(session.id))
            .accessibilitySortPriority(ParityAccessibility.sidebarPrimary - 2)
        }
    }

    /// The title the task has in the task list: without its project's name, which the line under
    /// it shows.
    private func activityTitle(for session: SessionRecord) -> String {
        if let group = allGroups.first(where: { $0.sessions.contains { $0.id == session.id } }) {
            return SidebarProjection.rowTitle(for: session, under: group)
        }
        return SidebarProjection.chatRowTitle(for: SidebarRow(content: .session(session)))
    }
}

/// The activity view's heading, the Codex app's "Priority" with its options menu, which here
/// holds only "Mark all as read".
private struct SidebarActivityHeader: View {
    let canMarkAllRead: Bool
    let onMarkAllRead: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(L10n.string("Priority"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Menu {
                Button(L10n.string("Mark all as read"), action: onMarkAllRead)
                    .disabled(!canMarkAllRead)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .parityPointer()
            .help(L10n.string("Activity view options"))
            .accessibilityLabel(L10n.string("Activity view options"))
        }
    }
}

/// A project's label over its tasks, faint and small as the Claude app's Code list labels a group
/// (2026-10-16, the person's request). Clicking it collapses or expands the tasks under it, as in
/// the Codex app, and a caret after the name shows which; hovering brightens it and shows its
/// summary and the options and New task actions. A collapsed project keeps its tasks' running and
/// unread marks at its end.
private struct ProjectTaskHeader: View {
    let group: WorkspaceGroup
    let completeGroup: WorkspaceGroup
    /// The tasks nested under the project, shown or not.
    let nestedSessions: [SessionRecord]
    let isCollapsed: Bool
    @Bindable var projects: ProjectStore
    let onToggle: () -> Void
    let onNewTask: () -> Void
    let onEditProject: () -> Void
    let onArchiveChats: () -> Void
    let onRemoveProject: () -> Void
    @State private var isHovering = false
    @Environment(\.shellBusyTaskIDs) private var shellBusyTaskIDs
    @Environment(\.taskAttentionDetails) private var attentionDetails
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(TaskResourceMonitor.self) private var resources: TaskResourceMonitor?

    private var displayName: String { completeGroup.displayName }

    /// A collapsed project keeps its busy tasks' CPU on its own row, as it keeps their state.
    private var collapsedCPUPercent: Int? {
        guard isCollapsed, let resources else { return nil }
        let ids = nestedSessions.map(\.id)
        return SidebarTaskIndicatorProjection.cpuPercent(for: ids, busyCPU: resources.busyCPU(of: ids))
    }

    private var helpText: String {
        var lines = [summary]
        if let collapsedStatus { lines.append(collapsedStatus.help) }
        if let collapsedCPUPercent { lines.append(SidebarCPUIndicatorView.help(collapsedCPUPercent)) }
        return lines.joined(separator: "\n")
    }

    private var accessibilityStatus: String {
        var parts = [L10n.string(isCollapsed ? "Collapsed" : "Expanded"), taskSummary]
        if let collapsedStatus { parts.append(collapsedStatus.accessibilityName) }
        if let collapsedCPUPercent { parts.append(L10n.format("CPU %lld%%", collapsedCPUPercent)) }
        return parts.joined(separator: ", ")
    }

    private var isPinned: Bool { completeGroup.project?.isPinned ?? false }

    private func togglePinned() {
        guard let id = completeGroup.project?.id else { return }
        projects.togglePinned(id)
    }

    private var activeTaskCount: Int {
        completeGroup.sessions.count {
            $0.status == .running || $0.status == .waitingForApproval || shellBusyTaskIDs.contains($0.id)
        }
    }

    private var taskSummary: String {
        L10n.format("%lld tasks · %lld active", completeGroup.sessions.count, activeTaskCount)
    }

    /// The summary the Codex app shows in the project's hover card: name, counts, folders.
    private var summary: String {
        let roots = completeGroup.roots.map { ProjectSidebarPresentation.abbreviatedPath(for: $0) }
        return ([displayName, taskSummary] + roots).joined(separator: "\n")
    }

    /// A collapsed project shows its most urgent task's state, as the Codex app's collapsed project
    /// shows a running or unread mark for the chats under it.
    private var collapsedStatus: SidebarTaskStatus? {
        guard isCollapsed else { return nil }
        return SidebarTaskIndicatorProjection.summary(of: nestedSessions, details: attentionDetails,
                                                      shellBusy: shellBusyTaskIDs)
    }

    private var trailingItems: [SidebarRowTrailingItem] {
        SidebarTaskIndicatorProjection.trailingItems(cpuPercent: collapsedCPUPercent, status: collapsedStatus)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onToggle) {
                HStack(spacing: 4) {
                    Text(displayName)
                        .font(.system(size: SidebarMetrics.projectHeaderFontSize * interfaceScale))
                        .foregroundStyle(isHovering ? .primary : .secondary)
                        .lineLimit(1)
                    // The Claude app's caret after the name: shown while collapsed, and on hover
                    // turned down while open.
                    DisclosureCaret(isOpen: !isCollapsed, size: 8 * interfaceScale)
                        .foregroundStyle(.secondary)
                        .opacity(isCollapsed || isHovering ? 1 : 0)
                    Spacer(minLength: 4)
                    if !isHovering {
                        SidebarRowTrailingItemsView(items: trailingItems)
                    }
                }
                .padding(.leading, SidebarMetrics.projectHeaderLeading - SidebarMetrics.rowInset)
                .padding(.trailing, isHovering ? 58 : SidebarMetrics.rowTrailingPadding)
                .frame(height: SidebarMetrics.projectHeaderHeight * interfaceScale)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .parityPointer()
            .help(helpText)
            .accessibilityLabel(L10n.format("Project %@", displayName))
            .accessibilityValue(accessibilityStatus)
            .accessibilityHint(L10n.string(isCollapsed ? "Expand folder" : "Collapse folder"))
            .accessibilityAddTraits(.isHeader)

            if isHovering {
                HStack(spacing: 0) {
                    Menu {
                        projectOptions
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .parityPointer()
                    .accessibilityLabel(L10n.string("Project options"))

                    ProjectHoverActionButton(
                        systemName: "square.and.pencil",
                        label: L10n.string("New task in project"),
                        action: onNewTask
                    )
                }
                .padding(.trailing, 3)
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            projectOptions
        }
        .padding(.top, SidebarMetrics.projectHeaderTopSpacing)
        .padding(.horizontal, SidebarMetrics.rowInset)
        .accessibilitySortPriority(ParityAccessibility.sidebarPrimary - 2)
    }

    @ViewBuilder
    private var projectOptions: some View {
        Button(isPinned ? L10n.string("Unpin project") : L10n.string("Pin project"), action: togglePinned)
            .disabled(completeGroup.project == nil)
        Button(L10n.string("Edit project"), action: onEditProject)
            .disabled(completeGroup.project == nil)
        Divider()
        Button(L10n.string("Show in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([group.workspaceURL])
        }
        Divider()
        Button(L10n.string("Archive chats"), action: onArchiveChats)
            .disabled(completeGroup.sessions.isEmpty)
        Divider()
        Button(L10n.string("Remove project"), role: .destructive, action: onRemoveProject)
            .disabled(completeGroup.project == nil)
    }
}

/// A line under a project's label where its rows' titles start: "No chats".
private struct SidebarNestedLine<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 0) {
            content
                .font(.system(size: 13 * interfaceScale))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, SidebarMetrics.rowInset + SidebarRowLeading<EmptyView>.titleLeading())
        .frame(height: SidebarMetrics.secondaryLineHeight * interfaceScale)
    }
}

/// "Show more" under a project that holds more rows than it lists (Codex: tertiary, regular
/// weight), where the rows' titles start. Each press lists ten more until the project is collapsed.
private struct SidebarShowMoreButton: View {
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(L10n.string("Show more"))
                    .font(.system(size: 13 * interfaceScale))
                    .foregroundStyle(isHovering ? .secondary : .tertiary)
                Spacer(minLength: 0)
            }
            .padding(.leading, SidebarRowLeading<EmptyView>.titleLeading())
            .frame(height: SidebarMetrics.secondaryLineHeight * interfaceScale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .onHover { isHovering = $0 }
        .accessibilitySortPriority(ParityAccessibility.sidebarPrimary - 2)
    }
}

/// A row's tasks keep using a lot of CPU (Task Resource Usage): a CPU mark and their recent CPU,
/// before the running and unread marks, as quiet as they are. Shown only while busy.
struct SidebarCPUIndicatorView: View {
    let percent: Int
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "cpu")
                .font(.system(size: 10 * interfaceScale, weight: .medium))
            Text(verbatim: "\(percent)%")
                .font(.system(size: 11 * interfaceScale).monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .fixedSize()
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.format("CPU %lld%%", percent))
    }

    /// The line a row's help adds while it shows the mark.
    static func help(_ percent: Int) -> String {
        L10n.format("Processes are using %lld%% CPU (10-second average)", percent)
    }
}

/// The marks at a row's end, drawn in the order `SidebarTaskIndicatorProjection.trailingItems`
/// gives them.
struct SidebarRowTrailingItemsView: View {
    let items: [SidebarRowTrailingItem]
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            switch item {
            case .cloud:
                Image(systemName: "cloud")
                    .font(.system(size: 10 * interfaceScale, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            case .worktree:
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10 * interfaceScale, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            case let .pullRequest(mark):
                // The Claude app's 12 pt state glyph, without the number.
                Image(systemName: mark.glyph.systemName)
                    .font(.system(size: 10 * interfaceScale, weight: .semibold))
                    .foregroundStyle(TaskPullRequestBadgeView.color(mark.tone))
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            case let .cpu(percent):
                SidebarCPUIndicatorView(percent: percent)
            case let .status(status):
                SidebarTaskStatusView(status: status)
            }
        }
    }
}

/// A task's state at a row's end, as the Claude app's Code session list marks it at the row's end:
/// a 6 pt dot (`status-dot`) — green for an approval and amber for a question (the Claude app draws
/// both waiting states amber; Yardlet keeps its green for an approval so the two stay apart), a
/// gray dot that blinks while a turn runs (`dframe-dot-blink`, still with Reduce Motion), the blue
/// unread dot — and, in place of a dot, the Claude app's red warning mark for a failed turn and its
/// usage gauge for a plan limit. Every mark is the same 14 pt wide, so a title is never cut for it.
struct SidebarTaskStatusView: View {
    let status: SidebarTaskStatus
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    /// The dot's diameter, the Claude app's `.status-dot` (6 px).
    static let dotSize: CGFloat = 6

    var body: some View {
        content
            .frame(width: 14, height: 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.accessibilityName)
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .awaitingApproval:
            SidebarStatusDot(color: .green)
        case .needsInput:
            SidebarStatusDot(color: .orange)
        case .waitingInBrowser:
            // The browser's globe, in the color of a question waiting for the person.
            Image(systemName: "globe")
                .font(.system(size: 10 * interfaceScale, weight: .semibold))
                .foregroundStyle(.orange)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10 * interfaceScale, weight: .semibold))
                .foregroundStyle(.red)
        case .usageLimit:
            Image(systemName: "gauge.with.dots.needle.100percent")
                .font(.system(size: 10 * interfaceScale, weight: .medium))
                .foregroundStyle(.orange)
        case .running:
            SidebarStatusDot(color: .secondary, blinks: true)
        case .reconnecting:
            Image(systemName: "network.slash")
                .font(.system(size: 10 * interfaceScale, weight: .medium))
                .foregroundStyle(.secondary)
        case .unread:
            SidebarStatusDot(color: ParityTheme.accent)
        }
    }
}

/// The Claude app's status dot. A working dot fades to 30% and back every 1.2 s (`BlinkingDot`), and
/// holds still with Reduce Motion.
private struct SidebarStatusDot: View {
    let color: Color
    var blinks = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let diameter = SidebarTaskStatusView.dotSize * interfaceScale
        if blinks, !reduceMotion {
            BlinkingDot(color: color, diameter: diameter)
        } else {
            Circle()
                .fill(color)
                .frame(width: diameter, height: diameter)
        }
    }
}

private struct ProjectHoverActionButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Equal when it would show the same row: its actions are bound to the same task and window, so a
/// window redraw that changed nothing the row shows does not redraw it.
private struct SidebarTaskEntry: View, @MainActor Equatable {
    let session: SessionRecord
    /// The title the row shows; under a project, without the project's name.
    let title: String
    /// A second line under the title: the project, in the activity view.
    var subtitle: String? = nil
    /// The project the task belongs to, for its hover card; nil for a chat. A value rather than a
    /// lookup the window hands down, so a window update that changes no name draws no row again.
    var projectName: String? = nil
    /// Where the row sits in the family it is nested in, when it is a task started from another.
    var familyPlace: SidebarFamilyPlace? = nil
    /// Hiding or showing the tasks nested under this one, when it has any.
    var familyToggle: SidebarFamilyToggle? = nil
    let isSelected: Bool
    let onSelect: () -> Void
    let onTogglePinned: (SessionRecord) -> Void
    let onArchive: (SessionRecord) -> Void
    let onDelete: (SessionRecord) -> Void
    let onRename: (SessionRecord) -> Void
    let onMarkRead: (SessionRecord) -> Void
    let onMarkUnread: (SessionRecord) -> Void
    /// The projects the task can move to and whether it can go back to Chats.
    let projectMove: TaskProjectMove.Options
    let onMoveToProject: (Project?) -> Void
    let onDropTask: (UUID) -> Void
    /// "Detach to top level", for a task listed under the task it was started from.
    var onDetach: ((SessionRecord) -> Void)? = nil
    @State private var isDropTargeted = false
    @Environment(TaskPullRequestMonitor.self) private var pullRequests: TaskPullRequestMonitor?
    @Environment(\.openWindowItemInNewTab) private var openInNewTab
    @Environment(\.openTaskInSplitView) private var openInSplitView
    @Environment(\.openTaskInSidePanel) private var openInSidePanel

    /// The pull request the row marks, whose number and link its menu offers.
    private var pullRequestMark: TaskPullRequestRowMark? {
        pullRequests?.pullRequest(for: session.id).flatMap(TaskPullRequestRowMark.init)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session == rhs.session && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
            && lhs.projectName == rhs.projectName && lhs.familyPlace == rhs.familyPlace && lhs.familyToggle?.isCollapsed == rhs.familyToggle?.isCollapsed
            && lhs.isSelected == rhs.isSelected && lhs.projectMove == rhs.projectMove
            && (lhs.onDetach == nil) == (rhs.onDetach == nil)
    }

    var body: some View {
        TaskRow(
            session: session,
            title: title,
            subtitle: subtitle,
            projectName: projectName,
            familyPlace: familyPlace,
            isSelected: isSelected || isDropTargeted,
            onSelect: onSelect,
            onTogglePinned: { onTogglePinned(session) },
            onArchive: { onArchive(session) }
        )
        .contextMenu {
            if session.isCloud, let url = session.cloudTargetURL() {
                Button(session.harness == .codex ? L10n.string("Open in Codex…") : L10n.string("Open in Browser…")) {
                    NSWorkspace.shared.open(url)
                }
                Divider()
            }
            if let openInNewTab {
                Button(L10n.string("Open in New Tab")) { openInNewTab.open(.session(session.id)) }
            }
            if let openInSplitView {
                Button(L10n.string("Open in Split View")) { openInSplitView.open(session.id) }
            }
            if let openInSidePanel {
                Button(L10n.string("Open in Side Panel")) { openInSidePanel.open(session.id) }
            }
            if openInNewTab != nil || openInSplitView != nil || openInSidePanel != nil {
                Divider()
            }
            Button(session.isPinned ? L10n.string("Unpin") : L10n.string("Pin")) {
                onTogglePinned(session)
            }
            Button(L10n.string("Rename…")) { onRename(session) }
            if session.hasUnreadUpdate {
                Button(L10n.string("Mark task as read")) { onMarkRead(session) }
            } else {
                Button(L10n.string("Mark task as unread")) { onMarkUnread(session) }
            }
            if let familyToggle {
                Button(familyToggle.title, action: familyToggle.action)
            }
            // The Claude app's row menu item for a session another started (`XP5vxiZixk`).
            if familyPlace != nil, let onDetach {
                Button(L10n.string("Detach to top level")) { onDetach(session) }
            }
            if let pullRequestMark {
                Button(pullRequestMark.openTitle) { NSWorkspace.shared.open(pullRequestMark.url) }
            }
            TaskProjectMoveMenuItems(options: projectMove, onMove: onMoveToProject)
            Button(L10n.string("Archive"), role: .destructive) { onArchive(session) }
            Button(L10n.string("Delete task"), role: .destructive) { onDelete(session) }
        }
        // Dragging a task onto another task's row, or onto a pane, puts both in a split view.
        .draggable(TaskDragItem(sessionID: session.id)) {
            Label(title, systemImage: "rectangle.split.2x1")
                .padding(6)
        }
        .dropDestination(for: TaskDragItem.self) { items, _ in
            guard let dropped = items.first?.sessionID, dropped != session.id else { return false }
            onDropTask(dropped)
            return true
        } isTargeted: { isDropTargeted = $0 }
        // AppKit can retain the previous context menu when a row moves between sections (pinning,
        // or moving to another project) or its family is hidden or shown. Refresh its host while the
        // outer scroll target keeps the task's stable identity.
        .id("\(session.id):\(session.isPinned):\(session.projectID?.uuidString ?? "-"):"
            + "\(session.parentTaskID?.uuidString ?? "-"):"
            + (familyToggle.map { $0.isCollapsed ? "hidden" : "shown" } ?? "-"))
    }
}

/// The leading part every task-like row shares, harness or not, wherever it is listed (Pinned,
/// Chats, under a project, the activity view): the mark centred in the 32pt gutter, the title after
/// it. A task started from another sits one family indent further in.
struct SidebarRowLeading<Mark: View>: View {
    /// A task started from another sits a family indent further in for each level it is nested.
    var nestingDepth = 0
    @ViewBuilder let mark: Mark
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        mark.frame(width: SidebarMetrics.nestedIconSize * interfaceScale,
                   height: SidebarMetrics.nestedIconSize * interfaceScale)
            .frame(width: SidebarMetrics.gutterWidth)
            .padding(.leading, Self.indent(nestingDepth: nestingDepth))
    }

    /// How far a row's gutter sits in from the row's start: a family indent per level nested.
    static func indent(nestingDepth: Int) -> CGFloat {
        CGFloat(nestingDepth) * SidebarMetrics.familyIndent
    }

    /// Where a row's title starts, from the row's start.
    static func titleLeading(nestingDepth: Int = 0) -> CGFloat {
        indent(nestingDepth: nestingDepth) + SidebarMetrics.gutterWidth
    }

    /// Where the family guide's line for a level runs down: under the middle of the mark of the row
    /// a level out (level 1 under the family's top task).
    static func guideX(level: Int) -> CGFloat { indent(nestingDepth: level - 1) + SidebarMetrics.gutterWidth / 2 }
}

/// A row that acts above or below a list of tasks (New task, Scheduled tasks, Personal agents, Back, Import): its
/// symbol in the rows' gutter and its words where task titles start, in the rows' size, inset from
/// the sidebar's edges as the rows are, so every row's symbol and words share one column
/// (2026-10-22 alignment audit). New task keeps its fill.
struct SidebarActionRow: View {
    let systemName: String
    let title: String
    var symbolWeight: Font.Weight = .medium
    var titleWeight: Font.Weight = .regular
    var height: CGFloat = SidebarMetrics.rowHeight
    var isFilled = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 0) {
            SidebarRowLeading {
                Image(systemName: systemName)
                    .font(.system(size: 12 * interfaceScale, weight: symbolWeight))
            }
            Text(title)
                .font(.system(size: 13 * interfaceScale, weight: titleWeight))
                .lineLimit(1)
            Spacer(minLength: SidebarMetrics.rowTrailingPadding)
        }
        .frame(height: height * interfaceScale)
        .contentShape(Rectangle())
        .background(isFilled ? ParityTheme.hoverFill : .clear, in: SidebarMetrics.rowShape())
    }
}

/// A list's search field, its magnifier in the rows' gutter and its text where task titles start.
struct SidebarSearchField: View {
    let placeholder: String
    @Binding var text: String
    @Environment(\.yardletInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 0) {
            SidebarRowLeading {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12 * interfaceScale, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13 * interfaceScale))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .parityPointer()
                .accessibilityLabel(L10n.string("Clear search"))
            }
        }
        .padding(.trailing, SidebarMetrics.rowTrailingPadding)
        .frame(height: SidebarMetrics.rowHeight * interfaceScale)
        .background(ParityTheme.subtleFill, in: SidebarMetrics.rowShape())
    }
}

/// The lines joining a nested task to its family (Claude `.df-family:after`): at the task's level,
/// down from the row above, then across toward the task's mark with a rounded corner, carried on
/// down when more of that level follows; at each level further out whose line runs on to a later
/// row, straight through (`SidebarFamilyPlace.continuingLevels`).
struct SidebarFamilyGuide: Shape {
    let place: SidebarFamilyPlace

    /// A stronger line than a separator, as the Claude app draws it (`--cds-border-strong`).
    static let color = Color.primary.opacity(0.22)

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = SidebarMetrics.familyGuideRadius
        let midY = rect.midY
        let top = rect.minY - SidebarMetrics.rowSpacing
        for level in place.continuingLevels where level < place.depth {
            let x = SidebarRowLeading<EmptyView>.guideX(level: level)
            path.move(to: CGPoint(x: x, y: top))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        let x = SidebarRowLeading<EmptyView>.guideX(level: place.depth)
        path.move(to: CGPoint(x: x, y: top))
        path.addLine(to: CGPoint(x: x, y: midY - radius))
        path.addQuadCurve(to: CGPoint(x: x + radius, y: midY), control: CGPoint(x: x, y: midY))
        path.addLine(to: CGPoint(x: x + SidebarMetrics.familyGuideLength, y: midY))
        if place.continuingLevels.contains(place.depth) {
            path.move(to: CGPoint(x: x, y: midY - radius))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        return path
    }
}

/// The row menu item that hides or shows the tasks nested under a task, in the Claude app's words.
struct SidebarFamilyToggle {
    let isCollapsed: Bool
    let action: () -> Void

    var title: String { L10n.string(isCollapsed ? "Show nested sessions" : "Hide nested sessions") }
}

/// The line under a collapsed family, as the Claude app's `df-family-stub`: how many nested tasks
/// it hides, and of those how many failed, have something new and are working, "more" when some
/// stay listed (those waiting on the person and the one shown). Pressing it shows them again.
struct SidebarFamilySummaryLine: View {
    let hidden: [SessionRecord]
    /// Some nested tasks are still listed above the line.
    let showsMore: Bool
    let onExpand: () -> Void
    @State private var isHovering = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.shellBusyTaskIDs) private var shellBusyTaskIDs
    @Environment(\.taskAttentionDetails) private var attentionDetails

    struct Counts: Equatable {
        var sessions = 0
        var failed = 0
        var new = 0
        var working = 0
    }

    static func counts(of hidden: [SessionRecord], details: [UUID: TaskAttentionDetail] = [:],
                       shellBusy: Set<UUID> = []) -> Counts {
        var counts = Counts(sessions: hidden.count)
        for session in hidden {
            switch SidebarTaskIndicatorProjection.status(of: session, detail: details[session.id],
                                                         isShellBusy: shellBusy.contains(session.id)) {
            case .failed?: counts.failed += 1
            case .running?: counts.working += 1
            default: break
            }
            if session.hasUnreadUpdate { counts.new += 1 }
        }
        return counts
    }

    /// "3 nested sessions", or "3 more nested sessions" when some are still listed.
    static func sessionsText(_ count: Int, more: Bool) -> String {
        if more {
            return count == 1 ? L10n.string("1 more nested session") : L10n.format("%lld more nested sessions", count)
        }
        return count == 1 ? L10n.string("1 nested session") : L10n.format("%lld nested sessions", count)
    }

    /// The parts after the count, in the Claude app's order.
    static func detailTexts(_ counts: Counts) -> (failed: String?, new: String?, working: String?) {
        (counts.failed > 0 ? L10n.format("%lld failed", counts.failed) : nil,
         counts.new > 0 ? L10n.format("%lld new", counts.new) : nil,
         counts.working > 0 ? L10n.format("%lld working", counts.working) : nil)
    }

    /// What the line says to assistive apps: Claude's "Show {sessions}, {news}".
    static func accessibilityLabel(_ counts: Counts, more: Bool) -> String {
        let sessions = sessionsText(counts.sessions, more: more)
        guard let new = detailTexts(counts).new else { return L10n.format("Show %@", sessions) }
        return L10n.format("Show %@, %@", sessions, new)
    }

    /// One line of text, so it is cut once at its end: the count first, then the details, with the
    /// unread dot before what is new.
    private func summaryText(counts: Counts, details: (failed: String?, new: String?, working: String?)) -> Text {
        var text = Text(Self.sessionsText(counts.sessions, more: showsMore))
        if let failed = details.failed { text = text + Text(verbatim: " · ") + Text(failed) }
        if let new = details.new {
            text = text + Text(verbatim: " · ")
                + Text(Image(systemName: "circle.fill")).font(.system(size: 6 * interfaceScale))
                    .foregroundStyle(ParityTheme.accent)
                + Text(verbatim: " ") + Text(new)
        }
        if let working = details.working { text = text + Text(verbatim: " · ") + Text(working) }
        return text
    }

    var body: some View {
        let counts = Self.counts(of: hidden, details: attentionDetails, shellBusy: shellBusyTaskIDs)
        let details = Self.detailTexts(counts)
        Button(action: onExpand) {
            HStack(spacing: 5) {
                summaryText(counts: counts, details: details)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if counts.failed > 0 {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10 * interfaceScale, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: 14, height: 14)
                }
            }
            .font(.system(size: 12 * interfaceScale))
            .foregroundStyle(isHovering ? .primary : .secondary)
            .lineLimit(1)
            .padding(.leading, SidebarMetrics.familyIndent
                     + (SidebarMetrics.gutterWidth - SidebarMetrics.nestedIconSize * interfaceScale) / 2)
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .frame(height: SidebarMetrics.secondaryLineHeight * interfaceScale)
            .contentShape(Rectangle())
            .background(alignment: .leading) {
                SidebarFamilyGuide(place: SidebarFamilyPlace(depth: 1))
                    .stroke(SidebarFamilyGuide.color, style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
            .background(isHovering ? ParityTheme.hoverFill : .clear, in: SidebarMetrics.rowShape())
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .onHover { isHovering = $0 }
        .help(([Self.sessionsText(counts.sessions, more: showsMore)]
               + [details.failed, details.new, details.working].compactMap { $0 }).joined(separator: " · "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(counts, more: showsMore))
        .accessibilityAddTraits(.isButton)
    }
}

/// A split view's row. It reads like a task row: the tasks' titles (or the name the user gave),
/// the same running and unread marks, and the same pin and archive actions.
private struct SidebarSplitEntry: View {
    let split: SplitGroup
    let members: [SessionRecord]
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void
    let actions: SidebarSplitActions
    @State private var isHovering = false
    @State private var isDropTargeted = false
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.shellBusyTaskIDs) private var shellBusyTaskIDs
    @Environment(\.taskAttentionDetails) private var attentionDetails
    @Environment(TaskResourceMonitor.self) private var resources: TaskResourceMonitor?
    @Environment(\.openWindowItemInNewTab) private var openInNewTab

    private var hasUnreadUpdate: Bool { members.contains(where: \.hasUnreadUpdate) }

    private var cpuPercent: Int? {
        guard let resources else { return nil }
        let ids = members.map(\.id)
        return SidebarTaskIndicatorProjection.cpuPercent(for: ids, busyCPU: resources.busyCPU(of: ids))
    }

    private func memberStatus(_ member: SessionRecord) -> SidebarTaskStatus? {
        SidebarTaskIndicatorProjection.status(of: member, detail: attentionDetails[member.id],
                                              isShellBusy: shellBusyTaskIDs.contains(member.id))
    }

    private var helpText: String {
        var lines = [split.customName ?? members.map(\.title).joined(separator: " + ")]
        lines += members.map { member in
            ([member.title, member.harness.displayName] + [memberStatus(member)?.accessibilityName].compactMap { $0 })
                .joined(separator: " · ")
        }
        if let cpuPercent { lines.append(SidebarCPUIndicatorView.help(cpuPercent)) }
        return lines.joined(separator: "\n")
    }

    private var accessibilityStatus: String {
        var parts = members.map { memberStatus($0)?.accessibilityName ?? $0.status.displayName }
        if let cpuPercent { parts.append(L10n.format("CPU %lld%%", cpuPercent)) }
        return parts.joined(separator: ", ")
    }

    /// The split row shows its most urgent task's state, as a collapsed project does.
    private var trailingItems: [SidebarRowTrailingItem] {
        SidebarTaskIndicatorProjection.trailingItems(
            cpuPercent: cpuPercent,
            status: SidebarTaskIndicatorProjection.summary(of: members, details: attentionDetails,
                                                           shellBusy: shellBusyTaskIDs)
        )
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onSelect) {
                HStack(spacing: 0) {
                    SidebarRowLeading {
                        Image(systemName: splitSymbol)
                            .font(.system(size: 11 * interfaceScale, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.system(size: 13 * interfaceScale, weight: hasUnreadUpdate ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 3)
                    if !isHovering {
                        SidebarRowTrailingItemsView(items: trailingItems)
                    }
                }
                .padding(.trailing, isHovering ? 53 : SidebarMetrics.rowTrailingPadding)
                .frame(height: SidebarMetrics.rowHeight * interfaceScale)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .parityPointer()
            .help(helpText)
            .accessibilityLabel(L10n.format("Split view: %@", members.map(\.title).joined(separator: ", ")))
            .accessibilityValue(accessibilityStatus)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if isHovering {
                HStack(spacing: 1) {
                    TaskRowActionButton(
                        systemName: split.isPinned ? "pin.fill" : "pin",
                        label: split.isPinned ? L10n.string("Unpin") : L10n.string("Pin"),
                        action: { actions.togglePinned(split) }
                    )
                    TaskRowActionButton(
                        systemName: "archivebox",
                        label: L10n.string("Archive"),
                        action: { actions.archive(split) }
                    )
                }
                .padding(.trailing, 4)
            }
        }
        .frame(height: SidebarMetrics.rowHeight * interfaceScale)
        .contentShape(Rectangle())
        .background(
            isSelected || isDropTargeted ? ParityTheme.selectedFill : (isHovering ? ParityTheme.hoverFill : .clear),
            in: SidebarMetrics.rowShape()
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            if let openInNewTab {
                Button(L10n.string("Open in New Tab")) { openInNewTab.open(.split(split.id)) }
                Divider()
            }
            Button(split.isPinned ? L10n.string("Unpin") : L10n.string("Pin")) { actions.togglePinned(split) }
            Button(L10n.string("Rename split view…")) { actions.rename(split) }
            Button(L10n.string("End split view")) { actions.dissolve(split) }
            Button(L10n.string("Archive tasks…"), role: .destructive) { actions.archive(split) }
        }
        .dropDestination(for: TaskDragItem.self) { items, _ in
            guard let dropped = items.first?.sessionID, !split.sessionIDs.contains(dropped) else { return false }
            actions.add(dropped, split)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var splitSymbol: String {
        if case let .branch(axis, _, _) = split.root, axis == .vertical { return "rectangle.split.1x2" }
        return "rectangle.split.2x1"
    }
}

/// One task's row, the same for every harness: the harness shows only as the small mark before
/// the title. A task in a linked worktree adds the worktree mark the Codex app puts at the row's
/// end; its name is in the row's help and accessibility value.
private struct TaskRow: View {
    let session: SessionRecord
    let title: String
    /// A second line under the title (the project, in the activity view).
    var subtitle: String? = nil
    /// The project the task belongs to, for its hover card; nil for a chat.
    var projectName: String? = nil
    /// Where the row sits in its family, when it is nested under the task it was started from.
    var familyPlace: SidebarFamilyPlace? = nil
    let isSelected: Bool
    let onSelect: () -> Void
    let onTogglePinned: () -> Void
    let onArchive: () -> Void
    @State private var isHovering = false
    /// Reads the task's saved conversation once the pointer has rested on the row a moment.
    @State private var prefetch: Task<Void, Never>?
    @Environment(\.prefetchTaskConversation) private var prefetchConversation
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @Environment(\.shellBusyTaskIDs) private var shellBusyTaskIDs
    @Environment(\.taskAttentionDetails) private var attentionDetails
    @Environment(\.scheduledTaskIDs) private var scheduledTaskIDs
    @Environment(TaskResourceMonitor.self) private var resources: TaskResourceMonitor?
    @Environment(TaskPullRequestMonitor.self) private var pullRequests: TaskPullRequestMonitor?
    @Environment(AccountAssignmentLog.self) private var accountAssignments: AccountAssignmentLog?
    @Environment(\.sidebarHoverCard) private var hoverCard
    /// Where the row is in the window, kept without drawing the row again as the list scrolls.
    @State private var place = SidebarRowPlace()

    private var isScheduledRun: Bool { scheduledTaskIDs.contains(session.id) }

    private var cpuPercent: Int? {
        resources.flatMap { SidebarTaskIndicatorProjection.cpuPercent(for: [session.id], busyCPU: $0.busyCPU(of: [session.id])) }
    }

    private var pullRequestMark: TaskPullRequestRowMark? {
        pullRequests?.pullRequest(for: session.id).flatMap(TaskPullRequestRowMark.init)
    }

    private var status: SidebarTaskStatus? {
        SidebarTaskIndicatorProjection.status(of: session, detail: attentionDetails[session.id],
                                              isShellBusy: shellBusyTaskIDs.contains(session.id))
    }

    private var trailingItems: [SidebarRowTrailingItem] {
        SidebarTaskIndicatorProjection.trailingItems(isCloud: session.isCloud, isWorktree: worktreeDetail != nil,
                                                     pullRequest: pullRequestMark, cpuPercent: cpuPercent, status: status)
    }

    private var rowHeight: CGFloat {
        (subtitle == nil ? SidebarMetrics.rowHeight : SidebarMetrics.twoLineRowHeight) * interfaceScale
    }

    /// What the row's hover card shows (`SidebarHoverCardView`), which the row's help showed before.
    private var hoverContent: SidebarHoverCardContent {
        SidebarHoverCardContent(session: session, projectName: projectName, status: status,
                                isScheduledRun: isScheduledRun, cpuPercent: cpuPercent, pullRequest: pullRequestMark,
                                accountAssignment: accountAssignments?.assignment(for: session.id))
    }

    /// The row's state in the words its mark stands for, and "Unread" when a result is unread
    /// whatever the mark shows.
    private var accessibilityStatus: String {
        var parts = [status.map(\.accessibilityName) ?? session.status.displayName]
        if session.hasUnreadUpdate, status != .unread { parts.append(SidebarTaskStatus.unread.accessibilityName) }
        if session.isCloud { parts.append(L10n.string("Cloud session")) }
        if let subtitle { parts.append(subtitle) }
        if isScheduledRun { parts.append(L10n.string("Scheduled task")) }
        if familyPlace != nil { parts.append(L10n.string("Nested session")) }
        if let worktreeDetail { parts.append(L10n.format("Worktree %@", worktreeDetail)) }
        if let pullRequestMark { parts.append(pullRequestMark.accessibilityName) }
        if let cpuPercent { parts.append(L10n.format("CPU %lld%%", cpuPercent)) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
#if DEBUG
        let _ = ViewBodyCensus.note(.sidebarRow)
#endif
        ZStack(alignment: .trailing) {
            Button {
                hoverCard?.dismiss()
                onSelect()
            } label: {
                HStack(spacing: 0) {
                    SidebarRowLeading(nestingDepth: familyPlace?.depth ?? 0) {
                        HarnessIdentityIcon(harness: session.harness,
                                            size: SidebarMetrics.nestedIconSize * interfaceScale)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 13 * interfaceScale,
                                          weight: session.hasUnreadUpdate ? .semibold : .regular))
                            .lineLimit(1)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 11 * interfaceScale))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if isScheduledRun {
                        Image(systemName: "clock")
                            .font(.system(size: 10 * interfaceScale, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 5)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 3)
                    if !isHovering {
                        SidebarRowTrailingItemsView(items: trailingItems)
                    }
                }
                .padding(.trailing, isHovering ? 53 : SidebarMetrics.rowTrailingPadding)
                .frame(height: rowHeight)
                .contentShape(Rectangle())
                .background(alignment: .leading) {
                    if let familyPlace {
                        SidebarFamilyGuide(place: familyPlace)
                            .stroke(SidebarFamilyGuide.color, style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    }
                }
            }
            .buttonStyle(.borderless)
            .parityPointer()
            .accessibilityLabel("\(title), \(session.harness.displayName)")
            .accessibilityValue(accessibilityStatus)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if isHovering {
                HStack(spacing: 1) {
                    TaskRowActionButton(
                        systemName: session.isPinned ? "pin.fill" : "pin",
                        label: session.isPinned ? L10n.string("Unpin") : L10n.string("Pin"),
                        action: { hoverCard?.dismiss(); onTogglePinned() }
                    )
                    TaskRowActionButton(
                        systemName: "archivebox",
                        label: L10n.string("Archive"),
                        action: { hoverCard?.dismiss(); onArchive() }
                    )
                }
                .padding(.trailing, 4)
            }
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .background(
            isSelected ? ParityTheme.selectedFill : (isHovering ? ParityTheme.hoverFill : .clear),
            in: SidebarMetrics.rowShape()
        )
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SidebarHoverCardMetrics.space)) } action: { frame in
            place.frame = frame
            if isHovering { hoverCard?.rowMoved(session.id, to: frame) }
        }
        // The Codex app's row: its hover card opens after a rest, or at once at the row's end, where
        // its buttons are.
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard let hoverCard else { return }
            switch phase {
            case let .active(location):
                hoverCard.rowHovered(hoverContent, frame: place.frame,
                                     atEnd: location.x >= place.frame.width - SidebarHoverCardMetrics.immediateWidth)
            case .ended:
                hoverCard.rowLeft(session.id)
            }
        }
        .onChange(of: hoverContent) { _, content in hoverCard?.rowChanged(content) }
        .onDisappear { hoverCard?.rowLeft(session.id) }
        .onHover { hovering in
            isHovering = hovering
            prefetch?.cancel()
            prefetch = nil
            guard hovering, !isSelected else { return }
            let id = session.id, read = prefetchConversation
            prefetch = Task {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                read(id)
            }
        }
        // A row in view counts as on screen for its pull request; a row scrolled away does not.
        .onAppear { pullRequests?.showRow(TaskPullRequestTarget(session: session)) }
        .onChange(of: TaskPullRequestTarget(session: session)) { _, target in pullRequests?.showRow(target) }
        .onDisappear { pullRequests?.hideRow(session.id) }
    }

    private var worktreeDetail: String? {
        SidebarWorktreeProjection.detail(for: session)
    }
}

/// A row's frame in the window, which the row reads when the pointer comes onto it. A class, so the
/// list's scrolling updates it without drawing every row again.
private final class SidebarRowPlace {
    var frame: CGRect = .zero
}

private struct TaskRowActionButton: View {
    let systemName: String
    let label: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 21, height: 22)
                .contentShape(Rectangle())
                .background(
                    isHovering ? ParityTheme.hoverFill : .clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
        }
        .buttonStyle(.borderless)
        .parityPointer()
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
