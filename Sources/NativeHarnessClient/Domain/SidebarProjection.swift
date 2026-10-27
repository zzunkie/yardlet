import Foundation
import Observation

/// One sidebar row: a task, or a split view holding several tasks. Both kinds sit in the same
/// lists and take the same row actions. A task row carries the tasks started from it, nested under
/// it (`SidebarProjection.nest`).
struct SidebarRow: Identifiable, Hashable, Sendable {
    enum Content: Hashable, Sendable {
        case session(SessionRecord)
        case split(SplitGroup, members: [SessionRecord])
    }

    let content: Content
    /// The tasks started from this one that the list shows nested under it, one level in, in order.
    var children: [SidebarRow] = []
    /// The nested tasks a collapsed family hides; a line under the family counts them.
    var hiddenChildren: [SessionRecord] = []
    /// Whether the row sits nested under the task it was started from.
    var isNestedChild = false

    var id: WindowItem {
        switch content {
        case let .session(session): .session(session.id)
        case let .split(split, _): .split(split.id)
        }
    }

    var isPinned: Bool {
        switch content {
        case let .session(session): session.isPinned
        case let .split(split, _): split.isPinned
        }
    }

    /// A split row sorts by its most recently active task, and a family by its most recently
    /// active member, as the Claude app places a family where its newest session would be.
    var sortDate: Date {
        let own: Date
        switch content {
        case let .session(session): own = session.updatedAt
        case let .split(_, members): own = members.map(\.updatedAt).max() ?? .distantPast
        }
        return ([own] + children.map(\.sortDate) + hiddenChildren.map(\.updatedAt)).max() ?? own
    }

    /// Whether tasks are nested under this one, shown or hidden.
    var hasFamily: Bool { !children.isEmpty || !hiddenChildren.isEmpty }

    /// The row followed by the rows nested under it, in the order the list shows them.
    var rowsWithChildren: [SidebarRow] { [self] + children }

    /// The row's tasks and every task nested under it, shown or hidden: what a collapsed project
    /// summarizes.
    var familySessions: [SessionRecord] { sessions + children.flatMap(\.sessions) + hiddenChildren }

    var sessions: [SessionRecord] {
        switch content {
        case let .session(session): [session]
        case let .split(_, members): members
        }
    }

    var title: String {
        switch content {
        case let .session(session): session.title
        case let .split(split, members):
            split.customName ?? members.map(\.title).joined(separator: " + ")
        }
    }

    /// Whether this row is what the window shows for `item`: the row itself, or the split view
    /// holding the task.
    func shows(_ item: WindowItem) -> Bool {
        if id == item { return true }
        guard case let .session(sessionID) = item else { return false }
        return sessions.contains { $0.id == sessionID }
    }

    /// Whether this row or a task nested under it, shown or hidden, is what the window shows.
    func familyShows(_ item: WindowItem) -> Bool {
        if shows(item) || children.contains(where: { $0.shows(item) }) { return true }
        guard case let .session(sessionID) = item else { return false }
        return hiddenChildren.contains { $0.id == sessionID }
    }
}

/// One project in the sidebar with the task rows nested under it.
struct SidebarSection: Identifiable, Hashable, Sendable {
    let group: WorkspaceGroup
    /// The rows the project shows, in order: none while collapsed, and the first few until
    /// "Show more" reveals the rest.
    let rows: [SidebarRow]
    /// Every row the project holds, shown or not.
    var allRows: [SidebarRow]
    var isCollapsed = false
    /// The key the project's collapsed state is remembered under.
    var disclosureKey: String

    init(group: WorkspaceGroup, rows: [SidebarRow], allRows: [SidebarRow]? = nil, isCollapsed: Bool = false,
         disclosureKey: String? = nil) {
        self.group = group
        self.rows = rows
        self.allRows = allRows ?? rows
        self.isCollapsed = isCollapsed
        self.disclosureKey = disclosureKey ?? SidebarProjection.disclosureKey(for: group)
    }

    var id: URL { group.id }

    /// Rows "Show more" would reveal.
    var hiddenRowCount: Int { isCollapsed ? 0 : allRows.count - rows.count }

    /// An expanded project with no task at all shows the muted "No chats" line. One whose tasks
    /// are all pinned, or sit in a split view under another project, lists nothing instead.
    var showsEmptyState: Bool { !isCollapsed && allRows.isEmpty && group.sessions.isEmpty }
}

