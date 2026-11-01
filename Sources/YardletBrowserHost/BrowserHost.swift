import AppKit
import Foundation
import IOSurface
import YardletCEFAccessibility
import YardletCEFBridge

/// The CEF side of Yardlet's browser host contract (BrowserHostProtocol.swift in the app). Commands
/// and events use the same JSON shape as the app's Codable enums: `{"<case>": {<fields>}}`.
@MainActor
final class BrowserHost {
    static var shared: BrowserHost!

    let arguments: HostArguments
    let output: EventOutput
    let surfaces: SurfaceExchange?
    private var isContextReady = false
    private var queuedCommands: [[String: Any]] = []
    private var isShuttingDown = false
    private var sequence: UInt64 = 0
    private var popupRects: [Int: [String: Any]] = [:]
    private var frameCount = 0
    /// Chromium's own windows (the passkey dialog) and the activation they need.
    private var chromiumWindows: ChromiumWindows?
    /// Where tasks' own request contexts keep their data (docs/BROWSER_SESSION_ISOLATION.md).
    var profiles: TaskProfiles?
    /// Tabs not at their page yet: Chromium is still loading their profile from disk (the browser is made
    /// once it has), or a task's tab waits on about:blank while its context takes cookies: a new task's starting
    /// cookies, the person's sign-ins it follows. The address (or the one navigated to meanwhile) loads after that.
    private struct WaitingTab {
        var url: String
        /// The address the browser is made at: about:blank while it takes cookies.
        var start: String
        /// The copies still to run, in order, into `profile`.
        var copies: [TaskProfiles.Copy] = []
        var profile = ""
        var copyRequest: Int32?
    }
    private var waitingTabs: [Int: WaitingTab] = [:]
    /// DevTools messages for a waiting tab (the agent's first navigation), sent once it is at its page.
    private var deferredDevTools: [Int: [String]] = [:]
    private var nextCookieCopy: Int32 = 1
    /// Imports under way (the copy's request → the app's), answered with `cookiesImported`.
    private var cookieImports: [Int32: Int] = [:]
    /// The app's copies under way (the copy's request → the app's), answered with `cookiesCopied`.
    private var cookieCopies: [Int32: Int] = [:]
    /// Digests under way (the bridge's request → the app's), answered with `cookieDigest`.
    private var cookieDigests: [Int32: Int] = [:]
    /// The memory saver's discards (docs/BROWSER_HOST.md §3 "Memory saver").
    private lazy var discarder = TabDiscarder(send: { [weak self] in self?.send($0) })

    init(arguments: HostArguments, output: EventOutput) {
        self.arguments = arguments
        self.output = output
        surfaces = SurfaceExchange(portName: arguments.surfacePortName, token: arguments.surfaceToken)
    }

    // MARK: Commands

    func receive(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.count == 1 else { return }
        if isContextReady { perform(object) } else { queuedCommands.append(object) }
    }

    func contextInitialized() {
        isContextReady = true
        let engine = "CEF 154.0.28 / Chromium 154.0.8037.58"
        send(["ready": ["processID": Int(ProcessInfo.processInfo.processIdentifier), "engine": engine,
                        "acceleratedPaint": arguments.acceleratedPaint]])
        chromiumWindows = ChromiumWindows(send: { [weak self] in self?.send($0) },
                                          setHidden: { yardlet_cef_set_hidden(Int32($0), $1 ? 1 : 0) })
        watchResponsiveness()
        let queued = queuedCommands
        queuedCommands = []
        queued.forEach(perform)
#if DEBUG
        if !arguments.accessibilityRecordPath.isEmpty { QAWindowWatcher.start(beside: arguments.accessibilityRecordPath) }
#endif
    }

