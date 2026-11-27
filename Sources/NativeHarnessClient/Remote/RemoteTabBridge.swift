#if canImport(IOSurface) && canImport(CoreImage) && canImport(ImageIO)
import CoreImage
import ImageIO
import IOSurface
#endif
import Foundation
import Observation
import YardletRemote

/// A task's browser tabs for the remote (docs/REMOTE_PROTOCOL.md §15.25): the tabs the task's side panel lists, a picture
/// of a watched tab's visible page, the person's clicks, scrolling and typing sent to it, and their answer to its site's
/// permission prompt, as the panel's permission bar gives it.
///
/// It goes through the paths the Mac already has: the task's tabs as the panel and the agent's tools see them
/// (`BrowserHostClient.tabs(forSession:)`, opening the ones the panel saved first, as the agent's first call does),
/// the agent's screenshot call (`Page.captureScreenshot`) and its trusted input (`Input.dispatchMouseEvent`,
/// `dispatchKeyEvent`, `insertText`), the panel's Back, Forward and Reload, and `browser_resize`'s emulation for a
/// phone's own size. The input counts as the person's, as the panel's does: the memory saver keeps a page they typed
/// in, and a password typed into the page keeps the agent's scripts and pictures off it while the vault is on, as one
/// typed in the panel does (refused when that cannot be marked). A tab paints, and takes a phone's size, while it is
/// watched, and goes back to how it was when no one watches it.
///
/// What the page copies because of a device's input (its ⌘C and ⌘X, or the page's Copy button it clicked) goes to that
/// device instead of this Mac's clipboard (`RemoteTabCopies`).
///
/// What it does not do: answer for another task's tabs or tabs outside any task; show or drive a `file:` page outside
/// the task's files (`RemoteFileReader.allowsPage`, as `readFile`); send anything while a Chromium window (a passkey, a
/// site's sign-in, one whose tab is not known) or a page's dialog is up, checked again before each step it sends; paste
/// or copy through the Mac's clipboard or press keys outside characters, the editing and moving keys, and ⌘C and ⌘X;
/// open another app on this Mac from a remote click without someone here choosing it (`BrowserTab.isDrivenByRemote`); or
/// go on with input whose watch ended (`RemoteTabPermit`).
@MainActor
final class RemoteTabBridge {
    /// What the Mac lends the bridge.
    struct Environment {
        /// The browser engine, when this build has one.
        var client: @MainActor () -> BrowserHostClient?
        /// Chromium on macOS performs editing keys only through the commands a key event carries.
        var usesMacEditingCommands = false
        /// A password typed into a page keeps the agent's scripts and pictures off it, as the panel's vault watch does
        /// (the vault or the wallet is on).
        var marksTypedSecrets: @MainActor () -> Bool = { false }
        #if canImport(IOSurface) && canImport(CoreImage) && canImport(ImageIO)
        /// The tab's latest painted view frame (`BrowserFrame` and its `IOSurfaceRef`), when the host shares frames as
        /// IOSurfaces (macOS CEF). Nil falls back to `Page.captureScreenshot`.
        var latestSurface: @MainActor (BrowserTabID) -> (frame: BrowserFrame, surface: IOSurfaceRef)? = { _ in nil }
        #endif
    }

    /// Persistent per-tab CDP frame-navigation state so repeated captures on an unchanged non-`file:` document can
    /// skip redundant `Page.enable` and `Page.getFrameTree` round-trips while preserving all `file:` security checks.
    @MainActor
    private final class FrameGuard {
        weak var tab: BrowserTab?
        var token: UUID?
        var pageEnabled = false
        var frameGeneration: UInt64 = 0
        var navigatedFiles: Set<String> = []
        var verifiedNavigations: Int?
        var verifiedGeneration: UInt64?
        var verifiedTaskID: String?
        var verifiedAgentFile: String?
        var verifiedHasFileFrame = true

        init(tab: BrowserTab) {
            self.tab = tab
        }

        func detach() {
            if let token { tab?.devTools.stopObservingEvents(token) }
            token = nil
        }
    }

    #if canImport(IOSurface) && canImport(CoreImage) && canImport(ImageIO)
    /// Pins an `IOSurfaceRef` for its lifetime so `SurfaceRing` cannot recycle it while off-main-thread JPEG encoding
    /// runs, and guarantees the use count is released on every exit path.
    private final class PinnedSurface: @unchecked Sendable {
        let surface: IOSurfaceRef

        init(_ surface: IOSurfaceRef) {
            self.surface = surface
            IOSurfaceIncrementUseCount(surface)
        }

        deinit {
            IOSurfaceDecrementUseCount(surface)
        }
    }
    #endif

    private struct Followed {
        var listToken: UUID
        var tabTokens: [BrowserTabID: (tab: BrowserTab, token: UUID)] = [:]
        /// The side-panel tabs watched for frames, and the size a phone asked each to be drawn at.
        var watched: [UUID: RemoteTabViewport?] = [:]
    }

    private weak var model: AppModel?
    private let environment: Environment
    var changeHandler: (@Sendable (RemoteBridgeChange) -> Void)?
    /// The files a task's `file:` pages may show (`RemoteFileScope`), as `readFile` reads them.
    var fileScope: @MainActor (String) async -> RemoteFileScope? = { _ in nil }
    private var followed: [UUID: Followed] = [:]
    /// The client the followed sessions' observers are on.
    private weak var followedClient: BrowserHostClient?
    /// A tab that painted is told of once until it is pictured, and a task's list once until it is read: a page
    /// paints up to 120 times a second.
    private var paintTold: Set<UUID> = []
    private var listTold: Set<UUID> = []
    private var observesWaits = false
    /// The phone size each tab is drawn at now.
    private var sized: [BrowserTabID: (tab: BrowserTab, viewport: RemoteTabViewport)] = [:]
    /// Recency order of viewports watching each tab key, so a newly active watcher wins over a stale smaller one.
    private var watchSequence: UInt64 = 0
    private var watchOrder: [UUID: [RemoteTabViewport: UInt64]] = [:]
    /// Persistent per-tab frame observers for `Page.frameNavigated` and `Page.enable` tracking.
    private var frameGuards: [BrowserTabID: FrameGuard] = [:]
    /// Adaptive JPEG quality state per watched tab key.
    private var lastCaptureAt: [UUID: ContinuousClock.Instant] = [:]
    private var lastCaptureWasMotion: [UUID: Bool] = [:]
    private var settleTasks: [UUID: Task<Void, Never>] = [:]
    /// What the watched tabs' pages copy for the devices whose input led to it.
    let copies = RemoteTabCopies()

    init(model: AppModel, environment: Environment) {
        self.model = model
        self.environment = environment
        copies.isWatched = { [weak self] tab in self?.isWatched(tab) == true }
        copies.carriesFilledValue = { [weak self] text in self?.environment.client()?.carriesFilledValue(text) ?? true }
        copies.showsPage = { [weak self] tab in
            guard let self, let session = self.session(of: tab) else { return false }
            return await PageScope(taskID: session.uuidString).check(tab, bridge: self) == nil
        }
        copies.deliver = { [weak self] tab, text, permit in
            guard let self, let session = self.session(of: tab) else { return }
            self.changeHandler?(.tabCopied(taskID: session.uuidString, tabID: tab.key.uuidString, text: text, permit: permit.id))
        }
    }

    /// A device watches the tab for frames now (not its list alone).
    private func isWatched(_ tab: BrowserTab) -> Bool {
        followed.values.contains { $0.watched[tab.key] != nil && $0.tabTokens[tab.id]?.tab === tab }
    }

