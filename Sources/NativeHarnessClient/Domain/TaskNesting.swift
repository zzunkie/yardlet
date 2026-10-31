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
/// so the moves offered are the ones the person can see.
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
        /// The task "Move up one level" lists it under: the one its parent is listed under. Nil when
        /// its parent is at the top level, where "Detach to top level" is the same move.
        var levelUp: UUID?
        /// Whether it is listed under another task, which "Detach to top level" offers to leave.
        var isNested = false
        /// The tasks of its list it can move under, in the order shown: not itself, not a task under
        /// it, and not the task it is already under.
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
        let parent = drop == .under ? target : list.parents[target]
        guard parent != list.parents[task], parent.map({ !list.isListed($0, under: task) }) ?? true else { return nil }
        return .some(parent)
    }

    static func options(for task: UUID, in layout: SidebarProjection.Layout) -> Options {
        guard let list = list(showing: task, in: layout) else { return .none }
        let current = list.parents[task]
        return Options(
            levelUp: current.flatMap { list.parents[$0] },
            isNested: current != nil,
            parents: list.rows.compactMap { row in
                guard case let .session(session) = row.content, session.id != current,
                      !list.isListed(session.id, under: task) else { return nil }
                return Parent(id: session.id, title: list.title(row))
            })
    }

    /// One list's task rows as shown, a family's nested rows after its task.
    private struct List {
        let rows: [SidebarRow]
        let title: (SidebarRow) -> String
        /// The task each nested row is listed under.
        let parents: [UUID: UUID]

        init(_ rows: [SidebarRow], title: @escaping (SidebarRow) -> String) {
            self.rows = rows.flatMap(\.rowsWithChildren).filter {
                if case .session = $0.content { true } else { false }
            }
            self.title = title
            var parents: [UUID: UUID] = [:]
            for row in self.rows {
                if case let .session(session) = row.content, let parent = row.familyPlace?.parentID {
                    parents[session.id] = parent
                }
            }
            self.parents = parents
        }

        func shows(_ task: UUID) -> Bool { rows.contains { $0.id == .session(task) } }

        /// Whether `task` is `ancestor` itself or listed somewhere under it.
        func isListed(_ task: UUID, under ancestor: UUID) -> Bool {
            var current: UUID? = task
            var seen: Set<UUID> = []
            while let id = current, seen.insert(id).inserted {
                if id == ancestor { return true }
                current = parents[id]
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
