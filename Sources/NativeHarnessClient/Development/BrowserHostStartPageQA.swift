#if DEBUG
import AppKit
import Foundation
import YardletAgentTools

/// QA for a new browser tab's start page and the launcher's pages (docs/BROWSER_HOST.md, section 3, "Start page") in the
/// real panel, run by `run-check.sh … --ui-fixture-browser-check-only=start-page`. A blank tab shows the start page with
/// the address field ready; the task's tabs show and close QA pages, and the address field's history gets a few other
/// sites; a new tab then offers the task's pages (the closed tab first) and the sites visited most, which the agent's
/// snapshot of the tab does not read; a page chosen there opens in that tab; an address entered takes the start page
/// away; a page chosen in the launcher opens in a new tab; turned off, nothing is offered. Captures
/// `start-page-{empty,history}-{light,dark}.png` and `launcher-{empty,history}-{light,dark}.png`.
@MainActor
final class BrowserHostStartPageQA {
    private typealias Navigation = TaskSurfaceNavigationProjection
    private let output: URL
    private let base: String
    private let session: UUID
    private var record: [String: JSONValue] = [:]
    private var checks: [JSONValue] = []
    private var client: BrowserHostClient { MacBrowserHost.shared.client }
    private lazy var agentTools = BrowserAgentTools(usesMacEditingCommands: true, tabs: BrowserAgentTabs { MacBrowserHost.shared.client })

    init(output: URL, base: String, session: UUID) {
        self.output = output
        self.base = base
        self.session = session
    }

