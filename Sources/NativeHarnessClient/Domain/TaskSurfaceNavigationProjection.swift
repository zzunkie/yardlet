import Foundation

/// Where the terminal opens (Settings › General › Terminal location): below the conversation, or as the
/// side panel's Terminal tab, as the Codex app's "Default terminal location" (`bottom`, `right`) chooses
/// where its terminal shortcut opens terminal tabs. The whole terminal goes there, its tabs with it.
enum TerminalLocation: String, CaseIterable, Sendable {
    case bottom
    case right

    static let key = "YardletTerminalLocation"

    static func current(in defaults: UserDefaults = .yardlet) -> Self {
        defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .bottom
    }
}

/// Deterministic keyboard navigation for the task-owned surface picker.
/// The projection operates on stable raw IDs so the view can keep its local enum private.
enum TaskSurfaceNavigationProjection {
    /// A task's side panel works like the Codex app's: the panels opened in it stay as tabs, hiding the
    /// panel keeps them, and showing it again returns to the tab used last. A task that has no tab yet
    /// opens to the launcher, the Codex app's panel launcher: what the panel can open, and the tasks
    /// whose conversations it can show.
    struct PanelState: Codable, Equatable {
        /// The side-panel surface on screen, or nil while the side panel is hidden.
        var trailingSurfaceID: String?
        var isTerminalPresented: Bool
        /// Side-panel tabs in the order they were opened.
        var trailingTabs: [String]
        /// The same tabs, most recently shown first.
        var recentTrailingTabs: [String]

        init(trailingSurfaceID: String? = nil, isTerminalPresented: Bool = false,
             trailingTabs: [String] = [], recentTrailingTabs: [String] = []) {
            self.trailingSurfaceID = trailingSurfaceID
            self.isTerminalPresented = isTerminalPresented
            self.trailingTabs = trailingTabs
            self.recentTrailingTabs = recentTrailingTabs
        }

        private enum CodingKeys: String, CodingKey {
            case trailingSurfaceID, isTerminalPresented, trailingTabs, recentTrailingTabs
        }

        // Snapshots saved before side-panel tabs have neither tab list.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            trailingSurfaceID = try container.decodeIfPresent(String.self, forKey: .trailingSurfaceID)
            isTerminalPresented = try container.decodeIfPresent(Bool.self, forKey: .isTerminalPresented) ?? false
            trailingTabs = try container.decodeIfPresent([String].self, forKey: .trailingTabs) ?? []
            recentTrailingTabs = try container.decodeIfPresent([String].self, forKey: .recentTrailingTabs) ?? []
        }

