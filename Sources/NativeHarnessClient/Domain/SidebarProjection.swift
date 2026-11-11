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
    /// The tasks nested under this one, from it or from the tasks it started, in the order the list
    /// shows them; each row's `familyPlace` says how far in it sits.
    var children: [SidebarRow] = []
    /// The nested tasks a collapsed family hides; a line under the family counts them.
    var hiddenChildren: [SessionRecord] = []
    /// Where the row sits in the family it is nested in; nil for a row at top level.
    var familyPlace: SidebarFamilyPlace?
    /// The project or Chats a row listed apart from them belongs to, in a list grouped by state;
    /// nil in a list grouped by project.
    var project: SidebarRowProject?

    /// Whether the row sits nested under the task it was started from.
    var isNestedChild: Bool { familyPlace != nil }

    /// The row with its family, listed apart from `project`.
    func listed(from project: SidebarRowProject) -> SidebarRow {
        var row = self
        row.project = project
        row.children = children.map { $0.listed(from: project) }
        return row
    }

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

/// Where a nested row sits in its family, which its guide draws: how many levels in, and which
/// levels' lines run on past it to a later row of the family.
struct SidebarFamilyPlace: Hashable, Sendable {
    /// 1 for a task started from the family's top task, one more for each task listed between,
    /// at most `SidebarProjection.deepestNesting`.
    var depth: Int
    /// The levels, from 1 to `depth`, whose line goes on below the row: to a later row at that level
    /// with no shallower row between, or, at level 1, to the line counting what a collapsed family
    /// hides.
    var continuingLevels: Set<Int> = []
    /// The task it is listed under: the nearest task it was started through that the list shows,
    /// which a move beside it in the sidebar's families puts a task under too (`TaskNesting`).
    var parentID: UUID?
}

/// Where a row listed by state belongs, which the line under its title names: a project, by the
/// folder its group is keyed by, or Chats.
enum SidebarRowProject: Hashable, Sendable {
    case project(URL)
    case chats
}

/// How the task list groups its rows, chosen in the menu beside its search field and kept across
/// launches: by project, the list as it always was, or by state, as the Claude app's Code sidebar
/// groups sessions ("Group by" › State).
enum SidebarGrouping: String, CaseIterable, Sendable {
    case project
    case state

    static let defaultsKey = "YardletSidebarGrouping"
}

/// One state of a list grouped by state, with the rows under it, after the Claude app's state
/// groups (4.4212, `KD`: Needs input, Working, Ready for review, Idle). A family sits under its most
/// urgent task, as the Claude app places a family by its most urgent session. Yardlet's third state
/// is an unread result, which it knows for every agent, where the Claude app's is an open pull request.
struct SidebarStateSection: Identifiable, Hashable, Sendable {
    let state: TaskAttentionState
    /// The rows the section shows, in order: none while collapsed, and the first few until "Show
    /// more" reveals the rest.
    let rows: [SidebarRow]
    /// Every row the section holds, shown or not.
    let allRows: [SidebarRow]
    var isCollapsed = false

    var id: TaskAttentionState { state }
    var disclosureKey: String { Self.disclosureKey(for: state) }

    /// Rows "Show more" would reveal.
    var hiddenRowCount: Int { isCollapsed ? 0 : allRows.count - rows.count }

    /// The sections in the Claude app's order, most urgent first.
    static let order: [TaskAttentionState] = [.waiting, .active, .unread, .idle]

    /// The key a section's collapsed state is remembered under, beside the projects' keys.
    static func disclosureKey(for state: TaskAttentionState) -> String {
        switch state {
        case .waiting: "state:waiting"
        case .active: "state:working"
        case .unread: "state:unread"
        case .idle: "state:idle"
        }
    }

