import Foundation

/// Owns the browser host's lifetime and routes its events to tabs.
///
/// Each task (session) has up to `maxTabsPerSession` tabs in strip order, one of them fronted: the
/// one the task's side panel last showed and the agent's browser tools use when they name no tab. Each
/// tab is a tab of the side panel (the Codex app's), which knows it by its `key`: the key outlives the
/// host, so a tab opened again after the host ended or Yardlet restarted is the same panel tab. A session tab stays until it is closed (from the
/// panel, by the agent, or for its task when the task is archived or deleted), as the Codex app keeps
/// a thread's browser pages until the thread is archived; a panel closing or the agent stopping does
/// not close it. When the last tab is gone the host waits
/// `idleGrace` (60 seconds) and ends, returning all of Chromium's memory; the next tab starts it
/// again. Tabs opened without a session (`openTab(url:viewport:)`) also stay until closed.
///
/// A session tab is shown to its engine (painting, full-speed timers) while a panel shows it, while a remote
/// device watches it, or within `agentVisibleWindow` of the agent's last use (or of opening); otherwise it is
/// hidden, so an unwatched page stops painting and its timers slow down, as the Codex app throttles a page nobody
/// sees.
///
/// Tabs lost with the host (a crash, or the host ending as Yardlet quits) leave their last addresses
/// behind (`rememberedTabs(forSession:)`), and the panel and the agent's tools open them again
/// (`restoreTabs(forSession:viewport:)`). Closing a task's tabs for the task forgets them.
@MainActor
final class BrowserHostClient {
    typealias Launcher = @MainActor () throws -> any BrowserHostConnection

    let idleGrace: Duration
    let agentVisibleWindow: Duration
    let shutdownTimeout: Duration
    /// How long after the person's last click, key, scroll or drag in a tab shown on screen they are taken as still
    /// using it (`personUse(of:)`): long enough for a pause while reading between scrolls. QA shortens it.
    var personUseWindow: Duration
    private let launcher: Launcher
    private var connection: (any BrowserHostConnection)?
    /// Yardlet asked the running host to end (`shutdown`); it closes every tab on its way out.
    private var isHostEnding = false
    private var tabs: [BrowserTabID: BrowserTab] = [:]
    private var nextTabID = 1
    private var idleTask: Task<Void, Never>?
    private var retentionTask: Task<Void, Never>?
    /// Each session's tabs in strip order, and its fronted tab.
    private var sessionOrder: [UUID: [BrowserTabID]] = [:]
    private var frontedTabs: [UUID: BrowserTabID] = [:]
    /// The tab each session's agent works in where it is not the tab in front: the agent chose it while the person
    /// was using the panel's tab, or the person showed another tab while the agent worked in the one in front. Tools
    /// that name no tab use it (`agentTab(forSession:)`). The turn's end, the tab closing, or the panel coming to show
    /// it lets it go.
    private var agentFronts: [UUID: BrowserTabID] = [:]
    /// The tab the session's agent used last in its turn, until the turn ends or the tab closes.
    private var agentUsedTabs: [UUID: BrowserTabID] = [:]
    /// Each session's tabs as they were when the host ended, to open again.
    private var remembered: [UUID: BrowserRememberedTabs] = [:]
    /// Addresses of each session's recently closed tabs, newest last.
    private var closedAddresses: [UUID: [String]] = [:]
    /// How each session tab that went went (`departure(of:)`).
    private var departures: [BrowserTabID: (session: UUID, departure: BrowserTabDeparture)] = [:]
    /// Whether an address or a title carries a value the vault filled lately (`VaultScrubList.carries`). A tab keeps
    /// such a page out of what it remembers: the page its task saves and opens again, a closed tab's, and the one
    /// opened again after the host ended.
    var carriesFilledValue: (String) -> Bool = { _ in false }
    private var sessionObservers: [UUID: [UUID: () -> Void]] = [:]
    /// Cookie imports waiting for the host's `cookiesImported`.
    private var cookieImports: [Int: CheckedContinuation<Int, Never>] = [:]
    private var nextCookieImport = 1

    /// The most tabs one task keeps, as the Claude app's Browser pane (⌘1…⌘9 reach all of them).
    nonisolated static let maxTabsPerSession = 9

    private(set) var launchCount = 0
    private(set) var hostProcessID: Int?
    private(set) var hostEngine: String?
    private(set) var acceleratedPaint: Bool?
    private(set) var lastTermination: String?
    /// Chromium's own windows in the host (the passkey dialog, a site's sign-in window, the print dialog), each with
    /// the tab it is over when the host knows it; empty when none is open.
    private(set) var chromiumWindows: [BrowserChromiumWindow] = []
    var chromiumWindowTitles: [String] { chromiumWindows.map(\.title) }
    /// Called after the windows or their tabs changed, for placing them over their tabs.
    var onChromiumWindowsChange: (() -> Void)?
    /// What opens other apps' addresses a page asks for (LaunchServices on macOS).
    var externalApps: any BrowserExternalApps = NoExternalApps()
    /// Called on every host start and exit, for status displays and measurements.
    var onHostStateChange: ((_ isRunning: Bool) -> Void)?
    /// Called when the agent uses a session's tab, for the rail's preview of what it drives.
    var onAgentActivity: ((_ session: UUID, _ tab: BrowserTabID) -> Void)?
    /// Called when a tab goes away: closed, or lost with the host.
    var onTabClosed: ((BrowserTabID) -> Void)?
    /// The address field's history, which every tab's pages and titles go to (`noteHistory`).
    var addressHistory: BrowserAddressHistory?
    /// Called whenever what a tab waits on from the person changes (`personWait(of:)`), for the task's marks and
    /// notification.
    var onPersonWaitsChange: (() -> Void)?
    /// Called with every event a tab receives, after the tab and its panel have it.
    var onTabEvent: ((BrowserTab, BrowserHostEvent) -> Void)?

    init(
        idleGrace: Duration = .seconds(60),
        agentVisibleWindow: Duration = .seconds(60),
        shutdownTimeout: Duration = .seconds(5),
        personUseWindow: Duration = .seconds(30),
        launcher: @escaping Launcher
    ) {
        self.idleGrace = idleGrace
        self.agentVisibleWindow = agentVisibleWindow
        self.shutdownTimeout = shutdownTimeout
        self.personUseWindow = personUseWindow
        self.launcher = launcher
    }

    var isHostRunning: Bool { connection != nil }
    /// The profile a session's tabs open in (`BrowserTaskProfiles`); nil, or no provider, is the default profile.
    var profileForSession: (@MainActor (UUID) -> BrowserTabProfile?)?
    /// The profile a session's tab opens with (`BrowserTaskProfiles.opening`, where a child task's first tab decides
    /// its profile); `profileForSession` when nil.
    var openingProfileForSession: (@MainActor (UUID) -> BrowserTabProfile?)?
    /// The host ended (idle, quit or crashed): the moment no profile folder is open.
    var onHostEnded: (@MainActor () -> Void)?

    /// The sessions with tabs in the host, whose profiles are open there.
    var sessionsWithTabs: [UUID] {
        sessionOrder.filter { !$0.value.isEmpty }.map(\.key)
    }