    private func session(of tab: BrowserTab) -> UUID? {
        followed.first { $0.value.tabTokens[tab.id]?.tab === tab }?.key
    }

    var isAvailable: Bool { environment.client() != nil }

    // MARK: - Listing

    /// - Parameter opening: the panel's saved tabs, and those lost with the host, open first, as the panel or the agent's
    ///   first call opens them; without it (a watch of the list alone) they are listed as they were, and nothing starts.
    func tabs(taskID: String, opening: Bool = true) async -> Result<[RemoteBrowserTab], RemoteError> {
        guard let (session, client) = resolve(taskID) else {
            return .failure(isAvailable ? RemoteError(.notFound) : RemoteError(.unavailable, "This Mac has no browser engine"))
        }
        listTold.remove(session)
        let saved = client.tabs(forSession: session).isEmpty ? client.rememberedTabs(forSession: session) : nil
        if opening, saved != nil {
            _ = try? client.restoreTabs(forSession: session, viewport: .offscreenDefault)
        }
        var listed: [RemoteBrowserTab] = []
        // The open tab each entry is, for the file its agent opened there; a saved one has none and is known as no one's.
        var open: [BrowserTab?] = []
        if !opening, let saved {
            for index in saved.addresses.indices {
                var entry = RemoteBrowserTab(tabId: saved.key(at: index).uuidString)
                let title = saved.title(at: index)
                entry.title = title.isEmpty ? nil : RemoteText.short(title, RemoteText.titleLimit)
                let address = saved.addresses[index]
                entry.url = client.carriesFilledValue(address) ? URL(string: address).flatMap(Self.origin) : address
                entry.active = index == saved.fronted ? true : nil
                listed.append(entry)
                open.append(nil)
            }
        } else {
            let front = client.tab(forSession: session)
            open = client.tabs(forSession: session)
            listed = open.compactMap { $0.map { remote($0, in: session, client: client, front: front) } }
        }
        // A file outside the task's is named by its scheme alone, its title too (a file's title is its name or path),
        // unless it is the page the task's agent opened in that tab.
        for index in listed.indices {
            if let address = listed[index].url, address.lowercased().hasPrefix("file:"),
               await !showsAllowedPage(address, taskID: taskID, in: open[index]) {
                listed[index].url = "file://"
                listed[index].title = nil
                // Its permission prompt is answered on the Mac, as the page is shown and driven there.
                listed[index].permission = nil
            }
        }
        return .success(listed)
    }

    private func remote(_ tab: BrowserTab, in session: UUID, client: BrowserHostClient, front: BrowserTab?) -> RemoteBrowserTab {
        let waits = model?.browserHandoffWaits[session] ?? []
        let handoff = waits.first { $0.tabKey == tab.key }
            ?? (tab.handoff != nil && tab.handoff?.answer == nil ? waits.first { $0.tabKey == nil } : nil)
        var listed = RemoteBrowserTab(tabId: tab.key.uuidString)
        listed.title = tab.title.isEmpty ? nil : RemoteText.short(tab.title, RemoteText.titleLimit)
        // A `file:` page's title is that file's name: the page the tab moved to does not show it before it names itself.
        if let titled = tab.titleAddress, titled != tab.currentURL, titled.lowercased().hasPrefix("file:") { listed.title = nil }
        if let address = tab.currentURL ?? tab.pendingAddress, !address.isEmpty {
            // A page whose address carries a value the vault filled is named by its site only, as it is kept.
            listed.url = client.carriesFilledValue(address) ? URL(string: address).flatMap(Self.origin) : address
        }
        listed.active = tab === front ? true : nil
        listed.loading = tab.isLoading ? true : nil
        listed.canGoBack = tab.canGoBack ? true : nil
        listed.canGoForward = tab.canGoForward ? true : nil
        listed.waiting = client.personWait(of: tab)?.kind.rawValue
        listed.requestId = handoff?.notice
        listed.reason = handoff.flatMap { RemoteText.short($0.reason, RemoteText.requestDetailLimit) }
        listed.passwordField = tab.isPasswordFieldFocused ? true : nil
        if let field = tab.editableField {
            listed.editableField = true
            listed.inputMode = field.inputMode
            listed.editableFocusCount = max(1, tab.editableFocusCount)
        }
        listed.permission = tab.permissionPrompt.map {
            RemoteTabPermission(prompt: $0.id, origin: $0.origin, permissions: $0.permissions)
        }
        return listed
    }

    private static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host() else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    /// A `file:` page the task may show: one of its files or folders, as `readFile` would serve it, or, in `tab`, the page
    /// the task's agent last opened there (`BrowserTab.agentOpenedFile`). An address a remote device asks to open is
    /// checked without a tab: only the agent's own opening lets a file outside the task's files show.
    private func showsAllowedPage(_ address: String, taskID: String, in tab: BrowserTab? = nil) async -> Bool {
        if let tab, tab.isAgentOpenedFile(address) { return true }
        guard let path = URL(string: address)?.path(percentEncoded: false), let scope = await fileScope(taskID) else { return false }
        return await RemoteFileReader.perform { RemoteFileReader.allowsPage(path, in: scope) }
    }

    // MARK: - Watching

    /// Follows the watched tasks' lists, keeps the watched tabs painting and at a phone's size where one asked; a tab
    /// no longer watched paints, and is sized, as before.
    func setWatched(_ watches: Set<RemoteTabWatch>) {
        guard let client = environment.client() else { return }
        if followedClient !== client { unfollowAll() }
        followedClient = client
        var next: [UUID: [UUID: RemoteTabViewport?]] = [:]
        var requestedViewports: [UUID: Set<RemoteTabViewport>] = [:]
        for watch in watches {
            guard let session = UUID(uuidString: watch.taskID) else { continue }
            var keys = next[session] ?? [:]
            if let key = watch.tabID.flatMap(UUID.init(uuidString:)) {
                if let viewport = watch.viewport {
                    requestedViewports[key, default: []].insert(viewport)
                }
                if keys[key] == nil { keys[key] = .some(nil) }
            }
            next[session] = keys
        }
        // When multiple watchers share a tab, prefer the most recently added/active watcher's viewport instead of
        // clamping to the smallest screen, breaking simultaneous ties in favor of the wider viewport.
        let activeKeys = Set(next.values.flatMap(\.keys))
        for key in Array(watchOrder.keys) where !activeKeys.contains(key) {
            watchOrder[key] = nil
        }
        for (session, var keys) in next {
            for key in keys.keys {
                let current = requestedViewports[key] ?? []
                if current.isEmpty {
                    watchOrder[key] = nil
                    keys[key] = .some(nil)
                } else {
                    var order = (watchOrder[key] ?? [:]).filter { current.contains($0.key) }
                    let added = current.filter { order[$0] == nil }
                    if !added.isEmpty {
                        watchSequence &+= 1
                        for viewport in added {
                            order[viewport] = watchSequence
                        }
                    }
                    watchOrder[key] = order
                    let chosen = order.max { lhs, rhs in
                        if lhs.value != rhs.value { return lhs.value < rhs.value }
                        return (lhs.key.width, lhs.key.height) < (rhs.key.width, rhs.key.height)
                    }?.key
                    keys[key] = chosen
                }
            }
            next[session] = keys
        }
        for session in followed.keys where next[session] == nil { unfollow(session, in: client) }
        for (session, keys) in next {
            if followed[session] == nil {
                let token = client.addTabsObserver(forSession: session) { [weak self] in self?.tabsChanged(session) }
                followed[session] = Followed(listToken: token)
            }
            followed[session]?.watched = keys
            observeTabs(of: session, in: client)
        }
        paintTold = paintTold.filter { key in followed.values.contains { $0.watched[key] != nil } }
        let cadenceKeys = Set(settleTasks.keys).union(lastCaptureAt.keys).union(lastCaptureWasMotion.keys)
        for key in cadenceKeys where !activeKeys.contains(key) {
            clearCaptureCadence(for: key)
        }
        if !followed.isEmpty { observeWaits() }
    }

