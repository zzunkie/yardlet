import Foundation

/// Moving a task among the sidebar's families, as Finder and Mail move a folder in their sidebars:
/// dropped on a task's row it goes under that task, dropped between rows it goes to the level of
/// the row it is dropped beside, and a row's menu does the same ("Move up one level", "Move under
/// task", "Detach to top level"). Only the task's link in Yardlet's index changes
/// (`SessionStore.nest`); the tasks under it go with it.
///
/// A task moves only within the list that shows it (a project, Chats, Pinned): the sidebar nests a
/// task only under a task of its own list, and going to another project is its own command
/// (`TaskProjectMove`), which changes the roots its harness gets. The lists are the rows as shown,
/// and a task is under the task the sidebar draws it under, so the moves offered are the ones the
/// person can see: an agent may start a task further down than `SidebarProjection.deepestNesting`,
/// which the sidebar draws at that level, and one level up from there is one level up from where it
/// is drawn. Nothing goes under a task at that level. A move that would leave the tasks under the
/// moved one deeper places them flat under the task they are drawn under (`flattening`).
enum TaskNesting {
    /// Where on a task's row a dragged task would land.
    enum Drop: Hashable, Sendable {
        /// On the row: under its task.
        case under
        /// On the row's top or bottom edge, between it and the row beside it: at the row's level.
        case above, below
    }

    /// A task "Move under task" offers, with the title its row shows.
    struct Parent: Identifiable, Hashable, Sendable {
        let id: UUID
        let title: String
    }

    /// What a task's menu offers.
    struct Options: Equatable, Sendable {
        /// The task "Move up one level" lists it under: the one the task it is drawn under is drawn
        /// under. Nil when that task is at the top level, where "Detach to top level" is the same move.
        var levelUp: UUID?
        /// Whether it is listed under another task, which "Detach to top level" offers to leave.
        var isNested = false
        /// The tasks of its list it can move under, in the order shown: not itself, not a task under
        /// it, not the task it is already under, and not a task at the deepest level.
        var parents: [Parent] = []

        static let none = Options()
    }

    /// The part of a row the pointer is over, `y` down from the row's top: its top and bottom
    /// quarters are the gaps beside it, the middle is the row itself.
    static func drop(at y: Double, height: Double) -> Drop {
        if y < height / 4 { return .above }
        if y > height * 3 / 4 { return .below }
        return .under
    }

    /// The task `task` would be listed under once dropped on `target`'s row: `.some(nil)` for the
    /// top level, nil when the drop changes nothing or cannot be made (the two are not in one list,
    /// or it would go under itself or a task under it).
    static func parent(of task: UUID, dropped drop: Drop, on target: UUID,
                       in layout: SidebarProjection.Layout) -> UUID?? {
        guard task != target, let list = list(showing: target, in: layout), list.shows(task) else { return nil }
        if drop == .under, !list.takesTasks(target) { return nil }
        let parent = drop == .under ? target : list.drawnParents[target]
        guard parent != list.drawnParents[task], parent.map({ !list.isDrawn($0, under: task) }) ?? true
        else { return nil }
        return .some(parent)
    }

    static func options(for task: UUID, in layout: SidebarProjection.Layout) -> Options {
        guard let list = list(showing: task, in: layout) else { return .none }
        let current = list.drawnParents[task]
        return Options(
            levelUp: current.flatMap { list.drawnParents[$0] },
            isNested: current != nil,
            parents: list.rows.compactMap { row in
                guard case let .session(session) = row.content, session.id != current, list.takesTasks(session.id),
                      !list.isDrawn(session.id, under: task) else { return nil }
                return Parent(id: session.id, title: list.title(row))
            })
    }