    /// Brings the person's sign-ins for `sites` over from another browser (`BrowserLoginImport`): each profile (a key;
    /// nil for the default profile) loses its cookies of those sites and takes `cookies`, one
    /// profile after another. What each set, as `cookiesImported` counts them; -1 for one the host did not answer
    /// within `timeout`. Starts the host when it is not running.
    func importCookies(_ cookies: [BrowserImportedCookie], sites: [String], into profiles: [String?],
                       timeout: Duration = .seconds(15)) async throws -> [Int] {
        var counts: [Int] = []
        for profile in profiles {
            let connection = try currentConnection()
            let request = nextCookieImport
            nextCookieImport += 1
            let count = await withCheckedContinuation { continuation in
                cookieImports[request] = continuation
                connection.send(.importCookies(request: request, to: profile, sites: sites, cookies: cookies))
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.cookieImports.removeValue(forKey: request)?.resume(returning: -1)
                }
            }
            counts.append(count)
        }
        if tabs.isEmpty { scheduleIdleShutdown() }
        return counts
    }
    var openTabCount: Int { tabs.count }

    // MARK: Session tabs

    /// The session's open tabs in strip order.
    func tabs(forSession session: UUID) -> [BrowserTab] {
        (sessionOrder[session] ?? []).compactMap { tabs[$0] }
    }

    /// The session's fronted tab, if the host has one: the tab its panel shows and the agent's tools
    /// use when they name none.
    func tab(forSession session: UUID) -> BrowserTab? {
        if let id = frontedTabs[session], let tab = tabs[id] { return tab }
        return tabs(forSession: session).first
    }

    /// The page the session's fronted tab last showed, also after its tabs were lost with the host.
    /// Nil for a task whose tabs showed no page or were closed for the task.
    func lastAddress(forSession session: UUID) -> String? {
        if let tab = tab(forSession: session) { return tab.lastPageURL }
        return remembered[session].map { $0.addresses[$0.fronted] }
    }

    /// The session's tabs as they were when the host ended, until they are opened again.
    func rememberedTabs(forSession session: UUID) -> BrowserRememberedTabs? {
        remembered[session]
    }

    /// The session's fronted tab, opened at `url` (starting the host) when it has none. An existing tab
    /// keeps its page; `url` is not loaded again.
    /// - Parameter byAgent: the agent's tools open the tab (`BrowserTab.openedByAgent`).
    func openTab(forSession session: UUID, url: String, viewport: BrowserViewport, byAgent: Bool = false) throws -> BrowserTab {
        if let tab = tab(forSession: session) { return tab }
        let tab = try open(url: url, viewport: viewport, session: session, key: UUID(), after: nil)
        tab.openedByAgent = byAgent
        frontedTabs[session] = tab.id
        reschedule()
        notifySession(session)
        return tab
    }

    /// Another tab for the session, after its others or right after `after`. `select` fronts it;
    /// otherwise it opens behind the fronted tab, as the Claude app's `tabs_create` does by default.
    /// - Parameter key: the side-panel tab it is; a tab opened for a panel tab that has none yet
    ///   passes that tab's key.
    /// - Parameter byAgent: the agent's tools open the tab (`BrowserTab.openedByAgent`).
    func newTab(forSession session: UUID, url: String, viewport: BrowserViewport, select: Bool,
                key: UUID = UUID(), after: BrowserTab? = nil, byAgent: Bool = false) throws -> BrowserTab {
        guard tabs(forSession: session).count < Self.maxTabsPerSession else { throw BrowserTabLimitError() }
        guard tab(key: key, forSession: session) == nil else { throw BrowserTabKeyInUseError() }
        let tab = try open(url: url, viewport: viewport, session: session, key: key,
                           after: after.flatMap { $0.session == session ? $0.id : nil })
        tab.openedByAgent = byAgent
        if select || frontedTabs[session].flatMap({ tabs[$0] }) == nil {
            keepAgentTab(inSession: session, as: tab.id)
            frontedTabs[session] = tab.id
        }
        reschedule()
        notifySession(session)
        return tab
    }

    /// The session's open tab that is the side-panel tab `key`.
    func tab(key: UUID, forSession session: UUID) -> BrowserTab? {
        tabs(forSession: session).first { $0.key == key }
    }

    /// How a session's tab went, and from which session, for a tool that names it afterwards: a tab opened again in
    /// its place is found by the side-panel tab it was (`tab(key:forSession:)`). Nil for an id no session tab had
    /// since Yardlet started, and for an open tab.
    func departure(of id: BrowserTabID) -> (session: UUID, departure: BrowserTabDeparture)? {
        departures[id]
    }

    private func noteDeparture(of tab: BrowserTab, from session: UUID, _ departure: BrowserTabDeparture) {
        departures[tab.id] = (session, departure)
        // Ids only grow, so the oldest go first.
        if departures.count > 2_000 { departures = departures.filter { $0.key > nextTabID - 1_000 } }
    }

    /// Fronts a session tab.
    func select(_ tab: BrowserTab) {
        guard let session = tab.session, tabs[tab.id] === tab, frontedTabs[session] != tab.id else { return }
        frontedTabs[session] = tab.id
        notifySession(session)
    }

    // MARK: The person's tab and the agent's

    /// The panel shows `tab` (the person chose it, or the panel follows the engine): it comes in front. An agent that
    /// worked in the tab in front during its turn keeps working there rather than following the person to the tab
    /// they show; once the panel shows the agent's own tab, the two are one again.
    func show(_ tab: BrowserTab) {
        guard let session = tab.session, tabs[tab.id] === tab else { return }
        // The memory saver's revisits, as Chrome counts a tab becoming its window's active tab; the agent's fronting
        // (`selectForAgent`) is no sign the person returns to the tab, and the panel following it finds it in front.
        if frontedTabs[session] != tab.id { tab.revisits += 1 }
        if agentFronts[session] == tab.id {
            agentFronts[session] = nil
        } else {
            keepAgentTab(inSession: session, as: tab.id)
        }
        select(tab)
    }

    /// Another tab is about to come in front: an agent that worked in the one in front this turn keeps it as its own.
    private func keepAgentTab(inSession session: UUID, as newFront: BrowserTabID) {
        guard agentFronts[session] == nil, let front = frontedTabs[session], front != newFront,
              agentUsedTabs[session] == front else { return }
        agentFronts[session] = front
    }

    /// The agent fronts a tab (`browser_tab_select`, a new tab in front). The panel shows it, as before, unless the
    /// person is using another of the task's tabs there: then the panel stays, and the tab is the agent's own
    /// (`agentTab(forSession:)`). Returns the tab the person is using when the panel stayed.
    @discardableResult
    func selectForAgent(_ tab: BrowserTab) -> BrowserTab? {
        guard let session = tab.session, tabs[tab.id] === tab else { return nil }
        if let used = personUsedTab(forSession: session), used !== tab {
            if agentFronts[session] != tab.id {
                agentFronts[session] = tab.id
                notifySession(session)
            }
            return used
        }
        agentFronts[session] = nil
        select(tab)
        return nil
    }

    /// The tab the session's agent acts on when a tool names none: its own where it has one apart from the tab in
    /// front, else the tab in front.
    func agentTab(forSession session: UUID) -> BrowserTab? {
        if let id = agentFronts[session], let tab = tabs[id], tab.session == session { return tab }
        return tab(forSession: session)
    }

    /// The tab the session's agent used last in its turn (the panel's tab strip marks it).
    func agentUsedTab(forSession session: UUID) -> BrowserTab? {
        agentUsedTabs[session].flatMap { tabs[$0] }
    }

    /// The person is using `tab`: a panel shows it on screen, and its page has their keyboard (the panel's view is
    /// the first responder of the key window) or their last click, key, scroll or drag in it came within
    /// `personUseWindow`. Nil otherwise.
    func personUse(of tab: BrowserTab, now: ContinuousClock.Instant = .now) -> BrowserPersonUse? {
        guard tabs[tab.id] === tab, tab.visiblePanelCount > 0 else { return nil }
        let recent = tab.lastPersonUse.map { now - $0 < personUseWindow } ?? false
        guard tab.hasPanelKeyboard || recent else { return nil }
        return BrowserPersonUse(hasKeyboard: tab.hasPanelKeyboard,
                                secondsSinceInput: tab.lastPersonUse.map { Int(max(0, (now - $0).components.seconds)) })
    }

    /// The session's tab the person is using in its panel, if any.
    func personUsedTab(forSession session: UUID) -> BrowserTab? {
        tabs(forSession: session).first { personUse(of: $0) != nil }
    }

    /// The panel's view has the keyboard on the tab's page, in the key window, or no longer has it.
    func setPanelKeyboard(_ hasKeyboard: Bool, on tab: BrowserTab) {
        guard tabs[tab.id] === tab else { return }
        tab.hasPanelKeyboard = hasKeyboard
    }

    /// The session's agent turn ended: its own tab and the mark on the tab it used go.
    func endAgentTurn(forSession session: UUID) {
        guard agentFronts[session] != nil || agentUsedTabs[session] != nil else { return }
        agentFronts[session] = nil
        agentUsedTabs[session] = nil
        notifySession(session)
    }

    /// Where a page's new tab goes: in front, as before, unless the person is using another of the task's tabs than
    /// the one that opened it; then behind, and the agent's when its tab opened it.
    private func opensBehind(from opener: BrowserTab, session: UUID) -> Bool {
        guard let used = personUsedTab(forSession: session), used !== opener else { return false }
        return true
    }

    // MARK: What a tab waits on from the person

    /// What `tab` waits on from the person, the most pressing first: the agent's handoff, one of Chromium's windows
    /// over it (a passkey, a site's sign-in), a permission, another app to open, a JavaScript dialog, a file chooser.
    func personWait(of tab: BrowserTab) -> BrowserPersonWait? {
        guard tabs[tab.id] === tab else { return nil }
        if let handoff = tab.handoff, handoff.answer == nil {
            return BrowserPersonWait(kind: .handoff, id: handoff.id.uuidString)
        }
        if let window = chromiumWindows.first(where: { $0.tab == tab.id && $0.kind != .print }) {
            return BrowserPersonWait(kind: window.kind == .signIn ? .signIn : .passkey, id: "window-\(window.id)")
        }
        if let prompt = tab.permissionPrompt { return BrowserPersonWait(kind: .permission, id: "permission-\(prompt.id)") }
        if let question = tab.externalAppQuestion {
            return BrowserPersonWait(kind: .externalApp, id: "app-\(question.url)")
        }
        if let dialog = tab.javaScriptDialog {
            return BrowserPersonWait(kind: .javaScriptDialog, id: "dialog-\(dialog.id)", agentLed: tab.dialogByAgent)
        }
        if let chooser = tab.fileDialog {
            return BrowserPersonWait(kind: .fileChooser, id: "file-\(chooser.id)", agentLed: tab.fileDialogByAgent)
        }
        return nil
    }

    /// What a tab waits on from the person changed: its task's panel tab and the task's marks follow.
    fileprivate func personWaitChanged(_ tab: BrowserTab) {
        if let session = tab.session { notifySession(session) }
        onPersonWaitsChange?()
    }

    /// Tabs to open again for a session with none (saved with the task before Yardlet restarted).
    func rememberTabs(_ saved: BrowserRememberedTabs, forSession session: UUID) {
        guard tabs(forSession: session).isEmpty, remembered[session] == nil, !saved.addresses.isEmpty else { return }
        var kept = saved
        kept.fronted = min(max(0, saved.fronted), saved.addresses.count - 1)
        remembered[session] = kept
    }

    /// Opens the session's tabs lost with the host again, fronting the one that was fronted, or the one `key` names.
    /// Only the fronted tab loads its page, as Chrome loads a restored tab once it is selected: the others are in the
    /// strip with their addresses, titles and icons, and load as a panel shows them or the agent uses them
    /// (`BrowserTab.pendingAddress`). Nil when the session has open tabs or nothing to restore.
    @discardableResult
    func restoreTabs(forSession session: UUID, viewport: BrowserViewport, fronting key: UUID? = nil) throws -> BrowserTab? {
        guard tabs(forSession: session).isEmpty, let saved = remembered[session] else { return nil }
        remembered[session] = nil
        let addresses = Array(saved.addresses.prefix(Self.maxTabsPerSession))
        let asked = key.flatMap { key in addresses.indices.first { saved.key(at: $0) == key } }
        let front = asked ?? (addresses.indices.contains(saved.fronted) ? saved.fronted : 0)
        var opened: [BrowserTab] = []
        for (index, address) in addresses.enumerated() {
            let tab = try open(url: address, viewport: viewport, session: session, key: saved.key(at: index), after: nil,
                               loads: index == front)
            if index != front { tab.holdUntilShown(address, title: saved.title(at: index), favicon: saved.favicon(at: index)) }
            // A restored page is no new visit.
            tab.visitedAddress = address
            opened.append(tab)
        }
        if opened.indices.contains(front) {
            frontedTabs[session] = opened[front].id
        }
        reschedule()
        notifySession(session)
        return tab(forSession: session)
    }

    /// A tab whose page does not respond, replaced by a new one at `url` under the same key, in the same
    /// place and as much in front: the side panel keeps its tab. A renderer Chromium's hang monitor holds
    /// is ended first; the new tab may still share a process with another page of the same site.
    @discardableResult
    func replace(_ tab: BrowserTab, url: String, cause: BrowserTabDeparture.Cause? = nil) throws -> BrowserTab {
        guard tabs[tab.id] === tab, let session = tab.session else { throw BrowserTabGoneError() }
        if tab.unresponsive == .hangMonitor { connection?.send(.unresponsive(tab: tab.id, action: .terminate)) }
        var order = sessionOrder[session] ?? []
        let index = order.firstIndex(of: tab.id) ?? order.count
        let wasFront = frontedTabs[session] == tab.id
        // Gone without the session hearing it as closed: the same key opens again below.
        noteDeparture(of: tab, from: session,
                      .reopened(key: tab.key, cause: cause ?? (tab.openFailure != nil ? .couldNotOpen : .notResponding)))
        tabs.removeValue(forKey: tab.id)
        connection?.send(.close(tab: tab.id))
        tab.markClosed()
        onTabClosed?(tab.id)
        order.removeAll { $0 == tab.id }
        sessionOrder[session] = order
        let replacement = try open(url: url, viewport: tab.viewport ?? .offscreenDefault, session: session, key: tab.key,
                                   after: nil, at: min(index, order.count))
        replacement.visitedAddress = tab.visitedAddress
        replacement.openedByAgent = tab.openedByAgent
        replacement.wasOnScreen = tab.wasOnScreen
        replacement.revisits = tab.revisits
        if wasFront || frontedTabs[session].flatMap({ tabs[$0] }) == nil { frontedTabs[session] = replacement.id }
        if agentFronts[session] == tab.id { agentFronts[session] = replacement.id }
        if agentUsedTabs[session] == tab.id { agentUsedTabs[session] = replacement.id }
        reschedule()
        notifySession(session)
        return replacement
    }

    /// The session's tabs open again in their places, each at its page, in the profile the session's tabs take now: a
    /// task took a profile of its own before its agent's sign-in, and a tab's profile is fixed once it opens. A
    /// restored tab that has not loaded opens in it when it does.
    func reopenTabs(forSession session: UUID, cause: BrowserTabDeparture.Cause) {
        for tab in tabs(forSession: session) where tab.pendingAddress == nil {
            _ = try? replace(tab, url: tab.currentURL ?? "about:blank", cause: cause)
        }
    }

    /// "Wait" for a page that does not respond: Chromium's hang monitor waits another 15 seconds and
    /// says so again if it still does not; a page that did not answer the agent is taken as answering
    /// until it misses another call.
    func waitForPage(_ tab: BrowserTab) {
        guard tabs[tab.id] === tab, tab.unresponsive != nil else { return }
        if tab.hangReported { connection?.send(.unresponsive(tab: tab.id, action: .wait)) }
        let deadline = ContinuousClock.now + Self.unresponsiveWait
        tab.wait(until: deadline)
        guard let session = tab.session else { return }
        notifySession(session)
        // Still not handling input once the wait is over: it says so again.
        Task { @MainActor [weak self, weak tab] in
            try? await Task.sleep(until: deadline + .milliseconds(50), clock: .continuous)
            guard let self, let tab, self.tabs[tab.id] === tab, tab.unresponsive != nil else { return }
            self.notifySession(session)
        }
    }

    /// How long Wait waits before a renderer that still does not handle input shows again (Chromium's
    /// hang monitor timeout).
    nonisolated static let unresponsiveWait: Duration = .seconds(15)

    /// How long the renderer has to answer the check after a late call (`BrowserTab.devToolsTimedOut`): it answers
    /// at once unless its main thread is busy. Tests shorten it.
    var rendererCheckWait: Duration = .seconds(5)

    /// The page of a session tab did not answer a DevTools call that needs its renderer.
    fileprivate func pageDidNotAnswer(_ tab: BrowserTab) {
        if let session = tab.session { notifySession(session) }
    }

    /// Opens the session's most recently closed tab again, fronted, as a new side-panel tab. Nil when
    /// none was closed.
    func reopenClosedTab(forSession session: UUID, viewport: BrowserViewport) throws -> BrowserTab? {
        guard let address = closedAddresses[session]?.last else { return nil }
        let tab = try newTab(forSession: session, url: address, viewport: viewport, select: true)
        closedAddresses[session]?.removeLast()
        return tab
    }

    /// Gives a session tab to another task, page and all: the tab leaves its strip as if it had never
    /// been there (no reopen entry) and joins the end of `target`'s, in front when `select` or when
    /// `target` has no tab in front. Nothing is sent to the host; the page goes on as it was. The new-task
    /// screen's tabs move this way to the task it starts, as the Codex app's thread takes over its
    /// draft's tabs.
    func move(_ tab: BrowserTab, toSession target: UUID, select: Bool) throws {
        guard tabs[tab.id] === tab, let source = tab.session, source != target else { return }
        guard tabs(forSession: target).count < Self.maxTabsPerSession else { throw BrowserTabLimitError() }
        var order = sessionOrder[source] ?? []
        if let index = order.firstIndex(of: tab.id) {
            order.remove(at: index)
            if frontedTabs[source] == tab.id {
                frontedTabs[source] = order.isEmpty ? nil : order[min(index, order.count - 1)]
            }
        }
        sessionOrder[source] = order.isEmpty ? nil : order
        if agentFronts[source] == tab.id { agentFronts[source] = nil }
        if agentUsedTabs[source] == tab.id { agentUsedTabs[source] = nil }
        noteDeparture(of: tab, from: source, .moved)
        tab.session = target
        remembered[target] = nil
        sessionOrder[target, default: []].append(tab.id)
        if select || frontedTabs[target].flatMap({ tabs[$0] }) == nil { frontedTabs[target] = tab.id }
        reschedule()
        notifySession(source)
        notifySession(target)
    }

    /// Moves every tab of `source` to `target` in strip order, keeping the one in front in front, and
    /// tabs `source` lost with the host, to open again there. A tab past `target`'s limit stays.
    func moveTabs(fromSession source: UUID, toSession target: UUID) {
        guard source != target else { return }
        let fronted = tab(forSession: source)
        for tab in tabs(forSession: source) {
            try? move(tab, toSession: target, select: tab === fronted)
        }
        if let saved = remembered[source], tabs(forSession: target).isEmpty, remembered[target] == nil {
            remembered[source] = nil
            remembered[target] = saved
            notifySession(target)
        }
    }

    /// Closes every tab of the session and forgets its addresses: the task was archived or deleted.
    func closeTabs(forSession session: UUID) {
        for tab in tabs(forSession: session) { close(tab) }
        remembered[session] = nil
        closedAddresses[session] = nil
        frontedTabs[session] = nil
        agentFronts[session] = nil
        agentUsedTabs[session] = nil
        sessionOrder[session] = nil
        notifySession(session)
    }

    /// Calls `observer` when the session's tabs open, close, change order or front, or a tab's title,
    /// address, icon or loading changes. Frames and other page events do not call it.
    func addTabsObserver(forSession session: UUID, _ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        sessionObservers[session, default: [:]][token] = observer
        return token
    }

    func removeTabsObserver(_ token: UUID, forSession session: UUID) {
        sessionObservers[session]?[token] = nil
        if sessionObservers[session]?.isEmpty == true { sessionObservers[session] = nil }
    }

    /// A panel shows the tab. The tab is kept, and shown to its engine while the panel is on screen, for as long as a
    /// panel is attached; attaching on screen also asks for a fresh frame.
    /// - Parameter occluded: the panel is not on screen as it attaches (`setPanelOccluded`).
    func attachPanel(to tab: BrowserTab, occluded: Bool = false) {
        guard tabs[tab.id] === tab else { return }
        tab.panelCount += 1
        tab.wasPanelAttached = true
        if occluded {
            tab.occludedPanelCount += 1
            wake(tab)
        } else {
            panelComesOnScreen(tab)
        }
        reschedule()
    }

    /// - Parameter occluded: the panel had reported itself occluded (`setPanelOccluded`) and not
    ///   yet visible again.
    func detachPanel(from tab: BrowserTab, occluded: Bool = false) {
        guard tab.panelCount > 0 else { return }
        tab.panelCount -= 1
        if occluded { tab.occludedPanelCount = max(0, tab.occludedPanelCount - 1) }
        tab.occludedPanelCount = min(tab.occludedPanelCount, tab.panelCount)
        reschedule()
    }

    /// An attached panel is on screen or not: its window is miniaturized, covered, on another
    /// space, or the app is hidden. An occluded panel still holds the tab, but no longer keeps it
    /// painting; the tab hides like a panel-less one and paints again when the panel shows.
    func setPanelOccluded(_ occluded: Bool, on tab: BrowserTab) {
        guard tabs[tab.id] === tab, tab.panelCount > 0 else { return }
        let occludedBefore = tab.occludedPanelCount
        tab.occludedPanelCount = min(tab.panelCount, max(0, tab.occludedPanelCount + (occluded ? 1 : -1)))
        if tab.occludedPanelCount < occludedBefore { panelComesOnScreen(tab) }
        reschedule()
    }

    /// A panel comes on screen with the tab: the tab is shown to its engine and asked for a fresh frame, also when the
    /// engine draws it already (the agent's tab, drawn for `agentVisibleWindow` after each use). The panel may hold no
    /// frame of it (a new view, or one that showed another tab), and a page that does not change draws none of its own;
    /// a discarded page loads again.
    private func panelComesOnScreen(_ tab: BrowserTab) {
        tab.wasOnScreen = true
        tab.isShown = true
        connection?.send(.visibility(tab: tab.id, isHidden: false))
        wake(tab)
    }

    /// A remote device watches the tab, or no longer does (docs/REMOTE_PROTOCOL.md §15.25): while watched it is shown to
    /// its engine, as a panel on screen shows it, and a discarded or restored page loads. The tab the task's panel
    /// shows does not change.
    func setRemotelyWatched(_ watched: Bool, tab: BrowserTab) {
        guard tabs[tab.id] === tab, tab.isRemotelyWatched != watched else { return }
        tab.isRemotelyWatched = watched
        if watched { wake(tab) }
        reschedule()
    }

    /// The agent used the session's fronted tab. Call it (or `noteAgentActivity(on:)` for the tab used)
    /// on every agent browser action; it shows the tab to its engine for `agentVisibleWindow` after the
    /// last call, also while the panel fronts another tab.
    func noteAgentActivity(forSession session: UUID) {
        guard let tab = tab(forSession: session) else { return }
        noteAgentActivity(on: tab)
    }

    func noteAgentActivity(on tab: BrowserTab) {
        guard tabs[tab.id] === tab else { return }
        tab.lastAgentActivity = .now
        tab.isInAgentTurn = true
        // Shown before the agent's next command, which follows on the same connection.
        updateVisibility(of: tab, now: .now)
        tab.onAgentActivity?()
        if let session = tab.session {
            onAgentActivity?(session, tab.id)
            if agentUsedTabs[session] != tab.id {
                agentUsedTabs[session] = tab.id
                notifySession(session)
            }
        }
        reschedule()
    }

    // MARK: Tabs without a session

    /// Opens a tab outside any session, starting the host if none is running. It stays until
    /// closed.
    func openTab(url: String, viewport: BrowserViewport) throws -> BrowserTab {
        try open(url: url, viewport: viewport, session: nil, key: UUID(), after: nil)
    }

    /// Closes the tab; `departure` is how a tool that names it afterwards hears it went (`departure(of:)`).
    func closeTab(_ tab: BrowserTab, as departure: BrowserTabDeparture = .closed) {
        close(tab, as: departure)
    }

    /// Closes a tab as a person closes it, as Chrome does: a page that asks before it is left asks first
    /// ("Leave site?", `BrowserTab.closeQuestion`), Stay keeps the tab, and the tab goes once the host closes
    /// it (`closed`). A page that neither asks nor closes within `closeAnswerWait` is closed as `closeTab` closes
    /// it: Chromium gives a renderer that does not answer 500 ms and then closes, but not to a tab with DevTools
    /// attached, which every Yardlet tab is (`ShouldIgnoreUnresponsiveRenderer`).
    func requestClose(_ tab: BrowserTab) {
        guard tabs[tab.id] === tab, !tab.isClosing else { return }
        // A restored tab that has not loaded has no page to ask.
        guard let connection, tab.pendingAddress == nil else { return close(tab, as: .closedByPerson) }
        tab.isClosing = true
        tab.closeRequests += 1
        let request = tab.closeRequests
        connection.send(.requestClose(tab: tab.id))
        Task { @MainActor [weak self, weak tab] in
            try? await Task.sleep(for: Self.closeAnswerWait)
            // Only this close's wait: after the person stayed and closed again, the next close has its own.
            guard let self, let tab, self.tabs[tab.id] === tab, tab.isClosing, tab.closeRequests == request,
                  tab.closeQuestion == nil else { return }
            self.close(tab, as: .closedByPerson)
        }
    }

    nonisolated static let closeAnswerWait: Duration = .seconds(1)

    /// The person stayed on a page that asked before its close: the tab is no longer closing.
    fileprivate func closeStayed(_ tab: BrowserTab) {
        if let session = tab.session { notifySession(session) }
    }

    /// Opens the recorded URL independently, preserving the input ownership when it was blocked.
    func openBlockedPopup(_ url: String, from tab: BrowserTab) {
        guard let popup = tab.blockedPopupRequests.first(where: { $0.url == url }) else { return }
        openBlockedPopup(popup, from: tab)
    }

    func openBlockedPopup(_ popup: BrowserBlockedPopup, from tab: BrowserTab) {
        guard tabs[tab.id] === tab, tab.blockedPopupRequests.contains(popup),
              !tab.openingBlockedPopups.contains(popup.id),
              let session = tab.session, tabs(forSession: session).count < Self.maxTabsPerSession else { return }
        if popup.id < 0 {
            // Older hosts report only a URL, without a retained request.
            tab.forgetBlockedPopup(popup.id)
            openWindow(popup.url, from: tab, background: false, userGesture: true, retained: popup)
        } else {
            tab.openingBlockedPopups.insert(popup.id)
            connection?.send(.openBlockedPopup(tab: tab.id, popupTab: popup.id))
        }
    }

    func setPopupsAllowed(_ allowed: Bool, for tab: BrowserTab) {
        guard tabs[tab.id] === tab else { return }
        connection?.send(.popupPermission(tab: tab.id, url: tab.currentURL ?? "", allowed: allowed))
    }

    // MARK: Host

    /// Asks the host to exit now and ends it if it has not exited within `shutdownTimeout`.
    func shutdownHost() {
        idleTask?.cancel()
        idleTask = nil
        retentionTask?.cancel()
        retentionTask = nil
        guard let current = connection else { return }
        isHostEnding = true
        current.send(.shutdown)
        let timeout = shutdownTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, self.connection === current else { return }
            current.terminate()
        }
    }

    /// Ends the host for application termination: it closes its tabs and shuts Chromium down, and
    /// Yardlet waits up to `shutdownTimeout` for that before ending it. The tabs stay the tasks' tabs,
    /// saved with them to open again at the next launch.
    func terminateHost() {
        idleTask?.cancel()
        idleTask = nil
        retentionTask?.cancel()
        retentionTask = nil
        guard let current = connection else { return }
        isHostEnding = true
        current.send(.shutdown)
        if !current.waitUntilExit(timeout: shutdownTimeout) { current.terminate() }
    }

    func send(_ command: BrowserHostCommand) {
        connection?.send(command)
    }

    /// Chromium's windows over this task's tabs.
    func chromiumWindows(forSession session: UUID) -> [BrowserChromiumWindow] {
        chromiumWindows.filter { window in window.tab.flatMap { tabs[$0] }?.session == session }
    }

    /// Closes Chromium's windows over this task's tabs as Escape would (a passkey request ends with
    /// NotAllowedError); another task's windows and one whose tab is not known stay. False when it has none.
    @discardableResult
    func closeChromiumWindows(forSession session: UUID) -> Bool {
        let windows = chromiumWindows(forSession: session)
        guard !windows.isEmpty, let connection else { return false }
        connection.send(.closeChromiumWindows(tabs: Array(Set(windows.compactMap(\.tab))).sorted()))
        return true
    }

    /// Closes every one of Chromium's windows (QA's cleanup). False when none is open.
    @discardableResult
    func closeChromiumWindows() -> Bool {
        guard !chromiumWindowTitles.isEmpty, let connection else { return false }
        connection.send(.closeChromiumWindows(tabs: nil))
        return true
    }

    // MARK: Memory saver (docs/BROWSER_HOST.md §3 "Memory saver")

    /// Whether hidden tabs are discarded as Chrome's Memory Saver discards them (`BrowserMemorySaver`, Settings ›
    /// General "Memory saver"). Turning it off loads the discarded tabs' pages again: the tabs are as they were before.
    var isMemorySaverOn = false {
        didSet {
            guard isMemorySaverOn != oldValue else { return }
            memorySaverTask?.cancel()
            memorySaverTask = nil
            // A restored tab not shown yet is not the saver's: it loads when shown or used either way.
            if isMemorySaverOn { runMemorySaver() } else { tabs.values.filter { $0.pendingAddress == nil }.forEach(wake) }
        }
    }
    /// Whether this Mac's memory is critical now (macOS's memory pressure), when Chrome discards a tab every few
    /// seconds; the platform layer reads it.
    var isMemoryCritical: () -> Bool = { false }
    /// Chrome's level the person chose (Settings › General "Memory saver").
    var memorySaverLevel = BrowserMemorySaver.Level.balanced
    /// Chrome's times; QA runs shorten them.
    var memorySaverTiming = BrowserMemorySaver.Timing()
    private var memorySaverTask: Task<Void, Never>?

    /// macOS said memory is critical: the saver looks now instead of at its next sweep.
    func memoryBecameCritical() {
        guard isMemorySaverOn else { return }
        memorySaverTask?.cancel()
        runMemorySaver()
    }

    private func runMemorySaver() {
        memorySaverTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let pause = self?.sweepForMemory() else { return }
                try? await Task.sleep(for: pause)
            }
        }
    }

    /// Asks the host to discard the tabs `BrowserMemorySaver` picks (the host checks the pages first), and says when to
    /// look again: sooner while memory is critical.
    private func sweepForMemory() -> Duration {
        let urgent = isMemoryCritical()
        let pause = urgent ? memorySaverTiming.urgentInterval : memorySaverTiming.sweepInterval
        guard isMemorySaverOn, let connection else { return pause }
        let now = SuspendingClock.now
        let windowed = Set(chromiumWindows.compactMap(\.tab))
        let candidates = tabs.values.compactMap {
            $0.memorySaverCandidate(now: now, hasChromiumWindow: windowed.contains($0.id), retryAfter: memorySaverTiming.retryAfter)
        }
        for id in BrowserMemorySaver.picks(candidates, urgent: urgent, level: memorySaverLevel, timing: memorySaverTiming) {
            guard let tab = tabs[id] else { continue }
            tab.isDiscardAsked = true
            connection.send(.discard(tab: id, urgent: urgent))
        }
        return pause
    }

    /// Loads a discarded tab's page again, as Chrome reloads a discarded tab it shows: a panel shows it, the agent uses
    /// it, or the saver was turned off. The tab keeps its history; the page's state is what a reload keeps.
    private func wake(_ tab: BrowserTab) {
        guard tab.isDiscarded, let connection else { return }
        tab.beginRestore()
        if let address = tab.takePendingAddress() {
            // A restored tab loads its page for the first time: the host opens it now, hidden if it is.
            let profile = tab.session.flatMap { (openingProfileForSession ?? profileForSession)?($0) }
            connection.send(.open(tab: tab.id, url: address, viewport: tab.viewport ?? .offscreenDefault, profile: profile))
            if !tab.isShown { connection.send(.visibility(tab: tab.id, isHidden: true)) }
        } else {
            connection.send(.navigation(tab: tab.id, action: .reload))
        }
        if let session = tab.session { notifySession(session) }
    }

    /// Opens a restored tab that has not loaded (`BrowserTab.pendingAddress`), for a use that needs its page.
    fileprivate func openIfPending(_ tab: BrowserTab) {
        guard tab.pendingAddress != nil, tabs[tab.id] === tab else { return }
        wake(tab)
    }

    // MARK: Internals

    /// `loads`: false for a restored tab that waits to be shown (`restoreTabs`), which the host opens on `wake`.
    private func open(url: String, viewport: BrowserViewport, session: UUID?, key: UUID, after: BrowserTabID?,
                      at position: Int? = nil, loads: Bool = true) throws -> BrowserTab {
        idleTask?.cancel()
        idleTask = nil
        let connection = try currentConnection()
        let tab = BrowserTab(id: nextTabID, client: self, session: session, key: key)
        tab.viewport = viewport
        nextTabID += 1
        tabs[tab.id] = tab
        if let session {
            // A tab opened for the task after the host ended replaces the tabs it lost.
            remembered[session] = nil
            var order = sessionOrder[session] ?? []
            if let position { order.insert(tab.id, at: min(position, order.count)) }
            else if let after, let index = order.firstIndex(of: after) { order.insert(tab.id, at: index + 1) }
            else { order.append(tab.id) }
            sessionOrder[session] = order
        }
        guard loads else { return tab }
        let profile = session.flatMap { (openingProfileForSession ?? profileForSession)?($0) }
        connection.send(.open(tab: tab.id, url: url, viewport: viewport, profile: profile))
        return tab
    }

    private func close(_ tab: BrowserTab, as departure: BrowserTabDeparture = .closed) {
        let waited = personWait(of: tab) != nil
        guard tabs.removeValue(forKey: tab.id) != nil else { return }
        if let session = tab.session { noteDeparture(of: tab, from: session, departure) }
        defer { if waited { onPersonWaitsChange?() } }
        tab.isClosing = false
        // The host holds a waiting dialog's callback until it is answered, also once its tab is gone.
        if let chooser = tab.fileDialog { connection?.send(.fileDialogResult(tab: tab.id, dialog: chooser.id, paths: nil)) }
        connection?.send(.close(tab: tab.id))
        tab.markClosed()
        if let session = tab.session { removeFromSession(tab, session: session) }
        onTabClosed?(tab.id)
        guard tabs.isEmpty else { return }
        retentionTask?.cancel()
        retentionTask = nil
        scheduleIdleShutdown()
    }

    /// Takes a closed tab out of its session's strip. A fronted tab hands the front to the tab that
    /// took its place, else the one before it, as Chrome does; its address goes on the reopen list.
    private func removeFromSession(_ tab: BrowserTab, session: UUID) {
        var order = sessionOrder[session] ?? []
        guard let index = order.firstIndex(of: tab.id) else { return }
        order.remove(at: index)
        sessionOrder[session] = order.isEmpty ? nil : order
        if frontedTabs[session] == tab.id {
            frontedTabs[session] = order.isEmpty ? nil : order[min(index, order.count - 1)]
        }
        if agentFronts[session] == tab.id { agentFronts[session] = nil }
        if agentUsedTabs[session] == tab.id { agentUsedTabs[session] = nil }
        if let address = tab.lastPageURL {
            var closed = closedAddresses[session] ?? []
            closed.append(address)
            closedAddresses[session] = Array(closed.suffix(10))
        }
        notifySession(session)
    }

    /// A page's new-window request: another tab of its task, in front unless a background-tab
    /// click asked for it behind, as the Codex and Claude apps' browsers open one. Without a user
    /// gesture nothing opens (Chrome blocks those pop-ups too). A tab outside a task, or a task with
    /// no room for another tab, loads the address itself, as before 2026-10-22.
    private func openWindow(_ url: String, from opener: BrowserTab, background: Bool, userGesture: Bool,
                            retained: BrowserBlockedPopup? = nil) {
        guard userGesture else { return }
        if let session = opener.session {
            let behind = opensBehind(from: opener, session: session)
            let agentsOpener = agentTab(forSession: session) === opener
            // The agent's click opened it, or a remote device's, as a pop-up the host adopts (`adoptPopup`).
            if let tab = try? newTab(forSession: session, url: retained == nil ? url : "about:blank",
                                     viewport: opener.viewport ?? .offscreenDefault,
                                     select: !background && !behind,
                                     byAgent: retained?.openedByAgent == true || opener.isDrivenByAgent) {
                tab.inherit(from: opener, retained: retained)
                // Apply retained download restrictions before a URL-only request starts loading.
                if retained != nil { connection?.send(.navigate(tab: tab.id, url: url)) }
                if !background { placeOpened(tab, behind: behind, agentsOpener: agentsOpener, session: session) }
                opener.receive(.openedTab(tab: opener.id, newTab: tab.id, url: url))
                return
            }
        }
        guard retained == nil else { return }
        connection?.send(.navigate(tab: opener.id, url: url))
        opener.receive(.openedTab(tab: opener.id, newTab: nil, url: url))
    }

    /// Adopts an engine-created window into its originating task. Ordinary page popups keep their opener;
    /// URLs selected from the blocked menu have an independent browsing context.
    /// placed as `openWindow` places one. A tab outside a task, or a task with no room for another tab,
    /// closes it, and the opener loads the address itself, as `openWindow` does.
    private func adoptPopup(_ id: BrowserTabID, opener: BrowserTab?, url: String, background: Bool) {
        let retained = opener?.blockedPopupRequests.first { $0.id == id }
        opener?.forgetBlockedPopup(id)
        guard tabs[id] == nil else { return }
        guard let opener, let session = opener.session, tabs(forSession: session).count < Self.maxTabsPerSession else {
            connection?.send(.close(tab: id))
            guard let opener, retained == nil else { return }
            connection?.send(.navigate(tab: opener.id, url: url))
            opener.receive(.openedTab(tab: opener.id, newTab: nil, url: url))
            return
        }
        let behind = opensBehind(from: opener, session: session)
        let agentsOpener = agentTab(forSession: session) === opener
        let tab = BrowserTab(id: id, client: self, session: session, key: UUID())
        tab.viewport = opener.viewport
        // The agent's click opened it; or a remote device's, which the new tab's own requests answer to.
        tab.openedByAgent = retained?.openedByAgent == true || opener.isDrivenByAgent
        tab.inherit(from: opener, retained: retained)
        tabs[id] = tab
        sessionOrder[session, default: []].append(id)
        if (!background && !behind) || frontedTabs[session].flatMap({ tabs[$0] }) == nil {
            keepAgentTab(inSession: session, as: id)
            frontedTabs[session] = id
        }
        if !background { placeOpened(tab, behind: behind, agentsOpener: agentsOpener, session: session) }
        opener.receive(.openedTab(tab: opener.id, newTab: id, url: url))
        reschedule()
        notifySession(session)
    }

    /// A page's new tab that asked to come in front, from the agent's tab: the agent follows it, as the tab in front
    /// or, where it opened behind the person's tab, as its own.
    private func placeOpened(_ tab: BrowserTab, behind: Bool, agentsOpener: Bool, session: UUID) {
        guard agentsOpener else { return }
        agentFronts[session] = behind ? tab.id : nil
    }

    /// A page's request to open another app's address, by Chrome's rules (`BrowserExternalAppPolicy`): after one
    /// request, the page asks again only after another click or key press (Chrome's flood guard); an address no
    /// app opens, or one Yardlet itself would open, goes nowhere; a mail link and a site the person always
    /// allowed open without asking; any other asks the person in the tab's panel. What the agent's input led to
    /// always asks. The tab hears what came of it (`externalAppHandled`).
    private func handleExternalApp(_ request: BrowserExternalAppRequest, on tab: BrowserTab) {
        func report(_ outcome: BrowserExternalAppOutcome, app: String? = nil) {
            tab.receive(.externalAppHandled(tab: tab.id, url: request.url, app: app, outcome: outcome))
        }
        let lastInput = [tab.lastPersonInput, tab.lastAgentActivity].compactMap { $0 }.max()
        if let last = tab.lastExternalAppRequest, lastInput.map({ $0 < last }) ?? true { return report(.ignored) }
        tab.lastExternalAppRequest = .now
        guard let url = URL(string: request.url), let scheme = url.scheme?.lowercased(), let app = externalApps.appName(for: url)
        else { return report(.noApp) }
        // A tab the agent opened, or the agent's input in another tab opened, is the agent's until someone here uses it.
        let byAgent = tab.isDrivenByAgent || (tab.openedByAgent && tab.lastPersonInput == nil)
        // Another app on this Mac opens only when someone at this Mac chose it: a remote device's click asks here.
        if !tab.isDrivenByRemote,
           BrowserExternalAppPolicy.opensWithoutAsking(scheme: scheme, remembered: request.remembered, byAgent: byAgent) {
            externalApps.open(url)
            return report(.opened, app: app)
        }
        tab.externalAppQuestion = BrowserExternalAppQuestion(
            url: request.url, origin: request.origin, app: app,
            offersAlwaysAllow: BrowserExternalAppPolicy.mayRemember(origin: request.origin), byAgent: byAgent)
        report(.asked, app: app)
        personWaitChanged(tab)
    }

    /// The person's answer in the panel: Open opens the app, and with "Always allow" checked the tab's profile
    /// keeps that this site may open such links without asking.
    fileprivate func answer(_ question: BrowserExternalAppQuestion, open: Bool, alwaysAllow: Bool, on tab: BrowserTab) {
        guard open, let url = URL(string: question.url), let scheme = url.scheme?.lowercased() else { return }
        if alwaysAllow, question.offersAlwaysAllow {
            connection?.send(.allowExternalApp(tab: tab.id, origin: question.origin, scheme: scheme))
        }
        externalApps.open(url)
    }

    /// Keeps the addresses of a session's tabs that showed a page, for `restoreTabs`. A tab the person was
    /// closing is not kept.
    private func remember(_ session: UUID) {
        let open = tabs(forSession: session)
        let fronted = tab(forSession: session)
        let kept = open.filter { $0.lastPageURL != nil && !$0.isClosing }
        guard !kept.isEmpty else { return }
        remembered[session] = BrowserRememberedTabs(
            addresses: kept.compactMap(\.lastPageURL),
            keys: kept.map(\.key),
            titles: kept.map(\.title),
            favicons: kept.map(\.favicon),
            fronted: kept.firstIndex { $0 === fronted } ?? 0
        )
    }

    private func notifySession(_ session: UUID) {
        for observer in (sessionObservers[session] ?? [:]).values { observer() }
    }

    private func currentConnection() throws -> any BrowserHostConnection {
        if let connection { return connection }
        let connection = try launcher()
        launchCount += 1
        connection.eventHandler = { [weak self, weak connection] event in
            guard let self, let connection, self.connection === connection else { return }
            self.handle(event)
        }
        self.connection = connection
        onHostStateChange?(true)
        return connection
    }

    private func scheduleIdleShutdown() {
        idleTask?.cancel()
        let grace = idleGrace
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, let self, self.tabs.isEmpty else { return }
            self.shutdownHost()
        }
    }

    /// Until when a session tab without a visible panel stays shown for the agent (nil: no longer).
    private func agentVisibleUntil(_ tab: BrowserTab) -> ContinuousClock.Instant? {
        guard tab.session != nil, tab.visiblePanelCount == 0 else { return nil }
        // A tab the agent opened without a panel is shown from its opening; once a panel has shown
        // the tab, only the agent's use does (a panel's own tab hides as soon as the panel is off screen).
        // A restored tab that waits to be shown is shown by neither: only the agent's use or a panel loads it.
        guard let since = tab.lastAgentActivity ?? (tab.wasPanelAttached || tab.pendingAddress != nil ? nil : tab.openedAt)
        else { return nil }
        return max(since, tab.openedAt) + agentVisibleWindow
    }

    private func updateVisibility(of tab: BrowserTab, now: ContinuousClock.Instant) {
        let shown = tab.session == nil || tab.visiblePanelCount > 0 || tab.isRemotelyWatched
            || (agentVisibleUntil(tab).map { now < $0 } ?? false)
        guard shown != tab.isShown else { return }
        tab.isShown = shown
        connection?.send(.visibility(tab: tab.id, isHidden: !shown))
        if shown { wake(tab) }
    }

    /// Brings each tab's visibility up to date and wakes again when the next agent window ends.
    private func reschedule() {
        retentionTask?.cancel()
        retentionTask = nil
        let now = ContinuousClock.now
        var earliest: ContinuousClock.Instant?
        for tab in tabs.values {
            updateVisibility(of: tab, now: now)
            if tab.isShown, let hideAt = agentVisibleUntil(tab), hideAt > now {
                earliest = earliest.map { min($0, hideAt) } ?? hideAt
            }
        }
        guard let earliest else { return }
        retentionTask = Task { [weak self] in
            try? await Task.sleep(until: earliest, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.reschedule()
        }
    }

    private func handle(_ event: BrowserHostEvent) {
        switch event {
        case .ready(let processID, let engine, let accelerated):
            hostProcessID = processID
            hostEngine = engine
            acceleratedPaint = accelerated
        case .chromiumWindow(let isShown, let titles, let kinds, let ids, let owners):
            let titles = isShown ? (titles ?? [""]) : []
            let before = chromiumWindows
            chromiumWindows = titles.indices.map { index in
                func value<T>(_ list: [T]?) -> T? { list.flatMap { $0.indices.contains(index) ? $0[index] : nil } }
                return BrowserChromiumWindow(title: titles[index], kind: value(kinds).flatMap(BrowserChromiumWindow.Kind.init) ?? .passkey,
                                             id: value(ids) ?? 0, tab: value(owners).flatMap { $0 >= 0 ? $0 : nil })
            }
            onChromiumWindowsChange?()
            if before != chromiumWindows {
                let sessions = Set((before + chromiumWindows).compactMap { $0.tab.flatMap { tabs[$0]?.session } })
                sessions.forEach(notifySession)
                onPersonWaitsChange?()
            }
        case .cookiesImported(let request, let count):
            cookieImports.removeValue(forKey: request)?.resume(returning: count)
        case .terminated(let reason):
            for waiting in cookieImports.values { waiting.resume(returning: -1) }
            cookieImports.removeAll()
            chromiumWindows = []
            onChromiumWindowsChange?()
            connection = nil
            isHostEnding = false
            hostProcessID = nil
            lastTermination = reason
            onHostEnded?()
            idleTask?.cancel()
            idleTask = nil
            retentionTask?.cancel()
            retentionTask = nil
            let sessions = Array(sessionOrder.keys)
            for session in sessions { remember(session) }
            for tab in tabs.values {
                if let session = tab.session { noteDeparture(of: tab, from: session, .reopened(key: tab.key, cause: .hostEnded)) }
            }
            let orphaned = tabs.values
            tabs.removeAll()
            sessionOrder.removeAll()
            frontedTabs.removeAll()
            agentFronts.removeAll()
            agentUsedTabs.removeAll()
            orphaned.forEach { $0.receive(event) }
            orphaned.forEach { onTabClosed?($0.id) }
            sessions.forEach(notifySession)
            onPersonWaitsChange?()
            onHostStateChange?(false)
        case .failed(_, let id?, _):
            // One tab's failure is that tab's; it never reaches the page another tab shows.
            guard let tab = tabs[id] else { return }
            tab.receive(event)
            if let session = tab.session { notifySession(session) }
        case .failed:
            tabs.values.forEach { $0.receive(event) }
        case .address(let id, _), .title(let id, _), .favicon(let id, _, _):
            guard let tab = tabs[id] else { return }
            tab.receive(event)
            noteHistory(event, of: tab)
            if let session = tab.session { notifySession(session) }
        case .loadError(let id, let url, let code, _):
            guard let tab = tabs[id] else { return }
            tab.receive(event)
            // The failed address's error page is no visit; an aborted load (-3) is only replaced by another.
            if code != -3 {
                tab.failedAddress = url
                tab.typedNavigation = false
            }
        case .loadEnd(let id, _, _):
            // Chromium reports the error page's commit with this load end and no address change.
            tabs[id]?.receive(event)
            tabs[id]?.failedAddress = nil
        case .newDocument(let id, _):
            guard let tab = tabs[id] else { return }
            tab.receive(event)
            noteHistory(event, of: tab)
        case .discarded(let id):
            guard let tab = tabs[id] else { return }
            tab.receive(event)
            // Shown, or used by the agent, while the host was ending its renderer; or the saver was turned off.
            if tab.isShown || tab.isPanelAttached || !isMemorySaverOn { wake(tab) }
            if let session = tab.session { notifySession(session) }
        case .responsiveness(let id, _), .pageCrashed(let id, _, _, _):
            guard let tab = tabs[id] else { return }
            let before = tab.unresponsive
            tab.receive(event)
            if tab.unresponsive != before, let session = tab.session { notifySession(session) }
        case .loading(let id, let isLoading, _, _):
            guard let tab = tabs[id] else { return }
            let changed = tab.isLoading != isLoading
            tab.receive(event)
            // The side panel's tabs show which pages are loading; the rest of the state needs no notice.
            if changed, let session = tab.session { notifySession(session) }
        case .newWindow(let id, let url, let background, let userGesture):
            guard let tab = tabs[id] else { return }
            tab.receive(event)
            openWindow(url, from: tab, background: background, userGesture: userGesture)
        case .externalApp(let id, let request):
            guard let tab = tabs[id] else { return }
            handleExternalApp(request, on: tab)
        case .javaScriptDialog(let id, _), .javaScriptDialogReset(let id):
            guard let tab = tabs[id] else { return }
            let asked = tab.closeQuestion
            tab.receive(event)
            // A page asks before the person's close goes on: the panel brings its tab forward to ask, as Chrome does.
            if tab.closeQuestion != asked, let session = tab.session { notifySession(session) }
        case .popupOpened(let id, let openerID, let url, let background):
            adoptPopup(id, opener: tabs[openerID], url: url, background: background)
        case .download(let id, let download):
            guard let tab = tabs[id] else { return }
            tab.receive(event)
            // A tab a page opened only to download (a target=_blank link to a file) never shows a page. As
            // in Chrome it closes and its opener comes back, once the download ends: CEF reports nothing
            // more of a download whose tab has closed, and the panel's download row waits for its end.
            if ![.started, .inProgress].contains(download.state), tab.lastPageURL == nil,
               let opener = tabs.values.first(where: { $0.openedTabs.contains(tab.id) }) {
                select(opener)
                close(tab)
            }
        case .remoteDownloadStopped(let id, let fileName):
            guard let tab = tabs[id] else { return }
            // A tab a page opened only for the refused download closes, as one whose download ended does, and its
            // opener, which comes back, says so.
            if tab.lastPageURL == nil, let opener = tabs.values.first(where: { $0.openedTabs.contains(tab.id) }) {
                select(opener)
                close(tab)
                opener.receive(.remoteDownloadStopped(tab: opener.id, fileName: fileName))
            } else {
                tab.receive(event)
            }
        case .closed(let id):
            // The page closed itself; a tab Yardlet closed is already gone. A host asked to end closes
            // every tab first: those are lost with it, as in a crash, and `.terminated` keeps them.
            guard !isHostEnding, let tab = tabs[id] else { return }
            // The person's close the page let through (`requestClose`), or the page's own `window.close()`.
            let departure: BrowserTabDeparture = tab.isClosing ? .closedByPerson : .closedByPage
            tab.receive(event)
            close(tab, as: departure)
        default:
            if let id = event.tab { tabs[id]?.receive(event) }
        }
    }

    /// Each page a tab commits is a visit in the address field's history, typed when the person opened it from
    /// the address field: not the address it counted last (a reload, a move within the page, a restored or woken
    /// tab) unless the person typed it again, nor a failed address's error page. Titles and icons follow their pages.
    private func noteHistory(_ event: BrowserHostEvent, of tab: BrowserTab) {
        guard let addressHistory else { return }
        // A page whose address or title carries a value the vault filled is no visit to keep.
        switch event {
        case .address(_, let url), .newDocument(_, let url):
            if carriesFilledValue(url) { return }
        case .title(_, let title):
            if carriesFilledValue(title) || tab.currentURL.map(carriesFilledValue) == true { return }
        default:
            break
        }
        switch event {
        case .address(_, let url):
            guard !BrowserURLPolicy.sameAddress(url, tab.visitedAddress) else { return }
            tab.visitedAddress = url
            let typed = tab.typedNavigation
            tab.typedNavigation = false
            if let failed = tab.failedAddress, BrowserURLPolicy.sameAddress(failed, url) {
                tab.failedAddress = nil
                return
            }
            addressHistory.noteVisit(url, typed: typed)
        case .newDocument(_, let url):
            // The person typed the address the tab shows: no address change reports that visit.
            guard tab.typedNavigation, BrowserURLPolicy.sameAddress(url, tab.visitedAddress) else { return }
            tab.typedNavigation = false
            addressHistory.noteVisit(url, typed: true)
        case .title(_, let title):
            // Chromium names a page without a title by its address.
            if let url = tab.currentURL, title != url { addressHistory.noteTitle(title, of: url) }
        case .favicon(_, _, let png):
            // Kept by site, in memory, for the start page and the launcher.
            if let url = tab.currentURL { addressHistory.noteIcon(png, of: url) }
        default:
            break
        }
    }
}

