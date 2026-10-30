import Foundation
import YardletAgentTools

/// A task's tab as the tab tools report it.
struct BrowserAgentTabInfo: Equatable, Sendable {
    /// The id the other browser tools take as `tabId`.
    var id: String
    /// Where the page is from: scheme, host and port only, since titles and paths are the page's own
    /// words (the Claude app's `tabs_context` lists origins for the same reason).
    var origin: String
    /// The agent's active tab: the one the tools use when they name none (`BrowserHostClient.agentTab(forSession:)`),
    /// which is the one the panel shows unless the person kept the panel on theirs.
    var isActive: Bool
    /// The task's panel shows it on screen.
    var isShown = false
    /// The person is using it in the panel (`BrowserHostClient.personUse(of:)`).
    var personUse: BrowserPersonUse?
    /// False while the tab's page does not respond (`BrowserTab.unresponsive`), its renderer ended, or the
    /// host could not open it.
    var isResponding = true
    /// The error code of the tab's renderer that ended (`BrowserTabCrash.errorCode`).
    var crash: String?
    /// Why the host could not open the tab (`BrowserTab.openFailure`).
    var openFailure: String?
}

/// The task's tabs, for the tab tools and for a tool that names a tab.
@MainActor
protocol BrowserAgentTabDirectory: AnyObject {
    /// The page of the task's tab `tabID`, or of the agent's active tab when `tabID` is nil (opening one when
    /// the task has none). Reports agent use of the tab.
    func page(for sessionID: UUID, tabID: String?) throws -> BrowserAgentPage
    /// The id of the task's tab that `tabID` names now: that tab while it is open, or the tab opened again in its place
    /// as the same side-panel tab (its page stopped responding or could not open, or the browser host ended), with a
    /// sentence saying so. Any other id throws, saying what became of that tab and listing the task's tabs.
    func resolve(_ tabID: String, for sessionID: UUID) throws -> (id: String, note: String?)
    func tabs(for sessionID: UUID) throws -> (tabs: [BrowserAgentTabInfo], panelOpen: Bool)
    /// A blank tab after the task's others; `foreground` makes it the agent's active tab, which the panel shows unless
    /// the person is using another tab there.
    func newTab(for sessionID: UUID, foreground: Bool) throws -> BrowserAgentTabInfo
    /// Makes the tab the agent's active tab, which the panel shows unless the person is using another tab there, and
    /// returns it.
    func select(_ tabID: String, for sessionID: UUID) throws -> BrowserAgentTabInfo
    /// The task's tab the person is using in its panel, if any.
    func personTab(for sessionID: UUID) -> BrowserAgentTabInfo?
    /// Closes the tab and returns it as it was, and the agent's active tab now, if any.
    func close(_ tabID: String, for sessionID: UUID) throws -> (closed: BrowserAgentTabInfo, active: BrowserAgentTabInfo?)
    /// The task was archived or deleted: its tabs close.
    func closeAll(for sessionID: UUID)
    /// A tab whose page does not respond, opened again in its place under the same side-panel tab
    /// (`BrowserHostClient.replace`); returns the new tab's page.
    func replace(_ tabID: String, for sessionID: UUID) throws -> BrowserAgentPage
    /// Chromium's own windows over the task's tabs (the passkey dialog, a site's sign-in window), and those whose tab
    /// is not known (the print dialog), which may be any task's; another task's windows are in neither.
    func browserDialogs(for sessionID: UUID) -> (own: [BrowserChromiumWindow], unknownTab: [BrowserChromiumWindow])
    /// Closes the task's own as Escape would: a passkey request ends with NotAllowedError, a sign-in is cancelled.
    func closeBrowserDialogs(for sessionID: UUID) -> Bool
    /// The task's turn ended: the screen sizes and color schemes the agent set on its tabs go, and its handoffs end.
    func endAgentEmulation(for sessionID: UUID) async
}

/// The agent's side of each task's browser tabs. The host keeps the task's tabs, which the task's
/// panel shows and these tools drive: the first tool call opens the task's tab in the background (no
/// panel opens), and every call reports agent activity so the host shows the tab it uses to its
/// engine while the agent works. The tools follow each tab's events through an observer, since the
/// panel owns the fronted tab's event handler.
@MainActor
final class BrowserAgentTabs: BrowserAgentTabDirectory {
    private struct Entry {
        let tab: BrowserTab
        let page: BrowserAgentPage
        let observer: UUID
    }