    private func clearCaptureCadence(for key: UUID) {
        settleTasks.removeValue(forKey: key)?.cancel()
        lastCaptureAt[key] = nil
        lastCaptureWasMotion[key] = nil
    }

    private func unfollowAll() {
        guard let client = followedClient else {
            followed = [:]
            return
        }
        for session in Array(followed.keys) { unfollow(session, in: client) }
    }

    private func unfollow(_ session: UUID, in client: BrowserHostClient) {
        guard let entry = followed.removeValue(forKey: session) else { return }
        client.removeTabsObserver(entry.listToken, forSession: session)
        for (tab, token) in entry.tabTokens.values {
            tab.removeEventObserver(token)
            client.setRemotelyWatched(false, tab: tab)
            copies.setWatched(false, tab: tab)
            size(tab, to: nil)
            frameGuards.removeValue(forKey: tab.id)?.detach()
            clearCaptureCadence(for: tab.key)
            watchOrder[tab.key] = nil
        }
        listTold.remove(session)
    }

    /// The session's tabs as they are now: each observed once, the watched ones painting and sized (a tab opened again
    /// in its place under the same panel tab is watched as the one it replaced).
    private func observeTabs(of session: UUID, in client: BrowserHostClient) {
        guard var entry = followed[session] else { return }
        let open = client.tabs(forSession: session)
        let openIDs = Set(open.map(\.id))
        for (id, observed) in entry.tabTokens where !openIDs.contains(id) {
            observed.tab.removeEventObserver(observed.token)
            entry.tabTokens[id] = nil
            sized[id] = nil
            frameGuards.removeValue(forKey: id)?.detach()
            clearCaptureCadence(for: observed.tab.key)
            copies.forget(observed.tab)
        }
        for tab in open {
            if entry.tabTokens[tab.id] == nil {
                let key = tab.key
                let token = tab.addEventObserver { [weak self] event in self?.tabEvent(event, key: key, session: session) }
                entry.tabTokens[tab.id] = (tab, token)
            }
            let watched = entry.watched.keys.contains(tab.key)
            client.setRemotelyWatched(watched, tab: tab)
            size(tab, to: watched ? entry.watched[tab.key] ?? nil : nil)
        }
        followed[session] = entry
        for tab in open { copies.setWatched(entry.watched.keys.contains(tab.key), tab: tab) }
    }

    /// Draws the tab at a phone's size, as `browser_resize` does, or takes it back to how it was: in the tab's order of
    /// emulation changes, the latest size asked for when its turn comes (`BrowserTab.sizeForRemote`).
    private func size(_ tab: BrowserTab, to viewport: RemoteTabViewport?) {
        guard sized[tab.id]?.viewport != viewport else { return }
        if viewport == nil, sized[tab.id] == nil { return }
        if let viewport { sized[tab.id] = (tab, viewport) } else { sized[tab.id] = nil }
        tab.sizeForRemote(viewport.map {
            BrowserViewportEmulation(width: $0.width, height: $0.height, mobile: $0.mobile ?? ($0.width < 768), owner: .remote)
        })
    }

    private func tabsChanged(_ session: UUID) {
        guard let client = followedClient else { return }
        observeTabs(of: session, in: client)
        tellList(session)
    }

    private func tabEvent(_ event: BrowserHostEvent, key: UUID, session: UUID) {
        // A page that finished loading takes copies too when it began before the script went in (a restored tab's first
        // page, a navigation under way as the watch began).
        if case .loading(_, false, _, _) = event, followed[session]?.watched[key] != nil,
           let tab = followed[session]?.tabTokens.values.first(where: { $0.tab.key == key })?.tab {
            copies.pageLoaded(tab)
        }
        switch event {
        case .frame:
            guard followed[session]?.watched[key] != nil, paintTold.insert(key).inserted else { return }
            changeHandler?(.tabPainted(taskID: session.uuidString, tabID: key.uuidString))
        case .title, .address, .loading, .passwordField, .editableField, .javaScriptDialog, .javaScriptDialogReset, .dialogClosed,
             .fileDialog, .permissionPrompt, .permissionPromptDismissed, .externalApp, .pageCrashed, .discarded, .closed:
            tellList(session)
        default:
            break
        }
    }

    private func tellList(_ session: UUID) {
        guard followed[session] != nil, listTold.insert(session).inserted else { return }
        changeHandler?(.browserTabs(session.uuidString))
    }