/// A blocked request and the input ownership it had when the page opened it.
struct BrowserBlockedPopup: Identifiable, Equatable {
    let id: BrowserTabID
    let url: String
    let openedByAgent: Bool
    let drivenByRemote: Bool
    let refusedDownloads: Bool
}

/// One page in the host. Events arrive through `eventHandler` and any added observers; CDP goes
/// through `devTools`.
@MainActor
final class BrowserTab {
    let id: BrowserTabID
    /// The side-panel tab this is. It stays with the tab when it moves to another task, and a tab
    /// opened again (after the host ended, or Yardlet restarted) takes the key it had.
    let key: UUID
    /// The task this tab belongs to; nil for a tab opened outside any session. It changes only when the
    /// tab moves to another task (`BrowserHostClient.move(_:toSession:select:)`).
    fileprivate(set) var session: UUID?
    private weak var client: BrowserHostClient?
    private(set) var isClosed = false
    /// The page's current address, as the host last reported it.
    private(set) var currentURL: String?
    /// How many times the main frame's address changed or it started another document: what was checked at one count
    /// is that page only, and a page that left and came back to the same address counts on (a remote device's picture
    /// and input, docs/REMOTE_PROTOCOL.md §15.25).
    private(set) var navigations = 0
    /// The last address that was a page (not empty, not about:blank), to open again.
    private(set) var lastPageURL: String?
    /// A restored tab that has not loaded: the address it opens at when a panel shows it or the agent uses it
    /// (`BrowserHostClient.restoreTabs`). The host has no page for it until then; it reads as discarded.
    private(set) var pendingAddress: String?
    /// The size the tab was opened or last resized at, for the tabs its page opens.
    fileprivate(set) var viewport: BrowserViewport?
    /// The screen size the page is shown at instead of its view's own, and who chose it; nil while the page
    /// takes its view's size (`emulate(_:)`).
    private(set) var emulation: BrowserViewportEmulation?
    /// The color scheme the agent emulates (`browser_resize` colorScheme), "light" or "dark"; nil follows the Mac.
    private(set) var emulatedColorScheme: String?
    /// The size the tab was last given without an emulation, which a tab no panel shows takes again.
    private var ownViewport: BrowserViewport?
    /// This Chromium's major version and brands, read from the page before any phone was emulated.
    private var browserIdentity: (major: String, brands: [JSONValue])?
    /// Called when `emulation` changes, for the panel that shows the tab.
    var onEmulationChange: (() -> Void)?
    /// The agent handed the tab to the person (`browser_handoff`), until the agent's wait ends.
    private(set) var handoff: BrowserHandoff?
    /// Called when `handoff` changes, for the panel that shows the tab.
    var onHandoffChange: (() -> Void)?
    /// The agent asks the person to keep a two-factor setup the page shows, until the agent's wait reads the answer.
    private(set) var vaultSetupAsk: BrowserVaultSetupAsk?
    /// Called when `vaultSetupAsk` changes, for the panel that shows the tab.
    var onVaultSetupAskChange: (() -> Void)?
    /// The page's title and navigation state, as the host last reported them, for a panel that
    /// fronts the tab later.
    private(set) var title = ""
    /// The address the page was at when it set `title`: a page the tab moved to keeps the last one's title until it
    /// names itself.
    private(set) var titleAddress: String?
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// The tab's page does not respond: Chromium says its renderer has not handled input for 15
    /// seconds, or it has answered neither a DevTools call its renderer answers nor the check after it
    /// (`devToolsTimedOut`). Nil once it answers, its renderer ended, or within 15 seconds of Wait.
    var unresponsive: BrowserTabUnresponsiveness? {
        if hangReported, waitedUntil.map({ ContinuousClock.now >= $0 }) ?? true { return .hangMonitor }
        return unanswered.map { .unanswered(method: $0) }
    }
    fileprivate var hangReported = false
    fileprivate var waitedUntil: ContinuousClock.Instant?
    private var unanswered: String?
    /// The check whether the renderer still answers, after a call it answers went unanswered: true when it answered.
    private var rendererCheck: Task<Bool, Never>?
    /// The tab's renderer ended (it crashed, ran out of memory or was killed); nil once the tab loads
    /// again, which starts another renderer.
    private(set) var crash: BrowserTabCrash?
    /// The host could not open the tab, so it has no page: why, as the host said. Such a tab opens
    /// again in its place (`BrowserHostClient.replace`), as Chrome's Reload does for its error page.
    private(set) var openFailure: BrowserTabOpenFailure?
    /// The tabs this tab's page opened (new-window requests, `openedTab`).
    private(set) var openedTabs: Set<BrowserTabID> = []
    /// The passwords and codes the vault filled into the tab's documents, for the agent and for the person.
    let vaultFills = BrowserVaultFills()
    /// What the page asks permission for and waits on, until the person answers or the page moves on.
    private(set) var permissionPrompt: BrowserPermissionPrompt?
    /// Another app's address the page asked to open, waiting for the person (the panel's bar), until the page
    /// moves on.
    fileprivate(set) var externalAppQuestion: BrowserExternalAppQuestion?
    /// Pop-ups the page opened without a click, which the browser blocked as Chrome does, in order (Chrome's
    /// address-bar list, at most 25), until the page moves on.
    private(set) var blockedPopupRequests: [BrowserBlockedPopup] = []
    var blockedPopups: [String] { blockedPopupRequests.map(\.url) }
    fileprivate var openingBlockedPopups: Set<BrowserTabID> = []
    private(set) var popupsAllowed = false
    /// The person's last input to the page: a click or key press in its panel, or an address, Back, Forward or
    /// Reload there (`notePersonInput`).
    fileprivate(set) var lastPersonInput: ContinuousClock.Instant?
    /// The person's last use of the page in its panel: that input, or a scroll, a drag or typed text
    /// (`BrowserHostClient.personUse(of:)`).
    fileprivate(set) var lastPersonUse: ContinuousClock.Instant?
    /// The address last counted as a visit in the address field's history, or the one a restored tab opened at.
    fileprivate var visitedAddress: String?
    /// The next page the tab commits came from the person's address field (Chrome's typed transition).
    fileprivate var typedNavigation = false
    /// The address whose load failed last, until its error page commits.
    fileprivate var failedAddress: String?
    /// The panel's view has the keyboard on this page, in the key window (`BrowserHostClient.setPanelKeyboard`).
    fileprivate(set) var hasPanelKeyboard = false
    /// The page's JavaScript dialog (alert, confirm, prompt, "Leave site?") waiting for an answer, until the panel or
    /// the agent answers it or the page goes: the panel that shows the tab shows it over the page, whenever it does.
    private(set) var javaScriptDialog: BrowserJavaScriptDialog?
    /// The agent's input led to `javaScriptDialog` (`isDrivenByAgent` when it opened).
    private(set) var dialogByAgent = false
    /// The page's file chooser waiting for files, until the panel or the agent answers it, the page moves to another
    /// document or the tab closes: the panel that shows the tab offers it, whenever it does.
    private(set) var fileDialog: BrowserFileDialog?
    /// The agent's input led to `fileDialog`.
    private(set) var fileDialogByAgent = false
    /// The page's last request to open another app (Chrome's flood guard waits for the next input).
    fileprivate var lastExternalAppRequest: ContinuousClock.Instant?
    /// The person closed the tab and its page is asked first (`BrowserHostClient.requestClose`); false once it
    /// closes or the person stays.
    fileprivate(set) var isClosing = false
    /// The page's leave-page question during that close ("Leave site?"), for the panel that shows the tab.
    private(set) var closeQuestion: BrowserJavaScriptDialog?
    /// The person's closes so far, so each close's wait for the page's answer is its own.
    fileprivate var closeRequests = 0
    /// The page's focused field is a password field, as the host last reported (false once the renderer
    /// ends), for a panel that shows the tab later.
    private(set) var isPasswordFieldFocused = false
    /// The page's icon as PNG, which the host downloads through the page's own profile; nil until
    /// one arrives, and again once the tab goes to another site.
    private(set) var favicon: Data?
    /// The page whose icon `favicon` is, by host.
    private var faviconHost: String?
    fileprivate(set) var panelCount = 0
    /// Attached panels that are not on screen (`BrowserHostClient.setPanelOccluded`).
    fileprivate(set) var occludedPanelCount = 0
    /// A panel has shown the tab at some point.
    fileprivate(set) var wasPanelAttached = false
    /// A panel has shown the tab on screen at some point: the person may have seen it.
    fileprivate(set) var wasOnScreen = false
    /// The agent's tools opened the tab, or the agent's input in another tab opened it as a pop-up.
    fileprivate(set) var openedByAgent = false
    /// A remote device watches the tab (`BrowserHostClient.setRemotelyWatched`).
    fileprivate(set) var isRemotelyWatched = false
    /// When the person's last input came from a remote device (`notePersonInput(remote:)`).
    private var lastRemoteInput: ContinuousClock.Instant?
    /// A page the remote device's input drove opened the tab (`inherit(from:)`).
    fileprivate(set) var remoteOpener = false
    /// The page that opened the tab had its downloads refused then (`inherit(from:)`).
    fileprivate var openerRefusedDownloads = false
    /// When the agent last acted on the page (a click, typing, a navigation …), not a read (`noteAgentInput`), and when
    /// before the act under way, which `undoAgentInput` takes back.
    private var lastAgentInput: ContinuousClock.Instant?
    private var agentInputBefore: ContinuousClock.Instant??
    /// Whether the host was last told to refuse the tab's downloads (`refuseDownloads`).
    private var refusesDownloads = false
    /// What the tab's emulation was before a phone's (`sizeForRemote`); nil while no phone's holds.
    private var emulationBeforeRemote: BrowserViewportEmulation??
    /// The phone's size asked for last and not yet applied (`.some(nil)`: no phone's), which the queued change takes.
    private var remoteSize: BrowserViewportEmulation??
    /// The last change of the emulation, which the next waits for (`inEmulationOrder`).
    private var emulationChanges: Task<Void, Never>?
    /// How many times the person brought the tab in front of its task (`BrowserHostClient.show`).
    fileprivate(set) var revisits = 0
    fileprivate(set) var lastAgentActivity: ContinuousClock.Instant?
    fileprivate let openedAt = ContinuousClock.now
    /// Whether the engine was last told the tab is shown (a new tab starts shown).
    fileprivate(set) var isShown = true {
        didSet { if isShown != oldValue { hiddenSince = isShown ? nil : .now } }
    }