/// The Chats section, above the projects as in the Codex app: tasks in a chat's folder that no
/// project holds (`ProjectProjection.isChat`). It lists five rows and each "Show more" ten more,
/// as a project does; it does not collapse.
struct SidebarChats: Hashable, Sendable {
    /// The rows the section shows, in order: the first few until "Show more" reveals the rest.
    let rows: [SidebarRow]
    /// Every row the section holds, shown or not.
    let allRows: [SidebarRow]

    /// The key "Show more" is remembered under, beside the projects' keys.
    static let disclosureKey = "chats"

    /// Rows "Show more" would reveal.
    var hiddenRowCount: Int { allRows.count - rows.count }
}

/// What the person opened and closed in the project list, kept the way the Codex app keeps it:
/// a project stays expanded until collapsed, which is remembered; an expanded project lists five
/// rows, and each "Show more" reveals ten more until the project is collapsed again.
struct SidebarDisclosure: Equatable, Sendable {
    /// Projects the person collapsed, by `SidebarProjection.disclosureKey(for:)`.
    var collapsedKeys: Set<String> = []
    /// How many times "Show more" was pressed in each project.
    var revealedPages: [String: Int] = [:]
    /// Rows an expanded project lists before "Show more"; `nil` lists them all.
    var rowLimit: Int?

    /// The Codex app lists five chats under a project (`maxItems` 5) and reveals ten more per
    /// "Show more".
    static let codexRowLimit = 5
    static let pageSize = 10

    /// How many rows the project with `key` lists, or `nil` for all of them.
    func limit(for key: String) -> Int? {
        rowLimit.map { $0 + Self.pageSize * (revealedPages[key] ?? 0) }
    }
}

/// Places split views among task rows. A split appears once, in the project of the task it
/// started from, and its tasks do not also appear as their own rows.
enum SidebarProjection {
    struct Layout: Equatable, Sendable {
        var pinned: [SidebarRow] = []
        /// Nil when there is no chat to list (or, in a search, none that matches).
        var chats: SidebarChats?
        var sections: [SidebarSection] = []

        /// Rows in rendered order for keyboard navigation, nested tasks after their task: the rows
        /// a collapsed project, a collapsed family or "Show more" hides are not among them.
        var rows: [SidebarRow] {
            (pinned + (chats?.rows ?? []) + sections.flatMap(\.rows)).flatMap(\.rowsWithChildren)
        }

        /// A plain list in place of the sections, as the activity view lists its rows; only
        /// keyboard navigation reads it.
        static func list(_ rows: [SidebarRow]) -> Layout { Layout(pinned: rows) }
    }