    func run() async {
        try? FileManager.default.createDirectory(at: output.appending(path: "markers"), withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(3))
        guard var controller = await openPanel(), let window = controller.view?.window else { return await finish() }
        let workspace = controller.workspace
        var frame = window.frame
        frame.size = NSSize(width: 1400, height: 900)
        window.setFrame(frame, display: true)
        try? await Task.sleep(for: .seconds(1))

        // A blank tab: the start page, with the address field ready, and nothing to offer yet.
        check("blank tab: the start page shows over it with the address field ready",
              controller.showsStartPage && controller.isEditingAddress && controller.tab != nil,
              "start page \(controller.showsStartPage), editing \(controller.isEditingAddress), page \(controller.tab?.currentURL ?? "nil")")
        await capture(window, "start-page-empty")
        await showLauncher(workspace)
        check("launcher: a task whose tabs showed no page offers none",
              TaskSidePanelTabs.visitedPageTabs(workspace.browserTabs, icons: client.addressHistory, limit: 5).isEmpty, "")
        await capture(window, "launcher-empty")
        guard let shown = await showBrowserTab(controller.key, in: workspace) else { return await finish() }
        controller = shown

        // The person's other sites, as the address field's history holds them.
        if let history = client.addressHistory {
            for (address, title, visits) in [("https://github.com/example/project", "example/project", 7),
                                             ("https://linear.app/example/inbox", "Inbox", 5),
                                             ("https://developer.apple.com/documentation/swiftui", "SwiftUI", 4),
                                             ("https://docs.swift.org/swift-book/", "The Swift Programming Language", 3),
                                             ("https://news.ycombinator.com/", "Hacker News", 2)] {
                for visit in 0..<visits { history.noteVisit(address, typed: visit == 0) }
                history.noteTitle(title, of: address)
            }
        }

        // The task's pages: the tab moves through three, and a second tab shows another and closes.
        for path in ["second", "a11y", "spa"] {
            await enter(base + path, in: controller, window)
        }
        guard let other = workspace.openBrowserTab(address: base + "tall") else { return await finish() }
        _ = await waitUntil(.seconds(10)) { self.client.tab(key: other, forSession: self.session)?.currentURL == self.base + "tall" }
        _ = await waitUntil(.seconds(5)) { workspace.browserTabs.tab(other)?.title == "Tall" }
        workspace.closeSidePanelTabs([Navigation.browserTabID(other)])
        _ = await waitUntil(.seconds(5)) { self.client.tab(key: other, forSession: self.session) == nil }

        // A new tab offers the closed tab first, then the pages the open tab moved on from, and the sites visited most.
        guard let blank = workspace.openBrowserTab(), let next = await showBrowserTab(blank, in: workspace) else { return await finish() }
        controller = next
        _ = await waitUntil(.seconds(10)) { controller.tab != nil && controller.showsStartPage }
        let offered = workspace.browserTabs.suggestedPages(limit: BrowserStartPage.pageCount).map(\.address)
        check("new tab: the task's pages, the closed tab first, none a tab shows",
              offered == [base + "tall", base + "a11y", base + "second"] && controller.showsStartPage,
              "offered \(offered)")
        let sites = client.addressHistory?.topSites(limit: BrowserStartPage.siteCount).map(\.url) ?? []
        check("new tab: the sites visited most, one page each",
              sites.first == "https://github.com/example/project" && sites.contains { $0.hasPrefix(base) } && sites.count == 6,
              "sites \(sites)")
        try? await Task.sleep(for: .seconds(1))
        await capture(window, "start-page-history")
        let snapshot = await agentText(AgentToolCatalog.snapshot)
        let shownWords = ["Tall", "Accessibility QA", "example/project", L10n.string("Pages in this task"),
                          L10n.string("Frequently visited")]
        check("agent: the snapshot of the new tab reads nothing of its start page",
              !snapshot.isEmpty && !shownWords.contains { snapshot.contains($0) }, String(snapshot.prefix(400)))

        // A page chosen on the start page opens in this tab.
        let tabs = Navigation.browserKeys(in: workspace.panels).count
        let pressed = pressButton(in: window.contentView, label: "Second")
        _ = await waitUntil(.seconds(10)) { controller.tab?.currentURL == self.base + "second" && !controller.isLoading }
        check("start page: a page chosen opens in this tab, and the start page goes",
              pressed && controller.tab?.currentURL == base + "second" && !controller.showsStartPage
                && Navigation.browserKeys(in: workspace.panels).count == tabs,
              "pressed \(pressed), page \(controller.tab?.currentURL ?? "nil"), tabs \(Navigation.browserKeys(in: workspace.panels).count) of \(tabs)")

        // An address entered on a new tab takes the start page away at once.
        guard let typed = workspace.openBrowserTab(), let typing = await showBrowserTab(typed, in: workspace) else { return await finish() }
        controller = typing
        _ = await waitUntil(.seconds(10)) { controller.tab != nil && controller.showsStartPage }
        let before = controller.showsStartPage
        await type(base + "tall", in: controller, window)
        press(window, "\r", keyCode: 0x24)
        let atOnce = !controller.showsStartPage
        _ = await waitUntil(.seconds(10)) { controller.tab?.currentURL == self.base + "tall" && !controller.isLoading }
        check("start page: an address entered takes it away at once, and the page opens",
              before && atOnce && controller.tab?.currentURL == base + "tall" && !controller.showsStartPage,
              "before \(before), right after Return \(!atOnce), page \(controller.tab?.currentURL ?? "nil")")

        // The launcher offers the task's pages: two closed tabs, then the page a tab moved on from; one chosen opens in
        // a new tab.
        for key in [blank, typed] {
            workspace.closeSidePanelTabs([Navigation.browserTabID(key)])
            _ = await waitUntil(.seconds(5)) { self.client.tab(key: key, forSession: self.session) == nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
        await showLauncher(workspace)
        let launcherPages = TaskSidePanelTabs.visitedPageTabs(workspace.browserTabs, icons: client.addressHistory,
                                                              limit: SidePanelLauncher.pageCount).map(\.id)
        check("launcher: the task's pages, the latest closed first",
              launcherPages == [base + "tall", base + "second", base + "a11y"], "pages \(launcherPages)")
        await capture(window, "launcher-history")
        let open = Navigation.browserKeys(in: workspace.panels).count
        let launched = pressButton(in: window.contentView, label: "Accessibility QA")
        _ = await waitUntil(.seconds(10)) {
            Navigation.browserKey(inTab: workspace.panels.trailingSurfaceID).flatMap {
                self.client.tab(key: $0, forSession: self.session)?.currentURL
            } == self.base + "a11y"
        }
        let shownAddress = Navigation.browserKey(inTab: workspace.panels.trailingSurfaceID).flatMap { workspace.browserTabAddress($0) }
        check("launcher: a page chosen opens in a new browser tab, shown",
              launched && Navigation.browserKeys(in: workspace.panels).count == open + 1 && shownAddress == base + "a11y",
              "pressed \(launched), tabs \(Navigation.browserKeys(in: workspace.panels).count) of \(open), shown \(shownAddress ?? "nil")")

        // Turned off, nothing is offered or kept.
        UserDefaults.yardlet.set(false, forKey: BrowserPageSuggestionPreference.key)
        let kept = workspace.browserTabs.visited.count
        if let current = BrowserHostPaneController.current { await enter(base + "tall", in: current, window) }
        check("setting: turned off, the launcher and the start page offer nothing and no page is kept",
              workspace.browserTabs.suggestedPages(limit: 6).isEmpty && workspace.browserTabs.visited.count == kept
                && workspace.snapshot.browser?.visited == nil,
              "visited \(workspace.browserTabs.visited.count) of \(kept)")
        UserDefaults.yardlet.removeObject(forKey: BrowserPageSuggestionPreference.key)
        await finish()
    }

    // MARK: Panel

    private func openPanel() async -> BrowserHostPaneController? {
        let previous = BrowserHostPaneController.current
        NotificationCenter.default.post(name: BrowserHostQAFixture.openBrowserPanel, object: nil)
        guard await waitUntil(.seconds(10), { BrowserHostPaneController.current !== previous
                && BrowserHostPaneController.current?.view != nil }),
              let controller = BrowserHostPaneController.current else {
            check("panel: the task's browser panel opens", false, "no panel")
            return nil
        }
        _ = await waitUntil(.seconds(10)) { controller.hasTab && controller.view?.viewSurface != nil }
        return controller
    }

    private func showLauncher(_ workspace: TaskWorkspaceState) async {
        workspace.setPanels(Navigation.showing(Navigation.launcherID, in: workspace.panels))
        try? await Task.sleep(for: .seconds(1))
    }

    /// The panel shows browser tab `key`, in the pane made for it once the launcher was shown.
    private func showBrowserTab(_ key: UUID, in workspace: TaskWorkspaceState) async -> BrowserHostPaneController? {
        workspace.setPanels(Navigation.showing(Navigation.browserTabID(key), in: workspace.panels))
        guard await waitUntil(.seconds(10), { BrowserHostPaneController.current?.key == key
                && BrowserHostPaneController.current?.view?.window != nil
                && BrowserHostPaneController.current?.hasTab == true }) else {
            check("panel: browser tab \(key) shows", false, "pane at \(BrowserHostPaneController.current?.key.uuidString ?? "nil")")
            return nil
        }
        return BrowserHostPaneController.current
    }

    /// The person enters `address` in the address field and the page opens.
    private func enter(_ address: String, in controller: BrowserHostPaneController, _ window: NSWindow) async {
        await type(address, in: controller, window)
        press(window, "\r", keyCode: 0x24)
        _ = await waitUntil(.seconds(10)) { controller.tab?.currentURL == address && !controller.isLoading }
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func type(_ text: String, in controller: BrowserHostPaneController, _ window: NSWindow) async {
        guard let field = addressField(in: window) else { return }
        if field.currentEditor() == nil || !controller.isEditingAddress {
            window.makeFirstResponder(field)
            _ = await waitUntil(.seconds(2)) { controller.isEditingAddress }
        }
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        try? await Task.sleep(for: .milliseconds(200))
    }

    private func press(_ window: NSWindow, _ characters: String, keyCode: UInt16) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: keyCode) else { continue }
            window.sendEvent(event)
        }
    }

