import Foundation
import Observation

struct SplitSnapshot: Codable, Equatable, Sendable {
    var version = 1
    var splits: [SplitGroup] = []
    /// Nil when nothing was saved yet, so restoration can fall back to the remembered task.
    var selection: WindowItem?
    /// The window's tabs, left to right; `selection` is the active one. Nil in files written before
    /// tabs, which open with the one saved item.
    var tabs: [WindowItem]?
    /// When it was saved: the last change, or the quit. Nil in files written before it, which reopen
    /// what they show.
    var savedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case version, splits, selection, tabs, savedAt
    }

    init(version: Int = 1, splits: [SplitGroup] = [], selection: WindowItem? = nil, tabs: [WindowItem]? = nil,
         savedAt: Date? = nil) {
        self.version = version
        self.splits = splits
        self.selection = selection
        self.tabs = tabs
        self.savedAt = savedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        splits = try container.decodeIfPresent([SplitGroup].self, forKey: .splits) ?? []
        selection = try container.decodeIfPresent(WindowItem.self, forKey: .selection)
        tabs = try container.decodeIfPresent([WindowItem].self, forKey: .tabs)
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt)
    }
}

@MainActor
protocol SplitRepository {
    func load() -> SplitSnapshot?
    func save(_ snapshot: SplitSnapshot)
}

@MainActor
final class InMemorySplitRepository: SplitRepository {
    var snapshot: SplitSnapshot?

    init(snapshot: SplitSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func load() -> SplitSnapshot? { snapshot }
    func save(_ snapshot: SplitSnapshot) { self.snapshot = snapshot }
}

/// Split views are Yardlet-owned presentation state and live beside the other `~/.yardlet`
/// records. They never carry provider credentials or conversation content. Before the first
/// save, the earlier `desks.json` workspace grid is read once and converted; that file is left
/// in place untouched.
struct FileSplitRepository: SplitRepository {
    let fileURL: URL
    var legacyDeskFileURL: URL?

