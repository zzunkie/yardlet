import AppKit
import Foundation

/// Windows Chromium opens in the host on its own: the passkey dialog (a phone's QR code, a security
/// key and its PIN), the sign-in window for a site's HTTP authentication, and the system's print dialog.
///
/// Each passkey dialog and sign-in window belongs to one tab: Chromium shows it as the tab's web-modal dialog
/// and the tab ignores input while it is open, as in Chrome. A windowless tab gives it no parent window on macOS
/// (CEF's `AlloyWebContentsDialogHelper::GetHostView` is empty and nothing else names the tab), so the host finds the
/// tab the way Chromium ties them: the dialog hides in the same call that hides its tab, and shows again in the call
/// that shows it (`WebContentsModalDialogManager::OnVisibilityChanged`). A window that appears or goes in a visibility
/// change belongs to that tab; a new one is a dialog of a tab not hidden, which each such tab, hidden for that one
/// call and shown again, rules in or out. The print dialog runs modal without a tab (`NSPrintPanel`), so its tab
/// stays unknown. Yardlet is told each window's tab (`chromiumWindow` with `ids` and `tabs`).
///
/// A window shows only where Yardlet places it (`present`): over the panel that shows its tab, just above that
/// panel's window, as Chrome draws a tab's dialog over the tab; a window of unknown tab where it is. Every other
/// window waits past the screens until a panel shows its tab. The host never activates for the windowless pages
/// (`.prohibited`); while a window is placed it may be (`.accessory`), Yardlet hands its activation over, and the
/// window becomes key. The agent's tools close the windows of their task's tabs (`close`). When the last one goes,
/// the host hands activation back to Yardlet and is not activatable again.
@MainActor
final class ChromiumWindows {
    /// Where Yardlet shows a window: over this screen rectangle (AppKit coordinates), above window `above`.
    struct Placement {
        var frame: CGRect?
        var above: Int?
    }

    private let send: ([String: Any]) -> Void
    /// Hides (true) or shows a tab in the engine, as the app's `visibility` command does.
    private let setHidden: (Int, Bool) -> Void
    private var isShowing = false
    /// What was last told to Yardlet.
    private var told: [String] = []
    private var observers: [any NSObjectProtocol] = []
    private var timer: Timer?
    /// Tabs the engine was last told are shown: a passkey dialog or sign-in window is over one of them.
    private var shownTabs: Set<Int> = []
    /// The tab each window is over, by window number, once known; -1 when it is not known.
    private var owners: [Int: Int] = [:]
    /// Where Yardlet shows each window, by window number; any other waits past the screens.
    private var placements: [Int: Placement] = [:]
    /// Where a waiting window was before it went past the screens, for one placed where it is.
    private var waitingFrom: [Int: CGRect] = [:]

