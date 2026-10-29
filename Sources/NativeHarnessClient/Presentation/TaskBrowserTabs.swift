import Foundation
import Observation

/// One of a task's browser tabs as the task keeps it between Yardlet's runs: the page it showed and
/// the page's title, under the side-panel tab's key (`BrowserTab.key`).
struct BrowserTabPage: Codable, Equatable, Sendable {
    var key: UUID
    var address: String
    var title: String
}

/// A page one of a task's browser tabs showed, which the side panel's launcher and a new browser tab's start page offer
/// again (docs/BROWSER_HOST.md, section 3, "Start page"). Saved with the task, so it goes when the task goes.
struct BrowserVisitedPage: Codable, Equatable, Sendable {
    var address: String
    var title: String
    /// When one of the task's tabs last showed the page.
    var visited: Date
    /// When the last tab that showed the page closed; nil once a tab shows it again.
    var closed: Date?
}

/// Settings › General "Suggest pages on new tabs", on unless turned off: a task keeps the pages its browser tabs show
/// (`TaskBrowserTabs.visited`), and the launcher and a new tab's start page offer them with the sites visited most.
/// Off, nothing is kept or offered, and each task's saved pages go the next time the task is saved.
enum BrowserPageSuggestionPreference {
    static let key = "Yardlet.browser.pageSuggestions"