    private func perform(_ command: [String: Any]) {
        guard let (name, value) = command.first, let fields = value as? [String: Any] else { return }
        let tab = fields["tab"] as? Int ?? -1
#if DEBUG
        // QA runs (the fixture sets the recording folder) trace commands against Chromium's log.
        if !arguments.accessibilityRecordPath.isEmpty, name != "mouse" || (fields["input"] as? [String: Any])?["kind"] as? String != "move" {
            var now = timeval()
            gettimeofday(&now, nil)
            var local = tm()
            var seconds = now.tv_sec
            localtime_r(&seconds, &local)
            var detail = ""
            if name == "devTools", let message = fields["message"] as? String,
               let method = message.range(of: #""method":"[A-Za-z.]+""#, options: .regularExpression) {
                detail = String(message[method])
            }
            FileHandle.standardError.write(Data(String(format: "[%02d%02d%02d.%06d] command %@ tab=%d %@\n", local.tm_hour, local.tm_min,
                                                       local.tm_sec, now.tv_usec, name, tab, detail).utf8))
        }
#endif
        switch name {
        case "open":
            guard let requested = fields["url"] as? String, let viewport = fields["viewport"] as? [String: Any] else { return }
            let url = Self.isAllowed(requested) ? requested : "about:blank"
            if url != requested { send(["navigationBlocked": ["tab": tab, "url": requested]]) }
            // A task's tabs share its own context; a new one starts with the cookies of the one it seeds from, and
            // one that follows the person's sign-ins takes those it has not yet.
            let profile = profiles?.prepare(fields["profile"] as? [String: Any])
            let copies = profile?.copies ?? []
            let start = copies.isEmpty ? url : "about:blank"
            // 2: the profile is still loading; the browser follows with YardletCEFEventProfileReady.
            let created = yardlet_cef_create_browser(
                Int32(tab), start, number(viewport["width"]),
                number(viewport["height"]), number(viewport["scale"], default: 1), number(viewport["screenX"]),
                number(viewport["screenY"]), frameRate(viewport), arguments.acceleratedPaint ? 1 : 0, profile?.path ?? ""
            )
            if created == -1 {
                let limit = Int(yardlet_cef_browser_limit())
                return notOpened(tab, "limit", "The browser already has \(limit) tabs open across tasks, its most; closing a "
                                 + "tab in this or another task makes room for this one", limit: limit)
            }
            guard created != 0 else { return notOpened(tab, "chromium", "Chromium could not create a browser for tab \(tab)") }
            send(["opened": ["tab": tab]])
            if created == 2 || !copies.isEmpty {
                waitingTabs[tab] = WaitingTab(url: url, start: start, copies: copies, profile: profile?.path ?? "")
            }
            if created == 1 { advance(tab) }
            // A profile that never loads leaves no tab waiting for good.
            if created == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.profileDeadline) { [weak self] in
                    MainActor.assumeIsolated {
                        guard yardlet_cef_cancel_waiting_browser(Int32(tab)) == 1 else { return }
                        self?.notOpened(tab, "profile", "The tab's browser profile did not load within "
                                        + "\(Int(Self.profileDeadline)) seconds")
                    }
                }
            }
        case "copyCookies":
            // The person signed in on a task's page: that site's cookies go to the default profile and the tasks
            // that follow the person's sign-ins, in place of theirs (docs/BROWSER_SESSION_ISOLATION.md 11). The app
            // hears when the target has them.
            let asked = fields["request"] as? Int ?? 0
            guard let profiles, let domain = fields["domain"] as? String, !domain.isEmpty else {
                return send(["cookiesCopied": ["request": asked, "count": -1]])
            }
            let from = profiles.path(forKey: fields["from"] as? String)
            let to = profiles.path(forKey: fields["to"] as? String)
            guard from != to else { return send(["cookiesCopied": ["request": asked, "count": 0]]) }
            let request = nextCookieCopy
            nextCookieCopy += 1
            cookieCopies[request] = asked
            if !Self.copyCookies(request, TaskProfiles.Copy(from: from, sites: [domain], mode: fields["replace"] as? Bool == true ? 1 : 0),
                                 to: to) {
                cookieCopies[request] = nil
                send(["cookiesCopied": ["request": asked, "count": -1]])
            }
        case "cookieDigest":
            // Whether a sign-in changed a site's cookies, without their values leaving the host.
            let asked = fields["request"] as? Int ?? 0
            guard let profiles, let site = fields["site"] as? String else {
                return send(["cookieDigest": ["request": asked, "digest": ""]])
            }
            let request = nextCookieCopy
            nextCookieCopy += 1
            cookieDigests[request] = asked
            if yardlet_cef_cookie_digest(request, profiles.path(forKey: fields["profile"] as? String), site) != 1 {
                cookieDigests[request] = nil
                send(["cookieDigest": ["request": asked, "digest": ""]])
            }
        case "importCookies":
            // The person brings sites' sign-ins over from another browser (docs/BROWSER_SESSION_ISOLATION.md 10).
            let asked = fields["request"] as? Int ?? 0
            guard let profiles, let sites = fields["sites"] as? [String], let cookies = fields["cookies"] as? [[String: Any]] else {
                return send(["cookiesImported": ["request": asked, "count": -1]])
            }
            let to = profiles.path(forKey: fields["to"] as? String)
            // A task profile without its folder yet starts from the default profile's cookies when its first tab opens.
            guard to.isEmpty || FileManager.default.fileExists(atPath: to) else {
                return send(["cookiesImported": ["request": asked, "count": 0]])
            }
            let request = nextCookieCopy
            nextCookieCopy += 1
            cookieImports[request] = asked
            if !Self.importCookies(request, to: to, sites: sites, cookies: cookies) {
                cookieImports[request] = nil
                send(["cookiesImported": ["request": asked, "count": -1]])
            }
        case "resize":
            guard let viewport = fields["viewport"] as? [String: Any] else { return }
            yardlet_cef_set_viewport(Int32(tab), number(viewport["width"]), number(viewport["height"]),
                                     number(viewport["scale"], default: 1), number(viewport["screenX"]),
                                     number(viewport["screenY"]), frameRate(viewport))
        case "navigate":
            guard let url = fields["url"] as? String else { return }
            // A waiting tab loads this address once it can.
            if waitingTabs[tab] != nil {
                if Self.isAllowed(url) { waitingTabs[tab]?.url = url }
                return
            }
            if Self.isAllowed(url) { yardlet_cef_load_url(Int32(tab), url) }
            else { send(["navigationBlocked": ["tab": tab, "url": url]]) }
        case "navigation":
            let actions = ["back": 0, "forward": 1, "reload": 2, "stop": 3]
            if let action = (fields["action"] as? String).flatMap({ actions[$0] }) {
                yardlet_cef_navigation(Int32(tab), Int32(action))
            }
        case "mouse":
            guard let input = fields["input"] as? [String: Any] else { return }
            let kinds = ["move": 0, "down": 1, "up": 2, "leave": 3]
            let buttons = ["left": 0, "middle": 1, "right": 2]
            yardlet_cef_send_mouse(
                Int32(tab), Int32(kinds[input["kind"] as? String ?? ""] ?? 0),
                Int32(number(input["x"]).rounded()), Int32(number(input["y"]).rounded()),
                Int32(buttons[input["button"] as? String ?? ""] ?? 0), Int32(input["clickCount"] as? Int ?? 1),
                UInt32(input["modifiers"] as? Int ?? 0)
            )
        case "wheel":
            guard let input = fields["input"] as? [String: Any] else { return }
            yardlet_cef_send_wheel(
                Int32(tab), Int32(number(input["x"]).rounded()), Int32(number(input["y"]).rounded()),
                Int32(number(input["deltaX"]).rounded()), Int32(number(input["deltaY"]).rounded()),
                UInt32(input["modifiers"] as? Int ?? 0)
            )
        case "key":
            guard let input = fields["input"] as? [String: Any] else { return }
            // cef_key_event_type_t: RAWKEYDOWN 0, KEYDOWN 1, KEYUP 2, CHAR 3.
            let kinds = ["rawDown": 0, "up": 2, "character": 3]
            yardlet_cef_send_key(
                Int32(tab), Int32(kinds[input["kind"] as? String ?? ""] ?? 0),
                UInt32(input["modifiers"] as? Int ?? 0), Int32(input["windowsKeyCode"] as? Int ?? 0),
                Int32(input["nativeKeyCode"] as? Int ?? 0), (input["isSystemKey"] as? Bool ?? false) ? 1 : 0,
                UInt16(input["character"] as? Int ?? 0), UInt16(input["unmodifiedCharacter"] as? Int ?? 0)
            )
        case "composition":
            guard let composition = fields["composition"] as? [String: Any] else { return }
            performComposition(tab: Int32(tab), composition)
        case "zoom":
            let actions = ["zoomIn": 0, "zoomOut": 1, "reset": 2]
            if let action = (fields["action"] as? String).flatMap({ actions[$0] }) {
                yardlet_cef_zoom(Int32(tab), Int32(action))
            }
        case "find":
            yardlet_cef_find(Int32(tab), fields["text"] as? String ?? "", (fields["forward"] as? Bool ?? true) ? 1 : 0,
                             (fields["matchCase"] as? Bool ?? false) ? 1 : 0, (fields["findNext"] as? Bool ?? false) ? 1 : 0)
        case "stopFinding":
            yardlet_cef_stop_finding(Int32(tab), (fields["clearSelection"] as? Bool ?? true) ? 1 : 0)
        case "drag":
            guard let input = fields["input"] as? [String: Any] else { return }
            let phases = ["enter": 0, "over": 1, "leave": 2, "drop": 3]
            let files = (input["files"] as? [String]) ?? []
            withCStringArray(files) { pointers in
                yardlet_cef_drag(Int32(tab), Int32(phases[input["phase"] as? String ?? ""] ?? 2),
                                 Int32(number(input["x"]).rounded()), Int32(number(input["y"]).rounded()),
                                 pointers, Int32(files.count), UInt32(input["operations"] as? Int ?? 1),
                                 UInt32(input["modifiers"] as? Int ?? 0))
            }
        case "javaScriptDialogResult":
#if DEBUG
            FileHandle.standardError.write(Data("javaScriptDialogResult id=\(fields["dialog"] ?? "") accepted=\(fields["accepted"] ?? "")\n".utf8))
#endif
            yardlet_cef_jsdialog_result(Int32(fields["dialog"] as? Int ?? -1), (fields["accepted"] as? Bool ?? false) ? 1 : 0,
                                        fields["text"] as? String ?? "")
        case "fileDialogResult":
            let dialog = Int32(fields["dialog"] as? Int ?? -1)
            if let paths = fields["paths"] as? [String] {
                withCStringArray(paths) { yardlet_cef_file_dialog_result(dialog, $0, Int32(paths.count)) }
            } else {
                yardlet_cef_file_dialog_result(dialog, nil, -1)
            }
        case "cancelDownload":
            yardlet_cef_cancel_download(Int32(fields["download"] as? Int ?? -1))
        case "permissionResult":
            let results = ["allow": 0, "block": 1, "dismiss": 2]
            guard let prompt = fields["prompt"] as? Int, let result = (fields["result"] as? String).flatMap({ results[$0] })
            else { return }
            FileHandle.standardError.write(Data("permission result id=\(prompt) \(fields["result"] ?? "")\n".utf8))
            yardlet_cef_permission_result(UInt64(truncatingIfNeeded: prompt), Int32(result))
        case "edit":
            let actions = ["undo": 0, "redo": 1, "cut": 2, "copy": 3, "paste": 4, "delete": 5, "selectAll": 6]
            if let action = (fields["action"] as? String).flatMap({ actions[$0] }) {
                yardlet_cef_edit(Int32(tab), Int32(action))
            }
        case "accessibility":
            let enabled = fields["isEnabled"] as? Bool ?? false
            if !enabled { accessibility.forget(tab: tab) }
            yardlet_cef_set_accessibility(Int32(tab), enabled ? 1 : 0)
        case "focus":
            yardlet_cef_set_focus(Int32(tab), (fields["isFocused"] as? Bool ?? false) ? 1 : 0)
        case "visibility":
            let hidden = fields["isHidden"] as? Bool ?? false
            // Chromium's window over the tab goes and comes with it, which tells the host the window's tab.
            if let chromiumWindows { chromiumWindows.changeVisibility(of: tab, hidden: hidden) }
            else { yardlet_cef_set_hidden(Int32(tab), hidden ? 1 : 0) }
            if !hidden { discarder.cancel(tab: tab) }
            if hidden {
                // Nothing paints a hidden tab; its rings go, and Yardlet is told so it can let go of
                // its references too (after every frame written so far). Showing it again paints
                // into a new ring.
                surfaces?.forget(key: "\(tab).view")
                surfaces?.forget(key: "\(tab).popup")
                send(["hidden": ["tab": tab]])
            }
        case "contextMenuResult":
            yardlet_cef_context_menu_result(Int32(fields["menu"] as? Int ?? -1), Int32(fields["commandID"] as? Int ?? -1))
        case "devTools":
            guard let message = fields["message"] as? String else { return }
            if waitingTabs[tab] != nil {
                deferredDevTools[tab, default: []].append(message)
                return
            }
            let sent = message.withCString { yardlet_cef_send_devtools_message(Int32(tab), $0, strlen($0)) }
            if sent != 1 {
                // The call fails at once for whoever made it (the agent's tools), as a DevTools error reply;
                // it is no failure of the page any tab shows. Before 2026-10-23 a host-wide `failed` went to
                // every tab and the panel's page showed "Unavailable".
                FileHandle.standardError.write(Data("devtools message refused tab=\(tab)\n".utf8))
                refuse(message, tab: tab, because: "The browser tab is gone.")
            }
        case "unresponsive":
            let terminate = fields["action"] as? String == "terminate"
            if yardlet_cef_unresponsive_action(Int32(tab), terminate ? 1 : 0) == 1 {
                FileHandle.standardError.write(Data("renderer \(terminate ? "ended" : "waited for") tab=\(tab)\n".utf8))
            }
        case "discard":
            discarder.discard(tab: tab, urgent: fields["urgent"] as? Bool ?? false)
        case "close":
            discarder.cancel(tab: tab)
            yardlet_cef_close_browser(Int32(tab))
            surfaces?.forget(key: "\(tab).view")
            surfaces?.forget(key: "\(tab).popup")
        case "requestClose":
            // The person closed the tab: its page may ask first, and the tab closes once it agrees (`closed`).
            yardlet_cef_request_close(Int32(tab))
        case "allowExternalApp":
            guard let origin = fields["origin"] as? String, let scheme = fields["scheme"] as? String else { return }
            let kept = yardlet_cef_allow_external_scheme(Int32(tab), origin, scheme) == 1
            FileHandle.standardError.write(Data("external app allowed tab=\(tab) scheme=\(scheme) kept=\(kept)\n".utf8))
        case "guardFilledValues":
            // The values are kept by the bridge only, for the document they went into; nothing writes them down.
            let values = (fields["values"] as? [String] ?? []).filter { !$0.isEmpty && !$0.contains("\0") }
            withCStringArray(values) { _ = yardlet_cef_guard_filled_values(Int32(tab), $0, Int32(values.count)) }
        case "presentChromiumWindows":
            var placements: [Int: ChromiumWindows.Placement] = [:]
            for placement in fields["placements"] as? [[String: Any]] ?? [] {
                guard let window = placement["window"] as? Int else { continue }
                let frame = (placement["frame"] as? [String: Any]).map {
                    CGRect(x: number($0["x"]), y: number($0["y"]), width: number($0["width"]), height: number($0["height"]))
                }
                placements[window] = ChromiumWindows.Placement(frame: frame, above: placement["above"] as? Int)
            }
            chromiumWindows?.present(placements)
        case "closeChromiumWindows":
            chromiumWindows?.close(tabs: (fields["tabs"] as? [Int]).map(Set.init))
        case "shutdown":
            shutdown()
        default:
            break
        }
    }

    /// The display's refresh rate the panel reported, else the host's default (1...240 for CEF).
    private func frameRate(_ viewport: [String: Any]) -> Int32 {
        let requested = Int32(number(viewport["framesPerSecond"], default: Double(arguments.frameRate)))
        return min(240, max(1, requested))
    }

    private func performComposition(tab: Int32, _ composition: [String: Any]) {
        guard let (kind, value) = composition.first, let fields = value as? [String: Any] else { return }
        func range(_ value: Any?) -> (Int32, Int32) {
            guard let range = value as? [String: Any] else { return (-1, -1) }
            let location = range["location"] as? Int ?? 0
            return (Int32(location), Int32(location + (range["length"] as? Int ?? 0)))
        }
        switch kind {
        case "set":
            let text = fields["text"] as? String ?? ""
            var underlines: [Int32] = []
            for underline in fields["underlines"] as? [[String: Any]] ?? [] {
                let (from, to) = range(underline["range"])
                underlines += [from, to, (underline["isThick"] as? Bool ?? false) ? 1 : 0]
            }
            let selection = range(fields["selection"])
            let replacement = range(fields["replacement"])
            yardlet_cef_ime_set_composition(tab, text, underlines, Int32(underlines.count / 3),
                                            selection.0, selection.1, replacement.0, replacement.1)
        case "commit":
            let replacement = range(fields["replacement"])
            yardlet_cef_ime_commit_text(tab, fields["text"] as? String ?? "", replacement.0, replacement.1,
                                        Int32(fields["relativeCursor"] as? Int ?? 0))
        case "finish":
            yardlet_cef_ime_finish_composing_text(tab, (fields["keepSelection"] as? Bool ?? false) ? 1 : 0)
        case "cancel":
            yardlet_cef_ime_cancel_composition(tab)
        default:
            break
        }
    }

    /// Seconds after which a shutdown that has not finished ends the host and its Chromium processes.
    static let shutdownDeadline = 10.0

    /// CEF's order: close every browser, quit the message loop after the last one closes, then
    /// `CefShutdown` (main.swift), which also starts Chromium's exit work such as the code-sign clone
    /// cleanup. The end of input, the `shutdown` command and SIGTERM all come here. Should closing or
    /// CefShutdown hang, the host ends with its process group, which holds its Chromium processes
    /// (the cleanup runs in a group of its own).
    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.shutdownDeadline) {
            FileHandle.standardError.write(Data("Yardlet Browser Host: shutdown did not finish in time\n".utf8))
            if getpgrp() == getpid() { killpg(getpid(), SIGKILL) }
            _exit(1)
        }
        if yardlet_cef_open_browser_count() == 0 {
            yardlet_cef_quit_message_loop()
            return
        }
        for tab in openTabs.union(waitingTabs.keys) { yardlet_cef_close_browser(Int32(tab)) }
        // Browsers close asynchronously; `browserClosed` quits the loop after the last one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { yardlet_cef_quit_message_loop() }
    }

    /// A DevTools call that cannot reach a page, answered at once with an error.
    private func refuse(_ message: String, tab: Int, because reason: String) {
        guard let id = Self.devToolsMessageID(message),
              let data = try? JSONSerialization.data(withJSONObject: ["id": id, "error": ["code": -32001, "message": reason]])
        else { return }
        send(["devTools": ["tab": tab, "message": String(decoding: data, as: UTF8.self)]])
    }

    /// Seconds a tab waits for its profile to load before it is given up (a profile on disk loads in well
    /// under a second).
    static let profileDeadline = 20.0

    /// The tab has no browser and gets none: Yardlet shows why in that tab alone, and the DevTools calls that
    /// waited for it are answered with the reason. host.log says which of `kind` (limit, chromium, profile).
    private func notOpened(_ tab: Int, _ kind: String, _ message: String, limit: Int? = nil) {
        FileHandle.standardError.write(Data("tab not opened tab=\(tab) reason=\(kind)\n".utf8))
        waitingTabs[tab] = nil
        for waiting in deferredDevTools.removeValue(forKey: tab) ?? [] {
            refuse(waiting, tab: tab, because: "This tab could not open: \(message).")
        }
        var fields: [String: Any] = ["message": message, "tab": tab]
        if let limit { fields["limit"] = limit }
        send(["failed": fields])
    }

    // MARK: Task profiles

    /// Moves a waiting tab on once its browser exists: its cookie copies first, one after another, then its page
    /// and the DevTools messages that waited.
    private func advance(_ tab: Int) {
        guard var waiting = waitingTabs[tab] else { return }
        if !waiting.copies.isEmpty {
            let copy = waiting.copies.removeFirst()
            let request = nextCookieCopy
            nextCookieCopy += 1
            waiting.copyRequest = request
            waitingTabs[tab] = waiting
            guard Self.copyCookies(request, copy, to: waiting.profile) else { return advance(tab) }
            // A copy that never reports still lets the page load. One that reported is done: host.log's
            // `count=-1` is a copy that did not report in time.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.waitingTabs.values.contains(where: { $0.copyRequest == request }) else { return }
                    self.cookiesCopied(request: request, count: -1)
                }
            }
            return
        }
        waitingTabs[tab] = nil
        if waiting.url != waiting.start { yardlet_cef_load_url(Int32(tab), waiting.url) }
        for message in deferredDevTools.removeValue(forKey: tab) ?? [] {
            _ = message.withCString { yardlet_cef_send_devtools_message(Int32(tab), $0, strlen($0)) }
        }
    }

    private func cookiesCopied(request: Int32, detail: String?) {
        if let asked = cookieDigests.removeValue(forKey: request) {
            return send(["cookieDigest": ["request": asked, "digest": detail ?? ""]])
        }
        cookiesCopied(request: request, count: Int(detail ?? "") ?? 0)
    }

    private func cookiesCopied(request: Int32, count: Int) {
        FileHandle.standardError.write(Data("cookies copied request=\(request) count=\(count)\n".utf8))
        if let asked = cookieImports.removeValue(forKey: request) {
            return send(["cookiesImported": ["request": asked, "count": count]])
        }
        if let asked = cookieCopies.removeValue(forKey: request) {
            return send(["cookiesCopied": ["request": asked, "count": count]])
        }
        guard let tab = waitingTabs.first(where: { $0.value.copyRequest == request })?.key else { return }
        advance(tab)
    }

    /// Starts a cookie copy into the profile at `path` (empty: the default profile); the bridge copies the site names.
    private static func copyCookies(_ request: Int32, _ copy: TaskProfiles.Copy, to path: String) -> Bool {
        let sites = copy.sites.map { strdup($0) }
        defer { sites.forEach { free($0) } }
        let list = sites.map { UnsafePointer($0) }
        return list.withUnsafeBufferPointer {
            yardlet_cef_copy_cookies(request, copy.from, path, $0.baseAddress, Int32($0.count), copy.mode) == 1
        }
    }

    /// Hands the bridge an import's cookies as C strings, which it copies before it returns.
    private static func importCookies(_ request: Int32, to path: String, sites: [String], cookies: [[String: Any]]) -> Bool {
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { free($0) } }
        func c(_ text: String) -> UnsafePointer<CChar>? {
            guard let copy = strdup(text) else { return nil }
            strings.append(copy)
            return UnsafePointer(copy)
        }
        let siteStrings = sites.map(c)
        let records = cookies.compactMap { cookie -> YardletCEFCookie? in
            guard let name = cookie["name"] as? String, let value = cookie["value"] as? String,
                  let domain = cookie["domain"] as? String, !domain.isEmpty else { return nil }
            let expires = (cookie["expires"] as? NSNumber)?.int64Value
            return YardletCEFCookie(name: c(name), value: c(value), domain: c(domain), path: c(cookie["path"] as? String ?? "/"),
                                    secure: cookie["secure"] as? Bool == true ? 1 : 0,
                                    httponly: cookie["httpOnly"] as? Bool == true ? 1 : 0,
                                    same_site: Int32(cookie["sameSite"] as? Int ?? 0), priority: Int32(cookie["priority"] as? Int ?? 0),
                                    has_expires: expires == nil ? 0 : 1, expires: expires ?? 0)
        }
        return siteStrings.withUnsafeBufferPointer { siteList in
            records.withUnsafeBufferPointer { list in
                yardlet_cef_import_cookies(request, path, siteList.baseAddress, Int32(siteList.count), list.baseAddress,
                                           Int32(list.count)) == 1
            }
        }
    }

    private var openTabs = Set<Int>()
    /// Tabs whose renderer has not handled input for 15 seconds, as last reported to Yardlet.
    private var unresponsiveTabs = Set<Int>()
    private var responsivenessTimer: DispatchSourceTimer?

    /// Chromium calls the hang monitor's handler only for a tab without a DevTools session (a debugger
    /// may be paused), and Yardlet's tabs have one; the renderer's state is read every second instead.
    private func watchResponsiveness() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for tab in self.openTabs {
                    self.reportResponsiveness(tab: tab, isResponsive: yardlet_cef_is_unresponsive(Int32(tab)) == 0)
                }
                self.unresponsiveTabs.formIntersection(self.openTabs)
            }
        }
        timer.resume()
        responsivenessTimer = timer
    }

    private func reportResponsiveness(tab: Int, isResponsive: Bool) {
        guard isResponsive == unresponsiveTabs.contains(tab) else { return }
        if isResponsive { unresponsiveTabs.remove(tab) } else { unresponsiveTabs.insert(tab) }
        FileHandle.standardError.write(Data("renderer \(isResponsive ? "responsive" : "unresponsive") tab=\(tab)\n".utf8))
        send(["responsiveness": ["tab": tab, "isResponsive": isResponsive]])
    }

    // MARK: Engine callbacks

    /// CEF's `cef_termination_status_t`.
    static func terminationStatus(_ value: Int32) -> String {
        switch value {
        case 0: "abnormal"  // a non-zero exit status, such as a failed CHECK
        case 1: "killed"
        case 2: "crashed"
        case 3: "oom"
        case 4: "launch-failed"
        case 5: "integrity-failure"
        default: "status-\(value)"
        }
    }

    /// Chrome's sad tab's "Error code": the signal's name when the renderer crashed (a failed CHECK is
    /// SIGTRAP), "Out of Memory", else the status and exit code. Signal numbers are this platform's.
    static func errorCode(status: String, code: Int) -> String {
        if status == "oom" { return "Out of Memory" }
        let signals = [SIGILL: "SIGILL", SIGTRAP: "SIGTRAP", SIGABRT: "SIGABRT", SIGFPE: "SIGFPE", SIGKILL: "SIGKILL",
                       SIGBUS: "SIGBUS", SIGSEGV: "SIGSEGV"]
        if status == "crashed" || status == "killed", let name = signals[Int32(code)] { return name }
        return "\(status) \(code)"
    }

    func event(tab: Int, kind: Int32, text: String?, detail: String?, number value: Int32) {
        switch UInt32(kind) {
        case YardletCEFEventContextInitialized.rawValue:
            contextInitialized()
        case YardletCEFEventAfterCreated.rawValue:
            openTabs.insert(tab)
            chromiumWindows?.opened(tab)
        case YardletCEFEventBeforeClose.rawValue:
            // One line per browser that went, for reading host.log: a closed tab's page may outlive the close.
            FileHandle.standardError.write(Data("browser closed tab=\(tab)\n".utf8))
            openTabs.remove(tab)
            chromiumWindows?.closed(tab)
            waitingTabs[tab] = nil
            deferredDevTools[tab] = nil
            surfaces?.forget(key: "\(tab).view")
            surfaces?.forget(key: "\(tab).popup")
            send(["closed": ["tab": tab]])
            if isShuttingDown, yardlet_cef_open_browser_count() == 0 { yardlet_cef_quit_message_loop() }
        case YardletCEFEventAddress.rawValue:
            send(["address": ["tab": tab, "url": text ?? ""]])
        case YardletCEFEventTitle.rawValue:
            send(["title": ["tab": tab, "title": text ?? ""]])
        case YardletCEFEventLoadingState.rawValue:
            send(["loading": ["tab": tab, "isLoading": value & 1 != 0, "canGoBack": value & 2 != 0,
                              "canGoForward": value & 4 != 0]])
        case YardletCEFEventLoadEnd.rawValue:
            send(["loadEnd": ["tab": tab, "url": text ?? "", "status": Int(value)]])
        case YardletCEFEventLoadError.rawValue:
            // One line per main-frame load error, for reading a person's host.log: the code and the site,
            // never the path or query.
            FileHandle.standardError.write(Data(
                "load error tab=\(tab) code=\(value) host=\(URL(string: text ?? "")?.host() ?? "-")\n".utf8))
            send(["loadError": ["tab": tab, "url": text ?? "", "code": Int(value), "message": detail ?? ""]])
        case YardletCEFEventConsole.rawValue:
            send(["console": ["tab": tab, "level": Int(value >> 16), "message": text ?? "",
                              "source": detail ?? "", "line": Int(value & 0xFFFF)]])
        case YardletCEFEventPopupBlocked.rawValue:
            send(["newWindow": ["tab": tab, "url": text ?? "", "background": value & 1 != 0, "userGesture": value & 2 != 0]])
        case YardletCEFEventExternalProtocol.rawValue:
            externalProtocol(tab: tab, url: text ?? "", source: detail ?? "", userGesture: value & 1 != 0)
        case YardletCEFEventDocumentStart.rawValue:
            send(["newDocument": ["tab": tab, "url": text ?? ""]])
        case YardletCEFEventPopupOpened.rawValue:
            send(["popupOpened": ["tab": tab, "opener": Int(detail ?? "") ?? -1, "url": text ?? "", "background": value != 0]])
        case YardletCEFEventPopupShow.rawValue:
            if value == 0 {
                popupRects[tab] = nil
                surfaces?.forget(key: "\(tab).popup")
                send(["popup": ["tab": tab]])
            }
        case YardletCEFEventTooltip.rawValue:
            var fields: [String: Any] = ["tab": tab]
            if let text, !text.isEmpty { fields["text"] = text }
            send(["tooltip": fields])
        case YardletCEFEventNavigationBlocked.rawValue:
            send(["navigationBlocked": ["tab": tab, "url": text ?? ""]])
        case YardletCEFEventFilledValueBlocked.rawValue:
            // One line per refusal, for reading a person's host.log: never the address, which holds the value.
            FileHandle.standardError.write(Data("filled value kept out of an address tab=\(tab) mainFrame=\(value)\n".utf8))
            send(["filledValueBlocked": ["tab": tab]])
        case YardletCEFEventResponsiveness.rawValue:
            reportResponsiveness(tab: tab, isResponsive: value != 0)
        case YardletCEFEventCookiesCopied.rawValue:
            cookiesCopied(request: value, detail: detail)
        case YardletCEFEventProfileReady.rawValue:
            FileHandle.standardError.write(Data("profile loaded tab=\(tab) browser=\(value)\n".utf8))
            if value == 1 { advance(tab) }
            else { notOpened(tab, "chromium", "Chromium could not create a browser for tab \(tab)") }
        case YardletCEFEventPageCrashed.rawValue:
            // One line per renderer that ended, for reading a person's host.log: how it ended and its exit code.
            let status = Self.terminationStatus(value)
            let code = Int(detail ?? "") ?? 0
            FileHandle.standardError.write(Data("renderer ended tab=\(tab) status=\(status) code=\(code)\n".utf8))
            discarder.rendererEnded(tab: tab)
            send(["pageCrashed": ["tab": tab, "reason": Self.errorCode(status: status, code: code), "status": status,
                                  "code": code]])
        case YardletCEFEventPageState.rawValue:
            discarder.answered(tab: tab, query: Int(detail ?? "") ?? -1, flags: value)
        case YardletCEFEventDiscarded.rawValue:
            discarder.discarded(tab: tab)
        case YardletCEFEventDialogReset.rawValue:
            send(["javaScriptDialogReset": ["tab": tab]])
        case YardletCEFEventDragOperation.rawValue:
            send(["dragOperation": ["tab": tab, "operations": Int(value)]])
        case YardletCEFEventPasswordField.rawValue:
            send(["passwordField": ["tab": tab, "isFocused": value != 0]])
        case YardletCEFEventCursor.rawValue:
            send(["cursor": ["tab": tab, "cursor": Self.cursorName(value)]])
        default:
            break
        }
    }

    /// A page asked to open another app's address. Yardlet asks the person or opens it by Chrome's rules;
    /// the host says which site asked and whether the person told Chrome to always allow that site's links of
    /// this kind (the tab's profile). host.log names the scheme only, never the address.
    private func externalProtocol(tab: Int, url: String, source: String, userGesture: Bool) {
        let origin = Self.origin(of: source)
        let scheme = String(url.prefix { $0 != ":" }).lowercased()
        let remembered = !origin.isEmpty && yardlet_cef_external_scheme_allowed(Int32(tab), origin, scheme) == 1
        FileHandle.standardError.write(Data("external app tab=\(tab) scheme=\(scheme) remembered=\(remembered)\n".utf8))
        send(["externalApp": ["tab": tab, "request": [
            "url": url, "origin": origin, "userGesture": userGesture, "remembered": remembered
        ] as [String: Any]]])
    }

    /// A document's origin as Chromium writes it (`url::Origin::Serialize`) for http and https pages; empty for
    /// any other, whose origin is opaque or a file.
    static func origin(of address: String) -> String {
        guard let components = URLComponents(string: address), let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = components.host, !host.isEmpty else { return "" }
        let port = components.port.map { $0 == (scheme == "https" ? 443 : 80) ? "" : ":\($0)" } ?? ""
        return "\(scheme)://\(host.lowercased())\(port)"
    }

    func popupRect(tab: Int, rect: YardletCEFRect) {
        let value: [String: Any] = ["x": Int(rect.x), "y": Int(rect.y), "width": Int(rect.width), "height": Int(rect.height)]
        popupRects[tab] = value
        send(["popup": ["tab": tab, "rect": value]])
    }

    func paint(tab: Int, layer: Int32, buffer: UnsafeRawPointer, width: Int, height: Int) {
        let paintedAt = DispatchTime.now().uptimeNanoseconds
        let layerName = layer == 0 ? "view" : "popup"
        guard let surface = surfaces?.surface(copyingBuffer: buffer, width: width, height: height,
                                              key: "\(tab).\(layerName)") else { return }
        sendFrame(tab: tab, layer: layerName, surface: surface, paintedAt: paintedAt, source: "software")
    }

    func acceleratedPaint(tab: Int, layer: Int32, surface source: IOSurfaceRef, format: Int32) {
        let paintedAt = DispatchTime.now().uptimeNanoseconds
        let layerName = layer == 0 ? "view" : "popup"
        guard let surface = surfaces?.surface(copyingSurface: source, format: format, key: "\(tab).\(layerName)") else { return }
        sendFrame(tab: tab, layer: layerName, surface: surface, paintedAt: paintedAt, source: "accelerated")
    }

    func contextMenu(tab: Int, menuID: Int32, x: Int32, y: Int32, items: [[String: Any]]) {
        send(["contextMenu": ["tab": tab, "menu": ["id": Int(menuID), "x": Int(x), "y": Int(y), "items": items]]])
    }

    func javaScriptDialog(tab: Int, id: Int32, kind: Int32, message: String, defaultPrompt: String,
                          origin: String, isReload: Bool) {
        let kinds = ["alert", "confirm", "prompt", "beforeUnload"]
#if DEBUG
        FileHandle.standardError.write(Data("javaScriptDialog tab=\(tab) id=\(id) kind=\(kind) reload=\(isReload)\n".utf8))
#endif
        send(["javaScriptDialog": ["tab": tab, "dialog": [
            "id": Int(id), "kind": kinds[max(0, min(3, Int(kind)))], "message": message,
            "defaultPrompt": defaultPrompt, "origin": origin, "isReload": isReload
        ] as [String: Any]]])
    }

    /// Chromium's names for what a page may ask (cef_permission_request_types_t bits, in bit order).
    private static let permissionNames = [
        "arSession", "cameraPanTiltZoom", "camera", "capturedSurfaceControl", "clipboard", "topLevelStorageAccess",
        "diskQuota", "localFonts", "geolocation", "handTracking", "identityProvider", "idleDetection", "microphone",
        "midiSysex", "multipleDownloads", "notifications", "keyboardLock", "pointerLock", "protectedMediaIdentifier",
        "registerProtocolHandler", "storageAccess", "vrSession", "webAppInstallation", "windowManagement",
        "fileSystemAccess", "localNetworkAccess", "localNetwork", "loopbackNetwork", "sensors"
    ]

    func permissionPrompt(tab: Int, id: UInt64, origin: String, permissions: UInt32) {
        let names = Self.permissionNames.indices.filter { permissions & (1 << $0) != 0 }.map { Self.permissionNames[$0] }
        FileHandle.standardError.write(Data("permission prompt tab=\(tab) id=\(id) \(names.joined(separator: ","))\n".utf8))
        send(["permissionPrompt": ["tab": tab, "prompt": [
            "id": Int(truncatingIfNeeded: id), "origin": origin, "permissions": names
        ] as [String: Any]]])
    }

    func permissionPromptDismissed(tab: Int, id: UInt64) {
        send(["permissionPromptDismissed": ["tab": tab, "prompt": Int(truncatingIfNeeded: id)]])
    }

    func fileDialog(tab: Int, id: Int32, mode: Int32, title: String, defaultPath: String, extensions: [String]) {
        let modes = ["open", "openMultiple", "openFolder", "save"]
        send(["fileDialog": ["tab": tab, "dialog": [
            "id": Int(id), "mode": modes[max(0, min(3, Int(mode)))], "title": title,
            "defaultPath": defaultPath, "extensions": extensions
        ] as [String: Any]]])
    }

    /// Downloads go to the user's Downloads folder under the suggested name, numbered when the
    /// name is taken ("report (1).pdf").
    func downloadPath(tab: Int, id: Int32, suggestedName: String) -> String? {
        guard !arguments.downloadsPath.isEmpty else { return nil }
        let directory = URL(filePath: arguments.downloadsPath, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleaned = suggestedName.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let name = cleaned.isEmpty || cleaned.hasPrefix(".") ? "download" + cleaned : cleaned
        let base = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        var candidate = directory.appending(path: name)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) || reservedDownloads.contains(candidate.path) {
            let numbered = "\(base) (\(counter))" + (pathExtension.isEmpty ? "" : ".\(pathExtension)")
            candidate = directory.appending(path: numbered)
            counter += 1
        }
        reservedDownloads.insert(candidate.path)
        return candidate.path(percentEncoded: false)
    }

    func download(tab: Int, id: Int32, state: Int32, path: String, received: Int64, total: Int64) {
        let states = ["started", "inProgress", "completed", "cancelled", "interrupted"]
        var stateName = states[max(0, min(4, Int(state)))]
        if stateName == "inProgress", !announcedDownloads.contains(id) {
            announcedDownloads.insert(id)
            stateName = "started"
        } else if stateName == "inProgress" {
            // Progress at most every half second per download.
            let now = DispatchTime.now().uptimeNanoseconds
            if let last = lastDownloadProgress[id], now &- last < 500_000_000 { return }
            lastDownloadProgress[id] = now
        }
        if state >= 2 {
            announcedDownloads.remove(id)
            lastDownloadProgress[id] = nil
            reservedDownloads.remove(URL(filePath: path).path)
        }
        send(["download": ["tab": tab, "download": [
            "id": Int(id), "state": stateName, "fileName": (path as NSString).lastPathComponent, "path": path,
            "receivedBytes": received, "totalBytes": total
        ] as [String: Any]]])
    }

    func findResult(tab: Int, matches: Int32, activeMatch: Int32, isFinal: Bool) {
        send(["findResult": ["tab": tab, "result": [
            "matches": Int(matches), "activeMatch": Int(activeMatch), "isFinal": isFinal
        ] as [String: Any]]])
    }

    private var reservedDownloads = Set<String>()
    private var announcedDownloads = Set<Int32>()
    private var lastDownloadProgress: [Int32: UInt64] = [:]

    /// The same list as BrowserURLPolicy in the app; the bridge applies it to page navigations.
    static func isAllowed(_ url: String) -> Bool {
        guard let colon = url.firstIndex(of: ":") else { return false }
        return ["http", "https", "file", "about", "data"].contains(url[..<colon].lowercased())
    }

    func compositionBounds(tab: Int, rects: [YardletCEFRect]) {
        let values = rects.map { ["x": Int($0.x), "y": Int($0.y), "width": Int($0.width), "height": Int($0.height)] }
        send(["compositionBounds": ["tab": tab, "rects": values]])
    }

    // MARK: Accessibility and scrolling

    private(set) lazy var accessibility = AccessibilityForwarder(output: output,
                                                                 recordPath: arguments.accessibilityRecordPath)
    private var scrollOffsets: [Int: (Double, Double)] = [:]

    func scrollOffset(tab: Int, x: Double, y: Double) {
        guard scrollOffsets[tab].map({ $0 != (x, y) }) ?? true else { return }
        scrollOffsets[tab] = (x, y)
        send(["scrollOffset": ["tab": tab, "x": x, "y": y]])
    }

    /// The `id` of a DevTools call, to answer it when the call cannot be delivered.
    static func devToolsMessageID(_ message: String) -> Int? {
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["id"] as? NSNumber)?.intValue
    }

    /// The page's icon, for its tab in Yardlet's side panel.
    func favicon(tab: Int, url: String, png: Data) {
        send(["favicon": ["tab": tab, "url": url, "png": png.base64EncodedString()]])
    }

    func devTools(tab: Int, message: String) {
        send(["devTools": ["tab": tab, "message": message]])
    }

    private func sendFrame(tab: Int, layer: String, surface: IOSurfaceRef, paintedAt: UInt64, source: String) {
        sequence += 1
        frameCount += 1
        send(["frame": ["tab": tab, "frame": [
            "layer": layer,
            "surface": UInt64(IOSurfaceGetID(surface)),
            "pixelWidth": IOSurfaceGetWidth(surface),
            "pixelHeight": IOSurfaceGetHeight(surface),
            "sequence": sequence,
            "paintedAt": paintedAt,
            "source": source
        ] as [String: Any]]])
    }

    func send(_ event: [String: Any]) {
        keepTabsAskingThePerson(event)
        output.write(event)
    }

    /// A page that asks the person something or begins a download while its discard is decided is kept, as Chrome keeps
    /// such a page: the memory saver's question about it is dropped (`TabDiscarder.cancel`).
    private func keepTabsAskingThePerson(_ event: [String: Any]) {
        guard let (name, value) = event.first, let fields = value as? [String: Any] else { return }
        switch name {
        case "javaScriptDialog", "fileDialog", "permissionPrompt", "download", "externalApp":
            if let tab = fields["tab"] as? Int { discarder.cancel(tab: tab) }
        case "chromiumWindow":
            for tab in fields["tabs"] as? [Int] ?? [] where tab >= 0 { discarder.cancel(tab: tab) }
        default:
            break
        }
    }

    /// Summary printed to standard error (Yardlet's host log) when the host exits.
    func statistics() -> String {
        let copies = surfaces?.copyMilliseconds.sorted() ?? []
        func percentile(_ fraction: Double) -> Double {
            copies.isEmpty ? 0 : copies[min(copies.count - 1, Int(Double(copies.count) * fraction))]
        }
        let accessibility = self.accessibility.statistics
        return "frames=\(frameCount) copies=\(copies.count) copyMedianMs=\(percentile(0.5)) "
            + "copyP95Ms=\(percentile(0.95)) sendFailures=\(surfaces?.sendFailures ?? 0) "
            + "axTreeChanges=\(accessibility.treeChanges) axLocationBatches=\(accessibility.locationBatches) "
            + "axRawBytes=\(accessibility.rawBytes) axSentBytes=\(accessibility.sentBytes) "
            + "axLargestRaw=\(accessibility.largestRawBytes) axLargestSent=\(accessibility.largestSentBytes) "
            + String(format: "axReduceMs=%.1f axSlowestReduceMs=%.1f", accessibility.reduceMilliseconds,
                     accessibility.slowestReduceMilliseconds)
    }

    private func number(_ value: Any?, default fallback: Double = 0) -> Double {
        (value as? NSNumber)?.doubleValue ?? fallback
    }

    static func cursorName(_ type: Int32) -> String {
        // cef_cursor_type_t order, mapped onto BrowserCursor raw values.
        let names = [
            "pointer", "crosshair", "hand", "text", "wait", "help", "resizeEast", "resizeNorth",
            "resizeNorth", "resizeNorth", "resizeSouth", "resizeSouth", "resizeSouth", "resizeWest",
            "resizeNorthSouth", "resizeEastWest", "resizeEastWest", "resizeNorthSouth", "resizeColumn",
            "resizeRow", "move", "move", "move", "move", "move", "move", "move", "move", "move", "move",
            "text", "crosshair", "contextMenu", "alias", "progress", "notAllowed", "copy", "none",
            "notAllowed", "zoomIn", "zoomOut", "grab", "grabbing"
        ]
        return Int(type) < names.count ? names[Int(type)] : "pointer"
    }
}