    init(send: @escaping ([String: Any]) -> Void, setHidden: @escaping (Int, Bool) -> Void) {
        self.send = send
        self.setHidden = setHidden
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // A closing window is still in the list; look once it has gone.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.focus() }
        })
        // A window Chromium orders in behind other apps' windows posts none of the notifications above
        // (it is not main, and its occlusion stays "not visible"), so the host also looks once a
        // second, with room for the system to batch the wake-up with others.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Chromium's windows ordered in now (the host has no other windows).
    private var shown: [NSWindow] {
        NSApp.windows.filter(\.isVisible)
    }

    /// A QA run (YARDLET_QA_BACKGROUND, inherited from the QA app): Chromium's windows stay past every
    /// screen, placed or not, and the host never becomes activatable, so the person using the Mac never sees or
    /// types into them.
    private let isQABackground = ProcessInfo.processInfo.environment["YARDLET_QA_BACKGROUND"] == "1"

    /// What a window of Chromium's own is, for the agent's tools: Views draws the passkey dialog and the sign-in
    /// window for HTTP authentication, which Chromium titles with its own "Sign in" (IDS_LOGIN_DIALOG_TITLE; the
    /// host ships its en and ko locales). The print dialog is AppKit's, run modal (`NSPrintPanel`).
    static func kind(of window: NSWindow) -> String {
        let className = NSStringFromClass(type(of: window))
        if className.contains("NativeWidgetMac") {
            return ["Sign in", "로그인"].contains(window.title) ? "signIn" : "passkey"
        }
        return NSApp.modalWindow != nil || className.localizedCaseInsensitiveContains("print") ? "print" : "other"
    }

    /// A tab's dialog: a window Views draws (the print dialog is AppKit's and belongs to no tab).
    private static func isTabDialog(_ window: NSWindow) -> Bool {
        NSStringFromClass(type(of: window)).contains("NativeWidgetMac")
    }

    // MARK: Tabs

    /// The engine made a tab's browser; it starts shown.
    func opened(_ tab: Int) {
        shownTabs.insert(tab)
    }

    func closed(_ tab: Int) {
        shownTabs.remove(tab)
    }

    /// Hides or shows a tab in the engine, and notes which windows went or came with it: they are its dialogs.
    func changeVisibility(of tab: Int, hidden: Bool) {
        let before = Set(shown.map(\.windowNumber))
        setHidden(tab, hidden)
        if hidden { shownTabs.remove(tab) } else { shownTabs.insert(tab) }
        let after = Set(shown.map(\.windowNumber))
        for number in hidden ? before.subtracting(after) : after.subtracting(before) where owners[number] != tab {
            owners[number] = tab
        }
        update()
    }

    /// The tab of each new tab dialog: the only tab not hidden, or the one whose hiding hides it. Each other tab
    /// shows again in the same call, so its page sees only a moment hidden; a tab that is the dialog's shows it again.
    private func findTabs(of windows: [NSWindow]) {
        var unknown = windows.filter { Self.isTabDialog($0) && owners[$0.windowNumber] == nil }
        guard !unknown.isEmpty else { return }
        if shownTabs.count == 1, let tab = shownTabs.first {
            for window in unknown { owners[window.windowNumber] = tab }
            return
        }
        for tab in shownTabs.sorted() where !unknown.isEmpty {
            setHidden(tab, true)
            let gone = unknown.filter { !$0.isVisible }
            setHidden(tab, false)
            for window in gone { owners[window.windowNumber] = tab }
            unknown.removeAll { window in gone.contains { $0 === window } }
        }
        for window in unknown { owners[window.windowNumber] = -1 }
#if DEBUG
        HostLog.write("Chromium windows' tabs: \(owners) (shown tabs \(shownTabs.sorted()))")
#endif
    }

    // MARK: Windows

    private func update() {
        // Windows gone from the app are forgotten; one Chromium hid with its tab keeps its tab.
        let numbers = Set(NSApp.windows.map(\.windowNumber))
        owners = owners.filter { numbers.contains($0.key) }
        placements = placements.filter { numbers.contains($0.key) }
        waitingFrom = waitingFrom.filter { numbers.contains($0.key) }
        let windows = shown
        findTabs(of: windows)
        arrange(windows, raising: false)
        let showing = !windows.isEmpty
        let titles = windows.map(\.title), kinds = windows.map(Self.kind(of:))
        let ids = windows.map(\.windowNumber), tabs = windows.map { owners[$0.windowNumber] ?? -1 }
        let description = titles + kinds + ids.map(String.init) + tabs.map(String.init)
        let window: [String: Any] = showing
            ? ["isShown": true, "titles": titles, "kinds": kinds, "ids": ids, "tabs": tabs] : ["isShown": false]
        // Another window in place of one (the passkey sheet's next step, a sign-in after a passkey) is told too.
        if showing, isShowing, description != told {
            told = description
            send(["chromiumWindow": window])
        }
        guard showing != isShowing else { return }
        isShowing = showing
        told = showing ? description : []
        send(["chromiumWindow": window])
        if isQABackground { return }
        if showing {
            NSApp.setActivationPolicy(.accessory)
        } else {
            giveActivationBack()
            NSApp.setActivationPolicy(.prohibited)
        }
    }

    /// Yardlet's placements for the windows shown now (by window number); the rest wait past the screens.
    func present(_ placements: [Int: Placement]) {
        self.placements = placements
        arrange(shown, raising: true)
        if NSApp.isActive { placements.isEmpty ? giveActivationBack() : focus() }
    }

    /// Each shown window where Yardlet placed it, the others past the screens. `raising` (Yardlet's own call, never the
    /// host's timer) puts each placed window just above the window it named, or over the windows in front: a window
    /// raised once a second would come back over another app the person went to.
    private func arrange(_ windows: [NSWindow], raising: Bool) {
        let screens = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        for window in windows {
            let number = window.windowNumber
            guard let placement = placements[number] else {
                if window.frame.intersects(screens) {
                    waitingFrom[number] = window.frame
                    window.setFrameOrigin(NSPoint(x: screens.minX - window.frame.width - 4000,
                                                  y: screens.minY - window.frame.height - 4000))
                }
                window.alphaValue = 0
                window.ignoresMouseEvents = true
                continue
            }
            if !isQABackground {
                if let frame = placement.frame {
                    window.setFrameOrigin(Self.origin(of: window.frame.size, over: frame))
                } else if let earlier = waitingFrom.removeValue(forKey: number) {
                    window.setFrameOrigin(earlier.origin)
                }
                window.alphaValue = 1
                window.ignoresMouseEvents = false
            } else if window.frame.intersects(screens) {
                window.setFrameOrigin(NSPoint(x: screens.minX - window.frame.width - 4000,
                                              y: screens.minY - window.frame.height - 4000))
                window.alphaValue = 0
                window.ignoresMouseEvents = true
            }
            guard raising else { continue }
            if let above = placement.above { window.order(.above, relativeTo: above) } else { window.orderFrontRegardless() }
        }
#if DEBUG
        if raising, !placements.isEmpty {
            let placed = placements.map { "\($0.key) over \($0.value.frame.map { "\($0)" } ?? "where it is") above \($0.value.above ?? 0)" }
            HostLog.write("Chromium windows placed: \(placed.sorted().joined(separator: "; "))")
        }
#endif
    }

    /// As Chrome places a tab's dialog: across the middle of the tab's page, from its top, kept on that screen.
    static func origin(of size: CGSize, over frame: CGRect) -> NSPoint {
        var origin = NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        return origin
    }

    /// Closes the windows of these tabs (every window for nil) as a person pressing Escape would: Chromium's passkey
    /// dialog cancels and the page's request ends with NotAllowedError (its "Close" on a sheet that says no passkey is
    /// available does the same); the sign-in window and the print dialog cancel. A window still open half a second
    /// later is closed. A window whose tab is not known is closed only for nil.
    func close(tabs: Set<Int>?) {
        let closing = shown.filter { window in tabs.map { $0.contains(owners[window.windowNumber] ?? -1) } ?? true }
        let numbers = Set(closing.map(\.windowNumber))
        for window in closing {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let escape = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else { continue }
                window.sendEvent(escape)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                for window in self.shown where numbers.contains(window.windowNumber) { window.performClose(nil) }
            }
        }
    }

    /// The newest placed window takes the keyboard (a security key's PIN, Escape to cancel).
    private func focus() {
        guard isShowing, !isQABackground,
              let window = shown.last(where: { placements[$0.windowNumber] != nil }) else { return }
        window.makeKeyAndOrderFront(nil)
    }

    /// No window here takes the keyboard: Yardlet gets it back if the host had it.
    private func giveActivationBack() {
        guard !isQABackground, NSApp.isActive, let yardlet = NSRunningApplication(processIdentifier: getppid()) else { return }
        yardlet.activate(from: .current, options: [])
    }
}