        /// The terminal is on screen: below the conversation, or as the side panel's Terminal tab.
        var showsTerminal: Bool {
            isTerminalPresented || trailingSurfaceID == TaskSurfaceNavigationProjection.terminalID
        }
    }

    enum Placement: Equatable {
        case primary
        case trailing
        case bottom
    }

    /// Side-panel surfaces that stay as tabs, besides browser tabs (`browserTabID`) and other tasks'
    /// conversations (`taskTabID`). A Claude subtask is shown in the panel but is not a tab.
    static let trailingTabIDs = ["diff", "files", "sideChat"]
    /// The launcher's and the + menu's Browser, and `⌘4`: not a tab. Choosing it opens a new browser
    /// tab, as the Codex app's Browser and Open Browser Tab do; `⌘4` shows the browser tab used last.
    static let browserChoiceID = "browser"
    /// The launcher (the Codex app's `RightPanelTabsEmptyState` and New tab page): what a panel with no
    /// tab shows, and what the + menu's "All tasks…" shows over the tabs. Not a tab; choosing from it
    /// opens one.
    static let launcherID = "launcher"
    static let defaultTrailingTabID = launcherID
    /// The title-bar control that shows or hides the whole side panel.
    static let sidePanelToggleID = "workspace"
    /// The terminal, below the conversation (`PanelState.isTerminalPresented`) or, with the terminal set to
    /// open on the right, as a side-panel tab of this id.
    static let terminalID = "terminal"
    private static let taskTabPrefix = "task:"
    private static let browserTabPrefix = "browser:"

    /// One of the task's browser tabs, as the Codex app's side panel holds each browser tab as a tab of
    /// its own. The key is the browser tab's (`BrowserTab.key`), which outlives the browser host.
    static func browserTabID(_ key: UUID) -> String { browserTabPrefix + key.uuidString }

    /// The browser tab a side-panel tab is.
    static func browserKey(inTab id: String?) -> UUID? {
        guard let id, id.hasPrefix(browserTabPrefix) else { return nil }
        return UUID(uuidString: String(id.dropFirst(browserTabPrefix.count)))
    }

    /// The task's browser tabs in the panel's order.
    static func browserKeys(in state: PanelState) -> [UUID] {
        state.trailingTabs.compactMap { browserKey(inTab: $0) }
    }

    /// The browser tab used last: the one `⌘4` shows.
    static func latestBrowserTab(in state: PanelState) -> String? {
        state.recentTrailingTabs.first { browserKey(inTab: $0) != nil && state.trailingTabs.contains($0) }
            ?? state.trailingTabs.last { browserKey(inTab: $0) != nil }
    }

    /// The tab that shows another task's conversation in this task's side panel.
    static func taskTabID(_ id: UUID) -> String { taskTabPrefix + id.uuidString }

    /// The task a tab shows, when it is another task's conversation.
    static func taskID(inTab id: String) -> UUID? {
        id.hasPrefix(taskTabPrefix) ? UUID(uuidString: String(id.dropFirst(taskTabPrefix.count))) : nil
    }

    /// A surface that stays in the strip as a tab.
    static func isTab(_ id: String) -> Bool {
        trailingTabIDs.contains(id) || id == terminalID || taskID(inTab: id) != nil || browserKey(inTab: id) != nil
    }

    static func focusedIndex(surfaceIDs: [String], focusedID: String?) -> Int? {
        guard !surfaceIDs.isEmpty else { return nil }
        if let focusedID, let index = surfaceIDs.firstIndex(of: focusedID) {
            return index
        }
        return 0
    }

    static func targetSurfaceID(
        in surfaceIDs: [String],
        focusedID: String?,
        offset: Int
    ) -> String? {
        guard let index = focusedIndex(surfaceIDs: surfaceIDs, focusedID: focusedID) else { return nil }
        let targetIndex = index + offset
        guard surfaceIDs.indices.contains(targetIndex) else { return nil }
        return surfaceIDs[targetIndex]
    }

    static func placement(for surfaceID: String) -> Placement {
        switch surfaceID {
        case "terminal": .bottom
        case "diff", browserChoiceID, "sideChat", "files", "subtask", TaskPanelDetail.surfaceID, launcherID: .trailing
        default: taskID(inTab: surfaceID) != nil || browserKey(inTab: surfaceID) != nil ? .trailing : .primary
        }
    }

    static func initialPanelState(surfaceID: String?, newBrowserKey: UUID = UUID()) -> PanelState {
        switch surfaceID {
        case "diff", "sideChat", "files", sidePanelToggleID, launcherID:
            reconciled(PanelState(trailingSurfaceID: surfaceID))
        case browserChoiceID:
            reconciled(PanelState(trailingSurfaceID: browserTabID(newBrowserKey)))
        case "terminal":
            PanelState(isTerminalPresented: true)
        case "full":
            reconciled(PanelState(trailingSurfaceID: browserTabID(newBrowserKey), isTerminalPresented: true))
        default:
            PanelState()
        }
    }

    /// The tab the side panel returns to when it is shown again.
    static func reopenedTrailingTab(in state: PanelState) -> String {
        state.recentTrailingTabs.first(where: state.trailingTabs.contains)
            ?? state.trailingTabs.last
            ?? defaultTrailingTabID
    }

    /// Shows a side-panel surface, adding it as a tab when it is not one yet.
    static func showing(_ surfaceID: String, in state: PanelState) -> PanelState {
        var next = state
        next.trailingSurfaceID = surfaceID
        return reconciled(next)
    }

    /// Hides the side panel and keeps its tabs for the next time it is shown.
    static func hidingTrailing(_ state: PanelState) -> PanelState {
        var next = state
        next.trailingSurfaceID = nil
        return reconciled(next)
    }

    /// Closes one tab. The panel moves to the tab used before it, and hides after its last tab closes.
    static func closingTrailingTab(_ surfaceID: String, in state: PanelState) -> PanelState {
        closingTrailingTabs([surfaceID], in: state)
    }

    /// Closes several tabs at once (the tab menu's Close Other Tabs and Close Tabs to the Right), by
    /// the same rule as one.
    static func closingTrailingTabs(_ surfaceIDs: [String], in state: PanelState) -> PanelState {
        let closing = Set(surfaceIDs)
        var next = state
        next.trailingTabs.removeAll { closing.contains($0) }
        next.recentTrailingTabs.removeAll { closing.contains($0) }
        if let shown = next.trailingSurfaceID, closing.contains(shown) {
            next.trailingSurfaceID = next.recentTrailingTabs.first(where: next.trailingTabs.contains)
                ?? next.trailingTabs.last
        }
        return reconciled(next)
    }

    /// A tab dragged along the strip: it goes before the tab `before`, or last. Only the order changes.
    static func movingTab(_ surfaceID: String, before: String?, in state: PanelState) -> PanelState {
        guard surfaceID != before, let from = state.trailingTabs.firstIndex(of: surfaceID) else { return state }
        var next = state
        next.trailingTabs.remove(at: from)
        let index = before.flatMap { next.trailingTabs.firstIndex(of: $0) } ?? next.trailingTabs.endIndex
        next.trailingTabs.insert(surfaceID, at: index)
        return reconciled(next)
    }

    /// The tabs a tab's menu closes with Close Other Tabs.
    static func otherTabs(than surfaceID: String, in state: PanelState) -> [String] {
        state.trailingTabs.filter { $0 != surfaceID }
    }

    /// The tabs a tab's menu closes with Close Tabs to the Right.
    static func tabs(rightOf surfaceID: String, in state: PanelState) -> [String] {
        guard let index = state.trailingTabs.firstIndex(of: surfaceID) else { return [] }
        return Array(state.trailingTabs[(index + 1)...])
    }

    /// A browser tab that joins the panel without being shown: one the agent or a page opened. It goes
    /// right after `after` (the browser tab before it in the browser's own order), else after the
    /// panel's last browser tab, else at the end, so the panel keeps the browser's order of its tabs.
    static func addingBrowserTab(_ key: UUID, after: UUID?, in state: PanelState) -> PanelState {
        let id = browserTabID(key)
        guard !state.trailingTabs.contains(id) else { return state }
        var next = state
        let anchor = after.map(browserTabID).flatMap { next.trailingTabs.firstIndex(of: $0) }
            ?? next.trailingTabs.lastIndex { browserKey(inTab: $0) != nil }
        if let anchor { next.trailingTabs.insert(id, at: anchor + 1) } else { next.trailingTabs.append(id) }
        // Least recently used, so closing the shown tab does not move to it.
        next.recentTrailingTabs.append(id)
        return reconciled(next)
    }

    /// Shows a new browser tab right after the tab `after` (the tab menu's New Tab to the Right and
    /// Duplicate), or at the end.
    static func showingNewBrowserTab(_ key: UUID, after: String?, in state: PanelState) -> PanelState {
        let id = browserTabID(key)
        var next = state
        if let after, let index = next.trailingTabs.firstIndex(of: after) {
            next.trailingTabs.insert(id, at: index + 1)
        }
        return showing(id, in: next)
    }

    /// The browser fronted the tab `key` (the agent chose it, or a page opened it in front): a panel
    /// showing a browser tab shows it; a panel showing anything else keeps it, and `⌘4` returns to
    /// it, as the browser tab used last.
    static func frontingBrowserTab(_ key: UUID, in state: PanelState) -> PanelState {
        let id = browserTabID(key)
        guard state.trailingTabs.contains(id), state.trailingSurfaceID != id else { return state }
        if browserKey(inTab: state.trailingSurfaceID) != nil { return showing(id, in: state) }
        var next = state
        next.recentTrailingTabs.removeAll { $0 == id }
        let firstBrowser = next.recentTrailingTabs.firstIndex { browserKey(inTab: $0) != nil }
        let afterShown = next.trailingSurfaceID == nil ? 0 : min(1, next.recentTrailingTabs.count)
        next.recentTrailingTabs.insert(id, at: max(afterShown, firstBrowser ?? next.recentTrailingTabs.count))
        return reconciled(next)
    }

    /// A panel saved before each browser tab was a side-panel tab of its own, whose one Browser tab
    /// held the task's browser tabs: the Browser tab becomes one tab per browser tab, in their order,
    /// where it was in the strip, and the one in front is shown, or used last, where Browser was.
    static func expandingLegacyBrowserTab(in state: PanelState, keys: [UUID], fronted: Int) -> PanelState {
        let legacy = browserChoiceID
        guard state.trailingTabs.contains(legacy) || state.trailingSurfaceID == legacy else { return state }
        let ids = keys.map(browserTabID)
        let frontedID = ids.indices.contains(fronted) ? ids[fronted] : ids.first
        var next = state
        if let index = next.trailingTabs.firstIndex(of: legacy) {
            next.trailingTabs.replaceSubrange(index...index, with: ids)
        } else {
            next.trailingTabs.append(contentsOf: ids)
        }
        let others = ids.filter { $0 != frontedID }
        if let index = next.recentTrailingTabs.firstIndex(of: legacy) {
            next.recentTrailingTabs.replaceSubrange(index...index, with: frontedID.map { [$0] } ?? [])
        } else if let frontedID {
            next.recentTrailingTabs.append(frontedID)
        }
        next.recentTrailingTabs.append(contentsOf: others)
        if next.trailingSurfaceID == legacy { next.trailingSurfaceID = frontedID }
        return reconciled(next)
    }

    /// Shows the terminal where Settings put it: below the conversation, or as the side panel's Terminal
    /// tab, shown in front.
    static func showingTerminal(in state: PanelState, at location: TerminalLocation) -> PanelState {
        switch location {
        case .bottom:
            var next = state
            next.isTerminalPresented = true
            return next
        case .right:
            var next = showing(terminalID, in: state)
            next.isTerminalPresented = false
            return next
        }
    }

    /// Hides the terminal, its shells going on: the panel below closes, and the side panel's Terminal tab
    /// closes as any tab does, the panel showing the tab used before it.
    static func hidingTerminal(_ state: PanelState) -> PanelState {
        var next = state
        next.isTerminalPresented = false
        return next.trailingTabs.contains(terminalID) ? closingTrailingTab(terminalID, in: next) : next
    }

    /// Moves the terminal to where Settings now put it: on screen below, it shows as the side panel's
    /// Terminal tab; a Terminal tab leaves the side panel, and shows below when it was in front.
    static func relocatingTerminal(_ state: PanelState, to location: TerminalLocation) -> PanelState {
        switch location {
        case .bottom:
            guard state.trailingTabs.contains(terminalID) else { return state }
            let wasShown = state.trailingSurfaceID == terminalID
            var next = closingTrailingTab(terminalID, in: state)
            if wasShown { next.isTerminalPresented = true }
            return next
        case .right:
            return state.isTerminalPresented ? showingTerminal(in: state, at: .right) : state
        }
    }

    /// Returns to the conversation alone. Both panels hide; the side panel keeps its tabs.
    static func closingAllPanels(_ state: PanelState) -> PanelState {
        var next = hidingTrailing(state)
        next.isTerminalPresented = false
        return next
    }

    /// Keeps the shown tab in the tab list and first among recent tabs, and drops unknown tabs.
    /// A state saved while the old panel list was showing opens the tab that list would lead to.
    static func reconciled(_ state: PanelState) -> PanelState {
        var next = state
        var seen = Set<String>()
        next.trailingTabs = next.trailingTabs.filter { isTab($0) && seen.insert($0).inserted }
        seen.removeAll()
        next.recentTrailingTabs = next.recentTrailingTabs.filter {
            next.trailingTabs.contains($0) && seen.insert($0).inserted
        }
        if next.trailingSurfaceID == sidePanelToggleID {
            next.trailingSurfaceID = reopenedTrailingTab(in: next)
        }
        if let shown = next.trailingSurfaceID, isTab(shown) {
            if !next.trailingTabs.contains(shown) { next.trailingTabs.append(shown) }
            next.recentTrailingTabs.removeAll { $0 == shown }
            next.recentTrailingTabs.insert(shown, at: 0)
        }
        return next
    }

    /// - Parameter newBrowserKey: the browser tab `⌘4` opens when the task has none.
    /// - Parameter terminalLocation: where the terminal opens.
    static func toggledPanelState(current: PanelState, targetID: String, newBrowserKey: UUID = UUID(),
                                  terminalLocation: TerminalLocation = .bottom) -> PanelState {
        switch targetID {
        case "chat":
            return closingAllPanels(current)
        case terminalID:
            return current.showsTerminal ? hidingTerminal(current) : showingTerminal(in: current, at: terminalLocation)
        case sidePanelToggleID:
            return current.trailingSurfaceID == nil
                ? showing(reopenedTrailingTab(in: current), in: current)
                : hidingTrailing(current)
        case browserChoiceID:
            // A browser tab on screen hides the panel; otherwise the browser tab used last shows, or a
            // new one when the task has none.
            if browserKey(inTab: current.trailingSurfaceID) != nil { return hidingTrailing(current) }
            return showing(latestBrowserTab(in: current) ?? browserTabID(newBrowserKey), in: current)
        case "diff", "sideChat", "files":
            return current.trailingSurfaceID == targetID
                ? hidingTrailing(current)
                : showing(targetID, in: current)
        default:
            return current
        }
    }
}