    static func isOn(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

/// A task's browser tabs as its side panel shows them, each a side-panel tab of its own as in the Codex
/// app: the page and title of each, saved with the task, and while the browser has the tab, its icon
/// and whether it loads. The browser engine's tabs fill it in (`TaskWorkspaceState.syncBrowserTabs`);
/// a build without the engine keeps a WebKit preview page per tab here instead.
@MainActor @Observable
final class TaskBrowserTabs {
    struct Tab: Equatable {
        var address = ""
        var title = ""
        /// PNG; never saved, so a tab shows its globe until its page loads again.
        var favicon: Data?
        var isLoading = false
        /// What the tab waits on from the person (`BrowserHostClient.personWait(of:)`), and the page's site it names.
        var wait: BrowserPersonWait?
        var site: String?
        /// The agent used this tab last in its turn.
        var isAgentUsing = false
        /// The memory saver discarded the page (`BrowserTab.isDiscarded`); it loads again when the tab shows.
        var isDiscarded = false
    }

    private(set) var tabs: [UUID: Tab]
    /// The pages the tabs showed, the latest shown or closed first, at most `keptPages`.
    private(set) var visited: [BrowserVisitedPage]
    /// The page each tab was last counted at, so that a tab counts each page it moves to once.
    @ObservationIgnored private var counted: [UUID: String] = [:]
    @ObservationIgnored private let keepsVisited: () -> Bool
    @ObservationIgnored private let now: () -> Date
    /// The build without the browser engine: each tab's WebKit page, which owns the page's state.
    @ObservationIgnored private var previews: [UUID: BrowserPreviewModel] = [:]
    @ObservationIgnored var onChange: (() -> Void)?

    /// More than the launcher and the start page offer, with room for the pages the tabs show.
    static let keptPages = 20

    init(pages: [BrowserTabPage] = [], visited: [BrowserVisitedPage] = [],
         keepsVisited: @escaping () -> Bool = { BrowserPageSuggestionPreference.isOn() }, now: @escaping () -> Date = Date.init) {
        tabs = Dictionary(pages.map { ($0.key, Tab(address: $0.address, title: $0.title)) }) { first, _ in first }
        counted = Dictionary(pages.map { ($0.key, $0.address) }) { first, _ in first }
        self.keepsVisited = keepsVisited
        self.now = now
        self.visited = keepsVisited() ? Array(visited.prefix(Self.keptPages)) : []
    }

    func tab(_ key: UUID) -> Tab? { tabs[key] }

    /// What the browser reports of its tab `key`; a nil address keeps the page last shown.
    func update(_ key: UUID, address: String?, title: String, favicon: Data?, isLoading: Bool, isDiscarded: Bool = false) {
        var tab = tabs[key] ?? Tab()
        if let address, !address.isEmpty, address != "about:blank" { tab.address = address }
        tab.title = title
        tab.favicon = favicon
        tab.isLoading = isLoading
        tab.isDiscarded = isDiscarded
        let noted = noteVisit(of: key, address: tab.address, title: tab.title)
        guard tab != tabs[key] else {
            if noted { onChange?() }
            return
        }
        let saved = tabs[key].map { ($0.address, $0.title) }
        tabs[key] = tab
        if noted || saved.map({ $0 != (tab.address, tab.title) }) ?? true { onChange?() }
    }

    /// A tab at a page it was not counted at visits it; at the page it was counted at, the page's title follows the
    /// tab's. The address is the tab's page, which keeps out an address or title that carries a value the vault filled
    /// (`BrowserTab.lastPageURL`), as the pages the task saves for its tabs do.
    private func noteVisit(of key: UUID, address: String, title: String) -> Bool {
        guard keepsVisited(), let page = BrowserAddressHistory.keptAddress(address) else { return false }
        // Chromium names a page without a title by its address.
        let title = title == address || title == page ? "" : title
        if counted[key] != address {
            counted[key] = address
            visited.removeAll { BrowserURLPolicy.sameAddress($0.address, page) }
            visited.insert(BrowserVisitedPage(address: page, title: title, visited: now()), at: 0)
            if visited.count > Self.keptPages { visited.removeLast(visited.count - Self.keptPages) }
            return true
        }
        guard let index = visited.firstIndex(where: { $0.address == page }), visited[index].title != title else { return false }
        visited[index].title = title
        return true
    }

    /// The pages to offer again, at most `limit`: those of closed tabs, the latest closed first, then the pages the tabs
    /// moved on from, the latest first; none a tab shows now. Nothing while "Suggest pages on new tabs" is off.
    func suggestedPages(limit: Int) -> [BrowserVisitedPage] {
        guard keepsVisited() else { return [] }
        let open = tabs.values.map(\.address)
        let offered = visited.filter { page in !open.contains { BrowserURLPolicy.sameAddress($0, page.address) } }
        let closed = offered.filter { $0.closed != nil }.sorted { ($0.closed ?? .distantPast) > ($1.closed ?? .distantPast) }
        let seen = offered.filter { $0.closed == nil }.sorted { $0.visited > $1.visited }
        return Array((closed + seen).prefix(limit))
    }

    /// A page taken out of what the task offers again.
    func removeVisited(_ address: String) {
        let count = visited.count
        visited.removeAll { $0.address == address }
        if visited.count != count { onChange?() }
    }

    /// What the panel's tab marks: what the tab waits on from the person, and whether the agent works in it. Never
    /// saved.
    func mark(_ key: UUID, wait: BrowserPersonWait?, site: String?, isAgentUsing: Bool) {
        guard var tab = tabs[key] else { return }
        tab.wait = wait
        tab.site = wait == nil ? nil : site
        tab.isAgentUsing = isAgentUsing
        guard tab != tabs[key] else { return }
        tabs[key] = tab
    }

    /// A new tab's page before the browser opens it (a duplicate, a link from the conversation).
    func setAddress(_ address: String, for key: UUID) {
        guard tabs[key]?.address != address else { return }
        tabs[key, default: Tab()].address = address
        onChange?()
    }

    /// The tabs closed: their pages and, in the build without the engine, their WebKit pages go. Each page a tab
    /// closed at is offered again first, as a closed tab.
    func remove(_ keys: some Sequence<UUID>) {
        var changed = false
        for key in keys {
            if let tab = tabs.removeValue(forKey: key) {
                changed = true
                noteClosed(tab)
            }
            counted.removeValue(forKey: key)
            previews.removeValue(forKey: key)?.terminateForApplicationShutdown()
        }
        if changed { onChange?() }
    }

    private func noteClosed(_ tab: Tab) {
        guard keepsVisited(), let page = BrowserAddressHistory.keptAddress(tab.address) else { return }
        let date = now()
        var closed = visited.first { $0.address == page }
            ?? BrowserVisitedPage(address: page, title: tab.title == tab.address ? "" : tab.title, visited: date)
        closed.closed = date
        visited.removeAll { $0.address == page }
        visited.insert(closed, at: 0)
        if visited.count > Self.keptPages { visited.removeLast(visited.count - Self.keptPages) }
    }

    /// The pages of the panel's browser tabs, in the panel's order, and the pages the tabs showed, for the task's
    /// snapshot. The page used last and, with several, every page and the one used last also go where a build before
    /// side-panel browser tabs reads them.
    func preferences(order: [UUID], latest: UUID?) -> BrowserPreviewPreferences? {
        let pages = order.map { key in
            BrowserTabPage(key: key, address: tabs[key]?.address ?? "", title: tabs[key]?.title ?? "")
        }
        let visited = keepsVisited() && !visited.isEmpty ? visited : nil
        guard !pages.isEmpty || visited != nil else { return nil }
        let shown = pages.filter { !$0.address.isEmpty }
        let latestAddress = latest.flatMap { tabs[$0]?.address } ?? ""
        return BrowserPreviewPreferences(
            address: latestAddress.isEmpty ? shown.last?.address ?? "" : latestAddress,
            tabs: shown.count > 1 ? shown.map(\.address) : nil,
            selectedTab: shown.count > 1 ? shown.firstIndex { $0.key == latest } ?? 0 : nil,
            pages: pages.isEmpty ? nil : pages,
            visited: visited)
    }

    // MARK: The build without the browser engine

    /// The WebKit page of tab `key`, made at its saved address the first time it shows.
    func preview(for key: UUID) -> BrowserPreviewModel {
        if let preview = previews[key] { return preview }
        let preview = BrowserPreviewModel(preferences: .init(address: tabs[key]?.address ?? ""))
        preview.onChange = { [weak self, weak preview] in
            guard let self, let preview else { return }
            self.update(key, address: preview.address, title: preview.title, favicon: nil, isLoading: preview.isLoading)
        }
        previews[key] = preview
        return preview
    }

    func terminateForApplicationShutdown() {
        for preview in previews.values { preview.terminateForApplicationShutdown() }
    }
}

extension BrowserPreviewPreferences {
    /// The pages of a task saved before each browser tab was a side-panel tab of its own, as
    /// side-panel tabs with new keys, and which was in front.
    var legacyPages: (pages: [BrowserTabPage], fronted: Int) {
        let addresses = tabs.flatMap { $0.isEmpty ? nil : $0 } ?? [address]
        let pages = addresses.map { BrowserTabPage(key: UUID(), address: $0, title: "") }
        return (pages, min(max(0, selectedTab ?? 0), max(0, pages.count - 1)))
    }
}