    // Memory saver (BrowserMemorySaver)
    /// The page was discarded (`BrowserHostEvent.discarded`): the tab keeps its address, title, icon and history, and
    /// its page loads again when it is shown or the agent uses it. False once that reload begins.
    private(set) var isDiscarded = false
    /// Yardlet asked the host to discard the tab and waits for the answer; one the host has not given within
    /// `discardAnswerWait` (its frames get 3 seconds) is taken as no.
    fileprivate var isDiscardAsked: Bool {
        get { discardAskedAt.map { ContinuousClock.now - $0 < Self.discardAnswerWait } ?? false }
        set { discardAskedAt = newValue ? .now : nil }
    }
    private var discardAskedAt: ContinuousClock.Instant?
    nonisolated static let discardAnswerWait: Duration = .seconds(15)
    /// When the host last kept the tab (`discardRefused`), and why (the page Chrome keeps: media, form, shared …).
    private var discardRefusedAt: SuspendingClock.Instant?
    private(set) var discardRefusal: String?
    /// When the tab was last hidden from its engine, on a clock that stops while the Mac sleeps; nil while shown.
    private(set) var hiddenSince: SuspendingClock.Instant?
    private enum Restore { case none, waiting, loading }
    /// The page loads again after a discard: waiting for its load to begin, then for it to end.
    private var restore = Restore.none
    /// When the page's current document began.
    private var documentStartedAt = ContinuousClock.now
    /// The person typed, pasted or deleted text in the page since its document began (Chrome's kUserEdits).
    private var hadPersonEdits = false
    /// The page's title or icon changed while it was hidden (Chrome's kBackgroundActivity).
    private var workedInBackground = false
    /// Downloads that have not ended.
    private var activeDownloads: Set<Int> = []
    /// The agent used the tab in its turn that is still going (`BrowserHostClient.noteAgentActivity`, until
    /// `endAgentEmulation`).
    fileprivate var isInAgentTurn = false
    /// When the last agent turn that used the tab ended, on the clock `hiddenSince` uses.
    private var agentTurnEndedAt: SuspendingClock.Instant?
    /// The panel's primary handler.
    var eventHandler: ((BrowserHostEvent) -> Void)?
    /// Called whenever the agent reports using this tab.
    var onAgentActivity: (() -> Void)?
    private var observers: [UUID: (BrowserHostEvent) -> Void] = [:]
    private(set) lazy var devTools: BrowserDevToolsClient = {
        let devTools = BrowserDevToolsClient { [weak self] message in
            guard let self, !self.isClosed, self.openFailure == nil else { return false }
            // A restored tab that has not loaded has no page yet: it opens first, and the call follows on the same connection.
            if self.pendingAddress != nil { self.client?.openIfPending(self) }
            self.client?.send(.devTools(tab: self.id, message: message))
            return self.client?.isHostRunning == true
        }
        devTools.onTimeout = { [weak self] method in self?.devToolsTimedOut(method) }
        devTools.onAnswer = { [weak self] method in self?.devToolsAnswered(method) }
        return devTools
    }()

