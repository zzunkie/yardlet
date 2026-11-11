import Foundation
import Observation
import YardletRemote

/// A task's browser tabs for the remote (docs/REMOTE_PROTOCOL.md §15.25): the tabs the task's side panel lists, a picture
/// of a watched tab's visible page, and the person's clicks, scrolling and typing sent to it.
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
/// What it does not do: answer for another task's tabs or tabs outside any task; show or drive a `file:` page outside
/// the task's files (`RemoteFileReader.allowsPage`, as `readFile`); send anything while a Chromium window (a passkey, a
/// site's sign-in, one whose tab is not known) or a page's dialog is up, checked again before each step it sends; paste
/// or copy through the Mac's clipboard or press keys outside characters and the editing and moving keys; open another
/// app on this Mac from a remote click without someone here choosing it (`BrowserTab.isDrivenByRemote`); or go on with
/// input whose watch ended (`RemoteTabPermit`).
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
    }

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

    init(model: AppModel, environment: Environment) {
        self.model = model
        self.environment = environment
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
        for watch in watches {
            guard let session = UUID(uuidString: watch.taskID) else { continue }
            var keys = next[session] ?? [:]
            if let key = watch.tabID.flatMap(UUID.init(uuidString:)) {
                // Two phones at two sizes: the smaller, which both can show.
                let asked = [keys[key] ?? nil, watch.viewport].compactMap { $0 }
                keys[key] = asked.min { ($0.width, $0.height) < ($1.width, $1.height) }
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
        if !followed.isEmpty { observeWaits() }
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
            size(tab, to: nil)
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
        switch event {
        case .frame:
            guard followed[session]?.watched[key] != nil, paintTold.insert(key).inserted else { return }
            changeHandler?(.tabPainted(taskID: session.uuidString, tabID: key.uuidString))
        case .title, .address, .loading, .passwordField, .javaScriptDialog, .javaScriptDialogReset, .dialogClosed,
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

    /// The visible page as JPEG, scaled to fit `maxWidth` by `maxHeight` and never past the page's own pixels, through
    /// the agent's screenshot call; the page's size is a phone's while one is drawn at it. A page under a dialog or a
    /// Chromium window, whose renderer ended, or a `file:` page outside the task's files, is not pictured.
    func capture(taskID: String, tabID: String, maxWidth: Int, maxHeight: Int) async -> Result<RemoteTabFrame, RemoteError> {
        let tab: BrowserTab
        switch watchedTab(taskID: taskID, tabID: tabID) {
        case let .success(found): tab = found
        case let .failure(error): return .failure(error)
        }
        paintTold.remove(tab.key)
        if let refusal = blocked(tab) { return .failure(refusal) }
        guard tab.crash == nil, tab.openFailure == nil else {
            return .failure(RemoteError(.unavailable, "The page cannot be pictured now"))
        }
        // The page checked is the one pictured: one that moved meanwhile is not, also when it came back to the same
        // address (`BrowserTab.navigations`), nor one any of whose frames moved (`frameMark`).
        let page = tab.navigations
        if let refusal = await outsideFiles(tab.currentURL, taskID: taskID, in: tab) { return .failure(refusal) }
        // A frame that comes and goes between the two reads of the tree is heard as it navigates (the Page domain's
        // events, as the agent's tools follow a page's frames): a file outside the task's among them keeps the picture.
        _ = try? await tab.devTools.send("Page.enable", timeout: Self.captureTimeout)
        var navigatedFiles: Set<String> = []
        let listening = tab.devTools.observeEvents { method, params in
            guard method == "Page.frameNavigated", let address = params["frame"]?["url"]?.stringValue,
                  address.lowercased().hasPrefix("file:") else { return }
            navigatedFiles.insert(address)
        }
        defer { tab.devTools.stopObservingEvents(listening) }
        let frames: String
        switch await checkFrames(tab, taskID: taskID) {
        case let .success(mark): frames = mark
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
            let shot = try await tab.devTools.send("Page.captureScreenshot", [
                "format": .string("jpeg"), "quality": .integer(Self.jpegQuality),
                "clip": .object([
                    "x": .number(visual?["pageX"]?.doubleValue ?? 0), "y": .number(visual?["pageY"]?.doubleValue ?? 0),
                    "width": .number(width), "height": .number(height), "scale": .number(fit / pixelRatio)
                ])
            ], timeout: Self.captureTimeout)
            guard let data = shot["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) }) else {
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
            return .success(RemoteTabFrame(image: data, mediaType: "image/jpeg", width: Int((width * fit).rounded()),
                                           height: Int((height * fit).rounded()), viewportWidth: width, viewportHeight: height))
        } catch {
            return .failure(RemoteError(.unavailable, error.localizedDescription))
        }
    }

    static let captureTimeout: Duration = .seconds(5)
    static let jpegQuality: Int64 = 60

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

    func close(taskID: String, tabID: String, permit: RemoteTabPermit) async -> RemoteError? {
        guard permit.isValid else { return RemoteError(.notAllowed) }
        let tab: BrowserTab
        do { tab = try watchedTab(taskID: taskID, tabID: tabID).get() }
        catch { return error }
        if let refusal = await stepRefusal(tab, permit, PageScope(taskID: taskID)) { return refusal }
        guard let (_, client) = resolve(taskID), permit.isValid else { return RemoteError(.notAllowed) }
        tab.notePersonInput(remote: true)
        client.requestClose(tab)
        return nil
    }

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
                try await send(tab, "Input.dispatchMouseEvent", point.merging(["type": .string("mouseMoved")]) { $1 }, permit, scope)
                let press = point.merging(["button": .string(button), "clickCount": .integer(Int64(input.clickCount ?? 1))]) { $1 }
                try await send(tab, "Input.dispatchMouseEvent",
                               press.merging(["type": .string("mousePressed"), "buttons": .integer(buttonMask)]) { $1 }, permit, scope)
                try await send(tab, "Input.dispatchMouseEvent",
                               press.merging(["type": .string("mouseReleased"), "buttons": .integer(0)]) { $1 }, permit, scope)
            case .mouse:
                tab.notePersonInput(remote: true)
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
                if let refusal = await protectPassword(tab) { return refusal }
                try await send(tab, "Input.insertText", ["text": .string(input.text ?? "")], permit, scope)
            case .key:
                guard let press = BrowserAgentKeyPress.parse(input.key ?? "") else {
                    return RemoteError(.badRequest, "Unknown key \(input.key ?? "")")
                }
                guard Self.allows(press) else {
                    return RemoteError(.notAllowed, "Only characters and the editing and moving keys; never the clipboard's")
                }
                let types = press.key.text != nil
                tab.notePersonInput(edits: types || ["Backspace", "Delete"].contains(press.key.key), remote: true)
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
            case let .success(mark): frames = mark
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
    fileprivate func checkFrames(_ tab: BrowserTab, taskID: String) async -> Result<String, RemoteError> {
        guard let frames = try? await frameMark(tab) else {
            return .failure(RemoteError(.unavailable, "The page cannot be read now"))
        }
        for file in Set(frames.files) {
            if let refusal = await outsideFiles(file, taskID: taskID, in: tab) { return .failure(refusal) }
        }
        return .success(frames.mark)
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

    /// Keys a remote device presses (§15.25), what editing text takes and no more: one character, alone or with Shift;
    /// Return, Tab and Escape, alone or with Shift; Backspace, Delete, the arrows, Home, End, Page Up and Page Down,
    /// alone or with Shift, Option or ⌘ (words, lines, selection); and ⌘A, ⌘Z and ⇧⌘Z. Every other ⌘ or Control
    /// combination (the clipboard's in any spelling, the browser's own keys, the developer tools'), Insert and the
    /// function keys are not taken: the Mac's clipboard and windows are not the person's there.
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
