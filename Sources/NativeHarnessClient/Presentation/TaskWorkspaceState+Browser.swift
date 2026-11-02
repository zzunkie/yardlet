import Foundation

/// The browser engine a task's side-panel browser tabs open in, and what the side panel knows of it.
@MainActor
final class BrowserPanelLink {
    let client: BrowserHostClient
    /// The task (or the new-task screen) whose tabs these are.
    let session: UUID
    fileprivate var observer: UUID?
    /// The tabs the engine had open at the last look while its host ran: one gone from it since, with
    /// the host still running, was closed (by the agent, by its page) rather than lost with the host.
    fileprivate var knownOpen: Set<UUID> = []
    /// The panel is changing the engine's tabs itself (closing, opening): what the engine reports
    /// meanwhile waits for one look at the end.
    fileprivate var pauses = 0
    /// Browser tabs the person closed whose pages are asked first (`BrowserHostClient.requestClose`): each leaves
    /// the panel when the engine closes it, by the panel's own rule for a closed tab, and stays if the person
    /// stays.
    fileprivate var closing: Set<UUID> = []

    init(client: BrowserHostClient, session: UUID) {
        self.client = client
        self.session = session
    }
}

/// Each of a task's browser tabs is a tab of its side panel, as in the Codex app (docs/BROWSER_HOST.md, section 3, "Tabs"):
/// the panel's browser tabs and the browser engine's tabs for the task are the same tabs, by key
/// (`BrowserTab.key`). A tab the agent or a page opens joins the panel; one they close leaves it; the
/// tab the panel shows is the engine's tab in front, and one the engine fronts (the agent's
/// `browser_tab_select`, a page opening a tab in front) shows in a panel that shows a browser tab. A
/// panel tab the engine has not opened yet (a new tab, or one saved before Yardlet restarted) opens
/// when its pane shows it (`openBrowserTab(_:viewport:)`).
extension TaskWorkspaceState {
    private typealias Navigation = TaskSurfaceNavigationProjection

    /// Follows the engine's tabs for `session` from now on. Tabs saved with the task before Yardlet
    /// restarted are handed to the engine to open again together, so the agent's first browser call
    /// finds the tabs the panel shows.
    func attachBrowser(_ client: BrowserHostClient, session: UUID) {
        guard browserLink == nil else { return }
        let link = BrowserPanelLink(client: client, session: session)
        browserLink = link
        link.observer = client.addTabsObserver(forSession: session) { [weak self] in self?.syncBrowserTabs() }
        rememberSavedBrowserTabs()
        syncBrowserTabs()
    }

    func detachBrowser() {
        guard let link = browserLink else { return }
        if let observer = link.observer { link.client.removeTabsObserver(observer, forSession: link.session) }
        browserLink = nil
    }

    /// The panel's browser tabs whose pages were saved, for the engine to open again together when the
    /// task has none open and none lost with the host: the one shown loads, the others with their titles
    /// and icons wait to be shown (`BrowserHostClient.restoreTabs`).
    func rememberSavedBrowserTabs() {
        guard let link = browserLink, link.client.tabs(forSession: link.session).isEmpty,
              link.client.rememberedTabs(forSession: link.session) == nil else { return }
        let saved = Navigation.browserKeys(in: panels).compactMap { key -> (key: UUID, tab: TaskBrowserTabs.Tab)? in
            guard let tab = browserTabs.tab(key), !tab.address.isEmpty else { return nil }
            return (key, tab)
        }
        guard !saved.isEmpty else { return }
        let latest = Navigation.browserKey(inTab: Navigation.latestBrowserTab(in: panels))
        link.client.rememberTabs(BrowserRememberedTabs(addresses: saved.map { $0.tab.address }, keys: saved.map { $0.key },
                                                       titles: saved.map { $0.tab.title }, favicons: saved.map { $0.tab.favicon },
                                                       fronted: saved.firstIndex { $0.key == latest } ?? 0),
                                 forSession: link.session)
    }