    /// DevTools calls the page's renderer answers (its main thread): all but the moves, which the
    /// browser answers once the new page commits and a slow server keeps waiting.
    static func needsRenderer(_ method: String) -> Bool {
        !["Page.navigate", "Page.reload", "Page.navigateToHistoryEntry"].contains(method)
            && !method.hasPrefix("Target.") && !method.hasPrefix("Browser.")
    }

    /// Wait: a page that missed a call is taken as answering until it misses another; one Chromium
    /// reports stays hidden for 15 seconds, as Chrome's Wait waits.
    fileprivate func wait(until deadline: ContinuousClock.Instant) {
        unanswered = nil
        if hangReported { waitedUntil = deadline }
    }

    /// A late call alone does not show that the page is stuck: one that awaits the page's promise (`browser_evaluate`)
    /// or a frame to draw can be late while the renderer answers everything else. A call the renderer answers at once
    /// tells, and the page reads as not responding only when that one goes unanswered too. While it runs, it decides.
    private func devToolsTimedOut(_ method: String) {
        guard !isClosed, unanswered == nil, rendererCheck == nil, Self.needsRenderer(method) else { return }
        checkRenderer(after: method)
    }

    /// The check under way, or a new one: whether the renderer answers a call it answers at once. When it does not, the
    /// page is not responding after `method`.
    @discardableResult
    private func checkRenderer(after method: String) -> Task<Bool, Never> {
        if let rendererCheck { return rendererCheck }
        let wait = client?.rendererCheckWait ?? .seconds(5)
        let check = Task { @MainActor [weak self] in
            let answered: Bool
            do {
                _ = try await self?.devTools.send("Runtime.evaluate", ["expression": .string("0")], timeout: wait)
                answered = true
            } catch BrowserDevToolsError.timedOut {
                answered = false
            } catch {
                // The tab closed or the host went: nothing is known of the page.
                answered = true
            }
            guard let self else { return answered }
            self.rendererCheck = nil
            if !answered, !self.isClosed, self.unanswered == nil {
                self.unanswered = method
                self.client?.pageDidNotAnswer(self)
            }
            return answered
        }
        rendererCheck = check
        return check
    }