    /// - Parameters:
    ///   - visibleGroups: the groups after search filtering, or every group when not searching.
    ///   - allGroups: every group, in sidebar order.
    ///   - isFiltering: whether a search narrows the rows; a split then shows when any of its
    ///     tasks matches. A search shows every match, collapsed project or not.
    ///   - disclosure: which projects are collapsed and how many rows each lists.
    ///   - selection: what the window shows; its row stays listed past the row limit, and in a
    ///     collapsed family.
    ///   - chats: the chats after search filtering, or every chat when not searching.
    ///   - allChats: every chat; `chats` when left out.
    ///   - waiting: tasks waiting on the person, which a collapsed family keeps showing.
    static func layout(
        visibleGroups: [WorkspaceGroup],
        allGroups: [WorkspaceGroup],
        chats visibleChats: [SessionRecord] = [],
        allChats: [SessionRecord]? = nil,
        splits: [SplitGroup],
        isFiltering: Bool,
        disclosure: SidebarDisclosure = SidebarDisclosure(),
        selection: WindowItem? = nil,
        waiting: Set<UUID> = []
    ) -> Layout {
        var keptInFamilies = waiting
        if case let .session(id)? = selection { keptInFamilies.insert(id) }
        func nested(_ rows: [SidebarRow]) -> [SidebarRow] {
            nest(rows, collapsedKeys: isFiltering ? [] : disclosure.collapsedKeys, keepingShown: keptInFamilies)
        }
        let allChats = allChats ?? visibleChats
        let sessionsByID = Dictionary(
            (allGroups.flatMap(\.sessions) + allChats).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Groups follow projects and worktree origins, not only a task's own folder, so a split
        // row goes to the group that actually lists its first task.
        let groupKeyBySessionID = Dictionary(
            allGroups.flatMap { group in group.sessions.map { ($0.id, group.workspaceURL.standardizedFileURL) } },
            uniquingKeysWith: { first, _ in first }
        )
        let chatIDs = Set(allChats.map(\.id))
        let visibleIDs = Set((visibleGroups.flatMap(\.sessions) + visibleChats).map(\.id))
        var grouped = Set<UUID>()
        var splitRowsByGroup: [URL: [SidebarRow]] = [:]
        var chatSplitRows: [SidebarRow] = []
        var pinned: [SidebarRow] = []

        for split in splits {
            let members = split.sessionIDs.compactMap { sessionsByID[$0] }
            guard !members.isEmpty else { continue }
            grouped.formUnion(members.map(\.id))
            guard !isFiltering || members.contains(where: { visibleIDs.contains($0.id) }) else { continue }
            let row = SidebarRow(content: .split(split, members: members))
            if split.isPinned {
                pinned.append(row)
            } else {
                let anchor = split.anchorSessionID.flatMap { sessionsByID[$0] } ?? members[0]
                if chatIDs.contains(anchor.id) {
                    chatSplitRows.append(row)
                } else {
                    let key = groupKeyBySessionID[anchor.id] ?? anchor.workspaceURL.standardizedFileURL
                    splitRowsByGroup[key, default: []].append(row)
                }
            }
        }

        let chatRows = visibleChats.filter { !grouped.contains($0.id) }.map { SidebarRow(content: .session($0)) }
        pinned += chatRows.filter(\.isPinned)
        let allChatRows = sorted(nested(chatRows.filter { !$0.isPinned } + chatSplitRows))
        let chats = allChatRows.isEmpty ? nil : SidebarChats(
            rows: isFiltering ? allChatRows : visibleRows(
                allChatRows, limit: disclosure.limit(for: SidebarChats.disclosureKey), selection: selection),
            allRows: allChatRows)

        let visibleByURL = Dictionary(
            visibleGroups.map { ($0.workspaceURL.standardizedFileURL, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var sections: [SidebarSection] = []
        for group in allGroups {
            let key = group.workspaceURL.standardizedFileURL
            let shownGroup = visibleByURL[key]
            let sessionRows = (shownGroup?.sessions ?? [])
                .filter { !grouped.contains($0.id) }
                .map { SidebarRow(content: .session($0)) }
            pinned += sessionRows.filter(\.isPinned)
            let allRows = sorted(nested(sessionRows.filter { !$0.isPinned } + (splitRowsByGroup[key] ?? [])))
            // A search lists a project only with rows to show: one whose matches all sit in a split
            // view under another project, or among the pinned rows, would be an empty heading.
            guard isFiltering ? !allRows.isEmpty : (shownGroup != nil || !allRows.isEmpty) else { continue }
            let disclosureKey = disclosureKey(for: group)
            let isCollapsed = !isFiltering && disclosure.collapsedKeys.contains(disclosureKey)
            let rows: [SidebarRow]
            if isCollapsed {
                rows = []
            } else if isFiltering {
                rows = allRows
            } else {
                rows = visibleRows(allRows, limit: disclosure.limit(for: disclosureKey), selection: selection)
            }
            sections.append(SidebarSection(
                group: shownGroup ?? group, rows: rows, allRows: allRows,
                isCollapsed: isCollapsed, disclosureKey: disclosureKey
            ))
        }
        return Layout(pinned: sorted(nested(pinned)), chats: chats, sections: sections)
    }

    /// The key a family's collapsed state is remembered under, beside the projects' keys: the task
    /// at its top.
    static func familyKey(for sessionID: UUID) -> String { "family:\(sessionID.uuidString)" }

    /// One list's rows with each task nested under the task it was started from
    /// (`SessionRecord.parentTaskID`), as the Claude app nests sessions: every descendant one level
    /// under the family's top task, depth first along who started whom, the most recently active
    /// first; the family sits where its most recently active member would. A task nests only under
    /// a task row of the same list, so a task whose parent is archived, gone, pinned apart, in a
    /// split view or in another project stays at top level, and so does a split view. A collapsed
    /// family (`familyKey`) hides its nested tasks except those in `keepingShown` (waiting on the
    /// person, or shown in the window), and the family row counts the rest.
    static func nest(_ rows: [SidebarRow], collapsedKeys: Set<String> = [],
                     keepingShown: Set<UUID> = []) -> [SidebarRow] {
        var sessionsByID: [UUID: SessionRecord] = [:]
        for row in rows {
            if case let .session(session) = row.content { sessionsByID[session.id] = session }
        }
        func listedParent(of id: UUID) -> UUID? {
            guard let parent = sessionsByID[id]?.parentTaskID, parent != id, sessionsByID[parent] != nil else { return nil }
            return parent
        }
        guard sessionsByID.keys.contains(where: { listedParent(of: $0) != nil }) else { return rows }
        func top(of id: UUID) -> UUID {
            var current = id
            var seen: Set<UUID> = [id]
            while let parent = listedParent(of: current), seen.insert(parent).inserted { current = parent }
            return current
        }
        // A task is at top level when it has no parent here, or when following its parents never
        // reaches a task that is (a loop, which the index refuses to record).
        func isTopLevel(_ id: UUID) -> Bool {
            let family = top(of: id)
            return family == id || top(of: family) != family
        }
        var childrenByParent: [UUID: [SessionRecord]] = [:]
        for (id, session) in sessionsByID where !isTopLevel(id) {
            if let parent = listedParent(of: id) { childrenByParent[parent, default: []].append(session) }
        }
        func newestFirst(_ lhs: SessionRecord, _ rhs: SessionRecord) -> Bool {
            if lhs.updatedAt == rhs.updatedAt { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.updatedAt > rhs.updatedAt
        }
        func descendants(of id: UUID, seen: inout Set<UUID>) -> [SessionRecord] {
            var result: [SessionRecord] = []
            for child in (childrenByParent[id] ?? []).sorted(by: newestFirst) where seen.insert(child.id).inserted {
                result.append(child)
                result += descendants(of: child.id, seen: &seen)
            }
            return result
        }
        return rows.compactMap { row -> SidebarRow? in
            guard case let .session(session) = row.content else { return row }
            guard isTopLevel(session.id) else { return nil }
            var seen: Set<UUID> = [session.id]
            let family = descendants(of: session.id, seen: &seen)
            guard !family.isEmpty else { return row }
            var parent = row
            let collapsed = collapsedKeys.contains(familyKey(for: session.id))
            parent.children = family.filter { !collapsed || keepingShown.contains($0.id) }
                .map { SidebarRow(content: .session($0), isNestedChild: true) }
            parent.hiddenChildren = collapsed ? family.filter { !keepingShown.contains($0.id) } : []
            return parent
        }
    }

    /// The key a project's collapsed state is remembered under: the project, or the folder of a
    /// group that belongs to none.
    static func disclosureKey(for group: WorkspaceGroup) -> String {
        if let project = group.project { return "project:\(project.id.uuidString)" }
        return "folder:\(ProjectSidebarPresentation.normalizedPath(for: group.workspaceURL))"
    }

    /// The first `limit` rows, as the Codex app lists a project: the selected row stays listed
    /// past the limit, and when only one row would be left behind "Show more" it is listed too.
    static func visibleRows(_ rows: [SidebarRow], limit: Int?, selection: WindowItem?) -> [SidebarRow] {
        guard let limit, rows.count > limit else { return rows }
        var shown = Array(rows.prefix(max(limit, 0)))
        if let selection, let selected = rows.dropFirst(shown.count).first(where: { $0.familyShows(selection) }) {
            shown.append(selected)
        }
        return rows.count - shown.count == 1 ? rows : shown
    }

    /// The project whose rows hold what the window shows for `item`, shown or not. A pinned row
    /// belongs to no project.
    static func section(holding item: WindowItem, in layout: Layout) -> SidebarSection? {
        guard !layout.pinned.contains(where: { $0.familyShows(item) }) else { return nil }
        return layout.sections.first { section in section.allRows.contains { $0.familyShows(item) } }
    }

    /// The title a task row shows under `group`. A Yardlet fallback title repeats the folder it
    /// was made from, which the project row above already names; provider and user titles show
    /// as they are.
    static func rowTitle(for session: SessionRecord, under group: WorkspaceGroup) -> String {
        SessionTitleProjection.titleUnderProject(
            session,
            projectNames: projectNames(for: group) + [session.workspaceURL.lastPathComponent]
        )
    }

    /// The title a row shows under Chats. A Yardlet fallback title repeats the chat's folder name
    /// (`new-chat`), which says nothing there.
    static func chatRowTitle(for row: SidebarRow) -> String {
        switch row.content {
        case let .session(session):
            SessionTitleProjection.titleUnderProject(session, projectNames: [session.workspaceURL.lastPathComponent])
        case .split:
            row.title
        }
    }

    /// A split view's title under `group`, from its tasks' titles there.
    static func rowTitle(for row: SidebarRow, under group: WorkspaceGroup) -> String {
        switch row.content {
        case let .session(session):
            rowTitle(for: session, under: group)
        case let .split(split, members):
            split.customName ?? members.map {
                SessionTitleProjection.titleUnderProject($0, projectNames: projectNames(for: group))
            }.joined(separator: " + ")
        }
    }

    /// The names a project row shows or stands for: its name and its folders' names.
    static func projectNames(for group: WorkspaceGroup) -> [String] {
        [group.displayName] + group.roots.map(\.lastPathComponent)
    }

    /// The next row for keyboard navigation, wrapping at either end.
    static func targetRow(in layout: Layout, selected: WindowItem, offset: Int) -> WindowItem? {
        let ids = layout.rows.map(\.id)
        guard !ids.isEmpty, offset != 0 else { return nil }
        let start = ids.firstIndex(of: selected) ?? (offset > 0 ? -1 : ids.count)
        let count = ids.count
        return ids[((start + offset) % count + count) % count]
    }

    /// The row before or after the selection for Previous and Next task. Unlike arrow keys in
    /// the list, these stop at either end, as the Codex app's do; with no listed row selected,
    /// Next goes to the first row and Previous to the last.
    static func adjacentRow(in layout: Layout, selected: WindowItem, offset: Int) -> WindowItem? {
        let ids = layout.rows.map(\.id)
        guard !ids.isEmpty, offset != 0 else { return nil }
        guard let index = ids.firstIndex(of: selected) else { return offset > 0 ? ids.first : ids.last }
        let target = index + offset
        return ids.indices.contains(target) ? ids[target] : nil
    }

    /// The sidebar row that shows `item`: a task inside a split selects the split's row.
    static func row(for item: WindowItem, in layout: Layout) -> WindowItem? {
        let rows = layout.rows
        if rows.contains(where: { $0.id == item }) { return item }
        guard case let .session(id) = item else { return nil }
        return rows.first { $0.sessions.contains { $0.id == id } }?.id
    }

    private static func sorted(_ rows: [SidebarRow]) -> [SidebarRow] {
        rows.sorted { lhs, rhs in
            if lhs.sortDate == rhs.sortDate { return lhs.id.sortKey < rhs.id.sortKey }
            return lhs.sortDate > rhs.sortDate
        }
    }
}

extension WindowItem {
    /// A stable text identity, used for scroll targets and deterministic ordering.
    var sortKey: String {
        switch self {
        case .home: "home"
        case let .session(id): "session-\(id.uuidString)"
        case let .split(id): "split-\(id.uuidString)"
        }
    }
}

/// The shown task keeps its place in the sidebar while the person works in it (2026-10-23 user
/// report: a message sent in a task far down the list moved it, and its project, to the top, out of
/// view of the person who had scrolled down to it). The list orders by activity, as the Codex app
/// (26.1016, "Last updated" by default) and the Claude app (3.1623.3, recency) order theirs; neither
/// holds a row or follows it, so a task that moves up leaves their view as well. While the list is
/// scrolled away from its top, the shown row's tasks are listed at the time they had when the hold
/// began, everywhere the sidebar orders by time (rows, families, projects, chats). The hold moves to
/// whatever the person shows next and ends with the list at its top, where the row's new place is in
/// view. Other tasks order by activity as before.
///
/// The list crosses its top over and over as the person scrolls near it, starting and ending the hold
/// each time. That changes how the tasks are listed only when a held task has been active since the
/// hold began, and only then are those who list them told (`revision`): crossing the top alone draws
/// neither the window nor its conversation again.
@MainActor @Observable
final class SidebarOrderHold {
    /// Changes whenever the hold changes how the tasks are listed, so the listing is read again.
    private(set) var revision = 0
    @ObservationIgnored private var listedAt: [UUID: Date] = [:]

    init() {}

    /// Holds `held` at the times they have now, in place of what was held; none lets the hold go.
    /// `sessions` are the tasks as they are listed now.
    func hold(_ held: [SessionRecord], listing sessions: [SessionRecord]) {
        let listedAt = Dictionary(held.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { first, _ in first })
        guard listedAt != self.listedAt else { return }
        let before = Self.listing(sessions, at: self.listedAt)
        self.listedAt = listedAt
        if Self.listing(sessions, at: listedAt) != before { revision += 1 }
    }

    /// `sessions` as the sidebar orders them: a held task that has been active since the hold began
    /// at the time it had then. The array is returned as it is when no held task moved.
    func listing(_ sessions: [SessionRecord]) -> [SessionRecord] {
        _ = revision
        return Self.listing(sessions, at: listedAt)
    }

    private static func listing(_ sessions: [SessionRecord], at listedAt: [UUID: Date]) -> [SessionRecord] {
        guard !listedAt.isEmpty, sessions.contains(where: { session in
            listedAt[session.id].map { session.updatedAt > $0 } ?? false
        }) else { return sessions }
        return sessions.map { session in
            guard let held = listedAt[session.id], session.updatedAt > held else { return session }
            var listed = session
            listed.updatedAt = held
            return listed
        }
    }
}