    /// The Claude app's names for its state groups, an unread result's as its rows' mark names it.
    var title: String {
        switch state {
        case .waiting: L10n.string("Needs input")
        case .active: L10n.string("Working")
        case .unread: L10n.string("Unread")
        case .idle: L10n.string("Idle")
        }
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
        /// The states under Pinned in a list grouped by state, in place of Chats and the projects.
        var states: [SidebarStateSection] = []

        /// Rows in rendered order for keyboard navigation, nested tasks after their task: the rows
        /// a collapsed project, a collapsed family or "Show more" hides are not among them.
        var rows: [SidebarRow] {
            (pinned + (chats?.rows ?? []) + sections.flatMap(\.rows) + states.flatMap(\.rows))
                .flatMap(\.rowsWithChildren)
        }

        /// A plain list in place of the sections, as the activity view lists its rows; only
        /// keyboard navigation reads it.
        static func list(_ rows: [SidebarRow]) -> Layout { Layout(pinned: rows) }

        /// The tasks under Pinned: pinned tasks and the tasks of pinned split views.
        var pinnedSessionIDs: Set<UUID> {
            Set(pinned.flatMap(\.rowsWithChildren).flatMap(\.sessions).map(\.id))
        }

        /// The task each nested task is drawn under, in every list, rows past "Show more" included:
        /// the nearest task shown a level out above it (`SidebarFamilyPlace.depth`), which for a task
        /// started further down than `deepestNesting` is the task its own parent sits under. A task
        /// at top level has none; the phone nests by this alone (docs/REMOTE_PROTOCOL.md §4.1).
        var nestingParents: [UUID: UUID] {
            var parents: [UUID: UUID] = [:]
            for row in pinned + (chats?.allRows ?? []) + sections.flatMap(\.allRows) + states.flatMap(\.allRows) {
                guard case let .session(top) = row.content else { continue }
                // The latest task shown at each level so far, the family's top at level 0.
                var latest = [top.id]
                for child in row.children {
                    guard case let .session(task) = child.content, let depth = child.familyPlace?.depth,
                          depth >= 1, depth <= latest.count else { continue }
                    parents[task.id] = latest[depth - 1]
                    latest = Array(latest.prefix(depth)) + [task.id]
                }
            }
            return parents
        }
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
    ///   - archivedParents: the task each archived task was started from
    ///     (`SessionStore.archivedParentIDs`), which `nest` follows past an archived parent.
    ///   - state: each task's state, given to group the rows by state: Chats and the projects then
    ///     list their rows, families as they nest there, under the states (`SidebarStateSection`).
    static func layout(
        visibleGroups: [WorkspaceGroup],
        allGroups: [WorkspaceGroup],
        chats visibleChats: [SessionRecord] = [],
        allChats: [SessionRecord]? = nil,
        splits: [SplitGroup],
        isFiltering: Bool,
        disclosure: SidebarDisclosure = SidebarDisclosure(),
        selection: WindowItem? = nil,
        waiting: Set<UUID> = [],
        archivedParents: [UUID: UUID] = [:],
        state: ((SessionRecord) -> TaskAttentionState)? = nil
    ) -> Layout {
        var keptInFamilies = waiting
        if case let .session(id)? = selection { keptInFamilies.insert(id) }
        func nested(_ rows: [SidebarRow]) -> [SidebarRow] {
            nest(rows, collapsedKeys: isFiltering ? [] : disclosure.collapsedKeys, keepingShown: keptInFamilies,
                 archivedParents: archivedParents)
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
        let chatList = nested(chatRows.filter { !$0.isPinned } + chatSplitRows)
        // Grouped by state, the rows each list would show, with the list they belong to, sorted once in their states.
        var listedRows = state == nil ? [] : chatList.map { $0.listed(from: .chats) }
        let allChatRows = state == nil ? sorted(chatList) : []
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
            let list = nested(sessionRows.filter { !$0.isPinned } + (splitRowsByGroup[key] ?? []))
            if state != nil {
                listedRows += list.map { $0.listed(from: .project(key)) }
                continue
            }
            let allRows = sorted(list)
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
        let states = state.map {
            stateSections(listedRows, state: $0, isFiltering: isFiltering, disclosure: disclosure, selection: selection)
        } ?? []
        return Layout(pinned: sorted(nested(pinned)), chats: chats, sections: sections, states: states)
    }

    /// `rows` under their states, each family under its most urgent task's, the most recently active
    /// first in each; a state with no row is left out. A state collapses and lists rows as a project
    /// does, and a search lists every match.
    private static func stateSections(
        _ rows: [SidebarRow], state: (SessionRecord) -> TaskAttentionState, isFiltering: Bool,
        disclosure: SidebarDisclosure, selection: WindowItem?
    ) -> [SidebarStateSection] {
        let order = SidebarStateSection.order
        var rowsByState: [TaskAttentionState: [SidebarRow]] = [:]
        for row in rows {
            var urgent = order.count - 1
            func note(_ session: SessionRecord) { urgent = min(urgent, order.firstIndex(of: state(session)) ?? urgent) }
            row.sessions.forEach(note)
            row.children.forEach { $0.sessions.forEach(note) }
            row.hiddenChildren.forEach(note)
            rowsByState[order[urgent], default: []].append(row)
        }
        return order.compactMap { state in
            guard let listed = rowsByState[state] else { return nil }
            let allRows = sorted(listed)
            let key = SidebarStateSection.disclosureKey(for: state)
            let isCollapsed = !isFiltering && disclosure.collapsedKeys.contains(key)
            let shown = isCollapsed ? [] : isFiltering ? allRows
                : visibleRows(allRows, limit: disclosure.limit(for: key), selection: selection)
            return SidebarStateSection(state: state, rows: shown, allRows: allRows, isCollapsed: isCollapsed)
        }
    }

    /// The key a family's collapsed state is remembered under, beside the projects' keys: the task
    /// at its top.
    static func familyKey(for sessionID: UUID) -> String { "family:\(sessionID.uuidString)" }

    /// How many levels in a nested task can sit. A task started further down sits at this level,
    /// beside the task it was started from, so a title keeps room at the sidebar's narrowest.
    static let deepestNesting = 2

    /// One list's rows with each task nested under the task it was started from
    /// (`SessionRecord.parentTaskID`), as the Claude app nests sessions under their top task, and
    /// each a level further in than the task it was started from, up to `deepestNesting`: depth
    /// first along who started whom, the most recently active first; the family sits where its most
    /// recently active member would. A task nests only under a task row of the same list. When its
    /// parent is archived, it nests under the nearest task it was started through that the list
    /// shows (`archivedParents`); a task whose parent is gone, pinned apart, in a split view or in
    /// another project stays at top level, and so does a split view. A collapsed family
    /// (`familyKey`) hides its nested tasks except those in `keepingShown` (waiting on the person,
    /// or shown in the window), each then a level in from the nearest task shown above it, and the
    /// family row counts the rest.
    static func nest(_ rows: [SidebarRow], collapsedKeys: Set<String> = [],
                     keepingShown: Set<UUID> = [], archivedParents: [UUID: UUID] = [:]) -> [SidebarRow] {
        var sessionsByID: [UUID: SessionRecord] = [:]
        for row in rows {
            if case let .session(session) = row.content { sessionsByID[session.id] = session }
        }
        // The nearest task each task was started through that this list shows, past archived ones.
        var listedParents: [UUID: UUID] = [:]
        for id in sessionsByID.keys {
            var seen: Set<UUID> = [id]
            var parent = sessionsByID[id]?.parentTaskID
            while let candidate = parent, seen.insert(candidate).inserted {
                if sessionsByID[candidate] != nil { listedParents[id] = candidate; break }
                parent = archivedParents[candidate]
            }
        }
        guard !listedParents.isEmpty else { return rows }
        func top(of id: UUID) -> UUID {
            var current = id
            var seen: Set<UUID> = [id]
            while let parent = listedParents[current], seen.insert(parent).inserted { current = parent }
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
            if let parent = listedParents[id] { childrenByParent[parent, default: []].append(session) }
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
            let shown = family.filter { !collapsed || keepingShown.contains($0.id) }
            parent.hiddenChildren = collapsed ? family.filter { !keepingShown.contains($0.id) } : []
            parent.children = zip(shown, places(of: shown, under: session.id, parents: listedParents,
                                                endsInSummary: !parent.hiddenChildren.isEmpty))
                .map { SidebarRow(content: .session($0), familyPlace: $1) }
            return parent
        }
    }

    /// Each shown nested task's place, in the order shown: a level in from the nearest task it was
    /// started through that is shown above it (the family's top task at level 0), and the levels whose
    /// line runs on past it. `endsInSummary` adds the line counting hidden tasks at level 1 below.
    private static func places(of shown: [SessionRecord], under top: UUID, parents: [UUID: UUID],
                               endsInSummary: Bool) -> [SidebarFamilyPlace] {
        var depthByID: [UUID: Int] = [top: 0]
        let depths = shown.map { task -> Int in
            var ancestor = parents[task.id]
            while let id = ancestor, depthByID[id] == nil { ancestor = parents[id] }
            let depth = min((ancestor.flatMap { depthByID[$0] } ?? 0) + 1, deepestNesting)
            depthByID[task.id] = depth
            return depth
        }
        // From the bottom up: a level's line runs on past a row while a later row sits at that level
        // with nothing shallower between.
        var open: Set<Int> = endsInSummary ? [1] : []
        var places = zip(shown, depths).map { SidebarFamilyPlace(depth: $1, parentID: parents[$0.id]) }
        for index in depths.indices.reversed() {
            let depth = depths[index]
            places[index].continuingLevels = open.filter { $0 <= depth }
            open = open.filter { $0 < depth }.union([depth])
        }
        return places
    }

    /// The key a project's collapsed state is remembered under: the project, or the folder of a
    /// group that belongs to none.
    static func disclosureKey(for group: WorkspaceGroup) -> String {
        if let project = group.project { return "project:\(project.id.uuidString)" }
        return "folder:\(ProjectSidebarPresentation.folderKey(for: group.workspaceURL))"
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

    /// The key the project or state whose rows hold what the window shows for `item` is collapsed
    /// under, shown or not. A pinned row belongs to neither.
    static func disclosureKey(holding item: WindowItem, in layout: Layout) -> String? {
        if let section = section(holding: item, in: layout) { return section.disclosureKey }
        guard !layout.pinned.contains(where: { $0.familyShows(item) }) else { return nil }
        return layout.states.first { section in section.allRows.contains { $0.familyShows(item) } }?.disclosureKey
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

    /// The title a row shows under Chats. A chat's fallback title leaves out its generated folder
    /// name (`new-chat`) wherever it shows (`SessionTitleProjection.storedTitle`); here a task
    /// moved to Chats from another folder also loses that folder's name from its fallback title.
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

    /// The most recently active first. Each row's date is worked out once, not at every comparison: a
    /// family's is its newest member's.
    private static func sorted(_ rows: [SidebarRow]) -> [SidebarRow] {
        rows.map { (row: $0, date: $0.sortDate) }.sorted { lhs, rhs in
            if lhs.date == rhs.date { return lhs.row.id.sortKey < rhs.row.id.sortKey }
            return lhs.date > rhs.date
        }.map(\.row)
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
/// hold began past another task's time, and only then are those who list them told (`revision`):
/// crossing the top alone draws neither the window nor its conversation again, nor does it after the
/// person worked in a task that stays where it is.
///
/// In a list grouped by state the shown row's tasks also keep the state they are listed under, so a
/// message sent in a task far down Idle does not take it up to Working out of view.
@MainActor @Observable
final class SidebarOrderHold {
    /// Changes whenever the hold changes how the tasks are listed, so the listing is read again.
    private(set) var revision = 0
    @ObservationIgnored private var listedAt: [UUID: Date] = [:]
    @ObservationIgnored private var listedStates: [UUID: TaskAttentionState] = [:]

    init() {}

    /// Holds `held` at the times they have now, in place of what was held; none lets the hold go.
    /// `sessions` are the tasks as they are listed now. `state` gives each task's state in a list
    /// grouped by state, where the held tasks keep theirs too.
    func hold(_ held: [SessionRecord], listing sessions: [SessionRecord],
              state: ((SessionRecord) -> TaskAttentionState)? = nil) {
        let listedAt = Dictionary(held.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { first, _ in first })
        let states = state.map { state in
            Dictionary(held.map { ($0.id, state($0)) }, uniquingKeysWith: { first, _ in first })
        } ?? [:]
        guard listedAt != self.listedAt || states != listedStates else { return }
        let before = Self.listing(sessions, at: self.listedAt)
        // A task let go from a state it has since left moves to its own.
        let leavesState = !listedStates.isEmpty && sessions.contains { session in
            listedStates[session.id].map { $0 != state?(session) } ?? false
        }
        self.listedAt = listedAt
        listedStates = states
        if leavesState || Self.reorders(before, Self.listing(sessions, at: listedAt)) { revision += 1 }
    }

    /// Whether the sidebar can order `after` otherwise than `before`, the same tasks at other times:
    /// a task whose time changed passed or met another task's on the way. Rows, families, projects and
    /// chats all order by their newest time, so any other change leaves every order as it was, and the
    /// window, which lists them, is not drawn again for it: the shown task held at the top of the list
    /// and let go there has only a newer time.
    private static func reorders(_ before: [SessionRecord], _ after: [SessionRecord]) -> Bool {
        let moved = zip(before, after).compactMap { old, new -> (id: UUID, times: ClosedRange<Date>)? in
            old.updatedAt == new.updatedAt ? nil
                : (new.id, min(old.updatedAt, new.updatedAt)...max(old.updatedAt, new.updatedAt))
        }
        guard !moved.isEmpty else { return false }
        return zip(before, after).contains { old, new in
            moved.contains { $0.id != new.id && ($0.times.contains(old.updatedAt) || $0.times.contains(new.updatedAt)) }
        }
    }

    /// The states the held tasks are listed under in a list grouped by state.
    var heldStates: [UUID: TaskAttentionState] {
        _ = revision
        return listedStates
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