    /// After `method` to the tab timed out: whether the renderer answered the check after it (`devToolsTimedOut`), once
    /// that ends, or a check of its own when an earlier late call's check ended meanwhile; false when the page was
    /// already not responding, nil when nothing is checked (a call the renderer does not answer, such as
    /// `Page.navigate`, or a closed tab).
    func rendererAnswered(after method: String) async -> Bool? {
        guard !isClosed, Self.needsRenderer(method) else { return nil }
        if rendererCheck == nil, unanswered != nil { return false }
        return await checkRenderer(after: method).value
    }

    private func devToolsAnswered(_ method: String) {
        guard unanswered != nil, Self.needsRenderer(method) else { return }
        unanswered = nil
        client?.pageDidNotAnswer(self)
    }

    init(id: BrowserTabID, client: BrowserHostClient, session: UUID? = nil, key: UUID = UUID()) {
        self.id = id
        self.client = client
        self.session = session
        self.key = key
    }

    var isPanelAttached: Bool { panelCount > 0 }
    /// Attached panels that are on screen.
    var visiblePanelCount: Int { panelCount - occludedPanelCount }

    func send(_ command: BrowserHostCommand) {
        guard !isClosed else { return }
        var answered: Int?
        switch command {
        case .resize(_, let viewport):
            self.viewport = viewport
            if emulation == nil { ownViewport = viewport }
        case .mouse(_, let input) where input.kind == .down:
            lastPersonInput = .now
            lastPersonUse = .now
            tellDownloads()
        case .key(_, let input) where input.kind == .rawDown:
            lastPersonInput = .now
            lastPersonUse = .now
            tellDownloads()
        case .key(_, let input) where input.kind == .character:
            hadPersonEdits = true
        case .composition(_, .commit):
            lastPersonUse = .now
            hadPersonEdits = true
        case .wheel, .drag, .composition:
            lastPersonUse = .now
        case .edit(_, .paste), .edit(_, .cut), .edit(_, .delete), .edit(_, .undo), .edit(_, .redo):
            hadPersonEdits = true
        case .javaScriptDialogResult(_, let dialog, let accepted, _):
            if dialog == closeQuestion?.id {
                closeQuestion = nil
                if !accepted {
                    isClosing = false
                    client?.closeStayed(self)
                }
            }
            if dialog == javaScriptDialog?.id {
                javaScriptDialog = nil
                answered = dialog
            }
        case .fileDialogResult(_, let dialog, _) where dialog == fileDialog?.id:
            fileDialog = nil
            answered = dialog
        default:
            break
        }
        client?.send(command)
        // Whoever answered, the other (the panel, the agent's tools) hears that it no longer waits.
        if let answered {
            deliver(.dialogClosed(tab: id, dialog: answered))
            client?.personWaitChanged(self)
        }
    }

    /// The person used the page from its panel without a click or key press on it: an address, Back, Forward
    /// or Reload; or from a remote device (`remote`), whose input goes over DevTools (`edits`: they typed or deleted
    /// text).
    func notePersonInput(edits: Bool = false, remote: Bool = false) {
        let now = ContinuousClock.now
        lastPersonInput = now
        lastPersonUse = now
        if remote { lastRemoteInput = now }
        if edits { hadPersonEdits = true }
        tellDownloads()
    }

    /// The person's last input to the page came from a remote device, or a page the remote device's input drove opened
    /// this tab and no one here has used it since: what the page asks now (another app to open, a download) waits for
    /// someone at this Mac. The agent's use of the tab since, a read included, does not end it; the person's own input
    /// here does.
    var isDrivenByRemote: Bool {
        if let remote = lastRemoteInput { return remote == lastPersonInput }
        return remoteOpener && lastPersonInput == nil
    }

    /// The agent acted on the page (a click, typing, a navigation …), as opposed to reading it: what the page downloads
    /// from now is the agent's, also after a remote device's input. Another app still opens only when someone here
    /// chooses it (`isDrivenByRemote`).
    func noteAgentInput() {
        agentInputBefore = .some(lastAgentInput)
        lastAgentInput = .now
        client?.noteAgentActivity(on: self)
        tellDownloads()
    }

    /// The agent's act failed before it reached the page (a stale reference, a path not allowed, a locked vault): the
    /// page's downloads are as they were before it.
    func undoAgentInput() {
        guard let before = agentInputBefore else { return }
        agentInputBefore = nil
        lastAgentInput = before
        tellDownloads()
    }

    /// A tab a page opened answers to what drove that page: a remote device's input, and whether its downloads were
    /// refused.
    fileprivate func inherit(from opener: BrowserTab, retained: BrowserBlockedPopup? = nil) {
        // Match the host: either the original request or the opener's current input can restrict a popup.
        // Local input in this popup ends both inherited restrictions through tellDownloads().
        remoteOpener = retained?.drivenByRemote == true || opener.isDrivenByRemote
        openerRefusedDownloads = retained?.refusedDownloads == true || opener.refusesDownloads
        tellDownloads()
    }

    /// Downloads are refused while a remote device's input is the last that drove the page: until someone here uses
    /// it, or the agent acts on it, whose downloads are its own.
    private var refusesDownloadsNow: Bool {
        if let remote = lastRemoteInput, remote == lastPersonInput { return lastAgentInput.map { $0 < remote } ?? true }
        return openerRefusedDownloads && lastPersonInput == nil && lastAgentInput == nil
    }

    /// Tells the host to refuse the tab's downloads (`refusesDownloadsNow`), or to take them again: sent before the
    /// input that changed it goes, so a download that input starts is refused before it begins (the host also refuses
    /// those of a pop-up such a page opens).
    fileprivate func tellDownloads() {
        let refuses = refusesDownloadsNow
        guard refuses != refusesDownloads else { return }
        refusesDownloads = refuses
        client?.send(.refuseDownloads(tab: id, isRefused: refuses))
    }

    // MARK: A remote device's size (docs/REMOTE_PROTOCOL.md §15.25)