    private let client: @MainActor () -> BrowserHostClient?
    private let unavailableReason: String
    private var entries: [BrowserTabID: Entry] = [:]
    /// Called before a tool reaches the task's tabs: the app loads the task's side panel, which hands
    /// the tabs it saved before Yardlet restarted to the engine to open again, so the agent and the
    /// panel have the same tabs.
    var prepareSession: (@MainActor (UUID) -> Void)?

    /// `client` is nil when this build carries no browser engine.
    init(
        unavailableReason: String = "This Yardlet build has no browser engine, so the browser tools are unavailable.",
        client: @escaping @MainActor () -> BrowserHostClient?
    ) {
        self.unavailableReason = unavailableReason
        self.client = client
    }

    func page(for sessionID: UUID, tabID: String?) throws -> BrowserAgentPage {
        let client = try requireClient(for: sessionID)
        let tab = try tabID.map { try existingTab($0, for: sessionID, in: client) } ?? frontedTab(for: sessionID, in: client)
        let page = entry(for: tab).page
        tab.noteAgentActivity()
        return page
    }

    func resolve(_ tabID: String, for sessionID: UUID) throws -> (id: String, note: String?) {
        let client = try requireClient(for: sessionID)
        try restoreLostTabs(for: sessionID, in: client)
        if client.tabs(forSession: sessionID).contains(where: { String($0.id) == tabID }) { return (tabID, nil) }
        if let went = BrowserTabID(tabID).flatMap(client.departure(of:)), went.session == sessionID,
           case .reopened(let key, let cause) = went.departure, let tab = client.tab(key: key, forSession: sessionID) {
            return (String(tab.id), "Tab \(tabID) is now tab \(tab.id): \(Self.describe(cause)), and it was opened again in its "
                + "place as the same tab of the task's browser panel. Calls that name tab \(tabID) go to tab \(tab.id).")
        }
        throw missing(tabID, for: sessionID, in: client)
    }

    func tabs(for sessionID: UUID) throws -> (tabs: [BrowserAgentTabInfo], panelOpen: Bool) {
        let client = try requireClient(for: sessionID)
        try restoreLostTabs(for: sessionID, in: client)
        let active = client.agentTab(forSession: sessionID)
        let tabs = client.tabs(forSession: sessionID)
        return (tabs.map { info($0, active: active, in: client) }, tabs.contains { $0.isPanelAttached })
    }

    func newTab(for sessionID: UUID, foreground: Bool) throws -> BrowserAgentTabInfo {
        let client = try requireClient(for: sessionID)
        // A task whose tabs were lost with the host gets them back first, so the new tab goes after them.
        try restoreLostTabs(for: sessionID, in: client)
        let tab = try start {
            try client.newTab(forSession: sessionID, url: "about:blank", viewport: .offscreenDefault, select: false, byAgent: true)
        }
        if foreground { client.selectForAgent(tab) }
        _ = entry(for: tab)
        tab.noteAgentActivity()
        return info(tab, active: client.agentTab(forSession: sessionID), in: client)
    }

    func select(_ tabID: String, for sessionID: UUID) throws -> BrowserAgentTabInfo {
        let client = try requireClient(for: sessionID)
        let tab = try existingTab(tabID, for: sessionID, in: client)
        client.selectForAgent(tab)
        tab.noteAgentActivity()
        return info(tab, active: client.agentTab(forSession: sessionID), in: client)
    }

    func personTab(for sessionID: UUID) -> BrowserAgentTabInfo? {
        guard let client = client(), let tab = client.personUsedTab(forSession: sessionID) else { return nil }
        return info(tab, active: client.agentTab(forSession: sessionID), in: client)
    }

    func close(_ tabID: String, for sessionID: UUID) throws -> (closed: BrowserAgentTabInfo, active: BrowserAgentTabInfo?) {
        let client = try requireClient(for: sessionID)
        let tab = try existingTab(tabID, for: sessionID, in: client)
        let closed = info(tab, active: client.agentTab(forSession: sessionID), in: client)
        forget(tab.id)
        client.closeTab(tab, as: .closedByAgent)
        return (closed, client.agentTab(forSession: sessionID).map { info($0, active: $0, in: client) })
    }

    func replace(_ tabID: String, for sessionID: UUID) throws -> BrowserAgentPage {
        let client = try requireClient(for: sessionID)
        let tab = try existingTab(tabID, for: sessionID, in: client)
        forget(tab.id)
        let replacement = try start { try client.replace(tab, url: "about:blank") }
        let page = entry(for: replacement).page
        replacement.noteAgentActivity()
        return page
    }