    static func live(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> FileSplitRepository {
        let root = homeURL.appending(path: YardletProduct.storageDirectoryName, directoryHint: .isDirectory)
        return FileSplitRepository(
            fileURL: root.appending(path: "splits.json"),
            legacyDeskFileURL: root.appending(path: "desks.json")
        )
    }

    func load() -> SplitSnapshot? {
        if let data = try? Data(contentsOf: fileURL) {
            guard let snapshot = try? JSONDecoder().decode(SplitSnapshot.self, from: data),
                  snapshot.version == 1 else { return nil }
            return snapshot
        }
        guard let legacyDeskFileURL, let data = try? Data(contentsOf: legacyDeskFileURL) else { return nil }
        return LegacyDeskMigration.snapshot(fromDesksJSON: data)
    }

    func save(_ snapshot: SplitSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Converts the 2×2 workspace grid saved before split views existed. A workspace with more
/// than one pane becomes a split view; a single-pane workspace only contributes its task as the
/// window's selection.
enum LegacyDeskMigration {
    private struct Snapshot: Decodable {
        var version: Int?
        var desks: [Desk]?
        var activeDeskID: UUID?
    }

    private struct Desk: Decodable {
        var id: UUID?
        var name: String?
        var panes: [Pane]?
        var focusedPaneID: UUID?
    }

    private struct Pane: Decodable {
        var id: UUID?
        var column: Int?
        var row: Int?
        var sessionID: UUID?
    }

    static func snapshot(fromDesksJSON data: Data) -> SplitSnapshot? {
        guard let legacy = try? JSONDecoder().decode(Snapshot.self, from: data),
              (legacy.version ?? 1) == 1 else { return nil }
        var splits: [SplitGroup] = []
        var selection: WindowItem = .home
        for desk in legacy.desks ?? [] {
            let panes = (desk.panes ?? []).map {
                (pane: SplitPane(id: $0.id ?? UUID(), sessionID: $0.sessionID), column: $0.column ?? 0, row: $0.row ?? 0)
            }
            let isActive = desk.id != nil && desk.id == legacy.activeDeskID
            if panes.count > 1, panes.contains(where: { $0.pane.sessionID != nil }) {
                let columns = Dictionary(grouping: panes, by: \.column)
                    .sorted { $0.key < $1.key }
                    .map { column -> SplitNode in
                        let stacked = column.value.sorted { $0.row < $1.row }.map { SplitNode.pane($0.pane) }
                        return stacked.count == 1
                            ? stacked[0]
                            : .branch(axis: .vertical, children: stacked,
                                      fractions: Array(repeating: 1, count: stacked.count))
                    }
                let root: SplitNode = columns.count == 1
                    ? columns[0]
                    : .branch(axis: .horizontal, children: columns,
                              fractions: Array(repeating: 1, count: columns.count))
                let split = SplitGroup(
                    customName: customName(desk.name),
                    root: root,
                    focusedPaneID: desk.focusedPaneID
                )
                guard split.isComplete else { continue }
                splits.append(split)
                if isActive { selection = .split(split.id) }
            } else if isActive {
                let focused = panes.first { $0.pane.id == desk.focusedPaneID } ?? panes.first
                selection = focused?.pane.sessionID.map(WindowItem.session) ?? .home
            }
        }
        return SplitSnapshot(splits: splits, selection: selection)
    }

    /// Automatic names ("Workspace 2", in English or Korean) carried no choice of the user's.
    private static func customName(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let automatic = name.range(of: #"^(Workspace|워크스페이스) \d+$"#, options: .regularExpression) != nil
        return automatic ? nil : name
    }
}

/// Owns split views and what the window shows. The focused pane's session (or the single task)
/// is the source for the shell's selected task; `SessionStore.selectedSessionID` mirrors it.
///
/// The window keeps tabs, as a browser does: each tab shows one item (the new-task screen, a task,
/// or a split view), and `selection` is the active tab's item. Choosing a sidebar row shows it in
/// the active tab, or moves to the tab that already shows it, so an item is in one tab at most.
@MainActor
@Observable
final class SplitStore {
    private(set) var splits: [SplitGroup]
    private(set) var selection: WindowItem
    /// Never empty, always holds `selection`, and no item twice.
    private(set) var tabs: [WindowItem]

    @ObservationIgnored private let repository: any SplitRepository
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var publishedSessionID: UUID?
    @ObservationIgnored private var hasSavedSelection: Bool
    /// External selection changes are ignored until the task index is known, so restoring the
    /// remembered task cannot rearrange a saved split.
    @ObservationIgnored private var isReady = false
    @ObservationIgnored var onFocusedSessionChange: ((UUID?) -> Void)?
    /// The active tab's item when the tabs were last brought in line with `selection`: the tab a
    /// new selection replaces.
    @ObservationIgnored private var tabbedSelection: WindowItem
    /// Split views that ended since then, and the item each leaves on screen.
    @ObservationIgnored private var endedSplits: [UUID: WindowItem] = [:]
    /// Archived, deleted or missing tasks, whose tabs close unless the task is chosen again.
    @ObservationIgnored private var removedSessionIDs: Set<UUID> = []
    /// Closed tabs, most recent last, for Reopen Closed Tab.
    @ObservationIgnored private var closedTabs: [WindowItem] = []
    /// What the window showed before and after `selection`, most recent last, for Back and Forward:
    /// the order things were shown in, not the sidebar's, as the Claude app's Go › Back and the Codex
    /// app's `navigateBack` step through the pages they showed. Kept for this run only.
    private var backItems: [WindowItem] = []
    private var forwardItems: [WindowItem] = []
    /// The selection the history last saw; a change from it is a visit.
    @ObservationIgnored private var visitedSelection: WindowItem
    @ObservationIgnored private let now: () -> Date

    static let historyLimit = 50

    /// How soon after the window was saved a launch reopens what it showed. The Claude app restores
    /// its page only when relaunched within five minutes (`stealth-relaunch`, `kVe=3e5`), as after an
    /// update or a restart; a later launch opens on its home, where the Codex app always starts (`/`).
    static let relaunchWindow: TimeInterval = 5 * 60

    init(repository: any SplitRepository = InMemorySplitRepository(), now: @escaping () -> Date = Date.init) {
        self.repository = repository
        self.now = now
        let snapshot = repository.load() ?? SplitSnapshot()
        splits = snapshot.splits.filter(\.isComplete)
        let saved = snapshot.selection ?? .home
        // A launch long after the last save opens the home in the active tab's place; the other tabs,
        // the split views and the sidebar keep what they had.
        let isLater = snapshot.savedAt.map { now().timeIntervalSince($0) > Self.relaunchWindow } ?? false
        let shown: WindowItem = isLater ? .home : saved
        self.selection = shown
        visitedSelection = shown
        tabs = snapshot.tabs ?? [saved]
        tabbedSelection = saved
        hasSavedSelection = snapshot.selection != nil
        publishedSessionID = nil
        publishedSessionID = focusedSessionID
        reconcileTabs()
    }

    // MARK: - Reading

    var activeSplit: SplitGroup? {
        guard case let .split(id) = selection else { return nil }
        return splits.first { $0.id == id }
    }

    var focusedSessionID: UUID? {
        switch selection {
        case .home: nil
        case let .session(id): id
        case .split: activeSplit?.focusedSessionID
        }
    }

    func split(containing sessionID: UUID) -> SplitGroup? {
        splits.first { $0.pane(hosting: sessionID) != nil }
    }

    /// Sessions shown inside a split view rather than as their own sidebar row.
    var groupedSessionIDs: Set<UUID> {
        Set(splits.flatMap(\.sessionIDs))
    }

    var canSplit: Bool { selection != .home }
    var canClosePane: Bool { activeSplit != nil }

    var activeTabIndex: Int { tabs.firstIndex(of: selection) ?? 0 }
    /// A window's last tab is not closed as a tab; closing it closes the window.
    var canCloseTab: Bool { tabs.count > 1 }
    var canReopenClosedTab: Bool { closedTabs.contains { resolved($0) != nil } }
    var canGoBack: Bool { backItems.contains(where: isVisitable) }
    var canGoForward: Bool { forwardItems.contains(where: isVisitable) }

    // MARK: - Launch handoff

    /// Adopts the shell's current selection without notifying. `isFinal` is false while the task
    /// index is still loading: its empty task list says nothing about which saved tasks still
    /// exist, so nothing is pruned until `restore` finishes the handoff.
    func adopt(selection fallback: UUID?, knownSessionIDs: Set<UUID>, isFinal: Bool) {
        defer { publishedSessionID = focusedSessionID }
        guard isFinal else { return }
        retain(knownSessionIDs)
        if !hasSavedSelection, let fallback, knownSessionIDs.contains(fallback) {
            selection = item(showing: fallback)
        }
        isReady = true
        reconcileTabs()
        visitedSelection = selection
    }

    /// Restoration keeps a saved split authoritative. Without a saved window item the previously
    /// selected task opens, inside its split view when it belongs to one.
    func restore(knownSessionIDs: Set<UUID>, fallbackSessionID: UUID?) {
        adopt(selection: fallbackSessionID, knownSessionIDs: knownSessionIDs, isFinal: true)
        schedulePersist()
        publishFocusedSession(force: true)
    }

    // MARK: - Navigation

    /// A sidebar row was chosen. A task goes into the focused split pane when that pane is empty
    /// and the task is not already arranged elsewhere, the way a split's empty half is filled.
    func activate(_ item: WindowItem) {
        activate(item, fillsEmptyPane: true)
    }

    private func activate(_ item: WindowItem, fillsEmptyPane: Bool) {
        if case let .session(id) = item { removedSessionIDs.remove(id) }
        switch item {
        case .home:
            selection = .home
        case let .session(id):
            if fillsEmptyPane, let split = activeSplit, split.focusedSessionID == nil, self.split(containing: id) == nil {
                mutateSplit(split.id) { $0.place(id, in: $0.focusedPaneID) }
            } else {
                selection = self.item(showing: id)
                if case let .split(splitID) = selection, let pane = self.split(containing: id)?.pane(hosting: id) {
                    mutateSplit(splitID) { $0.focus(paneID: pane.id) }
                }
            }
        case let .split(id):
            guard splits.contains(where: { $0.id == id }) else { return }
            selection = .split(id)
        }
        changed()
    }

    /// Mirrors an external selection change (a new task, a fork, a notification).
    func focusSession(_ id: UUID?) {
        guard isReady, id != focusedSessionID else { return }
        guard let id else {
            selection = .home
            return changed()
        }
        activate(.session(id))
    }

    func showNewTask() {
        guard selection != .home else { return }
        selection = .home
        changed()
    }

    // MARK: - Tabs

    /// ⌘T: the new-task screen in a new tab after the active one, or the tab that shows it already.
    func newTab() {
        openInNewTab(.home)
    }

    /// ⌘-click or "Open in New Tab" on a sidebar row: the row's item in a new tab after the active
    /// one. An item already in a tab is shown there instead, and a task in a split view opens that
    /// split view.
    func openInNewTab(_ item: WindowItem) {
        if case let .session(id) = item { removedSessionIDs.remove(id) }
        guard let target = resolved(item) else { return }
        if !tabs.contains(target) {
            tabs.insert(target, at: activeTabIndex + 1)
        }
        // The new tab is the active one now, so the tab the person left keeps its item.
        tabbedSelection = target
        activate(item, fillsEmptyPane: false)
    }

    func selectTab(_ item: WindowItem) {
        guard tabs.contains(item), item != selection else { return }
        selection = item
        tabbedSelection = item
        changed()
    }

    /// ⌃Tab and ⌃⇧Tab, wrapping around as a browser's tabs do.
    func selectTab(offset: Int) {
        guard tabs.count > 1 else { return }
        let index = (activeTabIndex + offset % tabs.count + tabs.count) % tabs.count
        selectTab(tabs[index])
    }

    /// Closes a tab, the active one by default. Its task stays in the sidebar as it was; the tab to
    /// its right becomes active, or the one to its left at the end.
    func closeTab(_ item: WindowItem? = nil) {
        let item = item ?? selection
        guard tabs.count > 1, let index = tabs.firstIndex(of: item) else { return }
        tabs.remove(at: index)
        closedTabs.removeAll { $0 == item }
        closedTabs.append(item)
        if closedTabs.count > 20 { closedTabs.removeFirst() }
        if item == selection {
            selection = tabs[min(index, tabs.count - 1)]
            tabbedSelection = selection
        }
        changed()
    }

    func closeOtherTabs(than item: WindowItem? = nil) {
        let kept = item ?? selection
        guard tabs.contains(kept) else { return }
        for other in tabs where other != kept {
            closedTabs.removeAll { $0 == other }
            closedTabs.append(other)
        }
        if closedTabs.count > 20 { closedTabs.removeFirst(closedTabs.count - 20) }
        tabs = [kept]
        selection = kept
        tabbedSelection = kept
        changed()
    }

    /// A tab dragged along the tab bar: it goes before the tab `before`, or last. Only the order changes;
    /// the window shows the dragged tab (`selectTab`), as Safari shows a tab once it is pressed.
    func moveTab(_ item: WindowItem, before: WindowItem?) {
        guard item != before, let from = tabs.firstIndex(of: item) else { return }
        var moved = tabs
        moved.remove(at: from)
        moved.insert(item, at: before.flatMap { moved.firstIndex(of: $0) } ?? moved.endIndex)
        guard moved != tabs else { return }
        tabs = moved
        schedulePersist()
    }

    /// A task dragged onto the tab bar (a split pane, another task's conversation from a side panel, a
    /// sidebar row): it becomes a tab of its own before the tab `before`, or last, and that tab shows.
    /// A task in a split view leaves it; a split view left with one task ends in its own tab.
    func openInOwnTab(_ sessionID: UUID, before: WindowItem?) {
        removedSessionIDs.remove(sessionID)
        detach(sessionID)
        let item = WindowItem.session(sessionID)
        let current = tabs.compactMap(resolved)
        var anchor = before.flatMap(resolved)
        // Dropped on its own tab's place, a task that has a tab keeps it there.
        if anchor == item, let index = current.firstIndex(of: item) {
            anchor = current[(index + 1)...].first { $0 != item }
        }
        var items: [WindowItem] = []
        for tab in current where tab != item && !items.contains(tab) { items.append(tab) }
        items.insert(item, at: anchor.flatMap { items.firstIndex(of: $0) } ?? items.endIndex)
        tabs = items
        selection = item
        tabbedSelection = item
        changed()
    }

    /// ⌘⇧T: the most recently closed tab whose item still exists, after the active tab.
    func reopenClosedTab() {
        while let item = closedTabs.popLast() {
            guard let target = resolved(item) else { continue }
            if !tabs.contains(target) { tabs.insert(target, at: activeTabIndex + 1) }
            selection = target
            tabbedSelection = target
            return changed()
        }
    }

    // MARK: - History

    /// Back (⌘[, the mouse's back button): what the window showed before, shown as a sidebar row
    /// shows it, in its tab or the active one. Items that are gone are passed over.
    func goBack() {
        guard let target = popVisitable(\.backItems) else { return }
        forwardItems.append(selection)
        show(visited: target)
    }

    /// Forward (⌘], the mouse's forward button): undoes a Back.
    func goForward() {
        guard let target = popVisitable(\.forwardItems) else { return }
        backItems.append(selection)
        show(visited: target)
    }

    private func popVisitable(_ list: ReferenceWritableKeyPath<SplitStore, [WindowItem]>) -> WindowItem? {
        while let item = self[keyPath: list].popLast() {
            if isVisitable(item), let target = resolved(item) { return target }
        }
        return nil
    }

    /// Shows an item from the history without recording it as a new visit.
    private func show(visited target: WindowItem) {
        visitedSelection = target
        activate(target, fillsEmptyPane: false)
    }

    private func isVisitable(_ item: WindowItem) -> Bool {
        resolved(item).map { $0 != selection } ?? false
    }

    /// A new selection is a visit: what was shown goes on the back list and the forward list ends,
    /// as a browser's history does.
    private func recordVisit() {
        defer { visitedSelection = selection }
        guard isReady, selection != visitedSelection else { return }
        backItems.append(visitedSelection)
        if backItems.count > Self.historyLimit { backItems.removeFirst() }
        forwardItems.removeAll()
    }

    // MARK: - Pane commands

    /// Splits the focused pane. From a single task this creates a split view holding that task
    /// and the new pane; `pinned` carries that task's pin so the row stays where it was.
    /// `placing` fills the new pane with a task instead of the composer.
    func split(_ direction: SplitDirection, placing sessionID: UUID? = nil, pinned: Bool = false) {
        switch selection {
        case .home:
            return
        case let .session(current):
            guard sessionID != current else { return }
            detach(sessionID)
            var split = SplitGroup(isPinned: pinned, root: .pane(SplitPane(sessionID: current)))
            split.split(direction, placing: sessionID)
            splits.append(split)
            selection = .split(split.id)
        case let .split(id):
            // A task the split view already shows keeps its pane, which takes the focus.
            if let sessionID, let pane = activeSplit?.pane(hosting: sessionID) {
                mutateSplit(id) { $0.focus(paneID: pane.id) }
                return changed()
            }
            detach(sessionID, keeping: id)
            mutateSplit(id) { $0.split(direction, placing: sessionID) }
        }
        changed()
    }

    /// "Open in Split View" on a sidebar task row, as the Claude app's session menu offers it: the task
    /// in a new pane right of the focused one, or its pane focused when the split view shows it
    /// already. The new-task screen has no pane to put it beside, and a task shown alone is already
    /// in view; both return false.
    @discardableResult
    func openInSplitView(_ sessionID: UUID, pinned: Bool = false) -> Bool {
        switch selection {
        case .home:
            return false
        case let .session(current) where current == sessionID:
            return false
        default:
            removedSessionIDs.remove(sessionID)
            split(.right, placing: sessionID, pinned: pinned)
            return true
        }
    }

    /// Places a dragged task beside a pane of the shown split, or beside the single task.
    func place(_ sessionID: UUID, beside paneID: UUID?, direction: SplitDirection, pinned: Bool = false) {
        switch selection {
        case .home:
            return
        case let .session(current):
            guard sessionID != current else { return }
            split(direction, placing: sessionID, pinned: pinned)
        case let .split(id):
            guard activeSplit?.pane(hosting: sessionID)?.id != paneID else { return }
            detach(sessionID, keeping: id)
            // A pane moved within the split leaves its place and takes the new one in one change, so a
            // split of two does not end in between.
            mutateSplit(id) { split in
                if let existing = split.pane(hosting: sessionID) { split.closePane(existing.id) }
                split.split(direction, from: paneID, placing: sessionID)
            }
            changed()
        }
    }

    /// A pane dragged onto the middle of another pane of the shown split: the two change places.
    func swap(_ sessionID: UUID, withPane paneID: UUID) {
        guard let split = activeSplit, let pane = split.pane(hosting: sessionID), pane.id != paneID else { return }
        mutateSplit(split.id) { $0.swap(pane.id, paneID) }
        changed()
    }

    /// A task dropped on another task's sidebar row: both become one split view, shown at once.
    func combine(_ sessionID: UUID, with targetSessionID: UUID, pinned: Bool = false) {
        guard sessionID != targetSessionID else { return }
        if let existing = split(containing: targetSessionID) {
            return add(sessionID, to: existing.id)
        }
        detach(sessionID)
        var split = SplitGroup(isPinned: pinned, root: .pane(SplitPane(sessionID: targetSessionID)))
        split.split(.right, placing: sessionID)
        splits.append(split)
        selection = .split(split.id)
        changed()
    }

    /// A task dropped on a split view's sidebar row joins it beside the focused pane.
    func add(_ sessionID: UUID, to splitID: UUID) {
        guard splits.contains(where: { $0.id == splitID }),
              split(containing: sessionID)?.id != splitID else { return }
        detach(sessionID)
        mutateSplit(splitID) { $0.split(.right, placing: sessionID) }
        selection = .split(splitID)
        changed()
    }

    /// Closing a pane takes its task out of the split; the task keeps its own sidebar row. A split
    /// left with one pane ends, and the window shows what remained.
    func closePane(_ paneID: UUID? = nil) {
        guard let split = activeSplit else { return }
        mutateSplit(split.id) { $0.closePane(paneID ?? $0.focusedPaneID) }
        changed()
    }

    func focusPane(_ id: UUID) {
        guard let split = activeSplit else { return }
        mutateSplit(split.id) { $0.focus(paneID: id) }
        changed()
    }

    func moveFocus(_ direction: PaneFocusDirection) {
        guard let split = activeSplit else { return }
        mutateSplit(split.id) { $0.moveFocus(direction) }
        changed()
    }

    func resize(at path: [Int], fractions: [Double]) {
        guard let split = activeSplit else { return }
        mutateSplit(split.id) { $0.resize(at: path, fractions: fractions) }
        schedulePersist()
    }

    // MARK: - Split rows

    /// Ends a split view. Its tasks return to their own rows; the focused one stays on screen.
    func dissolve(_ splitID: UUID) {
        guard let index = splits.firstIndex(where: { $0.id == splitID }) else { return }
        let split = splits.remove(at: index)
        let remaining = (split.focusedSessionID ?? split.sessionIDs.first).map(WindowItem.session) ?? .home
        endedSplits[splitID] = remaining
        if selection == .split(splitID) {
            selection = remaining
        }
        changed()
    }

    func rename(_ splitID: UUID, to name: String?) {
        guard let index = splits.firstIndex(where: { $0.id == splitID }) else { return }
        splits[index].customName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if splits[index].customName?.isEmpty == true { splits[index].customName = nil }
        schedulePersist()
    }

    func togglePinned(_ splitID: UUID) {
        guard let index = splits.firstIndex(where: { $0.id == splitID }) else { return }
        splits[index].isPinned.toggle()
        schedulePersist()
    }

    // MARK: - Task lifecycle

    /// An archived or deleted task leaves any split first, so the window stays on the split's
    /// remaining panes. A task shown on its own is left selected; the task index then leaves the
    /// window on the home, exactly as it does without split views.
    func removeSession(_ id: UUID) {
        removedSessionIDs.insert(id)
        // With other tabs open, the window moves to the next tab instead of to the index's next task.
        if selection == .session(id), let index = tabs.firstIndex(of: selection), tabs.count > 1 {
            tabs.remove(at: index)
            selection = tabs[min(index, tabs.count - 1)]
            tabbedSelection = selection
        }
        for split in splits where split.pane(hosting: id) != nil {
            mutateSplit(split.id) { $0.removeSession(id) }
        }
        changed()
    }

    func retainSessions(_ known: Set<UUID>) {
        retain(known)
        changed()
    }

    // MARK: - Persistence

    func persistNow() {
        pendingSave?.cancel()
        pendingSave = nil
        repository.save(SplitSnapshot(splits: splits, selection: selection, tabs: tabs, savedAt: now()))
    }

    // MARK: - Internals

    private func item(showing sessionID: UUID) -> WindowItem {
        split(containing: sessionID).map { .split($0.id) } ?? .session(sessionID)
    }

    /// Takes a task out of whichever split holds it, so one task is only ever in one place.
    private func detach(_ sessionID: UUID?, keeping keptSplitID: UUID? = nil) {
        guard let sessionID, let holder = split(containing: sessionID), holder.id != keptSplitID else { return }
        mutateSplit(holder.id) { $0.removeSession(sessionID) }
    }

    private func mutateSplit(_ id: UUID, _ body: (inout SplitGroup) -> Void) {
        guard let index = splits.firstIndex(where: { $0.id == id }) else { return }
        body(&splits[index])
        guard !splits[index].isComplete else { return }
        let ended = splits.remove(at: index)
        let remaining = ended.sessionIDs.first.map(WindowItem.session) ?? .home
        endedSplits[id] = remaining
        if selection == .split(id) {
            selection = remaining
        }
    }

    private func retain(_ known: Set<UUID>) {
        for case let .session(id) in tabs where !known.contains(id) { removedSessionIDs.insert(id) }
        for split in splits {
            mutateSplit(split.id) { $0.retainSessions(known) }
        }
        switch selection {
        case let .session(id) where !known.contains(id):
            selection = .home
        case let .split(id) where !splits.contains(where: { $0.id == id }):
            selection = .home
        default:
            break
        }
    }

    private func changed() {
        recordVisit()
        reconcileTabs()
        schedulePersist()
        publishFocusedSession()
    }

    /// What a tab's item has become: a task that went into a split view is that split, a split
    /// view that ended is what it left, and a removed task has no tab.
    private func resolved(_ item: WindowItem) -> WindowItem? {
        switch item {
        case .home:
            return .home
        case let .session(id):
            return removedSessionIDs.contains(id) ? nil : self.item(showing: id)
        case let .split(id):
            if splits.contains(where: { $0.id == id }) { return item }
            return endedSplits[id].flatMap { $0 == item ? nil : resolved($0) }
        }
    }

    /// Brings the tabs in line with `selection`: a new selection replaces the active tab's item
    /// unless another tab already shows it, every tab follows what its item became, and no item
    /// is in two tabs (the active tab keeps it).
    private func reconcileTabs() {
        let activeIndex = tabs.firstIndex(of: tabbedSelection)
        var items: [WindowItem?] = tabs.map(resolved)
        if !items.contains(selection) {
            if let activeIndex { items[activeIndex] = selection } else { items.append(selection) }
        }
        var seen: Set<WindowItem> = [selection]
        let keptActive = activeIndex.flatMap { items[$0] == selection ? $0 : nil } ?? items.firstIndex { $0 == selection }
        var result: [WindowItem] = []
        for (index, item) in items.enumerated() {
            guard let item else { continue }
            if item == selection {
                if index == keptActive { result.append(item) }
            } else if seen.insert(item).inserted {
                result.append(item)
            }
        }
        tabs = result.isEmpty ? [selection] : result
        tabbedSelection = selection
        endedSplits.removeAll()
    }

    private func publishFocusedSession(force: Bool = false) {
        let id = focusedSessionID
        guard force || id != publishedSessionID else { return }
        publishedSessionID = id
        onFocusedSessionChange?(id)
    }

    private func schedulePersist() {
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.persistNow()
        }
    }
}