    /// A phone watches the tab at `emulation`'s size, or no phone does any more (nil): the tab then takes the size and
    /// emulation it had before, unless the person or the agent set another since, and the agent's own goes if its turn
    /// ended meanwhile, as it would have. The change runs in order with every other (`inEmulationOrder`) and reads the
    /// size asked for when its turn comes: sizes asked for while earlier changes run make one change, the latest.
    func sizeForRemote(_ emulation: BrowserViewportEmulation?) {
        let queued = remoteSize != nil
        remoteSize = .some(emulation)
        guard !queued else { return }
        Task { [weak self] in
            try? await self?.inEmulationOrder { [weak self] in
                guard let self, let asked = self.remoteSize else { return }
                self.remoteSize = nil
                if let asked {
                    if self.emulation?.owner != .remote { self.emulationBeforeRemote = .some(self.emulation) }
                    try await self.applyEmulation(asked)
                } else {
                    guard let before = self.emulationBeforeRemote else { return }
                    self.emulationBeforeRemote = nil
                    guard self.emulation?.owner == .remote else { return }
                    try await self.applyEmulation(before?.owner == .agent && !self.isInAgentTurn ? nil : before)
                }
            }
        }
    }

    /// The person opened an address from the address field: the page it commits counts as typed.
    func noteTypedNavigation() {
        typedNavigation = true
    }

    /// The agent's input came after the person's last (or the person has not used the page): what the page does
    /// now follows the agent.
    var isDrivenByAgent: Bool {
        if let agent = lastAgentActivity { return lastPersonInput.map { agent > $0 } ?? true }
        return openedByAgent && lastPersonInput == nil
    }

    /// The person's answer to the page's request to open another app.
    func answerExternalApp(open: Bool, alwaysAllow: Bool) {
        guard let question = externalAppQuestion else { return }
        externalAppQuestion = nil
        client?.answer(question, open: open, alwaysAllow: alwaysAllow, on: self)
        client?.personWaitChanged(self)
    }

    fileprivate func forgetBlockedPopup(_ id: BrowserTabID) {
        blockedPopupRequests.removeAll { $0.id == id }
        openingBlockedPopups.remove(id)
    }

    func close() {
        client?.closeTab(self)
    }

    /// Fronts this tab in its task's strip.
    func select() {
        client?.select(self)
    }

    /// Adds an event observer besides `eventHandler` (the agent's tools use this).
    @discardableResult
    func addEventObserver(_ observer: @escaping (BrowserHostEvent) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeEventObserver(_ token: UUID) {
        observers[token] = nil
    }

    /// Answers the page's permission prompt.
    func answerPermission(_ result: BrowserPermissionResult) {
        guard let prompt = permissionPrompt else { return }
        permissionPrompt = nil
        send(.permissionResult(tab: id, prompt: prompt.id, result: result))
        client?.personWaitChanged(self)
    }

    /// Reports agent use of this tab to the lifetime manager.
    func noteAgentActivity() {
        client?.noteAgentActivity(on: self)
    }

    // MARK: Screen size emulation

    /// Shows the page at `emulation`'s size, or at its view's own again for nil, as the Claude app's Browser pane
    /// does over CDP: the page lays out at the size (a phone also gets touch and Android Chrome's user agent), and
    /// the tab is drawn at it, so a panel shows it scaled down and the page's coordinates stay the agent's. It holds
    /// across reloads and navigations, since the tab's DevTools session keeps it.
    func emulate(_ emulation: BrowserViewportEmulation?) async throws {
        try await inEmulationOrder { try await self.applyEmulation(emulation) }
    }

    /// Runs one change of the emulation after those before it have done all their steps: the agent's, the panel's and a
    /// remote device's never interleave, so none comes back after a later one.
    private func inEmulationOrder(_ change: @escaping @MainActor () async throws -> Void) async throws {
        let earlier = emulationChanges
        let work = Task { @MainActor in
            await earlier?.value
            try await change()
        }
        emulationChanges = Task { @MainActor in _ = try? await work.value }
        try await work.value
    }

    private func applyEmulation(_ emulation: BrowserViewportEmulation?) async throws {
        // The size the tab has before its first emulation is its own, which it takes again after the last.
        if self.emulation == nil { ownViewport = viewport }
        self.emulation = emulation
        onEmulationChange?()
        let timeout: Duration = .seconds(15)
        if let emulation {
            _ = try await devTools.send("Emulation.setDeviceMetricsOverride", emulation.deviceMetrics, timeout: timeout)
            _ = try await devTools.send("Emulation.setTouchEmulationEnabled", emulation.mobile
                ? ["enabled": .bool(true), "maxTouchPoints": .integer(5)] : ["enabled": .bool(false)], timeout: timeout)
            if emulation.mobile {
                let identity = try await readBrowserIdentity()
                _ = try await devTools.send("Emulation.setUserAgentOverride", [
                    "userAgent": .string(BrowserViewportEmulation.phoneUserAgent(chromeMajor: identity.major)),
                    "userAgentMetadata": BrowserViewportEmulation.phoneUserAgentMetadata(brands: identity.brands)
                ], timeout: timeout)
            } else {
                _ = try await devTools.send("Emulation.setUserAgentOverride", ["userAgent": .string("")], timeout: timeout)
            }
        } else {
            _ = try await devTools.send("Emulation.clearDeviceMetricsOverride", timeout: timeout)
            _ = try await devTools.send("Emulation.setTouchEmulationEnabled", ["enabled": .bool(false)], timeout: timeout)
            _ = try await devTools.send("Emulation.setUserAgentOverride", ["userAgent": .string("")], timeout: timeout)
        }
        // A panel showing the tab draws it at the size itself (`onEmulationChange`); without one the tab does.
        guard !isPanelAttached, var size = emulation == nil ? ownViewport ?? viewport : viewport else { return }
        if let emulation {
            size.width = Double(emulation.width)
            size.height = Double(emulation.height)
        }
        send(.resize(tab: id, viewport: size))
    }

    /// Emulates `prefers-color-scheme` ("light" or "dark") on the page, or follows the Mac again for nil.
    func emulateColorScheme(_ scheme: String?) async throws {
        emulatedColorScheme = scheme
        _ = try await devTools.send("Emulation.setEmulatedMedia", [
            "features": .array([.object(["name": .string("prefers-color-scheme"), "value": .string(scheme ?? "")])])
        ], timeout: .seconds(15))
    }

    // MARK: Handing the tab to the person

    /// The agent hands the tab to the person for a step only they can take. A handoff still waiting for them takes the
    /// new reason, and one they answered after the agent's last wait gave up is returned as it is, so the call reads
    /// the answer. Returns the handoff and whether it is new.
    func handOff(reason: String) -> (handoff: BrowserHandoff, isNew: Bool) {
        if var earlier = handoff, earlier.answer != .turnEnded {
            if earlier.answer == nil {
                earlier.reason = reason
                handoff = earlier
                onHandoffChange?()
            }
            return (earlier, false)
        }
        let new = BrowserHandoff(id: UUID(), reason: reason)
        handoff = new
        onHandoffChange?()
        client?.personWaitChanged(self)
        return (new, true)
    }

    /// The person's answer from the panel's bar, or the end of the agent's turn.
    func answerHandoff(_ answer: BrowserHandoff.Answer) {
        guard var waiting = handoff, waiting.answer == nil else { return }
        waiting.answer = answer
        handoff = waiting
        onHandoffChange?()
        client?.personWaitChanged(self)
    }

    /// The agent's wait read the answer: the tab is the agent's again.
    func endHandoff() {
        guard handoff != nil else { return }
        handoff = nil
        onHandoffChange?()
    }

    // MARK: The agent's two-factor setup

    /// The agent asks the person to keep the setup its page shows. An ask still waiting for this setup is returned as
    /// it is, as is one answered after the agent's last wait gave up, so the call reads the answer; another setup takes
    /// the place of an unanswered ask. Returns the ask and whether it is new.
    func askToSaveSetup(_ setup: OneTimeCodeSetup, origin: String) -> (ask: BrowserVaultSetupAsk, isNew: Bool) {
        if let earlier = vaultSetupAsk, earlier.setup == setup, earlier.answer != .turnEnded, earlier.answer != .pageMoved {
            return (earlier, false)
        }
        let new = BrowserVaultSetupAsk(id: UUID(), setup: setup, origin: origin)
        vaultSetupAsk = new
        onVaultSetupAskChange?()
        return (new, true)
    }

    /// The person's answer from the panel's setup bar, the page moving on, or the end of the agent's turn.
    func answerSetupAsk(_ answer: BrowserVaultSetupAsk.Answer) {
        guard var waiting = vaultSetupAsk, waiting.answer == nil else { return }
        waiting.answer = answer
        vaultSetupAsk = waiting
        onVaultSetupAskChange?()
    }

    /// The agent's wait read the answer.
    func endSetupAsk() {
        guard vaultSetupAsk != nil else { return }
        vaultSetupAsk = nil
        onVaultSetupAskChange?()
    }

    /// The agent's turn ended: the size and color scheme it set go, as the Claude app clears them; the person's stay.
    func endAgentEmulation() async {
        if isInAgentTurn { agentTurnEndedAt = .now }
        isInAgentTurn = false
        // A waiting call reads that the turn ended; an answer no call read belongs to the turn that ended.
        if handoff?.answer == nil { answerHandoff(.turnEnded) } else { endHandoff() }
        if vaultSetupAsk?.answer == nil { answerSetupAsk(.turnEnded) } else { endSetupAsk() }
        if emulation?.owner == .agent { try? await emulate(nil) }
        // Under a phone's size, the agent's own goes with its turn: the phone's end takes the tab back to its own.
        if case .some(.some(let before)) = emulationBeforeRemote, before.owner == .agent { emulationBeforeRemote = .some(nil) }
        if emulatedColorScheme != nil { try? await emulateColorScheme(nil) }
    }

    private func readBrowserIdentity() async throws -> (major: String, brands: [JSONValue]) {
        if let browserIdentity { return browserIdentity }
        let read = try await devTools.send("Runtime.evaluate", [
            "expression": .string("[navigator.userAgent, navigator.userAgentData ? navigator.userAgentData.brands : []]"),
            "returnByValue": .bool(true)
        ], timeout: .seconds(15))
        let values = read["result"]?["value"]?.arrayValue ?? []
        let identity = (major: BrowserViewportEmulation.chromeMajor(in: values.first?.stringValue ?? "") ?? "154",
                        brands: values.count > 1 ? values[1].arrayValue ?? [] : [])
        browserIdentity = identity
        return identity
    }

    // MARK: Memory saver

    /// What the memory saver weighs about this tab (`BrowserMemorySaver.picks`); nil for a tab it never discards:
    /// shown, outside a task, already discarded or asked about.
    fileprivate func memorySaverCandidate(now: SuspendingClock.Instant, hasChromiumWindow: Bool,
                                          retryAfter: Duration) -> BrowserMemorySaver.Candidate? {
        guard session != nil, !isShown, let hiddenSince, !isDiscarded, !isDiscardAsked, !isClosed else { return nil }
        // What Chrome keeps whatever the memory: the tab a window shows (here a panel, also one off screen), a page
        // still loading, ended or stuck, a person's typing or a page asking the person something, a download, the
        // agent's tab in its turn or handed to the person, and pages that are not on the web.
        let isProtected = isPanelAttached || isLoading || crash != nil || openFailure != nil || unresponsive != nil
            || isClosing || handoff != nil || isInAgentTurn || hasChromiumWindow || hadPersonEdits
            || permissionPrompt != nil || externalAppQuestion != nil || closeQuestion != nil || javaScriptDialog != nil
            || fileDialog != nil || !activeDownloads.isEmpty || !BrowserMemorySaver.isWebPage(currentURL)
        // A tab the agent opened that no one has seen: the agent let it go when it hid or its turn ended, the later.
        let unseenAgentIdle = openedByAgent && !wasOnScreen
            ? max(hiddenSince, agentTurnEndedAt ?? hiddenSince).duration(to: now) : nil
        return BrowserMemorySaver.Candidate(
            tab: id, hidden: hiddenSince.duration(to: now), isProtected: isProtected,
            isProtectedFromProactive: workedInBackground,
            refusedRecently: discardRefusedAt.map { $0.duration(to: now) < retryAfter } ?? false,
            revisits: revisits, unseenAgentIdle: unseenAgentIdle)
    }

    /// A restored tab waits to be shown: hidden, its page not loaded, with the address, title and icon it had.
    fileprivate func holdUntilShown(_ address: String, title: String, favicon: Data?) {
        pendingAddress = address
        currentURL = address
        lastPageURL = address
        self.title = title
        titleAddress = address
        self.favicon = favicon
        faviconHost = URL(string: address)?.host()
        isDiscarded = true
        isShown = false
    }

    /// The address a restored tab opens at, once (`BrowserHostClient.wake`).
    fileprivate func takePendingAddress() -> String? {
        defer { pendingAddress = nil }
        return pendingAddress
    }

    /// The memory saver loads the discarded page again (`BrowserHostClient.wake`).
    fileprivate func beginRestore() {
        isDiscarded = false
        restore = .waiting
    }

    /// Waits until a discarded page the agent's tools woke has loaded again, at most `BrowserMemorySaver.restoreWait`,
    /// so a tool reads the page and not its load. A discard the host is still deciding is waited for too: if it ends
    /// the page, the tool's use loads it again.
    func untilRestored() async {
        let deadline = ContinuousClock.now + BrowserMemorySaver.restoreWait
        while restore != .none || isDiscardAsked, !isClosed, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The page's title or icon changed: while the tab is hidden and past its load, the page works in the background.
    private func noteChangeWhileHidden() {
        guard !isShown, documentStartedAt.duration(to: .now) > BrowserMemorySaver.backgroundActivityGrace else { return }
        workedInBackground = true
    }

    fileprivate func markClosed() {
        isClosed = true
        devTools.failPending()
    }

    /// What the person is waited on for in the tab's own state, to tell when it changes.
    private var waitMark: [String] {
        [javaScriptDialog.map { "\($0.id)" } ?? "", fileDialog.map { "\($0.id)" } ?? "",
         permissionPrompt.map { "\($0.id)" } ?? "", externalAppQuestion?.url ?? ""]
    }

    fileprivate func receive(_ event: BrowserHostEvent) {
        let mark = waitMark
        var closedDialogs: [Int] = []
        switch event {
        case .devTools(_, let message):
            devTools.receive(message)
        case .address(_, let url):
            currentURL = url
            navigations += 1
            if !url.isEmpty, url != "about:blank", client?.carriesFilledValue(url) != true { lastPageURL = url }
            // Another site's icon is not this page's; the same site's stays until its own arrives.
            if favicon != nil, URL(string: url)?.host() != faviconHost {
                favicon = nil
                faviconHost = nil
            }
        case .title(_, let title):
            let title = client?.carriesFilledValue(title) == true ? "" : title
            if title != self.title { noteChangeWhileHidden() }
            self.title = title
            titleAddress = currentURL
        case .favicon(_, let url, let png):
            noteChangeWhileHidden()
            favicon = png.isEmpty ? nil : png
            faviconHost = URL(string: currentURL ?? url)?.host()
        case .loading(_, let isLoading, let canGoBack, let canGoForward):
            self.isLoading = isLoading
            self.canGoBack = canGoBack
            self.canGoForward = canGoForward
            if isLoading {
                crash = nil
                isDiscarded = false
                if restore == .waiting { restore = .loading }
            } else if restore == .loading {
                restore = .none
            }
        case .discarded:
            blockedPopupRequests = []
            openingBlockedPopups = []
            // The page is gone with its renderer, and with it what it asked of the person.
            isDiscarded = true
            isDiscardAsked = false
            isPasswordFieldFocused = false
            closedDialogs += [javaScriptDialog?.id, fileDialog?.id].compactMap { $0 }
            if let chooser = fileDialog { client?.send(.fileDialogResult(tab: id, dialog: chooser.id, paths: nil)) }
            javaScriptDialog = nil
            fileDialog = nil
            permissionPrompt = nil
            externalAppQuestion = nil
            closeQuestion = nil
        case .discardRefused(_, let reason):
            isDiscardAsked = false
            discardRefusedAt = .now
            discardRefusal = reason
        case .download(_, let download):
            if [.started, .inProgress].contains(download.state) { activeDownloads.insert(download.id) }
            else { activeDownloads.remove(download.id) }
        case .responsiveness(_, let isResponsive):
            hangReported = !isResponsive
            waitedUntil = nil
            if isResponsive { unanswered = nil }
        case .pageCrashed(_, let reason, let status, let code):
            blockedPopupRequests = []
            openingBlockedPopups = []
            hangReported = false
            waitedUntil = nil
            unanswered = nil
            restore = .none
            isDiscardAsked = false
            crash = BrowserTabCrash(status: status ?? "crashed", code: code ?? 0, errorCode: reason)
            // A renderer that ended takes its dialog and chooser with it.
            closedDialogs += [javaScriptDialog?.id, fileDialog?.id].compactMap { $0 }
            if let chooser = fileDialog { client?.send(.fileDialogResult(tab: id, dialog: chooser.id, paths: nil)) }
            javaScriptDialog = nil
            fileDialog = nil
        case .passwordField(_, let isFocused):
            isPasswordFieldFocused = isFocused
        case .failed(let message, _?, let limit):
            openFailure = BrowserTabOpenFailure(message: message, limit: limit)
        case .openedTab(_, let newTab?, _):
            openedTabs.insert(newTab)
        case .newWindow(_, let url, _, false):
            // Chrome keeps the first 25 (PopupBlockerTabHelper kMaximumNumberOfPopups).
            if blockedPopupRequests.count < 25 {
                let id = (blockedPopupRequests.map(\.id).min() ?? 0) - 1
                blockedPopupRequests.append(BrowserBlockedPopup(id: min(-1, id), url: url,
                    openedByAgent: isDrivenByAgent, drivenByRemote: isDrivenByRemote, refusedDownloads: refusesDownloads))
            }
        case .blockedPopup(_, let popupTab, let url):
            if blockedPopupRequests.count < 25, !blockedPopupRequests.contains(where: { $0.id == popupTab }) {
                blockedPopupRequests.append(BrowserBlockedPopup(id: popupTab, url: url,
                    openedByAgent: isDrivenByAgent, drivenByRemote: isDrivenByRemote, refusedDownloads: refusesDownloads))
            }
        case .blockedPopupRemoved(_, let popupTab):
            forgetBlockedPopup(popupTab)
        case .blockedPopupRetry(_, let popupTab):
            openingBlockedPopups.remove(popupTab)
        case .popupPermission(_, let allowed):
            popupsAllowed = allowed
        case .newDocument:
            navigations += 1
            blockedPopupRequests = []
            openingBlockedPopups = []
            popupsAllowed = false
            externalAppQuestion = nil
            documentStartedAt = .now
            hadPersonEdits = false
            workedInBackground = false
            // The chooser was the document's that went, as Chrome's goes with its frame.
            if let chooser = fileDialog {
                fileDialog = nil
                client?.send(.fileDialogResult(tab: id, dialog: chooser.id, paths: nil))
                closedDialogs.append(chooser.id)
            }
        case .javaScriptDialog(_, let dialog):
            if dialog.kind == .beforeUnload && isClosing { closeQuestion = dialog }
            javaScriptDialog = dialog
            dialogByAgent = isDrivenByAgent
        case .javaScriptDialogReset:
            closeQuestion = nil
            if let dialog = javaScriptDialog {
                javaScriptDialog = nil
                closedDialogs.append(dialog.id)
            }
        case .fileDialog(_, let chooser):
            fileDialog = chooser
            fileDialogByAgent = isDrivenByAgent
        case .permissionPrompt(_, let prompt):
            permissionPrompt = prompt
        case .permissionPromptDismissed(_, let prompt):
            if permissionPrompt?.id == prompt { permissionPrompt = nil }
        case .terminated, .closed:
            blockedPopupRequests = []
            openingBlockedPopups = []
            popupsAllowed = false
            isClosed = true
            restore = .none
            permissionPrompt = nil
            externalAppQuestion = nil
            closeQuestion = nil
            javaScriptDialog = nil
            fileDialog = nil
            devTools.failPending()
        default:
            break
        }
        deliver(event)
        for dialog in closedDialogs { deliver(.dialogClosed(tab: id, dialog: dialog)) }
        if waitMark != mark { client?.personWaitChanged(self) }
    }

    private func deliver(_ event: BrowserHostEvent) {
        eventHandler?(event)
        for observer in observers.values { observer(event) }
        client?.onTabEvent?(self, event)
    }
}

/// The person is using a tab in its panel (`BrowserHostClient.personUse(of:)`).
struct BrowserPersonUse: Equatable, Sendable {
    /// The page has their keyboard.
    var hasKeyboard: Bool
    /// Since their last click, key, scroll or drag in it; nil when they have not used it.
    var secondsSinceInput: Int?
}

/// What a tab waits on from the person (`BrowserHostClient.personWait(of:)`): the panel that shows the tab shows it,
/// and the task's marks and one notification say so meanwhile.
struct BrowserPersonWait: Equatable, Hashable, Sendable {
    enum Kind: String, Sendable {
        /// The agent handed the tab over (`browser_handoff`).
        case handoff
        /// Chromium's passkey dialog (a passkey, a phone's QR code, a security key).
        case passkey
        /// Chromium's sign-in window for a site's HTTP authentication.
        case signIn
        /// The page asks a permission (Chrome's permission bubble).
        case permission
        /// The page asks to open another app.
        case externalApp
        /// An alert, confirm, prompt or "Leave site?".
        case javaScriptDialog
        /// A file chooser, to open or to save.
        case fileChooser
    }
    var kind: Kind
    /// Tells one wait from the next on the tab.
    var id: String
    /// The agent's own input led to it, and the agent can answer it too: a JavaScript dialog, a file chooser.
    var agentLed = false
}

/// A tab the agent handed to the person (`browser_handoff`): what it asks of them, and how it ended.
struct BrowserHandoff: Equatable, Sendable {
    enum Answer: Equatable, Sendable {
        /// The person's Done.
        case done
        /// The person's Decline.
        case declined
        /// The agent's turn ended first.
        case turnEnded
    }

    let id: UUID
    var reason: String
    var answer: Answer?
}

/// The agent's ask to keep a two-factor setup its page shows (`browser_fill_credential` with `one_time_code`,
/// docs/BROWSER_VAULT_DESIGN.md §20): the setup, where it showed, and the person's answer from the setup bar.
struct BrowserVaultSetupAsk: Equatable, Sendable {
    /// Where the person's Save keeps the code: the item the bar suggested, another of the site's items, or a new one.
    enum Target: Equatable, Sendable {
        case suggested
        case item(UUID)
        case newItem
    }

    enum Answer: Equatable, Sendable {
        /// The person's Save, from the panel's bar or the phone's I'm done; the agent's call keeps the code.
        case save(Target)
        /// The person's Not Now.
        case declined
        /// The page went to another address before the person answered.
        case pageMoved
        /// The agent's turn ended first.
        case turnEnded
    }

    let id: UUID
    var setup: OneTimeCodeSetup
    /// The page's origin, as the browser reported it.
    var origin: String
    var answer: Answer?
}

/// One of Chromium's own windows in the host, as the host tells what it is.
struct BrowserChromiumWindow: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// Chromium's passkey dialog (a passkey, a phone's QR code, a security key).
        case passkey
        /// Chromium's sign-in window for a site's HTTP authentication.
        case signIn
        /// The system's print dialog (`window.print()`, the PDF viewer's Print).
        case print
        case other
    }
    var title: String
    var kind: Kind
    /// The window's number in the host (`presentChromiumWindows` names it).
    var id: Int = 0
    /// The tab the window is over; nil when the host does not know it (the print dialog).
    var tab: BrowserTabID?
}