    /// A handoff, or what a tab waits on from the person, changed: the followed tasks' lists say it.
    private func observeWaits() {
        guard !observesWaits, let model else { return }
        observesWaits = true
        withObservationTracking {
            _ = model.browserHandoffWaits
            _ = model.browserWaits
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observesWaits = false
                for session in self.followed.keys { self.tellList(session) }
                if !self.followed.isEmpty { self.observeWaits() }
            }
        }
    }

    // MARK: - Pictures

    /// The visible page as JPEG, scaled to fit `maxWidth` by `maxHeight` and never past the page's own pixels, encoding
    /// directly from the host's latest painted IOSurface when it matches the tab's viewport or falling back to
    /// `Page.captureScreenshot`. A page under a dialog or a Chromium window, whose renderer ended, or a `file:` page
    /// outside the task's files, is not pictured.
    func capture(taskID: String, tabID: String, maxWidth: Int, maxHeight: Int) async -> Result<RemoteTabFrame, RemoteError> {
        let tab: BrowserTab
        switch watchedTab(taskID: taskID, tabID: tabID) {
        case let .success(found): tab = found
        case let .failure(error): return .failure(error)
        }
        paintTold.remove(tab.key)
        // Wait for any queued remote viewport resize before capturing so the first frame uses the requested width.
        await tab.waitForEmulation()
        guard !tab.isClosed else { return .failure(RemoteError(.notFound, "The task has no such tab")) }
        if let refusal = blocked(tab) { return .failure(refusal) }
        guard tab.crash == nil, tab.openFailure == nil else {
            return .failure(RemoteError(.unavailable, "The page cannot be pictured now"))
        }
        // The page checked is the one pictured: one that moved meanwhile is not, also when it came back to the same
        // address (`BrowserTab.navigations`), nor one any of whose frames moved (`frameMark`).
        let page = tab.navigations
        if let refusal = await outsideFiles(tab.currentURL, taskID: taskID, in: tab) { return .failure(refusal) }
        let frameGuard = ensureFrameGuard(for: tab)
        if !frameGuard.pageEnabled {
            if (try? await tab.devTools.send("Page.enable", timeout: Self.captureTimeout)) != nil {
                frameGuard.pageEnabled = true
            }
        }
        guard !tab.isClosed else { return .failure(RemoteError(.notFound, "The task has no such tab")) }
        guard tab.navigations == page else { return .failure(RemoteError(.unavailable, "The page moved")) }

        let now = ContinuousClock.now
        let isMotion = lastCaptureAt[tab.key].map { now - $0 < Self.motionWindow } ?? false
        let quality = isMotion ? Self.motionJPEGQuality : Self.jpegQuality

        #if canImport(IOSurface) && canImport(CoreImage) && canImport(ImageIO)
        // Fast path: encode directly from the host's latest matching IOSurface off the main thread.
        // Requires `Page.enable` so subframe navigations are observed; acquires and pins the IOSurface only AFTER
        // all pre-capture async checks complete so SurfaceRing cannot recycle it across an await.
        if frameGuard.pageEnabled, hasEligibleSurface(for: tab) {
            let emulationRevisionBefore = tab.emulationRevision
            let isFilePage = tab.currentURL?.lowercased().hasPrefix("file:") == true
            let alreadyVerified = !isFilePage
                && !frameGuard.verifiedHasFileFrame
                && frameGuard.verifiedNavigations == page
                && frameGuard.verifiedGeneration == frameGuard.frameGeneration
                && frameGuard.verifiedTaskID == taskID
                && frameGuard.verifiedAgentFile == tab.agentOpenedFile
                && frameGuard.navigatedFiles.isEmpty
            var verifiedMark: String?
            if !alreadyVerified {
                let genBeforeCheck = frameGuard.frameGeneration
                let priorFiles = frameGuard.navigatedFiles
                frameGuard.navigatedFiles.removeAll()
                for file in priorFiles {
                    if let refusal = await outsideFiles(file, taskID: taskID, in: tab) { return .failure(refusal) }
                }
                switch await checkFrames(tab, taskID: taskID) {
                case let .success(checked):
                    verifiedMark = checked.mark
                    if frameGuard.frameGeneration == genBeforeCheck, tab.navigations == page {
                        frameGuard.verifiedNavigations = page
                        frameGuard.verifiedGeneration = genBeforeCheck
                        frameGuard.verifiedTaskID = taskID
                        frameGuard.verifiedAgentFile = tab.agentOpenedFile
                        frameGuard.verifiedHasFileFrame = checked.hasFiles
                    }
                case let .failure(refusal):
                    return .failure(refusal)
                }
                guard tab.navigations == page else { return .failure(RemoteError(.unavailable, "The page moved")) }
            }
            let filesBeforeEncode = frameGuard.navigatedFiles
            frameGuard.navigatedFiles.removeAll()
            for file in filesBeforeEncode {
                if let refusal = await outsideFiles(file, taskID: taskID, in: tab) { return .failure(refusal) }
            }
            if let refusal = blocked(tab) { return .failure(refusal) }
            let genBeforeEncode = frameGuard.frameGeneration
            // Acquire and immediately pin the surface synchronously after all pre-capture awaits.
            if tab.navigations == page,
               tab.emulationRevision == emulationRevisionBefore,
               let candidate = acquirePinnedSurface(for: tab),
               let encoded = await Self.encodeSurfaceJPEG(candidate.pinned, maxWidth: maxWidth, maxHeight: maxHeight,
                                                          quality: quality) {
                if let refusal = blocked(tab) { return .failure(refusal) }
                let duringEncodeFiles = frameGuard.navigatedFiles
                frameGuard.navigatedFiles.removeAll()
                for file in duringEncodeFiles {
                    if let refusal = await outsideFiles(file, taskID: taskID, in: tab) { return .failure(refusal) }
                }
                guard tab.navigations == page,
                      tab.emulationRevision == emulationRevisionBefore,
                      frameGuard.frameGeneration == genBeforeEncode,
                      candidate.frame.sequence > tab.minimumValidFrameSequence else {
                    return .failure(RemoteError(.unavailable, "The page moved"))
                }
                if isFilePage || frameGuard.verifiedHasFileFrame, let verifiedMark {
                    guard (try? await frameMark(tab).mark) == verifiedMark else {
                        return .failure(RemoteError(.unavailable, "The page moved"))
                    }
                }
                recordCapture(for: tab, taskID: taskID, isMotion: isMotion)
                return .success(RemoteTabFrame(image: encoded.data, mediaType: "image/jpeg",
                                               width: encoded.width, height: encoded.height,
                                               viewportWidth: candidate.viewportWidth, viewportHeight: candidate.viewportHeight))
            }
        }
        #endif

        // Fallback path: CDP `Page.captureScreenshot` (headless/non-Mac hosts or before the first matching IOSurface).
        var navigatedFiles: Set<String> = []
        let listening = tab.devTools.observeEvents { method, params in
            guard method == "Page.frameNavigated", let address = params["frame"]?["url"]?.stringValue,
                  address.lowercased().hasPrefix("file:") else { return }
            navigatedFiles.insert(address)
        }
        defer { tab.devTools.stopObservingEvents(listening) }
        let frames: String
        switch await checkFrames(tab, taskID: taskID) {
        case let .success(checked): frames = checked.mark
        case let .failure(refusal): return .failure(refusal)
        }
        guard tab.navigations == page else { return .failure(RemoteError(.unavailable, "The page moved")) }
        do {
            let metrics = try await tab.devTools.send("Page.getLayoutMetrics", timeout: Self.captureTimeout)
            let visual = metrics["cssVisualViewport"]
            let width = visual?["clientWidth"]?.doubleValue ?? 0
            let height = visual?["clientHeight"]?.doubleValue ?? 0
            guard width >= 1, height >= 1 else { return .failure(RemoteError(.unavailable, "Nothing is visible")) }
            let ratio = try await tab.devTools.send("Runtime.evaluate", [
                "expression": .string("devicePixelRatio"), "returnByValue": .bool(true)
            ], timeout: Self.captureTimeout)["result"]?["value"]?.doubleValue ?? 1
            let pixelRatio = max(ratio, 0.1)
            // Image pixels per CSS pixel: as many as fit, at most the page's own.
            let fit = min(Double(maxWidth) / width, Double(maxHeight) / height, pixelRatio)
            func shoot(clipped: Bool) async throws -> Data? {
                var parameters: [String: JSONValue] = ["format": .string("jpeg"), "quality": .integer(quality)]
                if clipped {
                    parameters["clip"] = .object([
                        "x": .number(visual?["pageX"]?.doubleValue ?? 0), "y": .number(visual?["pageY"]?.doubleValue ?? 0),
                        "width": .number(width), "height": .number(height), "scale": .number(fit / pixelRatio)
                    ])
                }
                let shot = try await tab.devTools.send("Page.captureScreenshot", parameters, timeout: Self.captureTimeout)
                return shot["data"]?.stringValue.flatMap { Data(base64Encoded: $0) }
            }
            // At the page's own pixels the picture is the view as drawn now. Only accept an unclipped shot when its
            // actual pixel dimensions fit the requested budget and match the measured visual viewport; never overwrite
            // `viewportWidth`/`viewportHeight` with mismatched backing pixels.
            var imageSize = (width: Int((width * fit).rounded()), height: Int((height * fit).rounded()))
            var picture: Data?
            let expectedWidth = width * pixelRatio
            let expectedHeight = height * pixelRatio
            let tolerance = max(2.0, pixelRatio * 2.0)
            if fit >= pixelRatio, (visual?["scale"]?.doubleValue ?? 1) == 1, let whole = try await shoot(clipped: false),
               let pixels = Self.jpegSize(whole), pixels.width <= maxWidth, pixels.height <= maxHeight,
               abs(Double(pixels.width) - expectedWidth) <= tolerance,
               abs(Double(pixels.height) - expectedHeight) <= tolerance {
                picture = whole
                imageSize = (pixels.width, pixels.height)
            }
            if picture == nil {
                picture = try await shoot(clipped: true)
                if let picture, let pixels = Self.jpegSize(picture) {
                    imageSize = (pixels.width, pixels.height)
                }
            }
            guard let data = picture else {
                return .failure(RemoteError(.internal, "The browser returned no image"))
            }
            // The page or one of its frames went elsewhere while it was pictured, even if it came back: that picture
            // is not sent.
            guard tab.navigations == page, try await frameMark(tab).mark == frames else {
                return .failure(RemoteError(.unavailable, "The page moved"))
            }
            for file in navigatedFiles {
                if let refusal = await outsideFiles(file, taskID: taskID, in: tab) { return .failure(refusal) }
            }
            recordCapture(for: tab, taskID: taskID, isMotion: isMotion)
            return .success(RemoteTabFrame(image: data, mediaType: "image/jpeg", width: imageSize.width, height: imageSize.height,
                                           viewportWidth: width, viewportHeight: height))
        } catch {
            return .failure(RemoteError(.unavailable, error.localizedDescription))
        }
    }

    private func ensureFrameGuard(for tab: BrowserTab) -> FrameGuard {
        if let existing = frameGuards[tab.id], existing.tab === tab { return existing }
        frameGuards[tab.id]?.detach()
        let frameGuard = FrameGuard(tab: tab)
        frameGuard.token = tab.devTools.observeEvents { [weak frameGuard] method, params in
            guard let frameGuard else { return }
            switch method {
            case "Page.frameNavigated":
                frameGuard.frameGeneration &+= 1
                frameGuard.tab?.invalidateSurfaceSequence()
                if let address = params["frame"]?["url"]?.stringValue,
                   address.lowercased().hasPrefix("file:") {
                    frameGuard.navigatedFiles.insert(address)
                }
            case "Page.frameAttached", "Page.frameDetached", "Page.navigatedWithinDocument":
                frameGuard.frameGeneration &+= 1
                frameGuard.tab?.invalidateSurfaceSequence()
            default:
                break
            }
        }
        frameGuards[tab.id] = frameGuard
        return frameGuard
    }

    #if canImport(IOSurface) && canImport(CoreImage) && canImport(ImageIO)
    /// Checks whether the tab currently has a valid, in-order IOSurface candidate without retaining or pinning it
    /// across async security checks.
    private func hasEligibleSurface(for tab: BrowserTab) -> Bool {
        validatedSurface(for: tab) != nil
    }

    /// Acquires and immediately pins the tab's latest IOSurface when its frame sequence is strictly newer than the
    /// last invalidation (navigation, subframe change, or emulation change), not ahead of main-actor event delivery,
    /// and matches the tab's expected CSS viewport and backing scale.
    private func acquirePinnedSurface(for tab: BrowserTab)
        -> (frame: BrowserFrame, pinned: PinnedSurface, viewportWidth: Double, viewportHeight: Double)? {
        guard let validated = validatedSurface(for: tab) else { return nil }
        return (validated.frame, PinnedSurface(validated.surface), validated.viewportWidth, validated.viewportHeight)
    }

    private func validatedSurface(for tab: BrowserTab)
        -> (frame: BrowserFrame, surface: IOSurfaceRef, viewportWidth: Double, viewportHeight: Double)? {
        guard !tab.holdsLayout,
              let (frame, surface) = environment.latestSurface(tab.id),
              frame.layer == .view,
              frame.sequence > tab.minimumValidFrameSequence,
              frame.sequence <= tab.lastViewFrameSequence,
              frame.pixelWidth > 0, frame.pixelHeight > 0,
              IOSurfaceGetWidth(surface) == frame.pixelWidth,
              IOSurfaceGetHeight(surface) == frame.pixelHeight else { return nil }
        let expectedWidth: Double
        let expectedHeight: Double
        let expectedScale: Double
        if let emulation = tab.emulation {
            expectedWidth = Double(emulation.width)
            expectedHeight = Double(emulation.height)
            expectedScale = emulation.mobile ? 2 : (tab.viewport?.scale ?? 2)
        } else if let viewport = tab.viewport, viewport.width >= 1, viewport.height >= 1, viewport.scale > 0 {
            expectedWidth = viewport.width
            expectedHeight = viewport.height
            expectedScale = viewport.scale
        } else {
            return nil
        }
        guard abs(Double(frame.pixelWidth) - expectedWidth * expectedScale) <= 2,
              abs(Double(frame.pixelHeight) - expectedHeight * expectedScale) <= 2 else { return nil }
        return (frame, surface, expectedWidth, expectedHeight)
    }
    #endif

    private func recordCapture(for tab: BrowserTab, taskID: String, isMotion: Bool) {
        let key = tab.key
        lastCaptureAt[key] = .now
        lastCaptureWasMotion[key] = isMotion
        settleTasks.removeValue(forKey: key)?.cancel()
        guard isMotion, let session = UUID(uuidString: taskID) else { return }
        settleTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self, self.lastCaptureWasMotion[key] == true,
                  self.followed[session]?.watched[key] != nil else { return }
            self.lastCaptureWasMotion[key] = false
            self.settleTasks[key] = nil
            self.paintTold.insert(key)
            self.changeHandler?(.tabPainted(taskID: taskID, tabID: key.uuidString))
        }
    }

    #if canImport(IOSurface) && canImport(CoreImage) && canImport(ImageIO)
    nonisolated private static let surfaceCIContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Hardware-accelerated off-main-thread JPEG encoding directly from a pinned IOSurface, downscaling cleanly to
    /// fit `maxWidth`×`maxHeight` without upscaling past the surface's own pixels.
    private nonisolated static func encodeSurfaceJPEG(_ pinned: PinnedSurface, maxWidth: Int, maxHeight: Int,
                                                      quality: Int64) async -> (data: Data, width: Int, height: Int)? {
        guard maxWidth >= 1, maxHeight >= 1 else { return nil }
        let sourceWidth = IOSurfaceGetWidth(pinned.surface)
        let sourceHeight = IOSurfaceGetHeight(pinned.surface)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let worker = Task.detached(priority: .userInitiated) { () -> (data: Data, width: Int, height: Int)? in
            guard !Task.isCancelled else { return nil }
            var image = CIImage(ioSurface: pinned.surface)
            let scale = min(1.0, Double(maxWidth) / Double(sourceWidth), Double(maxHeight) / Double(sourceHeight))
            if scale < 1.0 {
                if let filter = CIFilter(name: "CILanczosScaleTransform") {
                    filter.setValue(image, forKey: kCIInputImageKey)
                    filter.setValue(scale, forKey: kCIInputScaleKey)
                    filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
                    if let scaled = filter.outputImage { image = scaled }
                } else {
                    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                }
                if image.extent.width > Double(maxWidth) || image.extent.height > Double(maxHeight) {
                    image = image.cropped(to: CGRect(
                        origin: image.extent.origin,
                        size: CGSize(width: min(image.extent.width, Double(maxWidth)),
                                     height: min(image.extent.height, Double(maxHeight)))
                    ))
                }
            }
            guard !Task.isCancelled, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            let compression = min(max(Double(quality) / 100.0, 0.1), 1.0)
            guard let data = Self.surfaceCIContext.jpegRepresentation(
                of: image, colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: compression]
            ), let pixels = Self.jpegSize(data) else { return nil }
            return (data, pixels.width, pixels.height)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
    #endif

    static let captureTimeout: Duration = .seconds(5)
    static let jpegQuality: Int64 = 72
    static let motionJPEGQuality: Int64 = 48
    static let motionWindow: Duration = .milliseconds(180)
    static let settleDelay: Duration = .milliseconds(180)

    /// A JPEG's size in pixels, from its frame header (the first start-of-frame segment); nil for anything else.
    nonisolated static func jpegSize(_ data: Data) -> (width: Int, height: Int)? {
        data.withUnsafeBytes { bytes -> (width: Int, height: Int)? in
            guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
            var index = 2
            while index + 9 <= bytes.count, bytes[index] == 0xFF {
                let marker = bytes[index + 1]
                // Padding before a marker.
                if marker == 0xFF {
                    index += 1
                    continue
                }
                // Every start of frame (C0–CF) but the table and arithmetic coding segments (C4, C8, CC): length,
                // precision, height, width.
                if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                    return (Int(bytes[index + 7]) << 8 | Int(bytes[index + 8]), Int(bytes[index + 5]) << 8 | Int(bytes[index + 6]))
                }
                index += 2 + (Int(bytes[index + 2]) << 8 | Int(bytes[index + 3]))
            }
            return nil
        }
    }

    // MARK: - Address and tab controls

    func open(taskID: String, tabID: String?, address: String, permit: RemoteTabPermit) async -> Result<String, RemoteError> {
        guard permit.isValid, let (session, client) = resolve(taskID) else { return .failure(RemoteError(.notAllowed)) }
        let destination: String
        do { destination = try BrowserURLPolicy.addressFieldURL(address) }
        catch { return .failure(RemoteError(.badRequest, "The address cannot be opened")) }
        if let refusal = await outsideFiles(destination, taskID: taskID) { return .failure(refusal) }
        guard permit.isValid, resolve(taskID) != nil else { return .failure(RemoteError(.notAllowed)) }
        do {
            let tab: BrowserTab
            if let tabID {
                tab = try watchedTab(taskID: taskID, tabID: tabID).get()
                if let refusal = await stepRefusal(tab, permit, PageScope(taskID: taskID)) { return .failure(refusal) }
                guard resolve(taskID) != nil else { return .failure(RemoteError(.notFound)) }
                tab.notePersonInput(remote: true)
                tab.noteTypedNavigation()
                tab.send(.navigate(tab: tab.id, url: destination))
            } else {
                // An unnamed Chromium window may be a sign-in or passkey sheet. Only the host answers it.
                guard !client.chromiumWindows.contains(where: { $0.kind != .print && $0.tab == nil }) else {
                    return .failure(RemoteError(.notAllowed))
                }
                if let front = client.tab(forSession: session), let refusal = blocked(front) { return .failure(refusal) }
                guard permit.isValid else { return .failure(RemoteError(.notAllowed)) }
                tab = try client.newTab(forSession: session, url: destination, viewport: .offscreenDefault, select: true)
                tab.notePersonInput(remote: true)
            }
            return .success(tab.key.uuidString)
        } catch let error as RemoteError { return .failure(error) }
        catch { return .failure(RemoteError(.unavailable)) }
    }

    /// Asks the tab to close as the panel's close button does (§15.30). A close shows and drives nothing of the page, so
    /// a `file:` page outside the task's files, which a device sees only as `file://`, closes too; what is over the page
    /// (a dialog, one of Chromium's windows) still waits on the Mac.
    func close(taskID: String, tabID: String, permit: RemoteTabPermit) async -> RemoteError? {
        guard permit.isValid else { return RemoteError(.notAllowed) }
        let tab: BrowserTab
        do { tab = try watchedTab(taskID: taskID, tabID: tabID).get() }
        catch { return error }
        if let refusal = blocked(tab) { return refusal }
        guard let (_, client) = resolve(taskID), permit.isValid else { return RemoteError(.notAllowed) }
        tab.notePersonInput(remote: true)
        client.requestClose(tab)
        return nil
    }

    /// The person's answer to the watched tab's permission prompt, as the panel's permission bar gives it
    /// (`BrowserTab.answerPermission`): Chromium keeps an allow or a block for the site. Only while that very prompt is
    /// up: a prompt the page asked again, or answered here meanwhile, is `notFound`, so an answer never reaches a newer
    /// prompt. The page's boundaries are the input's: nothing over it, and no `file:` page outside the task's files.
    func answerPermission(taskID: String, tabID: String, prompt: Int, answer: RemoteTabPermissionAnswer,
                          permit: RemoteTabPermit) async -> Result<RemoteTabPermission, RemoteError> {
        guard permit.isValid else { return .failure(RemoteError(.notAllowed, "The watch ended")) }
        let tab: BrowserTab
        switch watchedTab(taskID: taskID, tabID: tabID) {
        case let .success(found): tab = found
        case let .failure(error): return .failure(error)
        }
        guard tab.permissionPrompt?.id == prompt else { return .failure(Self.promptGone) }
        if let refusal = await stepRefusal(tab, permit, PageScope(taskID: taskID)) { return .failure(refusal) }
        // Checked again after the page's checks, with nothing to wait on between this and the answer.
        guard resolve(taskID) != nil, !tab.isClosed, let asked = tab.permissionPrompt, asked.id == prompt else {
            return .failure(Self.promptGone)
        }
        tab.answerPermission(BrowserPermissionResult(answer))
        return .success(RemoteTabPermission(prompt: asked.id, origin: asked.origin, permissions: asked.permissions))
    }

    private static let promptGone = RemoteError(.notFound, "The permission prompt is no longer up")

    // MARK: - Input

    /// The person's input to a watched tab, as trusted input the page cannot tell from a keyboard and mouse here. Each
    /// step goes only while `permit` holds and nothing is over the page.
    func input(taskID: String, tabID: String, _ input: RemoteTabInput, permit: RemoteTabPermit) async -> RemoteError? {
        let tab: BrowserTab
        switch watchedTab(taskID: taskID, tabID: tabID) {
        case let .success(found): tab = found
        case let .failure(error): return error
        }
        guard permit.isValid else { return RemoteError(.notAllowed, "The watch ended") }
        if let refusal = blocked(tab) { return refusal }
        if let button = input.button, button != "left" {
            // A middle click pastes on some pages, a right click opens a menu on this Mac: the left button only.
            return RemoteError(.notAllowed, "Only the left button")
        }
        let scope = PageScope(taskID: taskID)
        if let refusal = await scope.check(tab, bridge: self) { return refusal }
        let point: [String: JSONValue] = [
            "x": .number(input.x ?? 0), "y": .number(input.y ?? 0), "modifiers": .integer(Self.modifierBits(input.modifiers))
        ]
        let button = input.button ?? "left"
        let buttonMask: Int64 = button == "left" ? 1 : button == "right" ? 2 : 4
        do {
            switch input.kind {
            case .click:
                tab.notePersonInput(remote: true)
                copies.noteInput(on: tab, permit: permit)
                let reports = tab.editableFieldReports
                try await send(tab, "Input.dispatchMouseEvent", point.merging(["type": .string("mouseMoved")]) { $1 }, permit, scope)
                let press = point.merging(["button": .string(button), "clickCount": .integer(Int64(input.clickCount ?? 1))]) { $1 }
                try await send(tab, "Input.dispatchMouseEvent",
                               press.merging(["type": .string("mousePressed"), "buttons": .integer(buttonMask)]) { $1 }, permit, scope)
                try await send(tab, "Input.dispatchMouseEvent",
                               press.merging(["type": .string("mouseReleased"), "buttons": .integer(0)]) { $1 }, permit, scope)
                noteTapSettled(on: tab, reportsBefore: reports)
            case .mouse:
                tab.notePersonInput(remote: true)
                if input.action != "move" { copies.noteInput(on: tab, permit: permit) }
                let type = switch input.action {
                case "down": "mousePressed"
                case "up": "mouseReleased"
                default: "mouseMoved"
                }
                var event = point.merging(["type": .string(type)]) { $1 }
                if input.action != "move" || input.button != nil {
                    event["button"] = .string(button)
                    event["buttons"] = .integer(input.action == "up" ? 0 : buttonMask)
                    if input.action != "move" { event["clickCount"] = .integer(Int64(input.clickCount ?? 1)) }
                }
                try await send(tab, "Input.dispatchMouseEvent", event, permit, scope)
            case .scroll:
                tab.notePersonInput(remote: true)
                try await send(tab, "Input.dispatchMouseEvent", point.merging([
                    "type": .string("mouseWheel"), "deltaX": .number(input.deltaX ?? 0), "deltaY": .number(input.deltaY ?? 0)
                ]) { $1 }, permit, scope)
            case .text:
                tab.notePersonInput(edits: true, remote: true)
                copies.noteInput(on: tab, permit: permit)
                if let refusal = await protectPassword(tab) { return refusal }
                try await send(tab, "Input.insertText", ["text": .string(input.text ?? "")], permit, scope)
            case .key:
                guard let press = BrowserAgentKeyPress.parse(input.key ?? "") else {
                    return RemoteError(.badRequest, "Unknown key \(input.key ?? "")")
                }
                if let cut = Self.copyKey(press) {
                    // The page's copy of its selection, for the device's clipboard: never through this Mac's.
                    if let refusal = await stepRefusal(tab, permit, scope) { return refusal }
                    tab.notePersonInput(edits: cut, remote: true)
                    try await copies.copy(on: tab, cut: cut, permit: permit)
                    return nil
                }
                guard Self.allows(press) else {
                    return RemoteError(.notAllowed, "Only characters, the editing and moving keys, and ⌘C and ⌘X; never paste")
                }
                let types = press.key.text != nil
                tab.notePersonInput(edits: types || ["Backspace", "Delete"].contains(press.key.key), remote: true)
                copies.noteInput(on: tab, permit: permit)
                if types, let refusal = await protectPassword(tab) { return refusal }
                for event in press.keyEvents(macEditingCommands: environment.usesMacEditingCommands) {
                    try await send(tab, "Input.dispatchKeyEvent", event, permit, scope)
                }
            case .navigate:
                let action: BrowserNavigationAction = switch input.action {
                case "back": .back
                case "forward": .forward
                default: .reload
                }
                if let refusal = await stepRefusal(tab, permit, scope) { return refusal }
                tab.notePersonInput(remote: true)
                tab.send(.navigation(tab: tab.id, action: action))
            }
            return nil
        } catch let refusal as RemoteError {
            return refusal
        } catch {
            return RemoteError(.unavailable, error.localizedDescription)
        }
    }

    static let inputTimeout: Duration = .seconds(5)

    /// How long a tap's focus report may trail the tap's last DevTools answer: the renderer sends it on another channel.
    static var tapSettle: Duration = .milliseconds(250)

    /// A tap on a tab whose text field has focus may land in that field again, which no focus report says: once the
    /// tap has settled with the field still focused and no report since, the tab counts it (`noteEditableFieldTapped`),
    /// so a device raises the keyboard its person put away. A tap elsewhere blurs the field or moves focus, which the
    /// host reports within the wait; a page that keeps focus on a tap outside the field (a toolbar that cancels its
    /// mousedown) counts as a tap in it.
    private func noteTapSettled(on tab: BrowserTab, reportsBefore reports: Int) {
        guard tab.editableField != nil else { return }
        Task { @MainActor [weak tab] in
            try? await Task.sleep(for: Self.tapSettle)
            tab?.noteEditableFieldTapped(reportsBefore: reports)
        }
    }

    /// One step of input: sent only while the watch holds, nothing is over the page and the page is the one the input
    /// was checked on, right before it goes.
    private func send(_ tab: BrowserTab, _ method: String, _ params: [String: JSONValue], _ permit: RemoteTabPermit,
                      _ scope: PageScope) async throws {
        if let refusal = await stepRefusal(tab, permit, scope) { throw refusal }
        _ = try await tab.devTools.send(method, params, timeout: Self.inputTimeout)
    }

    private func stepRefusal(_ tab: BrowserTab, _ permit: RemoteTabPermit, _ scope: PageScope) async -> RemoteError? {
        guard permit.isValid else { return RemoteError(.notAllowed, "The watch ended") }
        if let refusal = blocked(tab) { return refusal }
        if let refusal = await scope.check(tab, bridge: self) { return refusal }
        // Checked again after the wait: what holds now is what the step goes to.
        guard permit.isValid else { return RemoteError(.notAllowed, "The watch ended") }
        return blocked(tab)
    }

    /// The page an input goes to: checked against the task's files at its first step, its frames included, and each
    /// step after goes only while the tab shows that page with those frames (`BrowserTab.navigations`, `frameMark`);
    /// after a move, even back to the same address, the rest of the input is not sent.
    final class PageScope {
        let taskID: String
        private var page: (navigations: Int, frames: String)?

        init(taskID: String) {
            self.taskID = taskID
        }

        @MainActor
        func check(_ tab: BrowserTab, bridge: RemoteTabBridge) async -> RemoteError? {
            let navigations = tab.navigations
            if let page {
                guard navigations == page.navigations, (try? await bridge.frameMark(tab).mark) == page.frames,
                      tab.navigations == navigations else { return RemoteError(.notAllowed, "The page moved") }
                return nil
            }
            if let refusal = await bridge.outsideFiles(tab.currentURL, taskID: taskID, in: tab) { return refusal }
            let frames: String
            switch await bridge.checkFrames(tab, taskID: taskID) {
            case let .success(checked): frames = checked.mark
            case let .failure(refusal): return refusal
            }
            guard tab.navigations == navigations else { return RemoteError(.notAllowed, "The page moved") }
            page = (navigations, frames)
            return nil
        }
    }

    /// The page's frames as Chromium has them now: the `file:` addresses they show, and a mark that changes when any
    /// frame goes to another document or address (a frame's own link or script moves it without the tab's address).
    fileprivate func frameMark(_ tab: BrowserTab) async throws -> (files: [String], mark: String) {
        let tree = try await tab.devTools.send("Page.getFrameTree", [:], timeout: Self.captureTimeout)
        var files: [String] = []
        var mark: [String] = []
        func visit(_ node: JSONValue) {
            if let frame = node["frame"] {
                let address = frame["url"]?.stringValue ?? ""
                mark.append([frame["id"]?.stringValue ?? "", frame["loaderId"]?.stringValue ?? "", address].joined(separator: " "))
                if address.lowercased().hasPrefix("file:") { files.append(address) }
            }
            node["childFrames"]?.arrayValue?.forEach(visit)
        }
        visit(tree["frameTree"] ?? .null)
        return (files, mark.joined(separator: "\n"))
    }

    /// The page's frames when none shows a `file:` page outside the task's files (an iframe or an embed of one, or a
    /// frame a link moved there), as the agent's tools hold them (`BrowserAgentPage.shownFiles`); their mark.
    fileprivate func checkFrames(_ tab: BrowserTab, taskID: String) async -> Result<(mark: String, hasFiles: Bool), RemoteError> {
        guard let frames = try? await frameMark(tab) else {
            return .failure(RemoteError(.unavailable, "The page cannot be read now"))
        }
        for file in Set(frames.files) {
            if let refusal = await outsideFiles(file, taskID: taskID, in: tab) { return .failure(refusal) }
        }
        return .success((frames.mark, !frames.files.isEmpty))
    }

    /// What keeps the tab from a remote device now: it closed, a page's dialog waits, or one of Chromium's windows is up
    /// over it or over a tab Chromium did not name (the print dialog aside), which only the Mac answers.
    private func blocked(_ tab: BrowserTab) -> RemoteError? {
        if tab.isClosed { return RemoteError(.notFound, "The task has no such tab") }
        if tab.javaScriptDialog != nil { return RemoteError(.notAllowed, "The page's dialog waits on the Mac") }
        let windows = environment.client()?.chromiumWindows ?? []
        if let window = windows.first(where: { $0.kind != .print && ($0.tab == tab.id || $0.tab == nil) }) {
            return RemoteError(.notAllowed, "A \(window.kind.rawValue) window is open on the Mac")
        }
        return nil
    }

    /// A `file:` page outside the task's files is neither shown nor driven, unless it is the one the agent opened in `tab`.
    fileprivate func outsideFiles(_ address: String?, taskID: String, in tab: BrowserTab? = nil) async -> RemoteError? {
        guard let address, address.lowercased().hasPrefix("file:") else { return nil }
        return await showsAllowedPage(address, taskID: taskID, in: tab) ? nil : RemoteError(.notAllowed, "Not one of the task's files")
    }

    /// Typing into a password field marks the page as one that holds a secret before the text goes in, so no script of
    /// the agent's reads it, as the panel's vault watch does; when that cannot be marked, nothing is typed.
    private func protectPassword(_ tab: BrowserTab) async -> RemoteError? {
        guard environment.marksTypedSecrets() else { return nil }
        // The host says when a password field takes the keyboard, but a key that just moved the focus there (Tab) can
        // come before that word does: the page is asked too.
        let password = tab.isPasswordFieldFocused
            ? true : await VaultPageScripts.focusMayBePassword(tab.devTools, timeout: Self.inputTimeout)
        guard password else { return nil }
        let marked = await VaultPageScripts.noteSecretsShown([], on: tab.devTools, fills: tab.vaultFills)
        return marked ? nil : RemoteError(.unavailable, "The password field could not be protected")
    }

    /// ⌘C (false) or ⌘X (true), which copy the page's selection for the device (`RemoteTabCopies.copy`); nil for any
    /// other key.
    static func copyKey(_ press: BrowserAgentKeyPress) -> Bool? {
        guard press.modifiers == [.meta], ["c", "x"].contains(press.key.key.lowercased()) else { return nil }
        return press.key.key.lowercased() == "x"
    }

    /// Keys a remote device presses (§15.25), what editing text takes and no more: one character, alone or with Shift;
    /// Return, Tab and Escape, alone or with Shift; Backspace, Delete, the arrows, Home, End, Page Up and Page Down,
    /// alone or with Shift, Option or ⌘ (words, lines, selection); and ⌘A, ⌘Z and ⇧⌘Z. ⌘C and ⌘X go another way
    /// (`copyKey`). Every other ⌘ or Control combination (paste in any spelling, the browser's own keys, the developer
    /// tools'), Insert and the function keys are not taken: the Mac's clipboard and windows are not the person's there.
    static func allows(_ press: BrowserAgentKeyPress) -> Bool {
        let key = press.key.key
        let modifiers = Set(press.modifiers)
        let editing: Set<String> = ["Backspace", "Delete", "Home", "End", "PageUp", "PageDown",
                                    "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"]
        if key.count == 1 { return modifiers.isSubset(of: [.shift]) || (["a", "z"].contains(key.lowercased())
            && modifiers.contains(.meta) && modifiers.isSubset(of: [.meta, .shift]) && (key.lowercased() == "z" || !modifiers.contains(.shift))) }
        if ["Enter", "Tab", "Escape"].contains(key) { return modifiers.isSubset(of: [.shift]) }
        guard editing.contains(key), modifiers.isSubset(of: [.shift, .alt, .meta]) else { return false }
        // Shift-Delete cuts.
        return !(key == "Delete" && modifiers.contains(.shift))
    }

    private static func modifierBits(_ names: [String]?) -> Int64 {
        Int64((names ?? []).reduce(0) { bits, name in
            switch name {
            case "alt": bits | BrowserAgentKeyPress.Modifier.alt.bit
            case "control": bits | BrowserAgentKeyPress.Modifier.control.bit
            case "meta": bits | BrowserAgentKeyPress.Modifier.meta.bit
            case "shift": bits | BrowserAgentKeyPress.Modifier.shift.bit
            default: bits
            }
        })
    }

    // MARK: - Tasks and tabs

    /// The listed task's session and the engine its tabs are in.
    private func resolve(_ taskID: String) -> (UUID, BrowserHostClient)? {
        guard let model, let session = UUID(uuidString: taskID), model.sidebarSessions.contains(where: { $0.id == session }),
              let client = environment.client() else { return nil }
        // The task's side panel hands the engine the tabs it saved, as before the agent's first call.
        _ = model.taskWorkspaces.state(for: session)
        return (session, client)
    }

    /// One of the listed task's open tabs that a connection watches.
    private func watchedTab(taskID: String, tabID: String) -> Result<BrowserTab, RemoteError> {
        guard let (session, client) = resolve(taskID) else { return .failure(RemoteError(.notFound)) }
        guard let key = UUID(uuidString: tabID), let tab = client.tab(key: key, forSession: session), !tab.isClosed else {
            return .failure(RemoteError(.notFound, "The task has no such tab"))
        }
        return .success(tab)
    }
}

