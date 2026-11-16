import AppKit

/// A QA run (`scripts/browser-host-qa/qa-launch.sh` sets YARDLET_QA_BACKGROUND=1) stays out of the way of
/// the person using the Mac: no Dock icon, menu bar or ⌘Tab entry, never the active app, and its windows
/// past every screen, so none can be taken for Yardlet, clicked or typed into. Before 2026-10-23 its
/// window sat on screen as "Yardlet" while the QA drove its browser. The browser host follows the same
/// variable for Chromium's own windows (`ChromiumWindows`).
@MainActor
enum QABackground {
    nonisolated static let isOn = ProcessInfo.processInfo.environment["YARDLET_QA_BACKGROUND"] == "1"
    /// The performance run (`run-perf.sh`) measures frames on a display and the showcase capture
    /// (`scripts/showcase/capture.sh`) records its windows from one, so their windows stay on the screen
    /// they pick; they are still never active, and the showcase puts its windows behind the person's,
    /// with clicks passing through (`ShowcaseFixture.install`).
    private static let drawsOnScreen = CommandLine.arguments.contains { $0.hasPrefix("--ui-fixture-browser-perf=") }
        || Set(CommandLine.arguments).isSuperset(of: ["--ui-fixture=showcase", "--ui-fixture-ignore-pointer"])
    private static var observers: [any NSObjectProtocol] = []

    /// As the launch begins: SwiftUI orders the first window in before the launch finishes.
    static func start() {
        NSApp.setActivationPolicy(.accessory)
        guard !drawsOnScreen else { return }
        DispatchQueue.main.async { NSApp.windows.forEach(moveOffScreen) }
        // SwiftUI sizes and places a window before ordering it in, at launch or when an app launched in the
        // background is opened again (`open -g`, as a Dock click would), so each window is clear and off every
        // screen before it first shows. A fixture sizing or centering its window moves it again, and a window
        // ordered in later (another Yardlet window, a sheet's parent) changes its occlusion.
        observers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeOcclusionStateNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { NSApp.windows.forEach(moveOffScreen) }
            }
        }
    }

    /// Below and left of every screen, and clear and click-through, since AppKit keeps a corner of a
    /// titled window on a screen once it shows or is resized. Pages still paint there (the QA passes
    /// `--ui-fixture-browser-ignore-occlusion`), and the checks capture the views, not the screen. A window
    /// not shown yet goes too, so it shows nowhere; a sheet moves with its window.
    static func moveOffScreen(_ window: NSWindow) {
        guard window.sheetParent == nil else { return }
        if window.alphaValue != 0 { window.alphaValue = 0 }
        if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
        window.collectionBehavior.formUnion([.transient, .ignoresCycle])
        let screens = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let origin = NSPoint(x: screens.minX - window.frame.width - 4000, y: screens.minY - window.frame.height - 4000)
        guard window.frame.origin != origin else { return }
        window.setFrameOrigin(origin)
    }
}