    private func addressField(in window: NSWindow) -> NSTextField? {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        return all(window.contentView ?? NSView()).compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == L10n.string("Search Google or type a URL") }
    }

    /// Presses the button whose accessibility label is `label`, with the app's accessibility on, as VoiceOver would: the
    /// QA app never becomes active, so its window takes no click.
    private func pressButton(in root: NSView?, label: String) -> Bool {
        let attribute = "AXEnhancedUserInterface" as NSString
        let app = NSApplication.shared
        _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: attribute)
        defer { _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: false), with: attribute) }
        func visit(_ node: AnyObject) -> AnyObject? {
            for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                if (child.accessibilityLabel?() ?? nil) == label,
                   (child.accessibilityRole?() ?? nil) == NSAccessibility.Role.button { return child }
                if let found = visit(child) { return found }
            }
            return nil
        }
        return root.flatMap(visit)?.accessibilityPerformPress?() ?? false
    }

    /// What the agent's browser tool answers for the task's tab in front.
    private func agentText(_ tool: String) async -> String {
        let result = await agentTools.run(tool: tool, arguments: .object([:]), sessionID: session)
        return result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: " ")
    }

    // MARK: Record

    /// The window in light and dark, as AppKit draws it.
    private func capture(_ window: NSWindow, _ name: String) async {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)
            try? await Task.sleep(for: .seconds(1))
            guard let content = window.contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: output.appending(path: "\(name)-\(suffix).png"))
        }
        NSApp.appearance = nil
    }

    private func waitUntil(_ timeout: Duration, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private func check(_ name: String, _ ok: Bool, _ detail: String) {
        checks.append(.object(["check": .string("start-page: " + name), "ok": .bool(ok), "detail": .string(String(detail.prefix(800)))]))
        write()
    }

    private func write() {
        record["checks"] = .array(checks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(JSONValue.object(record)).write(to: output.appending(path: "result.json"), options: .atomic)
    }

    private func finish() async {
        write()
        try? "done".write(to: output.appending(path: "markers/finished"), atomically: true, encoding: .utf8)
        client.terminateHost()
        try? await Task.sleep(for: .seconds(1))
        _exit(0)
    }
}
#endif