/// Passes Swift strings to C as a temporary `const char *const *` array.
func withCStringArray<Result>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>?) -> Result) -> Result {
    let duplicates = strings.map { strdup($0) }
    defer { duplicates.forEach { free($0) } }
    let pointers = duplicates.map { UnsafePointer<CChar>($0) }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress) }
}

#if DEBUG
/// QA runs only: Chromium can show windows of its own in the host (a WebAuthn dialog, for example),
/// which the windowless panel never sees. Every new host window is described in
/// `<QA output>/host-windows/windows.jsonl` and drawn to a PNG beside it while it is visible.
@MainActor
enum QAWindowWatcher {
    private static var seen = Set<ObjectIdentifier>()
    private static var drawn: [ObjectIdentifier: Int] = [:]
    private static var lastText: [ObjectIdentifier: String] = [:]
    private static var textCount = 0
    private static var textReads: [ObjectIdentifier: Int] = [:]

    private static func accessibilityText(_ element: Any, depth: Int) -> String {
        guard depth < 14, let object = element as? NSObject else { return "" }
        func value(_ attribute: NSAccessibility.Attribute) -> Any? { object.accessibilityAttributeValue(attribute) }
        var parts: [String] = []
        let role = value(.role) as? String ?? ""
        let words = [value(.title), value(.description), value(.value)].compactMap { $0 as? String }.filter { !$0.isEmpty }
        if !words.isEmpty { parts.append(String(repeating: "  ", count: depth) + role + " " + words.joined(separator: " | ")) }
        for child in value(.children) as? [Any] ?? [] {
            let text = accessibilityText(child, depth: depth + 1)
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined(separator: "\n")
    }
    private static var timer: Timer?

    static func start(beside recordPath: String) {
        let directory = URL(filePath: recordPath).deletingLastPathComponent().appending(path: "host-windows")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { look(in: directory) }
        }
    }