/// A task's tabs as they were when the host ended: their addresses and side-panel keys in strip order
/// and which was fronted.
struct BrowserRememberedTabs: Equatable, Sendable {
    var addresses: [String]
    /// One per address; an address without one opens as a new side-panel tab.
    var keys: [UUID] = []
    /// The pages' titles and icons, for the tabs that wait to be shown (`BrowserHostClient.restoreTabs`).
    var titles: [String] = []
    var favicons: [Data?] = []
    var fronted: Int

    func key(at index: Int) -> UUID {
        keys.indices.contains(index) ? keys[index] : UUID()
    }

    func title(at index: Int) -> String {
        titles.indices.contains(index) ? titles[index] : ""
    }

    func favicon(at index: Int) -> Data? {
        favicons.indices.contains(index) ? favicons[index] : nil
    }
}

/// Why the host could not open a tab, as it said (`BrowserHostEvent.failed`).
struct BrowserTabOpenFailure: Equatable, Sendable {
    let message: String
    /// The most tabs the host holds, when that many were open.
    let limit: Int?
}

/// Why a tab's page is not responding.
/// How a tab's renderer ended, as CEF reports it.
struct BrowserTabCrash: Equatable, Sendable {
    /// CEF's termination status: "crashed", "oom", "killed", "abnormal", "launch-failed" …
    let status: String
    /// The exit code: the signal's number when it crashed.
    let code: Int
    /// Chrome's sad tab's "Error code", as the host names it: SIGTRAP (a failed CHECK), SIGSEGV, Out of
    /// Memory …
    let errorCode: String
}

enum BrowserTabUnresponsiveness: Equatable, Sendable {
    /// Chromium's hang monitor: the renderer has not handled input for 15 seconds (the host reads it
    /// every second, and holds the hang monitor's callback to end the renderer where Chromium gives one).
    case hangMonitor
    /// The page did not answer `method`, a DevTools call its renderer answers, in time, nor the call it answers at once
    /// that checked it right after.
    case unanswered(method: String)
}

/// How a session's tab went (`BrowserHostClient.departure(of:)`).
enum BrowserTabDeparture: Equatable, Sendable {
    enum Cause: Equatable, Sendable {
        /// Its page did not respond, and it was opened again in its place (`BrowserHostClient.replace`).
        case notResponding
        /// The host could not open it, and it was opened again in its place (`BrowserHostClient.replace`).
        case couldNotOpen
        /// The browser host ended, and the session's tabs open again as they were (`restoreTabs`).
        case hostEnded
        /// The task took a browser profile of its own before its agent signed in to a site itself, and its tabs opened
        /// again there (`reopenTabs`).
        case ownProfile
    }
    /// Another tab took or takes its place as the same side-panel tab, `key`.
    case reopened(key: UUID, cause: Cause)
    /// The agent closed it (`browser_tab_close`).
    case closedByAgent
    /// The person closed it in the task's panel.
    case closedByPerson
    /// Its page closed itself (`window.close()`).
    case closedByPage
    /// Yardlet closed it: with the task's other tabs, or once the download it was opened for ended.
    case closed
    /// It went to another task with its page (`BrowserHostClient.move`).
    case moved
}

/// The tab is no longer open.
struct BrowserTabGoneError: LocalizedError, Equatable {
    var errorDescription: String? { "The browser tab is no longer open." }
}

/// The task already has a tab for that side-panel tab.
struct BrowserTabKeyInUseError: LocalizedError, Equatable {
    var errorDescription: String? { "This task already has a browser tab for that side-panel tab." }
}

/// A task already has `BrowserHostClient.maxTabsPerSession` tabs.
struct BrowserTabLimitError: LocalizedError, Equatable {
    var errorDescription: String? {
        "This task already has \(BrowserHostClient.maxTabsPerSession) browser tabs. Close one to open another."
    }
}