    func closeAll(for sessionID: UUID) {
        guard let client = client() else { return }
        for tab in client.tabs(forSession: sessionID) { forget(tab.id) }
        client.closeTabs(forSession: sessionID)
    }

    func browserDialogs(for sessionID: UUID) -> (own: [BrowserChromiumWindow], unknownTab: [BrowserChromiumWindow]) {
        guard let client = client() else { return ([], []) }
        return (client.chromiumWindows(forSession: sessionID), client.chromiumWindows.filter { $0.tab == nil })
    }

    func closeBrowserDialogs(for sessionID: UUID) -> Bool {
        client()?.closeChromiumWindows(forSession: sessionID) ?? false
    }

    func endAgentEmulation(for sessionID: UUID) async {
        client()?.endAgentTurn(forSession: sessionID)
        for tab in client()?.tabs(forSession: sessionID) ?? [] { await tab.endAgentEmulation() }
    }

    // MARK: Internals

    private func requireClient(for sessionID: UUID) throws -> BrowserHostClient {
        guard let client = client() else { throw BrowserAgentToolError(unavailableReason) }
        prepareSession?(sessionID)
        return client
    }

    /// The agent's active tab; when the task has none, the tabs it lost with the host, else a blank tab.
    private func frontedTab(for sessionID: UUID, in client: BrowserHostClient) throws -> BrowserTab {
        if let tab = client.agentTab(forSession: sessionID) { return tab }
        return try start {
            try client.restoreTabs(forSession: sessionID, viewport: .offscreenDefault)
                ?? client.openTab(forSession: sessionID, url: "about:blank", viewport: .offscreenDefault, byAgent: true)
        }
    }

    private func existingTab(_ tabID: String, for sessionID: UUID, in client: BrowserHostClient) throws -> BrowserTab {
        guard let tab = client.tabs(forSession: sessionID).first(where: { String($0.id) == tabID }) else {
            throw missing(tabID, for: sessionID, in: client)
        }
        return tab
    }

    /// The panel's tabs saved before a restart or lost with the host are the task's tabs: they open again, so their
    /// ids are ones the other tools take, and a tool that names one of their old ids reaches it (`resolve`).
    private func restoreLostTabs(for sessionID: UUID, in client: BrowserHostClient) throws {
        guard client.tabs(forSession: sessionID).isEmpty, client.rememberedTabs(forSession: sessionID) != nil else { return }
        _ = try start { try client.restoreTabs(forSession: sessionID, viewport: .offscreenDefault) }
    }

    /// Why the task has no tab `tabID` (`BrowserHostClient.departure(of:)`), and the tabs it has.
    private func missing(_ tabID: String, for sessionID: UUID, in client: BrowserHostClient) -> BrowserAgentToolError {
        let went = BrowserTabID(tabID).flatMap(client.departure(of:)).flatMap { $0.session == sessionID ? $0.departure : nil }
        let why: String = switch went {
        case .reopened(_, let cause)?:
            "Tab \(tabID) went when \(Self.describe(cause)), and no tab of this task takes its place now."
        case .closedByAgent?: "Tab \(tabID) is closed: browser_tab_close closed it."
        case .closedByPerson?: "Tab \(tabID) is closed: the person closed it in the task's browser panel."
        case .closedByPage?: "Tab \(tabID) is closed: its page closed itself."
        case .closed?: "Tab \(tabID) is closed: Yardlet closed it, with the task's other tabs or once the download it was "
            + "opened for ended."
        case .moved?: "Tab \(tabID) went to another task, with its page."
        case nil: "This task has no tab \(tabID), and no tab of this task has had that id since Yardlet started."
        }
        let active = client.agentTab(forSession: sessionID)
        let open = client.tabs(forSession: sessionID)
        let tabs = open.map { tab in
            "\(tab.id) (\(Self.origin(of: tab.currentURL ?? "about:blank"))\(tab === active ? ", active" : ""))"
        }
        return BrowserAgentToolError(why + (tabs.isEmpty ? " This task has no browser tab now; browser_navigate or "
            + "browser_tab_new opens one." : " This task's tabs now: " + tabs.joined(separator: ", ") + "."),
            AgentToolFailure(.notFound, retry: .withChanges, details: [
                "tabId": .string(tabID), "tabs": .array(open.map { .string(String($0.id)) })
            ]))
    }

    /// How a tab that another took the place of went, as a clause.
    private static func describe(_ cause: BrowserTabDeparture.Cause) -> String {
        switch cause {
        case .notResponding: "its page was not responding"
        case .couldNotOpen: "it could not open"
        case .hostEnded: "the browser host ended"
        }
    }