    private static func look(in directory: URL) {
        for window in NSApp.windows {
            let id = ObjectIdentifier(window)
            let frame = window.frame
            if seen.insert(id).inserted {
                let line: [String: Any] = [
                    "at": Date().timeIntervalSince1970, "class": String(describing: type(of: window)),
                    "title": window.title, "visible": window.isVisible, "key": window.isKeyWindow,
                    "level": window.level.rawValue, "onScreen": window.occlusionState.contains(.visible),
                    "windowNumber": window.windowNumber, "appActive": NSApp.isActive,
                    "activationPolicy": NSApp.activationPolicy().rawValue,
                    "frame": [frame.origin.x, frame.origin.y, frame.width, frame.height]
                ]
                let log = directory.appending(path: "windows.jsonl")
                if !FileManager.default.fileExists(atPath: log.path(percentEncoded: false)) {
                    FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil)
                }
                if let data = try? JSONSerialization.data(withJSONObject: line), let handle = try? FileHandle(forWritingTo: log) {
                    handle.seekToEndOfFile()
                    handle.write(data + Data("\n".utf8))
                    try? handle.close()
                }
                FileHandle.standardError.write(Data("QA host window \(type(of: window)) visible=\(window.isVisible) frame=\(frame)\n".utf8))
            }
            // What the window says, through its own accessibility (Views draws through the compositor,
            // which a drawing of the content view does not catch); written again whenever it changes.
            // At most three reads per window: reading Chromium's accessibility can turn it on for
            // the whole browser.
            if window.isVisible, textReads[id, default: 0] < 3 {
                textReads[id, default: 0] += 1
                let text = Self.accessibilityText(window, depth: 0)
                if text != lastText[id], !text.isEmpty {
                    lastText[id] = text
                    textCount += 1
                    try? text.write(to: directory.appending(path: "window-text-\(textCount).txt"), atomically: true, encoding: .utf8)
                    let state = "key=\(window.isKeyWindow) appActive=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue)"
                    FileHandle.standardError.write(Data("QA host window text \(textCount) \(state):\n\(text)\n".utf8))
                }
            }
            // Drawn once while visible, again if it was not drawn yet.
            guard window.isVisible, drawn[id] == nil, let content = window.contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let index = drawn.count + 1
            drawn[id] = index
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "window-\(index).png"))
        }
    }
}
#endif