    /// The tasks under `task` that moving it under `parent` (nil: the top level) would leave deeper
    /// than `SidebarProjection.deepestNesting` in the list that shows it, each with the task the
    /// sidebar would draw it under: the one it is under at the level above the deepest. `layout` lists
    /// every row, families open (`AppModel.sidebarLists`). Empty when nothing goes deeper or no list
    /// shows the task; nil when the task itself would sit deeper, under a task at the deepest level.
    static func flattening(moving task: UUID, under parent: UUID?,
                           in layout: SidebarProjection.Layout) -> [UUID: UUID]? {
        guard let list = list(showing: task, in: layout) else { return [:] }
        var parents = list.listedParents
        parents[task] = parent.flatMap { list.shows($0) ? $0 : nil }
        /// The task and the tasks it is under, the top one last; nil for a loop.
        func chain(of id: UUID) -> [UUID]? {
            var chain = [id]
            while let next = parents[chain[chain.count - 1]] {
                guard !chain.contains(next) else { return nil }
                chain.append(next)
            }
            return chain
        }
        guard let moved = chain(of: task) else { return nil }
        guard moved.count - 1 <= SidebarProjection.deepestNesting else { return nil }
        var flat: [UUID: UUID] = [:]
        for case let .session(session) in list.rows.map(\.content) where session.id != task {
            guard let chain = chain(of: session.id), chain.contains(task),
                  chain.count - 1 > SidebarProjection.deepestNesting else { continue }
            flat[session.id] = chain[chain.count - SidebarProjection.deepestNesting]
        }
        return flat
    }

    /// One list's task rows as shown, a family's nested rows after its task.
    private struct List {
        let rows: [SidebarRow]
        let title: (SidebarRow) -> String
        /// The task each nested row is listed under in Yardlet's index, the nearest the list shows.
        let listedParents: [UUID: UUID]
        /// The task each nested row is drawn under: the one a level out above it, which for a task
        /// started further down than the sidebar draws is not the task it is listed under.
        let drawnParents: [UUID: UUID]
        /// How many levels in each row is drawn.
        let depths: [UUID: Int]

        init(_ rows: [SidebarRow], title: @escaping (SidebarRow) -> String) {
            self.title = title
            var listed: [UUID: UUID] = [:], drawn: [UUID: UUID] = [:], depths: [UUID: Int] = [:]
            var shown: [SidebarRow] = []
            for row in rows {
                shown.append(row)
                guard case let .session(top) = row.content else { continue }
                // The latest task drawn at each level so far, the family's top at level 0.
                var latest = [top.id]
                for child in row.children {
                    shown.append(child)
                    guard case let .session(task) = child.content, let place = child.familyPlace else { continue }
                    listed[task.id] = place.parentID
                    depths[task.id] = place.depth
                    guard place.depth >= 1, place.depth <= latest.count else { continue }
                    drawn[task.id] = latest[place.depth - 1]
                    latest = Array(latest.prefix(place.depth)) + [task.id]
                }
            }
            self.rows = shown.filter { if case .session = $0.content { true } else { false } }
            listedParents = listed
            drawnParents = drawn
            self.depths = depths
        }

        func shows(_ task: UUID) -> Bool { rows.contains { $0.id == .session(task) } }

        /// Whether a task can go under `task`: not when it is drawn at the deepest level.
        func takesTasks(_ task: UUID) -> Bool { (depths[task] ?? 0) < SidebarProjection.deepestNesting }

        /// Whether `task` is `ancestor` itself or drawn somewhere under it.
        func isDrawn(_ task: UUID, under ancestor: UUID) -> Bool {
            var current: UUID? = task
            var seen: Set<UUID> = []
            while let id = current, seen.insert(id).inserted {
                if id == ancestor { return true }
                current = drawnParents[id]
            }
            return false
        }
    }

    /// The list that shows `task`, with each row's title as the sidebar shows it there.
    private static func list(showing task: UUID, in layout: SidebarProjection.Layout) -> List? {
        let lists = [List(layout.pinned, title: \.title)]
            + (layout.chats.map { [List($0.rows, title: SidebarProjection.chatRowTitle)] } ?? [])
            + layout.sections.map { section in
                List(section.rows) { SidebarProjection.rowTitle(for: $0, under: section.group) }
            }
        return lists.first { $0.shows(task) }
    }
}