/// A task's browser tabs (§15.25), through `RemoteTabBridge`.
extension AppModelRemoteBridge {
    func openTab(taskID: String, tabID: String?, address: String, permit: RemoteTabPermit) async -> Result<String, RemoteError> {
        await browser.open(taskID: taskID, tabID: tabID, address: address, permit: permit)
    }
    func closeTab(taskID: String, tabID: String, permit: RemoteTabPermit) async -> RemoteError? {
        await browser.close(taskID: taskID, tabID: tabID, permit: permit)
    }
    func answerTabPermission(taskID: String, tabID: String, prompt: Int, answer: RemoteTabPermissionAnswer,
                             permit: RemoteTabPermit) async -> Result<RemoteTabPermission, RemoteError> {
        await browser.answerPermission(taskID: taskID, tabID: tabID, prompt: prompt, answer: answer, permit: permit)
    }

    func browserTabs(taskID: String) async -> Result<[RemoteBrowserTab], RemoteError> {
        await browser.tabs(taskID: taskID)
    }

    func browserTabList(taskID: String) async -> Result<[RemoteBrowserTab], RemoteError> {
        await browser.tabs(taskID: taskID, opening: false)
    }

    func setWatchedTabs(_ watches: Set<RemoteTabWatch>) async {
        browser.setWatched(watches)
    }

    func captureTab(taskID: String, tabID: String, maxWidth: Int, maxHeight: Int) async -> Result<RemoteTabFrame, RemoteError> {
        await browser.capture(taskID: taskID, tabID: tabID, maxWidth: maxWidth, maxHeight: maxHeight)
    }

    func tabInput(taskID: String, tabID: String, input: RemoteTabInput, permit: RemoteTabPermit) async -> RemoteError? {
        await browser.input(taskID: taskID, tabID: tabID, input, permit: permit)
    }
}

extension BrowserPermissionResult {
    init(_ answer: RemoteTabPermissionAnswer) {
        switch answer {
        case .allow: self = .allow
        case .block: self = .block
        case .dismiss: self = .dismiss
        }
    }
}

extension RemoteTabPermissionAnswer {
    init(_ result: BrowserPermissionResult) {
        switch result {
        case .allow: self = .allow
        case .block: self = .block
        case .dismiss: self = .dismiss
        }
    }
}