    private func start<T>(_ open: () throws -> T) throws -> T {
        do {
            return try open()
        } catch let limit as BrowserTabLimitError {
            throw BrowserAgentToolError(limit.localizedDescription)
        } catch {
            throw BrowserAgentToolError("The browser could not start: \(error.localizedDescription)")
        }
    }

    private func entry(for tab: BrowserTab) -> Entry {
        if let entry = entries[tab.id], entry.tab === tab { return entry }
        forget(tab.id)
        entries = entries.filter { !$0.value.tab.isClosed }
        let page = BrowserAgentPage(cdp: tab.devTools, tabID: tab.id) { [weak tab] command in tab?.send(command) }
        page.unresponsive = { [weak tab] in tab?.unresponsive }
        page.rendererAnswered = { [weak tab] method in
            guard let tab else { return nil }
            return await tab.rendererAnswered(after: method)
        }
        page.crash = { [weak tab] in tab?.crash }
        page.openFailure = { [weak tab] in tab?.openFailure }
        page.viewport = { [weak tab] in tab?.viewport }
        page.emulation = { [weak tab] in tab?.emulation }
        page.emulate = { [weak tab] in try await tab?.emulate($0) }
        page.emulateColorScheme = { [weak tab] in try await tab?.emulateColorScheme($0) }
        page.tabKey = tab.key
        page.isClosed = { [weak tab] in tab?.isClosed ?? true }
        page.untilRestored = { [weak tab] in await tab?.untilRestored() }
        page.handOff = { [weak tab] in tab?.handOff(reason: $0) }
        page.handoff = { [weak tab] in tab?.handoff }
        page.endHandoff = { [weak tab] in tab?.endHandoff() }
        page.vaultFills = tab.vaultFills
        page.linkedVaultFill = { [weak self, weak tab] in tab.flatMap { self?.filledTab(linkedTo: $0)?.id } }
        page.noteScriptInLinkedTabs = { [weak self, weak tab] in
            guard let self, let tab else { return }
            for linked in self.tabs(linkedTo: tab) {
                let frame = try? await VaultPageScripts.mainFrame(linked.devTools, timeout: .seconds(5))
                linked.vaultFills.noteScript(in: frame?.loaderID ?? "")
            }
        }
        let observer = tab.addEventObserver { [weak page] event in page?.receive(event) }
        let entry = Entry(tab: tab, page: page, observer: observer)
        entries[tab.id] = entry
        return entry
    }

    /// A tab of the same task that shows a document the vault filled and that `window.opener` links to this one: the
    /// tab that opened it, the tabs it opened, and theirs in turn. Page scripts can reach such a document through the
    /// opener or a window's name when it is of their origin, or through a frame of its origin they hold.
    private func filledTab(linkedTo tab: BrowserTab) -> BrowserTab? {
        tabs(linkedTo: tab).first { $0.vaultFills.holdShownDocument(in: $0.devTools.events) }
    }

    /// The task's other tabs that `window.opener` links to this one, directly or through other tabs.
    private func tabs(linkedTo tab: BrowserTab) -> [BrowserTab] {
        guard let client = client(), let session = tab.session else { return [] }
        let tabs = client.tabs(forSession: session)
        var reached: [BrowserTab] = []
        var seen: Set<BrowserTabID> = [tab.id]
        var pending = [tab]
        while let next = pending.popLast() {
            for other in tabs where !seen.contains(other.id)
                && (next.openedTabs.contains(other.id) || other.openedTabs.contains(next.id)) {
                seen.insert(other.id)
                reached.append(other)
                pending.append(other)
            }
        }
        return reached
    }

    private func forget(_ id: BrowserTabID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.tab.removeEventObserver(entry.observer)
    }

    private func info(_ tab: BrowserTab, active: BrowserTab?, in client: BrowserHostClient) -> BrowserAgentTabInfo {
        BrowserAgentTabInfo(id: String(tab.id), origin: Self.origin(of: tab.currentURL ?? "about:blank"), isActive: tab === active,
                            isShown: tab.visiblePanelCount > 0, personUse: client.personUse(of: tab),
                            isResponding: tab.unresponsive == nil && tab.crash == nil && tab.openFailure == nil,
                            crash: tab.crash?.errorCode, openFailure: tab.openFailure?.message)
    }

    static func origin(of address: String) -> String {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased() else { return address }
        guard let host = url.host(), !host.isEmpty else {
            return scheme == "about" ? address : scheme + ":"
        }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }
}