    /// Brings the panel's browser tabs in line with the engine's: tabs it opened join, tabs it closed
    /// leave, each tab's page, title, icon and loading are recorded, and the tab it fronts shows where
    /// the panel shows a browser tab.
    func syncBrowserTabs() {
        guard let link = browserLink, link.pauses == 0 else { return }
        let client = link.client
        let open = client.tabs(forSession: link.session)
        var next = panels
        var previous: UUID?
        let agentTab = client.agentUsedTab(forSession: link.session)
        for tab in open {
            next = Navigation.addingBrowserTab(tab.key, after: previous, in: next)
            previous = tab.key
            browserTabs.update(tab.key, address: tab.lastPageURL, title: tab.title, favicon: tab.favicon,
                               isLoading: tab.isLoading, isDiscarded: tab.isDiscarded)
            browserTabs.mark(tab.key, wait: client.personWait(of: tab), site: tab.currentURL.flatMap { URL(string: $0)?.host() },
                             isAgentUsing: tab === agentTab)
        }
        let openKeys = Set(open.map(\.key))
        if client.isHostRunning {
            let lostWithHost = Set(client.rememberedTabs(forSession: link.session)?.keys ?? [])
            let closed = link.knownOpen.subtracting(openKeys).subtracting(lostWithHost)
            if !closed.isEmpty {
                let shownClosed = Navigation.browserKey(inTab: next.trailingSurfaceID).map(closed.contains) ?? false
                let closedByPerson = !closed.isDisjoint(with: link.closing)
                next = Navigation.closingTrailingTabs(closed.map(Navigation.browserTabID), in: next)
                browserTabs.remove(closed)
                if shownClosed, closedByPerson {
                    // The person's close: the panel went to the tab used before, as for any tab, and the engine follows.
                    showInEngine(Navigation.browserKey(inTab: next.trailingSurfaceID), link: link)
                } else if shownClosed, let fronted = client.tab(forSession: link.session),
                   next.trailingTabs.contains(Navigation.browserTabID(fronted.key)) {
                    // The panel goes where the engine went: the tab it fronted in the closed one's place.
                    next = Navigation.showing(Navigation.browserTabID(fronted.key), in: next)
                }
            }
            link.knownOpen = openKeys
            // A tab the person stays on is no longer closing.
            link.closing = link.closing.filter { key in open.contains { $0.key == key && $0.isClosing } }
            // A page asks before the person's close goes on ("Leave site?"): its tab shows to ask, as Chrome brings
            // that tab forward, unless the tab shown asks too.
            let shown = Navigation.browserKey(inTab: next.trailingSurfaceID)
            if let asking = open.first(where: { $0.closeQuestion != nil }),
               open.first(where: { $0.key == shown })?.closeQuestion == nil {
                next = Navigation.showing(Navigation.browserTabID(asking.key), in: next)
                showInEngine(asking.key, link: link)
            }
        } else {
            // Tabs lost with the host stay as the panel's tabs, to open again; tabs the person was closing go.
            link.knownOpen = []
            if !link.closing.isEmpty {
                next = Navigation.closingTrailingTabs(link.closing.map(Navigation.browserTabID), in: next)
                browserTabs.remove(link.closing)
                link.closing = []
            }
        }
        if let fronted = client.tab(forSession: link.session) {
            // A shown tab the engine has not opened yet keeps the panel until its pane opens it.
            let shown = Navigation.browserKey(inTab: next.trailingSurfaceID)
            if shown.map(openKeys.contains) ?? true {
                next = Navigation.frontingBrowserTab(fronted.key, in: next)
            }
        }
        setPanels(next)
    }

    /// Fronts the engine's tab for `key` while the panel is changing itself.
    private func showInEngine(_ key: UUID?, link: BrowserPanelLink) {
        guard let key, let tab = link.client.tab(key: key, forSession: link.session) else { return }
        link.pauses += 1
        link.client.show(tab)
        link.pauses -= 1
    }

    /// Tells the engine which tab the panel shows, when it has that tab open.
    func frontShownBrowserTab() {
        guard let link = browserLink, let key = Navigation.browserKey(inTab: panels.trailingSurfaceID),
              let tab = link.client.tab(key: key, forSession: link.session) else { return }
        link.client.show(tab)
    }

    // MARK: Opening and closing

    /// A new browser tab in the side panel, shown, at the end or right after the tab `after` (the tab
    /// menu's New Tab to the Right and Duplicate), at `address` or blank. The engine opens it when its
    /// pane shows it. The launcher's and the + menu's Browser, and `⌘T` on a page, open one.
    /// Nil when the task has `BrowserHostClient.maxTabsPerSession` browser tabs already.
    @discardableResult
    func openBrowserTab(after: String? = nil, address: String? = nil) -> UUID? {
        guard Navigation.browserKeys(in: panels).count < BrowserHostClient.maxTabsPerSession else { return nil }
        let key = UUID()
        if let address { browserTabs.setAddress(address, for: key) }
        setPanels(Navigation.showingNewBrowserTab(key, after: after, in: panels))
        return key
    }

    /// A web address in a new browser tab of the task, shown, with the panel open: a link from the
    /// conversation. False when the task has `BrowserHostClient.maxTabsPerSession` browser tabs already.
    @discardableResult
    func openBrowserPage(_ url: URL) -> Bool {
        guard let key = openBrowserTab(address: url.absoluteString) else { return false }
        // Without the engine the tab is a WebKit preview, which loads its address when told to.
        if browserClient == nil { browserTabs.preview(for: key).navigate() }
        return true
    }

    /// One of the task's servers (`localhost:<port>`) in its browser, with the panel open: the tab
    /// already on that server shows, else a new tab opens at it. False when a new tab has no room.
    @discardableResult
    func showServer(_ server: TaskServerPort) -> Bool {
        let shown = Navigation.browserKeys(in: panels).first {
            Self.address(browserTabAddress($0), isLocalhostPort: server.port)
        }
        guard let shown else { return openBrowserPage(server.url) }
        setPanels(Navigation.showing(Navigation.browserTabID(shown), in: panels))
        return true
    }

    /// Whether a page's address is on this Mac's `port` (localhost, 127.0.0.1, [::1]).
    static func address(_ address: String?, isLocalhostPort port: Int) -> Bool {
        guard let address, let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"].contains(host) else { return false }
        return (components.port ?? (scheme == "https" ? 443 : 80)) == port
    }

    /// The page the panel's browser tab `key` needs: the engine's tab, opened now if the engine has none
    /// for it. Tabs lost with the host or saved before Yardlet restarted open again together first,
    /// so the agent sees the tabs the panel shows; a new tab opens at its address, or blank, after the
    /// panel's browser tab before it. Nil without the engine.
    @discardableResult
    func openBrowserEngineTab(_ key: UUID, viewport: BrowserViewport) throws -> BrowserTab? {
        guard let link = browserLink else { return nil }
        let client = link.client
        link.pauses += 1
        defer {
            link.pauses -= 1
            frontShownBrowserTab()
            syncBrowserTabs()
        }
        if let tab = client.tab(key: key, forSession: link.session) { return tab }
        if client.tabs(forSession: link.session).isEmpty {
            rememberSavedBrowserTabs()
            if client.rememberedTabs(forSession: link.session) != nil {
                // The tab the panel shows is the one that loads.
                try client.restoreTabs(forSession: link.session, viewport: viewport, fronting: key)
            }
            if let tab = client.tab(key: key, forSession: link.session) {
                client.show(tab)
                return tab
            }
        }
        let keys = Navigation.browserKeys(in: panels)
        let before = keys.firstIndex(of: key).map { keys[..<$0] } ?? []
        let after = before.reversed().lazy.compactMap { client.tab(key: $0, forSession: link.session) }.first
        let address = browserTabs.tab(key)?.address ?? ""
        return try client.newTab(forSession: link.session, url: address.isEmpty ? "about:blank" : address,
                                 viewport: viewport, select: true, key: key, after: after)
    }

    /// Closes side-panel tabs, a tab's menu's Close Other Tabs and Close Tabs to the Right among them: the
    /// panel moves to the tab used before (hiding after its last tab, as for one tab), and a browser
    /// tab's page closes with its tab. A page open in the engine is asked first, as Chrome asks when a person
    /// closes a tab: its tab leaves once the engine closes it (`syncBrowserTabs`), or stays if the person stays
    /// on a page that asks "Leave site?". Before 2026-10-25 the tab left the panel at once and the host answered
    /// the page itself.
    func closeSidePanelTabs(_ ids: [String]) {
        let keys = ids.compactMap { Navigation.browserKey(inTab: $0) }
        guard let link = browserLink, !keys.isEmpty else {
            setPanels(Navigation.closingTrailingTabs(ids, in: panels))
            browserTabs.remove(keys)
            return
        }
        let asking = keys.compactMap { link.client.tab(key: $0, forSession: link.session) }
        let askingKeys = Set(asking.map(\.key))
        link.pauses += 1
        setPanels(Navigation.closingTrailingTabs(ids.filter { Navigation.browserKey(inTab: $0).map { !askingKeys.contains($0) } ?? true },
                                                  in: panels))
        browserTabs.remove(keys.filter { !askingKeys.contains($0) })
        link.closing.formUnion(askingKeys)
        for tab in asking { link.client.requestClose(tab) }
        // The panel chose the tab to show by its own rule (the tab used before); the engine follows it
        // rather than fronting the closed tab's neighbor.
        frontShownBrowserTab()
        link.pauses -= 1
        syncBrowserTabs()
    }

    /// The tab menu's Reload.
    func reloadBrowserTab(_ key: UUID) {
        guard let link = browserLink, let tab = link.client.tab(key: key, forSession: link.session) else { return }
        tab.send(.navigation(tab: tab.id, action: .reload))
    }

    /// The tab menu's Duplicate: a new tab at the page, right after it.
    @discardableResult
    func duplicateBrowserTab(_ key: UUID) -> UUID? {
        let open = browserLink.flatMap { $0.client.tab(key: key, forSession: $0.session) }
        let address = open?.lastPageURL ?? browserTabs.tab(key)?.address ?? ""
        return openBrowserTab(after: Navigation.browserTabID(key), address: address.isEmpty ? nil : address)
    }

    /// What the tab menu shows of browser tab `key`: the page it shows, or showed before Yardlet restarted.
    func browserTabAddress(_ key: UUID) -> String? {
        browserLink.flatMap { $0.client.tab(key: key, forSession: $0.session)?.currentURL } ?? browserTabs.tab(key)?.address
    }

    /// The engine has the tab open, so it can reload.
    func isBrowserTabOpen(_ key: UUID) -> Bool {
        browserLink.map { $0.client.tab(key: key, forSession: $0.session) != nil } ?? false
    }

    /// `⌘⇧T` on a page: the task's most recently closed browser tab opens again, in front, and the
    /// panel shows it.
    func reopenClosedBrowserTab(viewport: BrowserViewport) throws {
        guard let link = browserLink else { return }
        _ = try link.client.reopenClosedTab(forSession: link.session, viewport: viewport)
    }
}
