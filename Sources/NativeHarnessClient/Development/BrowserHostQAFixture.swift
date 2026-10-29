#if DEBUG
import AppKit
import CoreImage
import CoreBluetooth
import CryptoKit
import Foundation
import IOSurface
import SwiftUI
import YardletAgentTools
import YardletSurfacePort

/// DEBUG-only QA run of the browser panel (`--ui-fixture=conversation
/// --ui-fixture-browser-check=<output directory> --ui-fixture-browser-url=<qa page>`). It drives the
/// real panel, host and CDP path, answers native sheets itself, and writes `result.json` and phase
/// markers for scripts/browser-host-qa/run-check.sh. Product builds never compile it.
@MainActor
enum BrowserHostQAFixture {
    static let openBrowserPanel = Notification.Name("YardletBrowserQAOpenPanel")
    static let closeBrowserPanel = Notification.Name("YardletBrowserQAClosePanel")
    /// The QA task's composer draft, which a picked element joins (`visual-context`).
    static weak var composerDraft: TaskComposerDraft?
    /// The app, whose tasks mark and announce browser tabs that wait on the person (`AppModel.browserWaits`).
    static weak var model: AppModel?
    private static var started = false

    static func argument(_ name: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
    }

    static func startIfRequested(session: UUID) {
        BrowserHostLatencyFixture.startIfRequested()
        BrowserHostPerfFixture.startIfRequested(session: session)
        guard !started, MacBrowserHost.isAvailable,
              let output = argument("ui-fixture-browser-check").map({ URL(filePath: $0) }),
              let base = argument("ui-fixture-browser-url") else { return }
        started = true
        // `--ui-fixture-browser-check-only=vault` runs the vault for agents alone (BrowserHostVaultQA).
        // `--ui-fixture-browser-check-only=isolation` runs each task's own browser profile alone.
        if argument("ui-fixture-browser-check-only") == "isolation" {
            Task { @MainActor in await BrowserHostIsolationQA(output: output, base: base).run() }
            return
        }
        // `--ui-fixture-browser-check-only=import` runs bringing another browser's sign-ins over alone.
        if argument("ui-fixture-browser-check-only") == "import" {
            Task { @MainActor in await BrowserHostLoginImportQA(output: output, base: base).run() }
            return
        }
        if argument("ui-fixture-browser-check-only") == "vault" {
            Task { @MainActor in await BrowserHostVaultQA(output: output, base: base, panelSession: session).run() }
            return
        }
        // `--ui-fixture-browser-check-only=browser-use` runs screen sizes, frames and handing a tab to the person
        // alone (BrowserHostBrowserUseQA).
        if argument("ui-fixture-browser-check-only") == "browser-use" {
            Task { @MainActor in await BrowserHostBrowserUseQA(output: output, base: base, panelSession: session).run() }
            return
        }
        // `--ui-fixture-browser-check-only=person-first` runs the person's screen against the agent and the page alone
        // (BrowserHostPersonFirstQA): dialogs that wait in their tab, and the tab the person uses.
        if argument("ui-fixture-browser-check-only") == "person-first" {
            Task { @MainActor in await BrowserHostPersonFirstQA(output: output, panelSession: session).run() }
            return
        }
        // `--ui-fixture-browser-check-only=address-suggest` runs the address field's suggestions alone
        // (BrowserHostAddressSuggestQA).
        if argument("ui-fixture-browser-check-only") == "address-suggest" {
            Task { @MainActor in await BrowserHostAddressSuggestQA(output: output, base: base).run() }
            return
        }
        // `--ui-fixture-browser-check-only=start-page` runs a new tab's start page and the launcher's pages alone
        // (BrowserHostStartPageQA).
        if argument("ui-fixture-browser-check-only") == "start-page" {
            Task { @MainActor in await BrowserHostStartPageQA(output: output, base: base, session: session).run() }
            return
        }
        // `--ui-fixture-browser-check-only=memory-saver` runs the memory saver's discards alone (BrowserHostMemorySaverQA).
        if argument("ui-fixture-browser-check-only") == "memory-saver" {
            Task { @MainActor in await BrowserHostMemorySaverQA(output: output, base: base).run() }
            return
        }
        Task { @MainActor in await BrowserHostQARunner(output: output, base: base, session: session).run() }
    }
}

@MainActor
private final class BrowserHostQARunner {
    let output: URL
    let base: String
    let session: UUID
    private var record: [String: JSONValue] = [:]
    private var checks: [JSONValue] = []
    private var phases: [JSONValue] = []
    private let start = DispatchTime.now().uptimeNanoseconds
    private var client: BrowserHostClient { MacBrowserHost.shared.client }

    init(output: URL, base: String, session: UUID) {
        self.output = output
        self.base = base
        self.session = session
    }

    func run() async {
        try? FileManager.default.createDirectory(at: output.appending(path: "markers"), withIntermediateDirectories: true)
        record["pid"] = .integer(Int64(ProcessInfo.processInfo.processIdentifier))
        record["paths"] = .object([
            "profile": .string(MacBrowserHost.shared.paths.profile.path(percentEncoded: false)),
            "downloads": .string(MacBrowserHost.shared.paths.downloads.path(percentEncoded: false))
        ])
        try? await Task.sleep(for: .seconds(3))
        // `--ui-fixture-browser-check-only=rail-preview` runs the session rail's preview alone.
        if BrowserHostQAFixture.argument("ui-fixture-browser-check-only") == "rail-preview" {
            await exerciseRailPreview()
            return await finish()
        }
        // `--ui-fixture-browser-check-only=tabs` runs the side panel's browser tabs alone (with
        // `--ui-fixture-appearance=dark` for the dark capture).
        if BrowserHostQAFixture.argument("ui-fixture-browser-check-only") == "tabs" {
            if let controller = await openPanel(label: "tabs", address: base), let view = controller.view {
                _ = await waitUntil(.seconds(10)) { controller.title == "Browser QA" && !controller.isLoading }
                do { try await exerciseTabs(controller, view) } catch { check("tabs: side-panel tabs", false, error.localizedDescription) }
                await exerciseQuitKeepsTabs(controller.workspace)
                await closePanel()
                client.closeTabs(forSession: session)
            }
            return await finish()
        }
        // `--ui-fixture-browser-check-only=passkey` runs the passkey requests alone.
        if BrowserHostQAFixture.argument("ui-fixture-browser-check-only") == "passkey" {
            if let controller = await openPanel(label: "passkey", address: base), let view = controller.view {
                _ = await waitUntil(.seconds(10)) { controller.title == "Browser QA" && !controller.isLoading }
                do { try await exercisePasskey(controller, view) } catch { check("passkey", false, error.localizedDescription) }
                await closePanel()
                client.closeTabs(forSession: session)
            }
            return await finish()
        }
        // `--ui-fixture-browser-check-only=compat` runs what ordinary sites ask of a browser alone.
        if BrowserHostQAFixture.argument("ui-fixture-browser-check-only") == "compat" {
            if let controller = await openPanel(label: "compat", address: base + "compat"), let view = controller.view {
                _ = await waitUntil(.seconds(10)) { controller.title == "Compat" && !controller.isLoading }
                do { try await exerciseCompat(controller, view) } catch { check("compat", false, error.localizedDescription) }
                await closePanel()
                client.closeTabs(forSession: session)
            }
            return await finish()
        }
        // `--ui-fixture-browser-check-only=checkout` runs a card checkout and the issuer's check alone.
        if BrowserHostQAFixture.argument("ui-fixture-browser-check-only") == "checkout" {
            if let controller = await openPanel(label: "checkout", address: base), let view = controller.view {
                _ = await waitUntil(.seconds(10)) { controller.title == "Browser QA" && !controller.isLoading }
                do { try await exerciseCheckout(controller, view) } catch { check("checkout", false, error.localizedDescription) }
                await closePanel()
                client.closeTabs(forSession: session)
            }
            return await finish()
        }
        // `--ui-fixture-browser-check-only=visual-context` runs picking an element for the composer and
        // marking up its capture alone.
        if BrowserHostQAFixture.argument("ui-fixture-browser-check-only") == "visual-context" {
            if let controller = await openPanel(label: "visual-context", address: base + "pick"), let view = controller.view {
                _ = await waitUntil(.seconds(10)) { controller.title == "Pick" && !controller.isLoading }
                do { try await exerciseVisualContext(controller, view) } catch { check("visual context", false, error.localizedDescription) }
                await closePanel()
                client.closeTabs(forSession: session)
            }
            return await finish()
        }
        // `--ui-fixture-browser-check-only=unresponsive` runs pages that stop responding alone.
        if BrowserHostQAFixture.argument("ui-fixture-browser-check-only") == "unresponsive" {
            await exerciseUnresponsive()
            return await finish()
        }
        // `--ui-fixture-browser-check-only=input` runs the caret, keys, page size and renderer-end checks alone.
        if BrowserHostQAFixture.argument("ui-fixture-browser-check-only") == "input" {
            await exerciseInput()
            return await finish()
        }
        // `--ui-fixture-browser-check-only=load-errors` runs the page load errors the panel shows alone.
        if BrowserHostQAFixture.argument("ui-fixture-browser-check-only") == "load-errors" {
            await exerciseLoadErrors()
            return await finish()
        }
        // `--ui-fixture-browser-check-only=draft-handoff` runs the new-task screen's tabs going to a task.
        if BrowserHostQAFixture.argument("ui-fixture-browser-check-only") == "draft-handoff" {
            await exerciseDraftHandoff()
            return await finish()
        }
        // `--ui-fixture-browser-check-only=external-links` runs links and HTML files other apps open with Yardlet, the
        // default browser, alone.
        if BrowserHostQAFixture.argument("ui-fixture-browser-check-only") == "external-links" {
            await exerciseExternalLinks()
            return await finish()
        }
        // `--ui-fixture-browser-check-only=many-tabs --ui-fixture-browser-limit=20` runs many tasks' tabs and a
        // tab the browser has no room for alone.
        if BrowserHostQAFixture.argument("ui-fixture-browser-check-only") == "many-tabs" {
            await exerciseManyTabs()
            return await finish()
        }
        // `--ui-fixture-browser-check-only=tooltips` runs the names the panel's header buttons show on hover alone.
        if BrowserHostQAFixture.argument("ui-fixture-browser-check-only") == "tooltips" {
            if let controller = await openPanel(label: "tooltips", address: base), let view = controller.view {
                _ = await waitUntil(.seconds(10)) { controller.title == "Browser QA" && !controller.isLoading }
                await exerciseTooltips(controller, view)
                await closePanel()
                client.closeTabs(forSession: session)
            }
            return await finish()
        }
        // `--ui-fixture-browser-check-only=resize` runs dragging the side panel's divider over pages laid out
        // for their width alone.
        if BrowserHostQAFixture.argument("ui-fixture-browser-check-only") == "resize" {
            if let controller = await openPanel(label: "resize", address: base + "responsive"), let view = controller.view {
                _ = await waitUntil(.seconds(10)) { controller.title == "Responsive" && !controller.isLoading }
                await exerciseResize(controller, view)
                await closePanel()
                client.closeTabs(forSession: session)
            }
            return await finish()
        }
        // A QA window launched in the background may sit under other windows; run-check.sh passes
        // --ui-fixture-browser-ignore-occlusion so the panel paints anyway. Recorded for the reader.
        record["windowVisibleAtStart"] = .bool(qaWindow?.occlusionState.contains(.visible) ?? false)
        await phase("0-before-host")

        guard let controller = await openPanel(label: "cold", address: base) else { return await finish() }
        await exercise(controller)
        await exercisePanelLessTab()
        await phase("1-panel-open")

        // Close: the tab stays for the grace period, then the host ends.
        let tabID = controller.tab?.id
        _ = try? await evaluate(controller, "document.querySelector('#name').value = 'kept across panels'; 'ok'")
        await closePanel()
        check("tab kept after the panel closes", client.tab(forSession: session) != nil && client.isHostRunning,
              "open tabs \(client.openTabCount)")
        await phase("2-closed-in-grace")
        if let warm = await openPanel(label: "warm", address: nil) {
            let kept = (try? await evaluate(warm, "document.querySelector('#name').value")) ?? ""
            check("warm reopen shows the same tab and page state", warm.tab?.id == tabID && kept == "kept across panels",
                  "tab \(String(describing: warm.tab?.id)) was \(String(describing: tabID)); field \"\(kept)\"")
            await closePanel()
        }

        // A task's tab stays without its panel until it is closed for the task; then the host ends.
        client.noteAgentActivity(forSession: session)
        let grace = Double(client.idleGrace.components.seconds)
        try? await Task.sleep(for: .seconds(grace + 2))
        check("a task's tab keeps the host past the grace period", client.isHostRunning && client.tab(forSession: session) != nil,
              "grace \(Int(grace)) s, open tabs \(client.openTabCount)")
        client.tab(forSession: session)?.close()
        let closedAt = DispatchTime.now().uptimeNanoseconds
        let exited = await waitUntil(.seconds(Int(grace) + 20)) { !self.client.isHostRunning }
        record["taskTabCloseToExitMs"] = .number(Self.milliseconds(since: closedAt))
        check("host ends the grace period after the task's tab closes", exited, client.lastTermination ?? "still running")
        try? await Task.sleep(for: .seconds(3))
        await phase("3-after-host-exit")

        // Cold start again: the persistent profile kept the cookies. The tab closed above closed its
        // page (a side-panel tab's rule), so the panel opens a new tab and goes to the page.
        if let cold = await openPanel(label: "cold-2", address: base) {
            _ = await waitUntil(.seconds(10)) { cold.title == "Browser QA" && !cold.isLoading }
            let cookies = (try? await evaluate(cold, "document.cookie")) ?? ""
            check("profile keeps cookies across host restarts", cookies.contains("persistent=1") && cookies.contains("session=1"),
                  "cookies \"\(cookies)\"")
            await crashDrill(cold)
            await closePanel()
        }
        client.tab(forSession: session)?.close()
        _ = await waitUntil(.seconds(Int(grace) + 20)) { !self.client.isHostRunning }
        try? await Task.sleep(for: .seconds(3))
        await phase("4-after-exit")

        // The agent works in the task's tab while the panel is closed; the panel opens later.
        await exerciseFullPageScreenshot()
        await exerciseCDPWhileSurfacesAreReused()
        await exerciseAgentTabThenPanel()
        _ = await waitUntil(.seconds(Int(grace) + 20)) { !self.client.isHostRunning }
        try? await Task.sleep(for: .seconds(3))
        await phase("5-after-agent-tab")
        checkFileLocations()
        await finish()
    }

    // MARK: The new-task screen's tabs

    /// The new-task screen's tabs go to the task it starts as `AppModel.handOffDraftWorkspace` moves
    /// them (`BrowserHostClient.moveTabs`): the same tabs in the same order with the same one in front,
    /// nothing opened or loaded again, the pages' state kept, and the task's panel shows them.
    private func exerciseDraftHandoff() async {
        let draft = TaskWorkspaceStore.draftID
        guard let first = try? client.openTab(forSession: draft, url: base, viewport: .offscreenDefault),
              let second = try? client.newTab(forSession: draft, url: base + "animation", viewport: .offscreenDefault,
                                              select: true)
        else { return check("draft tabs open", false, "could not open") }
        let loaded = await waitUntil(.seconds(20)) {
            first.title == "Browser QA" && !first.isLoading && !second.isLoading && second.lastPageURL != nil
        }
        check("draft tabs open", loaded, "titles \"\(first.title)\", \"\(second.title)\"")
        let marked = try? await first.devTools.send("Runtime.evaluate", [
            "expression": .string("window.__draftMark = performance.timeOrigin; document.querySelector('#name').value = 'typed on the new-task screen'; String(window.__draftMark)"),
            "returnByValue": .bool(true)
        ])
        let mark = marked?["result"]?["value"]?.readableText ?? ""
        let launches = client.launchCount
        let tabIDs = [first.id, second.id]
        await phase("draft-1-tabs-open")

        client.moveTabs(fromSession: draft, toSession: session)
        check("the task has the draft's tabs in order, the same one in front",
              client.tabs(forSession: session).map(\.id) == tabIDs && client.tab(forSession: session) === second
                && client.tabs(forSession: draft).isEmpty && first.session == session && second.session == session,
              "task tabs \(client.tabs(forSession: session).map(\.id)), was \(tabIDs); draft \(client.tabs(forSession: draft).count)")

        first.select()
        guard let controller = await openPanel(label: "after-draft-handoff", address: nil) else { return }
        let state = (try? await evaluate(controller,
            "String(window.__draftMark) + '|' + document.querySelector('#name').value")) ?? ""
        check("the task's panel shows the same page with its state",
              controller.tab === first && state == "\(mark)|typed on the new-task screen" && client.launchCount == launches,
              "tab \(String(describing: controller.tab?.id)) (was \(first.id)), state \"\(state)\" (mark \(mark)), "
                + "host launches \(client.launchCount - launches)")
        await phase("draft-2-task-panel")
        await closePanel()
        client.closeTabs(forSession: session)
        let grace = Double(client.idleGrace.components.seconds)
        _ = await waitUntil(.seconds(Int(grace) + 20)) { !self.client.isHostRunning }
        await phase("draft-3-after")
    }

    // MARK: Links from other apps

    /// Links and HTML files other apps open with Yardlet once it is the default browser (`AppModel.openExternalLinks`):
    /// Launch Services hands each to this running app, which it does not make active, and each opens at its page in a
    /// new tab of the side panel of the task the window shows, with no window of its own (SwiftUI opens one for a URL
    /// the app delegate does not take).
    private func exerciseExternalLinks() async {
        guard let controller = await openPanel(label: "external-links", address: base) else { return }
        _ = await waitUntil(.seconds(10)) { controller.title == "Browser QA" && !controller.isLoading }
        let workspace = controller.workspace
        let windowsBefore = NSApp.windows.filter(\.canBecomeMain)
        let windows = windowsBefore.count
        let file = output.appending(path: "external-link.html")
        try? Data("<!doctype html><title>Local file</title><p>Opened with Yardlet</p>".utf8).write(to: file)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        for (name, url, title) in [("a link", URL(string: base + "second"), "Second"), ("an HTML file", file, "Local file")] {
            guard let url else { continue }
            let before = Set(TaskSurfaceNavigationProjection.browserKeys(in: workspace.panels))
            var opened: String?
            do {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: Bundle.main.bundleURL, configuration: configuration)
            } catch {
                opened = error.localizedDescription
            }
            var shown = "none"
            let arrived = await waitUntil(.seconds(20)) {
                guard let key = TaskSurfaceNavigationProjection.browserKey(inTab: workspace.panels.trailingSurfaceID),
                      !before.contains(key) else { return false }
                let tab = self.client.tab(key: key, forSession: self.session)
                shown = "\(workspace.browserTabs.tab(key)?.address ?? "-") \"\(tab?.title ?? "")\""
                return tab?.title == title && !(tab?.isLoading ?? true)
            }
            check("external links: \(name) opens in a new tab of the shown task's panel, at its page", arrived && opened == nil,
                  "open \(opened ?? "sent"); shown \(shown); tabs \(before.count) → "
                    + "\(TaskSurfaceNavigationProjection.browserKeys(in: workspace.panels).count)")
        }
        let added = NSApp.windows.filter { $0.canBecomeMain && !windowsBefore.contains($0) }
        check("external links: no window of their own", added.isEmpty,
              "windows \(windows) → \(windows + added.count); added \(added.map { $0.identifier?.rawValue ?? "-" })")
        await phase("external-links")
        await closePanel()
        client.closeTabs(forSession: session)
        let grace = Double(client.idleGrace.components.seconds)
        _ = await waitUntil(.seconds(Int(grace) + 20)) { !self.client.isHostRunning }
    }

    // MARK: Many tasks' tabs

    /// One browser host holds every task's tabs. Until 2026-10-27 it held 16: past them no tab of any task
    /// opened, while the app kept each as an open blank tab and the agent heard only "The browser tab is
    /// gone." Tabs past 16 across tasks open, the agent's included; a tab the browser has no room for (this run
    /// caps it at `--ui-fixture-browser-limit`, 20) says why to the agent and in its panel, and opens again in
    /// its place once a tab closes.
    private func exerciseManyTabs() async {
        let page = base + "second"
        guard let controller = await openPanel(label: "many-tabs", address: page) else { return }
        _ = await waitUntil(.seconds(10)) { controller.title == "Second" && !controller.isLoading }
        // Two other tasks, each with its own profile and the most tabs a task has, as tasks with closed panels.
        var others: [BrowserTab] = []
        for task in [UUID(), UUID()] {
            for index in 0..<BrowserHostClient.maxTabsPerSession {
                let tab = index == 0
                    ? try? client.openTab(forSession: task, url: page, viewport: .offscreenDefault)
                    : try? client.newTab(forSession: task, url: page, viewport: .offscreenDefault, select: false)
                if let tab { others.append(tab) }
            }
        }
        let loaded = await waitUntil(.seconds(60)) { others.allSatisfy { $0.title == "Second" } }
        let atPage = others.filter { $0.title == "Second" }.count + 1
        check("many tabs: tabs past 16 across tasks open", loaded && others.count == 2 * BrowserHostClient.maxTabsPerSession,
              "\(atPage) of \(others.count + 1) tabs at their page; not: \(others.filter { $0.title != "Second" }.map(\.id))")

        let agentTools = BrowserAgentTools(usesMacEditingCommands: true, tabs: BrowserAgentTabs { MacBrowserHost.shared.client })
        func run(_ tool: String, _ arguments: [String: JSONValue] = [:]) async -> (text: String, isError: Bool) {
            let result = await agentTools.run(tool: tool, arguments: .object(arguments), sessionID: session)
            let text = result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: " ")
            return (text, result.isError)
        }
        func newAgentTab() async -> String {
            let opened = await run(AgentToolCatalog.tabNew)
            return opened.text.range(of: #""tabId":"(\d+)""#, options: .regularExpression)
                .map { String(opened.text[$0]).filter(\.isNumber) } ?? ""
        }
        func title(_ tabID: String) async -> String {
            await run(AgentToolCatalog.evaluate, ["function": .string("() => document.title"), "tabId": .string(tabID)]).text
        }
        // The agent's own tab, the 20th: a task whose panel was closed opens one on its next call.
        let agentTab = await newAgentTab()
        let moved = await run(AgentToolCatalog.navigate, ["url": .string(page), "tabId": .string(agentTab)])
        let agentTitle = await title(agentTab)
        check("many tabs: the agent's tab past 16 opens its page", !moved.isError && agentTitle.contains("Second"),
              "tab \(agentTab): navigate \"\(moved.text.prefix(200))\", title \"\(agentTitle.prefix(200))\"")
        await phase("many-1-twenty-tabs")

        // The browser is full: the 21st tab cannot open. The agent hears why at once, and the tab list says so.
        let full = await newAgentTab()
        let listed = await waitUntil(.seconds(5)) { self.client.tabs(forSession: self.session).contains { String($0.id) == full } }
        let started = DispatchTime.now().uptimeNanoseconds
        let refused = await run(AgentToolCatalog.navigate, ["url": .string(page), "tabId": .string(full)])
        let refusedMs = Self.milliseconds(since: started)
        let listing = await run(AgentToolCatalog.tabList).text
        check("many tabs: a tab the browser cannot open tells the agent why",
              listed && refused.isError && refused.text.contains("could not open") && !refused.text.contains("not running")
                && refusedMs < 5_000 && listing.contains("Could not open"),
              "navigate in \(Int(refusedMs)) ms: \"\(refused.text.prefix(300))\"; list \"\(listing.suffix(300))\"")

        // Its panel says why, though the tab failed before the panel showed it.
        let failed = client.tabs(forSession: session).last
        failed?.select()
        let shown = await waitUntil(.seconds(5)) { controller.tab === failed && controller.errorMessage != nil }
        let limitMessage = L10n.string("The browser has too many tabs open. Close a tab in this or another task, then try again.")
        check("many tabs: the panel shows why its tab could not open", shown && controller.errorMessage == limitMessage,
              "panel tab \(controller.tab?.id ?? -1) (failed \(failed?.id ?? -1)), error \"\(controller.errorMessage ?? "none")\"")

        // A tab of another task closes (its browser goes once Chromium has closed it): Try again opens the tab in
        // its place.
        others.removeFirst().close()
        try? await Task.sleep(for: .seconds(1))
        controller.retry()
        let reopened = await waitUntilAsync(.seconds(20)) {
            guard controller.errorMessage == nil, controller.tab != nil, controller.tab !== failed else { return false }
            return (try? await self.evaluate(controller, "document.readyState")) == "complete"
        }
        check("many tabs: Try again opens the tab once there is room", reopened,
              "panel tab \(controller.tab?.id ?? -1) (was \(failed?.id ?? -1)), error \"\(controller.errorMessage ?? "none")\"")

        // Full again: the agent's next tab cannot open; once a tab closes, browser_navigate opens it in its place.
        let second = await newAgentTab()
        _ = await waitUntil(.seconds(5)) { self.client.tabs(forSession: self.session).contains { String($0.id) == second } }
        try? await Task.sleep(for: .milliseconds(500))
        others.removeFirst().close()
        try? await Task.sleep(for: .seconds(1))
        let retried = await run(AgentToolCatalog.navigate, ["url": .string(page), "tabId": .string(second)])
        let replacement = retried.text.range(of: #"as tabId "(\d+)""#, options: .regularExpression)
            .map { String(retried.text[$0]).filter(\.isNumber) } ?? second
        let retriedTitle = await title(replacement)
        check("many tabs: browser_navigate opens a tab that could not open once there is room",
              !retried.isError && replacement != second && retriedTitle.contains("Second"),
              "navigate \"\(retried.text.prefix(300))\", tab \(replacement) title \"\(retriedTitle.prefix(200))\"")

        await closePanel()
        client.closeTabs(forSession: session)
        for tab in others { tab.close() }
        let grace = Double(client.idleGrace.components.seconds)
        _ = await waitUntil(.seconds(Int(grace) + 20)) { !self.client.isHostRunning }
    }

    // MARK: Pages that stop responding

    /// The renderers of this QA bundle's pages, busiest first: process id and CPU %.
    private func rendererLoad() -> [(pid: Int, cpu: Double)] {
        let ps = Process()
        ps.executableURL = URL(filePath: "/bin/ps")
        ps.arguments = ["-A", "-o", "pid=,%cpu=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try? ps.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let bundle = Bundle.main.bundlePath
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            guard line.contains(bundle), line.contains("Helper (Renderer)") else { return nil }
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = Int(fields[0]), let cpu = Double(fields[1]) else { return nil }
            return (pid, cpu)
        }.sorted { $0.cpu > $1.cpu }
    }

    private func describeLoad(_ load: [(pid: Int, cpu: Double)]) -> String {
        load.isEmpty ? "no renderer" : load.map { "\($0.pid) \(Int($0.cpu))%" }.joined(separator: ", ")
    }

    /// A page whose main thread does not return, as the ERP review's tab was: the agent's tools say so
    /// (no answer in time; the tab list says which tab), browser_navigate opens the page again in its
    /// place, and the busy renderer goes; in a panel the person uses, Chromium's hang monitor says so
    /// after 15 seconds and the panel shows "Page Unresponsive" with Wait and Reload.
    private func exerciseUnresponsive() async {
        guard let controller = await openPanel(label: "unresponsive", address: base), let view = controller.view else { return }
        _ = await waitUntil(.seconds(10)) { controller.title == "Browser QA" && !controller.isLoading }
        let agentTools = BrowserAgentTools(usesMacEditingCommands: true, tabs: BrowserAgentTabs { MacBrowserHost.shared.client })
        func text(_ result: AgentToolResult) -> String {
            result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: " ")
        }
        var results: [String: JSONValue] = [:]

        // The agent's tab behind the panel's: a script that does not return.
        let opened = await agentTools.run(tool: AgentToolCatalog.tabNew, arguments: .object([:]), sessionID: session)
        let tabID = text(opened).range(of: #""tabId":"(\d+)""#, options: .regularExpression)
            .map { String(text(opened)[$0]).filter(\.isNumber) } ?? ""
        _ = await agentTools.run(tool: AgentToolCatalog.navigate, arguments: .object([
            "url": .string(base + "busy?ms=0"), "tabId": .string(tabID)]), sessionID: session)
        let loadBefore = rendererLoad()
        let started = DispatchTime.now().uptimeNanoseconds
        let stuck = await agentTools.run(tool: AgentToolCatalog.evaluate, arguments: .object([
            "function": .string("() => { while (true) {} }"), "tabId": .string(tabID)]), sessionID: session)
        let stuckMs = Self.milliseconds(since: started)
        let stuckText = text(stuck)
        let saysSo = stuckText.contains("This tab's page is not responding")
        let snapshot = await agentTools.run(tool: AgentToolCatalog.snapshot, arguments: .object(["tabId": .string(tabID)]),
                                            sessionID: session)
        let listing = text(await agentTools.run(tool: AgentToolCatalog.tabList, arguments: .object([:]), sessionID: session))
        let listed = listing.contains(#""responding":false"#) && listing.contains("Not responding: tab \(tabID)")
        try? await Task.sleep(for: .seconds(2))
        let loadStuck = rendererLoad()
        let keyBefore = client.tabs(forSession: session).first { String($0.id) == tabID }?.key
        let moved = await agentTools.run(tool: AgentToolCatalog.navigate, arguments: .object([
            "url": .string(base + "second"), "tabId": .string(tabID)]), sessionID: session)
        let movedText = text(moved)
        let replacement = client.tabs(forSession: session).first { $0.key == keyBefore }
        let reopened = movedText.contains("was opened again") && replacement != nil && String(replacement!.id) != tabID
            && replacement?.lastPageURL?.hasSuffix("/second") == true
        try? await Task.sleep(for: .seconds(3))
        let loadAfter = rendererLoad()
        let stuckRendererGone = !loadAfter.contains { $0.cpu > 50 }
        results["agent"] = .object([
            "evaluateMs": .number(stuckMs), "evaluateResult": .string(stuckText), "snapshotResult": .string(text(snapshot)),
            "tabList": .string(listing), "navigateResult": .string(movedText),
            "renderersBefore": .string(describeLoad(loadBefore)), "renderersStuck": .string(describeLoad(loadStuck)),
            "renderersAfter": .string(describeLoad(loadAfter))
        ])
        check("unresponsive: the agent hears its tab's page is not responding", saysSo && !stuck.content.isEmpty && listed,
              "evaluate \(Int(stuckMs)) ms: \(stuckText.prefix(260)); listed \(listed)")
        check("unresponsive: browser_navigate opens the page again in its place", reopened && stuckRendererGone,
              "\(movedText.prefix(220)); renderers stuck \(describeLoad(loadStuck)) → after \(describeLoad(loadAfter))")

        // The old id reaches the tab opened in its place, saying so.
        let replacementID = replacement.map { String($0.id) } ?? "none"
        let viaOld = text(await agentTools.run(tool: AgentToolCatalog.evaluate, arguments: .object([
            "function": .string("() => location.pathname"), "tabId": .string(tabID)]), sessionID: session))
        check("unresponsive: the old tab id reaches the tab opened in its place",
              viaOld.hasPrefix("Tab \(tabID) is now tab \(replacementID): its page was not responding") && viaOld.contains("/second"),
              String(viaOld.prefix(260)))
        // A function whose promise does not settle is late on a page that answers everything else: no page that does not
        // respond, for the agent or the panel.
        let pendingStarted = DispatchTime.now().uptimeNanoseconds
        let pending = text(await agentTools.run(tool: AgentToolCatalog.evaluate, arguments: .object([
            "function": .string("() => new Promise(() => {})"), "tabId": .string(replacementID)]), sessionID: session))
        let pendingMs = Self.milliseconds(since: pendingStarted)
        let pendingListing = text(await agentTools.run(tool: AgentToolCatalog.tabList, arguments: .object([:]), sessionID: session))
        check("unresponsive: a promise that does not settle is late, not a page that does not respond",
              pending.contains("The function did not finish within 15 seconds. The page answered another call right after")
                && !pending.contains("not responding") && replacement?.unresponsive == nil && !pendingListing.contains("Not responding"),
              "\(Int(pendingMs)) ms: \(pending.prefix(260)); listed \(!pendingListing.contains("Not responding"))")
        results["late"] = .object(["evaluateMs": .number(pendingMs), "evaluateResult": .string(pending),
                                   "oldIdResult": .string(viaOld)])
        if let replacement { replacement.close() }

        // The person's tab: a click starts a long script, the next input waits, and the hang monitor says so.
        func hold(_ milliseconds: Int) async -> Bool {
            controller.addressInput = base + "busy?ms=\(milliseconds)"
            controller.submitAddress()
            _ = await waitUntil(.seconds(10)) { controller.title == "Busy" && !controller.isLoading }
            guard let point = try? await center(controller, "#loop") else { return false }
            click(view, at: point)
            try? await Task.sleep(for: .milliseconds(300))
            move(view, to: NSPoint(x: point.x + 40, y: point.y + 40))
            return true
        }
        let held = await hold(40_000)
        let heldAt = DispatchTime.now().uptimeNanoseconds
        let barShown = await waitUntil(.seconds(25)) { controller.isUnresponsive }
        let barMs = Self.milliseconds(since: heldAt)
        capturePanel(view, named: "unresponsive-bar.png")
        controller.waitForUnresponsivePage()
        let waited = !controller.isUnresponsive
        // Still busy: the hang monitor says so again after another 15 seconds; once the script ends,
        // the page answers and the bar goes.
        let saidAgain = await waitUntil(.seconds(25)) { controller.isUnresponsive }
        let answered = await waitUntil(.seconds(30)) { !controller.isUnresponsive && controller.title == "Busy (done)" }
        check("unresponsive: the panel shows Page Unresponsive, and Wait waits", held && barShown && waited && saidAgain && answered,
              "bar after \(Int(barMs)) ms \(barShown), wait hides it \(waited), again \(saidAgain), answered after the script \(answered)")

        let heldForGood = await hold(0)
        let barAgain = await waitUntil(.seconds(25)) { controller.isUnresponsive }
        let stuckLoad = rendererLoad()
        let stuckTab = controller.tab
        controller.reloadUnresponsivePage()
        let reloaded = await waitUntil(.seconds(20)) {
            controller.tab != nil && controller.tab !== stuckTab && controller.title == "Busy" && !controller.isUnresponsive
        }
        try? await Task.sleep(for: .seconds(3))
        let afterReload = rendererLoad()
        capturePanel(view, named: "unresponsive-reloaded.png")
        check("unresponsive: Reload ends the renderer and opens the page again",
              heldForGood && barAgain && reloaded && !afterReload.contains { $0.cpu > 50 },
              "bar \(barAgain), reloaded \(reloaded); renderers \(describeLoad(stuckLoad)) → \(describeLoad(afterReload))")
        results["person"] = .object(["barMs": .number(barMs)])
        try? write(.object(results), to: "unresponsive.json")
        await closePanel()
        client.closeTabs(forSession: session)
        let grace = Double(client.idleGrace.components.seconds)
        _ = await waitUntil(.seconds(Int(grace) + 20)) { !self.client.isHostRunning }
    }

    // MARK: Keyboard focus, the caret and the page's size

    /// The caret and the keys a page gets (2026-10-23, the person's "no caret in a login's password
    /// field" and keys that went missing): a text and a password field take the caret and typing after a
    /// click, also in a tab the panel shows after another while the page had the keyboard; the page keeps
    /// the keyboard across its own moves and takes it from the address field; the page keeps its size
    /// while it loads; a renderer that ends says how in host.log. `input.json` records each.
    private func exerciseInput() async {
        guard let controller = await openPanel(label: "input", address: base + "login"), let view = controller.view else { return }
        _ = await waitUntil(.seconds(10)) { controller.title == "Login" && !controller.isLoading }
        var results: [String: JSONValue] = [:]

        func field(_ id: String, _ name: String) async -> Bool {
            guard let point = try? await center(controller, "#\(id)") else { return false }
            click(view, at: point)
            try? await Task.sleep(for: .milliseconds(500))
            let focused = (try? await evaluate(controller, "String(document.hasFocus() && document.activeElement.id)")) ?? ""
            let caret = await caretShows(view, await fieldRect(controller, id))
            capturePanel(view, named: "\(name).png")
            key(view, "a", keyCode: 0)
            try? await Task.sleep(for: .milliseconds(400))
            let typed = (try? await evaluate(controller, "String(document.querySelector('#\(id)').value.length)")) ?? ""
            _ = try? await evaluate(controller, "document.querySelector('#\(id)').value = ''; 'ok'")
            results[name] = .object(["focused": .string(focused), "caret": .bool(caret), "typed": .string(typed)])
            return focused == id && caret && typed == "1"
        }

        let text = await field("user", "text-field")
        let password = await field("pass", "password-field")
        check("input: a text and a password field show the caret and take keys", text && password,
              "\(results["text-field"]?.readableText ?? "") \(results["password-field"]?.readableText ?? "")")

        // Secure keyboard entry and Roman input sources in the password field (2026-10-25, the person's
        // Hangul in a password field): on while it has the keyboard, off when the keyboard leaves it. Here
        // the recorder (`BrowserSecureInputRecorder`) stands in, so the person's input source stays.
        let recorder = BrowserSecureInput.system as? BrowserSecureInputRecorder
        var secureSteps: [String] = []
        func secure(_ step: String, _ expected: Bool) async -> Bool {
            // The renderer's report reaches the panel through the host.
            _ = await waitUntil(.seconds(3)) { view.isInSecureInputState == expected }
            let on = view.isInSecureInputState
            secureSteps.append("\(step) \(on ? "on" : "off")")
            return on == expected && recorder?.secureEventInputCount == (on ? 1 : 0)
        }
        func clickField(_ selector: String) async {
            if let point = try? await center(controller, selector) { click(view, at: point) }
            try? await Task.sleep(for: .milliseconds(400))
        }
        var secureOK = recorder != nil
        await clickField("#user")
        secureOK = await secure("text field", false) && secureOK
        await clickField("#pass")
        secureOK = await secure("password field", true) && secureOK
        await clickField("#user")
        secureOK = await secure("text field again", false) && secureOK
        await clickField("#pass")
        view.window?.makeFirstResponder(nil)
        secureOK = await secure("keyboard left the panel", false) && secureOK
        view.window?.makeFirstResponder(view)
        try? await Task.sleep(for: .milliseconds(300))
        secureOK = await secure("keyboard back", true) && secureOK
        check("input: secure keyboard entry and Roman input sources only while the password field has the keyboard",
              secureOK, secureSteps.joined(separator: ", "))

        // The page moves as an SPA does after a click and after Enter (a soft navigation). Before, CEF
        // stamped forwarded input with AppKit's absent or stale current event, the move seemed to start
        // before the page's time origin, and Blink's CHECK ended the renderer.
        let pageTab = controller.tab
        if let go = try? await center(controller, "#go") { click(view, at: go) }
        let clicked = await waitUntil(.seconds(5)) { controller.title == "Login step 1" }
        if let pass = try? await center(controller, "#pass") { click(view, at: pass) }
        try? await Task.sleep(for: .milliseconds(300))
        key(view, "\r", keyCode: 36)
        let entered = await waitUntil(.seconds(5)) { controller.title == "Login step 2" }
        try? await Task.sleep(for: .seconds(2))
        let survived = controller.tab === pageTab && controller.errorMessage == nil
        let ages = (try? await evaluate(controller, "JSON.stringify(__input)")) ?? ""
        let agesMs = (try? JSONSerialization.jsonObject(with: Data(ages.utf8)) as? [[Any]])?.compactMap { $0.last as? Int } ?? []
        let fresh = !agesMs.isEmpty && agesMs.allSatisfy { (0...3000).contains($0) }
        results["softNavigation"] = .object(["afterClick": .bool(clicked), "afterEnter": .bool(entered),
                                             "rendererKept": .bool(survived), "inputAgesMs": .string(ages)])
        check("input: pages get input stamped now, and an SPA's moves keep the renderer", clicked && entered && survived && fresh,
              "click \(clicked), Enter \(entered), renderer kept \(survived); input ages (ms) \(ages.prefix(200))")

        // The page keeps the keyboard across its own moves (2026-10-24, the person's "no caret in a login's
        // password field"): a login's next step as a new document on the same site and on another, a frame
        // from another site, back, and Enter in the address field (which gives the page the keyboard, as in
        // Chrome). With CEF 154 each new page view or frame lost the focus: keys still went in, but no caret
        // was drawn. A page move while the panel does not have the keyboard does not give the page the focus.
        let other = base.replacingOccurrences(of: "127.0.0.1", with: "localhost")
        let passRect = await fieldRect(controller, "pass")
        var moves: [String: JSONValue] = [:]
        // The password field keeps its secure input across the page's moves, the frame and the address field.
        var movesSecure = true
        secureSteps = []
        func focusedWithCaret(_ name: String, in frameRect: [Double]? = nil, expect: String = "pass") async -> Bool {
            var rect = frameRect
            if rect == nil { rect = await fieldRect(controller, "pass") }
            let active = (try? await evaluate(controller, "String(document.hasFocus() && document.activeElement.id)")) ?? ""
            let caret = await caretShows(view, rect ?? [])
            movesSecure = await secure(name, true) && movesSecure
            moves[name] = .string("focused \(active), caret \(caret)")
            return active == expect && caret
        }
        func move(_ address: String, until marker: String) async {
            _ = try? await evaluate(controller, "location.href = '\(address)'; 'ok'")
            _ = await waitUntil(.seconds(10)) { (controller.tab?.currentURL ?? "").contains(marker) && !controller.isLoading }
            try? await Task.sleep(for: .milliseconds(500))
        }
        await move(base + "login?autofocus=pass&step=same", until: "step=same")
        let sameSite = await focusedWithCaret("sameSite")
        await move(other + "login?autofocus=pass&step=other", until: "step=other")
        let otherSite = await focusedWithCaret("otherSite")
        // The frame page puts the login page at the same place, so its password field is at `passRect`.
        await move(base + "login-frame?src=" + (other + "login").addingPercentEncoding(withAllowedCharacters: .alphanumerics)!,
                   until: "login-frame")
        try? await Task.sleep(for: .milliseconds(500))
        if passRect.count == 4 { click(view, at: NSPoint(x: passRect[0] + passRect[2] / 2, y: passRect[1] + passRect[3] / 2)) }
        try? await Task.sleep(for: .milliseconds(400))
        let frame = await focusedWithCaret("frameFromOtherSite", in: passRect, expect: "frame")
        controller.navigate(.back)
        _ = await waitUntil(.seconds(10)) { (controller.tab?.currentURL ?? "").contains("step=other") && !controller.isLoading }
        try? await Task.sleep(for: .milliseconds(500))
        let restored = (try? await evaluate(controller, "String(window.__restored)")) ?? ""
        let back = await focusedWithCaret("back")
        let addressField = Self.subviews(of: view.window?.contentView ?? view).compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == L10n.string("Search Google or type a URL") }
        if let addressField, view.window?.makeFirstResponder(addressField) == true,
           let editor = addressField.currentEditor() as? NSTextView {
            editor.selectAll(nil)
            editor.insertText(base + "login?autofocus=pass&step=address", replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.insertNewline(nil)
        }
        _ = await waitUntil(.seconds(10)) { (controller.tab?.currentURL ?? "").contains("step=address") && !controller.isLoading }
        try? await Task.sleep(for: .milliseconds(500))
        let pageHasKeyboard = view.hasKeyboardFocus
        let address = await focusedWithCaret("addressField") && pageHasKeyboard
        check("input: the page keeps the keyboard across its moves and takes it from the address field",
              sameSite && otherSite && frame && back && address,
              moves.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.readableText ?? "")" }.joined(separator: "; "))
        // A page without a field after the password field's page.
        await move(base + "second", until: "second")
        movesSecure = await secure("page without a field", false) && movesSecure
        check("input: the password field's secure input follows the page's moves, its frame and the address field",
              movesSecure, secureSteps.joined(separator: ", ") + "; back from the back-forward cache \(restored)")

        view.window?.makeFirstResponder(nil)
        await move(base + "login?autofocus=pass&step=unfocused", until: "step=unfocused")
        let unfocused = (try? await evaluate(controller, "String(document.hasFocus())")) ?? ""
        secureSteps = []
        let unfocusedSecure = await secure("password field without the panel's keyboard", false)
        results["pageMoves"] = .object(moves.merging(["withoutKeyboard": .string("hasFocus \(unfocused)")]) { $1 })
        check("input: a page move does not give the page a keyboard the panel lacks", unfocused == "false" && unfocusedSecure,
              "document.hasFocus() \(unfocused); \(secureSteps.joined())")

        // Another browser tab in the same view while its page has the keyboard: before, the tab shown next
        // never got the focus, and a click on its page did not give it.
        let firstKey = controller.key
        let first = controller.tab
        controller.onNewTab?()
        _ = await waitUntil(.seconds(5)) { controller.key != firstKey && controller.tab != nil && controller.isEditingAddress }
        controller.isEditingAddress = false
        controller.addressInput = base + "login"
        controller.submitAddress()
        _ = await waitUntil(.seconds(10)) { controller.title == "Login" && !controller.isLoading }
        let secondTab = await field("user", "second-tab-field")
        let secondKey = controller.key
        // Each tab keeps its own focused field: the password field in one, the text field in the other.
        secureSteps = []
        var tabsSecure = await secure("second tab's text field", false)
        await clickField("#pass")
        tabsSecure = await secure("second tab's password field", true) && tabsSecure
        controller.onShowTab?(firstKey)
        _ = await waitUntil(.seconds(5)) { controller.tab === first && controller.title == "Login" }
        try? await Task.sleep(for: .milliseconds(400))
        let shownAgain = await field("pass", "tab-shown-again-field")
        tabsSecure = await secure("first tab's password field", true) && tabsSecure
        await clickField("#user")
        tabsSecure = await secure("first tab's text field", false) && tabsSecure
        controller.onShowTab?(secondKey)
        _ = await waitUntil(.seconds(5)) { controller.key == secondKey && controller.tab != nil }
        tabsSecure = await secure("second tab again", true) && tabsSecure
        controller.onShowTab?(firstKey)
        _ = await waitUntil(.seconds(5)) { controller.tab === first }
        tabsSecure = await secure("first tab again", false) && tabsSecure
        check("input: a tab shown after another in the same view gets the keyboard", secondTab && shownAgain,
              "\(results["second-tab-field"]?.readableText ?? "") \(results["tab-shown-again-field"]?.readableText ?? "")")
        check("input: secure input follows the tab the view shows", tabsSecure, secureSteps.joined(separator: ", "))

        // The page keeps its size while it loads (before, a loading row above it resized it each time).
        let heightBefore = view.bounds.height
        controller.addressInput = base + "slow?ms=1500"
        controller.submitAddress()
        _ = await waitUntil(.seconds(3)) { controller.isLoading }
        try? await Task.sleep(for: .milliseconds(500))
        let heightLoading = view.bounds.height
        _ = await waitUntil(.seconds(10)) { !controller.isLoading }
        results["pageHeight"] = .object(["before": .number(Double(heightBefore)), "loading": .number(Double(heightLoading))])
        check("input: the page keeps its size while it loads", heightLoading == heightBefore,
              "\(heightBefore) pt → \(heightLoading) pt while loading")

        // A renderer that ends: the panel says so and host.log has one line with how it ended. It ends in the
        // password field, whose secure input goes with it.
        await move(base + "login?autofocus=pass&step=crash", until: "step=crash")
        view.window?.makeFirstResponder(view)
        secureSteps = []
        var crashSecure = await secure("password field before the renderer ends", true)
        let crashedTab = controller.tab
        _ = try? await crashedTab?.devTools.send("Page.crash", [:], timeout: .seconds(2))
        // Blink ends the renderer on a CHECK, which leaves a crash report; run-check.sh allows this many.
        record["intentionalRendererCrashes"] = .integer(1)
        let crashed = await waitUntil(.seconds(10)) { controller.crash != nil }
        try? await Task.sleep(for: .milliseconds(500))
        let log = (try? String(contentsOf: MacBrowserHost.shared.paths.log, encoding: .utf8)) ?? ""
        let line = log.split(separator: "\n").last { $0.hasPrefix("renderer ended tab=\(crashedTab?.id ?? -1) ") }
        capturePanel(view, named: "renderer-ended.png")
        let shown = controller.crash?.errorCode ?? ""
        results["rendererEnded"] = .object(["panel": .string(shown), "log": .string(line.map(String.init) ?? "")])
        check("input: a renderer that ends is shown and logged with how", crashed && line != nil,
              "panel \(shown.isEmpty ? "-" : shown); log \(line ?? "-")")
        crashSecure = await secure("renderer ended", false) && crashSecure
        controller.navigate(.reload)
        _ = await waitUntil(.seconds(10)) { !controller.isLoading && controller.title == "Login" }
        crashSecure = await secure("reloaded page's password field", true) && crashSecure
        // The host ends in the password field.
        MacBrowserHost.shared.process?.kill()
        // A killed host leaves its code-sign clone behind; run-check.sh allows this many.
        record["intentionalHostKills"] = .integer(1)
        _ = await waitUntil(.seconds(10)) { controller.errorMessage != nil && !controller.hasTab }
        crashSecure = await secure("host ended", false) && crashSecure
        controller.retry()
        _ = await waitUntil(.seconds(20)) { controller.hasTab && controller.title == "Login" && !controller.isLoading }
        crashSecure = await secure("page opened again in a new host", true) && crashSecure

        await closePanel()
        crashSecure = await secure("panel closed", false) && crashSecure
        check("input: secure input ends with the renderer, the host and the panel, each turn on with one turn off",
              crashSecure && recorder?.secureEventInputCount == 0
                  && recorder?.calls.filter({ $0 == "secure on" }).count == recorder?.calls.filter({ $0 == "secure off" }).count,
              secureSteps.joined(separator: ", ") + "; \(recorder?.calls.filter { $0 == "secure on" }.count ?? -1) turns on")
        results["secureInput"] = .object(["calls": .array((recorder?.calls ?? []).map(JSONValue.string))])
        try? write(.object(results), to: "input.json")
        client.closeTabs(forSession: session)
    }

    /// Whether the caret blinks in an empty field at `rect` (page points, from `fieldRect`) within 1.5
    /// seconds: a dark column in the field's left padding of the frames on screen.
    private func caretShows(_ view: BrowserHostView, _ rect: [Double]) async -> Bool {
        guard rect.count == 4 else { return false }
        let scale = view.window?.backingScaleFactor ?? 2
        for _ in 0..<19 {
            if let surface = view.frameDisplay.currentSurface, Self.darkColumn(in: surface, x: (rect[0] + 4) * scale,
                                                                           width: 20 * scale, y: (rect[1] + 6) * scale,
                                                                           height: (rect[3] - 12) * scale) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return false
    }

    /// The field `id`'s x, y, width and height in page points, or nothing.
    private func fieldRect(_ controller: BrowserHostPaneController, _ id: String) async -> [Double] {
        (try? await evaluate(controller, """
            (() => { const r = document.querySelector('#\(id)').getBoundingClientRect(); return [r.x, r.y, r.width, r.height].join(',') })()
            """))?.split(separator: ",").compactMap { Double($0) } ?? []
    }

    /// A column at least half the region's height of dark pixels (the caret) in a white region.
    nonisolated private static func darkColumn(in surface: IOSurfaceRef, x: Double, width: Double, y: Double, height: Double) -> Bool {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        let surfaceWidth = IOSurfaceGetWidth(surface), surfaceHeight = IOSurfaceGetHeight(surface)
        let left = max(0, Int(x)), right = min(surfaceWidth, Int(x + width))
        let top = max(0, Int(y)), bottom = min(surfaceHeight, Int(y + height))
        guard right > left, bottom > top else { return false }
        for column in left..<right {
            var dark = 0
            for row in top..<bottom {
                let pixel = base + row * rowBytes + column * 4
                if (Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 3 < 110 { dark += 1 }
            }
            if dark * 2 >= bottom - top { return true }
        }
        return false
    }

    // MARK: Page load errors

    /// What the panel says of a page's load errors: "Unavailable" and the error card belong to the tab on
    /// screen and to the navigation that failed, and go once a page commits. Each step records the host's
    /// events for the tab (`loading`, `address`, `loadError`, `loadEnd`, `failed`) with what the panel
    /// showed after it, in `load-errors.json`.
    private func exerciseLoadErrors() async {
        guard let controller = await openPanel(label: "load-errors", address: base) else { return }
        _ = await waitUntil(.seconds(10)) { controller.title == "Browser QA" && !controller.isLoading }
        var events: [String] = []
        controller.eventObserver = { event in
            switch event {
            case .loading(_, let isLoading, _, _): events.append("loading \(isLoading)")
            case .address(_, let url): events.append("address \(url)")
            case .loadError(_, let url, let code, _): events.append("loadError \(code) \(url)")
            case .loadEnd(_, let url, let status): events.append("loadEnd \(status) \(url)")
            case .failed(let message, _, _): events.append("failed \(message)")
            case .navigationBlocked(_, let url): events.append("blocked \(url)")
            default: break
            }
        }
        var steps: [JSONValue] = []
        func shown() -> String {
            controller.errorMessage.map { "error: " + $0.replacingOccurrences(of: "\n", with: " ") } ?? "no error"
        }
        func step(_ name: String, expectError: Bool, _ detail: String = "") {
            let ok = (controller.errorMessage != nil) == expectError
            steps.append(.object([
                "step": .string(name), "ok": .bool(ok), "shown": .string(shown()),
                "notice": .string(controller.notice ?? ""), "events": .array(events.map { .string($0) }),
                "detail": .string(detail)
            ]))
            check("load errors: \(name)", ok, "\(shown()); events \(events.joined(separator: " | "))")
            events = []
        }
        func go(_ address: String) {
            controller.addressInput = address
            controller.submitAddress()
        }
        func settle(_ seconds: Double = 2.5) async {
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            _ = await waitUntil(.seconds(10)) { !controller.isLoading }
            try? await Task.sleep(for: .milliseconds(300))
        }
        let refused = "http://127.0.0.1:9/"

        // A page that does not answer, then one that does (a dev server down, then back).
        go(refused)
        await settle()
        step("refused shows the error", expectError: true)
        go(base + "second")
        await settle()
        step("a page loading after the failure clears it", expectError: false)

        // Moves in quick succession, and a slow redirect.
        go(base + "slow?ms=1500")
        try? await Task.sleep(for: .milliseconds(150))
        go(base + "second")
        await settle(3)
        step("a slow move replaced by another", expectError: false)
        go(base + "slow-redirect")
        await settle(3)
        step("a slow redirect", expectError: false)

        // The agent's browser_navigate: a page, one that fails, one that works.
        let agentTools = BrowserAgentTools(usesMacEditingCommands: true, tabs: BrowserAgentTabs { MacBrowserHost.shared.client })
        _ = await agentTools.run(tool: AgentToolCatalog.navigate, arguments: .object(["url": .string(base + "spa")]), sessionID: session)
        await settle(1)
        step("the agent's move", expectError: false)
        _ = await agentTools.run(tool: AgentToolCatalog.navigate, arguments: .object(["url": .string(refused)]), sessionID: session)
        await settle()
        step("the agent's move that fails", expectError: true)
        _ = await agentTools.run(tool: AgentToolCatalog.navigate, arguments: .object(["url": .string(base + "spa")]), sessionID: session)
        await settle(1)
        step("the agent's next move clears it", expectError: false)

        // A page moving with history.pushState, a link to a 204 and to another scheme: the page stays.
        _ = try? await evaluate(controller, "document.querySelector('#push').click(); location.pathname", userGesture: true)
        await settle(1)
        step("pushState", expectError: false)
        _ = try? await evaluate(controller, "document.querySelector('#no-content').click(); 'ok'", userGesture: true)
        await settle(1.5)
        step("a link answered with 204 keeps the page", expectError: false)
        _ = try? await evaluate(controller, "document.querySelector('#scheme').click(); 'ok'", userGesture: true)
        await settle(1.5)
        step("a link to another scheme keeps the page", expectError: false)

        // Another tab failing behind the shown one says nothing on the shown one.
        if let behind = try? client.newTab(forSession: session, url: refused, viewport: .offscreenDefault, select: false) {
            await settle()
            step("a tab behind fails", expectError: false, "tab \(behind.id)")
            behind.close()
        }

        // DevTools for a tab the host no longer has (the agent's call racing its tab's close): the host
        // refuses it; the shown page is not unavailable for it.
        client.send(.devTools(tab: 9_999, message: #"{"id":424242,"method":"Runtime.evaluate","params":{"expression":"1"}}"#))
        try? await Task.sleep(for: .milliseconds(800))
        step("a DevTools message refused for another tab", expectError: false)

        controller.eventObserver = nil
        try? write(.array(steps), to: "load-errors.json")
        await closePanel()
        client.closeTabs(forSession: session)
        let grace = Double(client.idleGrace.components.seconds)
        _ = await waitUntil(.seconds(Int(grace) + 20)) { !self.client.isHostRunning }
    }

    // MARK: The session rail's preview

    /// The rail's Preview card draws the tab the agent drives from the frames the host already sends,
    /// on the event pipe's queue as the panel does: the agent's use names the tab for the card
    /// (`BrowserAgentUse`), frames reach the preview off the main thread while the agent works, the
    /// preview never keeps the tab painting (it hides once the agent is idle, and the router lets go
    /// of its frame), and the card's tab goes when the turn ends or the tab closes.
    private func exerciseRailPreview() async {
        let session = UUID()
        guard let tab = try? client.openTab(forSession: session, url: base + "animation", viewport: .offscreenDefault) else {
            return check("rail preview", false, "could not open")
        }
        client.noteAgentActivity(forSession: session)
        check("the agent's use names the tab for the rail's preview", BrowserAgentUse.shared.tabs[session] == tab.id,
              "tab \(tab.id), named \(String(describing: BrowserAgentUse.shared.tabs[session]))")

        // The card's own view, in a window that is never shown (the rail's column size).
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 256, height: 156), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = BrowserFramePreviewView(frame: NSRect(x: 0, y: 0, width: 256, height: 156))
        window.contentView = view
        view.tab = tab.id
        let shown = await waitUntil(.seconds(10)) { view.hasFrame }
        check("the preview shows the tab's frame", shown, "frame \(view.hasFrame)")

        // A second display on the same route counts the frames and the thread that placed them.
        let counter = PreviewFrameCounter()
        let layer = CALayer()
        let display = BrowserFrameDisplay(layer: layer, sizesLayer: false)
        display.setObserver { _, latency in counter.add(latency: latency, onMain: Thread.isMainThread) }
        MacBrowserHost.shared.showPreviewFrames(of: tab.id, in: display)
        for _ in 0..<3 {
            client.noteAgentActivity(forSession: session)
            try? await Task.sleep(for: .milliseconds(400))
        }
        counter.reset()
        try? await Task.sleep(for: .seconds(1))
        let used = counter.snapshot()
        check("frames reach the preview off the main thread while the agent works",
              used.frames > 20 && used.onMain == 0,
              "\(used.frames) frames in 1 s, \(used.onMain) placed on the main thread, median latency \(Int(used.medianLatency)) ms")

        // Idle: the tab hides as it would without the preview, and the router lets go of its frame.
        let idle = client.agentVisibleWindow + .seconds(2)
        try? await Task.sleep(for: idle)
        counter.reset()
        try? await Task.sleep(for: .seconds(2))
        let quiet = counter.snapshot()
        let visibility = (try? await tab.devTools.send("Runtime.evaluate", ["expression": .string("document.visibilityState"),
                                                                             "returnByValue": .bool(true)], timeout: .seconds(10)))?["result"]?["value"]?.stringValue ?? "?"
        let released = MacBrowserHost.shared.process?.frameRouter.latestFrame(of: tab.id) == nil
        check("the preview does not keep an idle agent tab painting",
              quiet.frames <= 2 && visibility == "hidden" && released && view.hasFrame,
              "\(quiet.frames) frames in 2 s idle, page \(visibility), router frame released \(released), "
                + "card keeps the last frame \(view.hasFrame)")

        BrowserAgentUse.shared.endTurn(session: session)
        let endedTurn = BrowserAgentUse.shared.tabs[session] == nil
        client.noteAgentActivity(forSession: session)
        MacBrowserHost.shared.stopShowingPreviewFrames(of: tab.id, in: display)
        view.tab = nil
        window.contentView = nil
        window.close()
        tab.close()
        check("the card's tab goes with the turn and with the tab", endedTurn && BrowserAgentUse.shared.tabs[session] == nil,
              "after the turn \(endedTurn), after closing \(BrowserAgentUse.shared.tabs[session] == nil)")
        record["railPreview"] = .object([
            "framesPerSecondWhileUsed": .integer(Int64(used.frames)),
            "framesPlacedOnMainThread": .integer(Int64(used.onMain)),
            "medianLatencyMs": .number(used.medianLatency),
            "framesIn2sIdle": .integer(Int64(quiet.frames)),
            "idleVisibility": .string(visibility)
        ])
    }

    private var qaWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }
    }

    // MARK: The agent's tab, then the panel

    /// The person's panel is closed while the agent opens the task's tab (a cold host) and works in
    /// it; the tab hides once the agent is idle. Meanwhile other frame surfaces come and go (another
    /// tab resized many times, then closed), so the kernel hands out IOSurface IDs again. Opening the
    /// panel then must show the agent's page at the panel's size right away, not a blank panel.
    /// The agent's CDP answers share the event pipe with the frames. Another tab's rings are made
    /// and dropped thirty times and the tab closes, so the kernel hands its IOSurface IDs out again;
    /// then an animating tab (painting every frame) gets new rings while the agent sends forty CDP
    /// round trips. A frame whose surface never arrives must not hold up the pipe: on 2026-10-22 the
    /// installed app's agent saw its browser tools time out for a minute or two.
    private func exerciseCDPWhileSurfacesAreReused() async {
        let size = BrowserViewport(width: 640, height: 400, scale: 2)
        guard let agent = try? client.openTab(url: base + "animation", viewport: size) else {
            return check("the agent's CDP answers while frame surfaces are reused", false, "could not open")
        }
        try? await Task.sleep(for: .seconds(2))
        if let other = try? client.openTab(url: base + "second", viewport: BrowserViewport(width: 300, height: 200, scale: 2)) {
            for index in 0..<30 {
                other.send(.resize(tab: other.id, viewport: BrowserViewport(
                    width: 300 + Double(index % 7) * 20, height: 200 + Double(index) * 6, scale: 2
                )))
                try? await Task.sleep(for: .milliseconds(60))
            }
            other.close()
        }
        try? await Task.sleep(for: .milliseconds(300))
        var latencies: [Double] = []
        var failures = 0
        for index in 0..<40 {
            if index % 8 == 0 {
                agent.send(.resize(tab: agent.id, viewport: BrowserViewport(
                    width: size.width + Double(index) * 4, height: size.height + Double(index) * 3, scale: 2
                )))
            }
            let started = DispatchTime.now().uptimeNanoseconds
            let answered = (try? await agent.devTools.send("Runtime.evaluate", [
                "expression": .string("1"), "returnByValue": .bool(true)
            ], timeout: .seconds(5))) != nil
            latencies.append(Self.milliseconds(since: started))
            if !answered { failures += 1 }
            try? await Task.sleep(for: .milliseconds(50))
        }
        agent.close()
        let sorted = latencies.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let slowest = sorted.last ?? 0
        record["cdpWhileSurfacesAreReused"] = .object([
            "medianMs": .number(median), "p95Ms": .number(p95), "maxMs": .number(slowest), "failures": .integer(Int64(failures))
        ])
        check("the agent's CDP answers while frame surfaces are reused", failures == 0 && slowest < 1000,
              "median \(Int(median)) ms, p95 \(Int(p95)) ms, slowest \(Int(slowest)) ms, \(failures) of 40 timed out after 5 s")
    }

    /// The agent's full-page screenshot of a page longer than its tab (/tall in a tab of the agent's size): every
    /// band once and in order at the page's whole size, and afterwards the tab at its size and the page laid out
    /// as before. CEF's windowless view had repeated the first screen down the image.
    private func exerciseFullPageScreenshot() async {
        let agentTools = BrowserAgentTools(usesMacEditingCommands: true, tabs: BrowserAgentTabs { MacBrowserHost.shared.client })
        func text(_ result: AgentToolResult) -> String {
            result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: " ")
        }
        let opened = text(await agentTools.run(tool: AgentToolCatalog.tabNew, arguments: .object([:]), sessionID: session))
        let tabID = opened.range(of: #""tabId":"(\d+)""#, options: .regularExpression).map { String(opened[$0]).filter(\.isNumber) } ?? ""
        func evaluate(_ function: String) async -> String {
            text(await agentTools.run(tool: AgentToolCatalog.evaluate, arguments: .object([
                "function": .string(function), "tabId": .string(tabID)]), sessionID: session))
        }
        _ = await agentTools.run(tool: AgentToolCatalog.navigate, arguments: .object([
            "url": .string(base + "tall"), "tabId": .string(tabID)]), sessionID: session)
        let tab = client.tabs(forSession: session).first { String($0.id) == tabID }
        let viewportBefore = tab?.viewport
        func numbers(_ text: String) -> [Int] {
            ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        }
        // Each band's middle in page pixels and its color, as the page lays them out.
        let bandsText = await evaluate("""
            () => [...document.body.children].map(e => {
              const r = e.getBoundingClientRect()
              return [Math.round(r.top + scrollY + r.height / 2), ...getComputedStyle(e).backgroundColor.match(/\\d+/g).map(Number)] })
            """)
        let bands = ((try? JSONSerialization.jsonObject(with: Data(bandsText.utf8))) as? [[NSNumber]] ?? []).map { $0.map(\.intValue) }
        let layoutBefore = numbers(await evaluate("() => [innerHeight, document.documentElement.scrollHeight, window.qa.resizes]"))
        let shot = await agentTools.run(tool: AgentToolCatalog.screenshot, arguments: .object([
            "fullPage": .bool(true), "tabId": .string(tabID)]), sessionID: session)
        let layoutAfter = numbers(await evaluate("() => [innerHeight, document.documentElement.scrollHeight, window.qa.resizes]"))
        let viewportAfter = tab?.viewport
        var image: NSBitmapImageRep?
        for case .image(let base64, _) in shot.content {
            if let data = Data(base64Encoded: base64) {
                image = NSBitmapImageRep(data: data)
                try? data.write(to: output.appending(path: "fullpage-screenshot.png"))
            }
        }
        // Bands whose middle in the image has the band's color.
        let matched = bands.filter { $0.count == 4 }.map { band -> String in
            guard let image, band[0] < image.pixelsHigh else { return "\(band[0]): outside" }
            var pixel = [Int](repeating: 0, count: 4)
            image.getPixel(&pixel, atX: 40, y: band[0])
            let close = zip(pixel.prefix(3), band.dropFirst()).allSatisfy { abs($0 - $1) <= 24 }
            return close ? "\(band[0]) ok" : "\(band[0]): \(Array(pixel.prefix(3))) not \(Array(band.dropFirst()))"
        }
        let size = image.map { "\($0.pixelsWide)×\($0.pixelsHigh)" } ?? "no image"
        record["fullPageScreenshot"] = .object([
            "result": .string(text(shot)), "image": .string(size), "bands": .string(matched.joined(separator: ", ")),
            "layoutBefore": .string("\(layoutBefore)"), "layoutAfter": .string("\(layoutAfter)")
        ])
        let everyBand = matched.count == 8 && matched.allSatisfy { $0.hasSuffix(" ok") }
        check("full-page screenshot: every band of a page longer than the tab, once and in order",
              everyBand && layoutBefore.count == 3 && size == "\(Int(viewportBefore?.width ?? 0))×\(layoutBefore[1])",
              "\(size); \(matched.joined(separator: ", "))")
        // innerHeight and the page's height; Chromium's capture itself fires one resize event.
        check("full-page screenshot: the tab and the page's layout are as before",
              viewportAfter == viewportBefore && layoutAfter.prefix(2) == layoutBefore.prefix(2),
              "viewport \(viewportBefore.map { "\($0.width)×\($0.height)" } ?? "-") → \(viewportAfter.map { "\($0.width)×\($0.height)" } ?? "-"); "
                + "innerHeight, height, resizes \(layoutBefore) → \(layoutAfter)")
        _ = await agentTools.run(tool: AgentToolCatalog.tabClose, arguments: .object(["tabId": .string(tabID)]), sessionID: session)
    }

    private func exerciseAgentTabThenPanel() async {
        let url = base + "a11y"
        // As the agent's browser tools do (BrowserAgentTabs): a blank tab, then Page.navigate.
        guard let tab = try? client.openTab(forSession: session, url: "about:blank", viewport: .offscreenDefault) else {
            return check("agent-opened tab shows in the panel", false, "could not open")
        }
        client.noteAgentActivity(forSession: session)
        func evaluate(_ expression: String) async -> String {
            let result = try? await tab.devTools.send("Runtime.evaluate", ["expression": .string(expression), "returnByValue": .bool(true)],
                                                    timeout: .seconds(20))
            return result?["result"]?["value"]?.stringValue ?? ""
        }
        _ = try? await tab.devTools.send("Page.navigate", ["url": .string(url)], timeout: .seconds(20))
        let loaded = await waitUntilAsync(.seconds(20)) { await evaluate("location.href + ' ' + document.readyState") == url + " complete" }
        var agentFrames = 0
        let agentCounter = tab.addEventObserver { if case .frame = $0 { agentFrames += 1 } }
        defer { tab.removeEventObserver(agentCounter) }

        // Churn: another tab's rings are made and dropped thirty times, then the tab closes.
        var churnFrames = 0
        var resizesWithFrame = 0
        if let other = try? client.openTab(url: base + "second", viewport: BrowserViewport(width: 300, height: 200, scale: 2)) {
            var frames = 0
            var sizes: [String] = []
            let counter = other.addEventObserver {
                if case .frame(_, let frame) = $0, frame.layer == .view {
                    frames += 1
                    // A frame whose surface never came (the host thought it sent it) is not shown.
                    if MacBrowserHost.shared.surface(for: frame.surface) != nil { sizes.append("\(frame.pixelWidth)x\(frame.pixelHeight)") }
                }
            }
            for index in 0..<30 {
                let size = BrowserViewport(width: 300 + Double(index % 7) * 20, height: 200 + Double(index) * 6, scale: 2)
                let expected = "\(Int(size.width * 2))x\(Int(size.height * 2))"
                other.send(.resize(tab: other.id, viewport: size))
                if await waitUntil(.milliseconds(500), poll: .milliseconds(5), { sizes.contains(expected) }) { resizesWithFrame += 1 }
            }
            churnFrames = frames
            other.removeEventObserver(counter)
            other.close()
        }

        // The agent stops; the tab hides after the agent-visible window.
        try? await Task.sleep(for: client.agentVisibleWindow + .seconds(1))
        let hiddenState = await evaluate("document.visibilityState")
        let framesBeforePanel = agentFrames

        guard let controller = await openPanel(label: "agent-tab", address: nil), let view = controller.view else {
            return check("agent-opened tab shows in the panel", false, "no panel")
        }
        let scale = view.window?.backingScaleFactor ?? 2
        func expectedSize() -> (Int, Int) { (Int(view.viewport.width * scale), Int(view.viewport.height * scale)) }
        let fitted = await waitUntil(.seconds(5), poll: .milliseconds(10)) {
            guard let surface = view.viewSurface else { return false }
            return (IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface)) == expectedSize()
        }
        let title = (try? await self.evaluate(controller, "document.title")) ?? ""
        let shown = view.viewSurface.map { "\(IOSurfaceGetWidth($0))x\(IOSurfaceGetHeight($0))" } ?? "none"
        let windowVisible = view.window?.occlusionState.contains(.visible) ?? false
        var firstFrame = "never"
        if case .number(let milliseconds)? = record["open-agent-tab"]?["openToFirstFrameMs"] { firstFrame = "\(Int(milliseconds)) ms" }
        check("every resize of another tab shows a frame at its size", resizesWithFrame == 30,
              "\(resizesWithFrame) of 30 resizes within 500 ms, \(churnFrames) frames")
        check("agent-opened tab shows in the panel at the panel's size",
              loaded && fitted && controller.tab === tab && controller.addressInput == url && title == "Accessibility QA",
              "window visible \(windowVisible); page \(hiddenState) before the panel, \(framesBeforePanel) frames while panel-less (\(churnFrames) churn frames); "
                + "first frame \(firstFrame), surface \(shown) for view \(expectedSize().0)x\(expectedSize().1), "
                + "address \(controller.addressInput), title \"\(title)\"")
        await closePanel()
    }

    // MARK: Tooltips

    /// A header button names itself when the pointer rests on it, as in Chrome and the Codex app. SwiftUI answers
    /// AppKit's tooltips for its views through one tracking-area owner on the window's hosting view
    /// (`TooltipBridge.DynamicTooltipManager`, `dynamicToolTipStringAtPoint:trackingRect:`), which this check asks at
    /// the middle of each button of the panel's header and toolbar: beside the conversation (the header in the title
    /// bar's row), expanded, and for Review. The window's hit test there must reach the button, not the title bar or
    /// the page. Then AppKit's own path to the shown name runs with the pointer resting at each button's middle
    /// (`TooltipDisplayProbe`), in the panel and elsewhere in the window (the title bar's sidebar button). A name that
    /// was found but never shown (2026-10-27) came from the window, not the button: a scroll AppKit never saw end
    /// holds every name in it back, and the first move of the pointer once the hold has outlasted any scroll gives
    /// them back (`WindowTooltipRelease`). Last, the delay: the Codex app's 200 ms (`NSInitialToolTipDelay`). First, a
    /// page element's `title`: Chromium's tooltip reaches the panel's view (`BrowserHostView.toolTip`), which AppKit
    /// shows the same way.
    private func exerciseTooltips(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async {
        guard let window = view.window, let frameView = window.contentView?.superview else { return }
        var windowFrame = window.frame
        windowFrame.size = NSSize(width: 1400, height: 900)
        window.setFrame(windowFrame, display: true)
        try? await Task.sleep(for: .seconds(1))
        // The page's own: an element's `title` names it over the page, as in Chrome. The pointer comes onto the
        // element's first line (`#tip` wraps at the panel's width) and rests there.
        var pageTooltips: [String] = []
        let pageObserver = controller.eventObserver
        controller.eventObserver = { event in
            if case .tooltip(_, let text) = event { pageTooltips.append(text ?? "(none)") }
            pageObserver?(event)
        }
        if let tip = try? await center(controller, "#tip") {
            move(view, to: NSPoint(x: tip.x - 40, y: tip.y))
            try? await Task.sleep(for: .milliseconds(100))
            move(view, to: tip)
        }
        _ = await waitUntil(.seconds(4)) { view.toolTip != nil }
        let lines = (try? await evaluate(controller, "String(document.querySelector('#tip').getClientRects().length)")) ?? "?"
        check("tooltips: an element's title names it over the page", view.toolTip == "Tooltip text",
              "host tooltip events \(pageTooltips), panel shows \(view.toolTip ?? "none"), the element on \(lines) lines")
        controller.eventObserver = pageObserver

        typealias Lookup = @convention(c) (AnyObject, Selector, NSPoint, UnsafeMutablePointer<NSRect>) -> Unmanaged<NSString>?
        let lookupSelector = NSSelectorFromString("dynamicToolTipStringAtPoint:trackingRect:")
        func allViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }
        // Each name SwiftUI gives along the rows above the page, with what the window hit-tests at the middle of the
        // area it holds; `places` keeps that middle and the name's tooltip owner.
        var places: [String: (point: NSPoint, owner: NSObject)] = [:]
        func names(above page: NSRect, from minX: CGFloat, to maxX: CGFloat, step: CGFloat = 2) -> [String: String] {
            // Where hosting views nest, the innermost answers for its own views.
            let owners = allViews(frameView).flatMap { candidate in
                candidate.trackingAreas.compactMap { area in
                    (area.owner as? NSObject).flatMap { manager in
                        manager.responds(to: lookupSelector)
                            ? (view: candidate, manager: manager, frame: candidate.convert(candidate.bounds, to: nil),
                               size: allViews(candidate).count)
                            : nil
                    }
                }
            }
            places = [:]
            var found: [String: String] = [:]
            for row in stride(from: page.maxY + 1, through: frameView.bounds.height - 1, by: step) {
                for column in stride(from: minX, through: maxX, by: step) {
                    let point = NSPoint(x: column, y: row)
                    guard let owner = owners.filter({ $0.frame.contains(point) }).min(by: { $0.size < $1.size }) else { continue }
                    var rect = NSRect.zero
                    let lookup = unsafeBitCast(owner.manager.method(for: lookupSelector), to: Lookup.self)
                    guard let name = lookup(owner.manager, lookupSelector, owner.view.convert(point, from: nil), &rect)?
                        .takeUnretainedValue() as String?, found[name] == nil, !rect.isEmpty else { continue }
                    let middle = owner.view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                    let hit = frameView.hitTest(middle)
                    let reaches = hit.map { $0 === owner.view || $0.isDescendant(of: owner.view) } ?? false
                    found[name] = reaches ? "" : "hit \(hit.map { String(describing: type(of: $0)) } ?? "nil")"
                    places[name] = (middle, owner.manager)
                }
            }
            return found
        }
        func expect(_ layout: String, _ wanted: [String], in found: [String: String]) {
            let missing = wanted.filter { found[$0] == nil }
            let blocked = wanted.compactMap { name in found[name].flatMap { $0.isEmpty ? nil : "\(name) \($0)" } }
            check("tooltips (\(layout)): every header button names itself where the pointer rests",
                  missing.isEmpty && blocked.isEmpty,
                  "missing \(missing), hit elsewhere \(blocked); found \(found.keys.sorted())")
        }
        // AppKit's path to each shown name, with the pointer resting at the name's middle: the names that never showed.
        var probeLog = ""
        func display(_ layout: String, _ wanted: [String], wait: Duration = .seconds(4)) async -> [String] {
            var missing: [String] = []
            for name in wanted {
                guard let place = places[name] else {
                    missing.append(name)
                    continue
                }
                let rest = await TooltipDisplayProbe.rest(at: place.point, in: window, owner: place.owner, wait: wait)
                if !rest.shown { missing.append(name) }
                probeLog += "== \(layout): \(name) at \(place.point) shown \(rest.shown)\n"
                var last = ""
                for step in rest.steps where step.name != last || !step.stack.isEmpty {
                    probeLog += String(format: "%6.3f  ", step.time) + step.name + "\n"
                    for frame in step.stack { probeLog += "          " + frame + "\n" }
                    last = step.name
                }
            }
            try? probeLog.write(to: output.appending(path: "tooltip-probe.txt"), atomically: true, encoding: .utf8)
            return missing
        }
        func shows(_ layout: String, _ wanted: [String]) async {
            let missing = await display(layout, wanted)
            check("tooltips (\(layout)): AppKit shows each name once the pointer rests", missing.isEmpty,
                  "not shown \(missing) (tooltip-probe.txt)")
        }
        let toolbar = ["Back", "Forward", "Reload", "Open", "Select an element to attach to your message"].map(L10n.string)
        let header = ["Close tab", "Open externally", "Close panel"].map(L10n.string)
        var page = view.convert(view.bounds, to: nil)
        expect("beside the conversation", toolbar + header + [L10n.string("Expand panel")],
               in: names(above: page, from: page.minX, to: page.maxX))
        await shows("beside the conversation", toolbar + header + [L10n.string("Expand panel")])

        // A scroll AppKit never saw end (an animated scroll the person's own scrolling interrupted, or one whose view
        // left the window) holds the window's names back, as it does while a scroll runs: none shows, however long
        // the pointer rests. The pointer moving over the window once the hold has outlasted any scroll ends it.
        let closePanel = L10n.string("Close panel")
        _ = window.perform(NSSelectorFromString("_disableToolTipCreationAndDisplay"))
        let whileHeld = await display("held by a scroll that never ended", [closePanel], wait: .seconds(2))
        let moved = ContinuousClock.now
        if let event = NSEvent.mouseEvent(with: .mouseMoved, location: places[closePanel]?.point ?? .zero, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            NSApp.postEvent(event, atStart: false)
        }
        let released = await waitUntil(.seconds(4)) { WindowTooltipRelease.namesShow(in: window) }
        let releasedAfter = moved.duration(to: .now)
        if !released { _ = window.perform(NSSelectorFromString("_enableToolTipCreationAndDisplay")) }
        let afterRelease = await display("after the hold ended", [closePanel])
        check("tooltips: a scroll that never ended holds no name back for good", !whileHeld.isEmpty && released && afterRelease.isEmpty,
              "while held \(whileHeld.isEmpty ? "shown" : "not shown"); given back \(released ? "\(releasedAfter) after the pointer moved" : "never"); "
                + "then \(afterRelease.isEmpty ? "shown" : "not shown")")

        // Names elsewhere in the window: the title bar's sidebar button and what the sidebar and conversation show.
        let elsewhere = names(above: NSRect(x: 0, y: -1, width: 0, height: 0), from: 0, to: page.minX - 8, step: 4)
        let sidebar = L10n.string("Hide sidebar")
        await shows("outside the panel", [sidebar] + elsewhere.keys.filter { $0 != sidebar }.sorted().prefix(4))
        controller.workspace.layout.isExpanded = true
        try? await Task.sleep(for: .seconds(1))
        page = view.convert(view.bounds, to: nil)
        expect("expanded", toolbar + header + [L10n.string("Browser settings")],
               in: names(above: page, from: page.minX, to: page.maxX))
        await shows("expanded", toolbar + header + [L10n.string("Browser settings")])
        controller.workspace.layout.isExpanded = false
        try? await Task.sleep(for: .seconds(1))
        page = view.convert(view.bounds, to: nil)
        controller.workspace.setPanels(TaskSurfaceNavigationProjection.showing("diff", in: controller.workspace.panels))
        try? await Task.sleep(for: .seconds(2))
        // Review's own header sits at the top of the panel, where the page was.
        let panel = NSRect(x: page.minX, y: page.maxY - 60, width: page.width, height: 0)
        expect("Review", [L10n.string("Close tab"), L10n.string("Close panel")],
               in: names(above: panel, from: panel.minX, to: panel.maxX))

        // How long AppKit waits before it shows a name (`NSToolTipManager`'s own reading of its delay).
        typealias Delay = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Double>, UnsafeMutablePointer<ObjCBool>, NSView?) -> Void
        let delaySelector = NSSelectorFromString("_getDisplayDelay:inQuickMode:forView:")
        var delay = -1.0
        var quick = ObjCBool(false)
        if let manager = (NSClassFromString("NSToolTipManager") as AnyObject)
            .perform(NSSelectorFromString("sharedToolTipManager"))?.takeUnretainedValue() as? NSObject,
           manager.responds(to: delaySelector) {
            unsafeBitCast(manager.method(for: delaySelector), to: Delay.self)(manager, delaySelector, &delay, &quick, view)
        }
        check("tooltips: a name shows after the Codex app's 200 ms", abs(delay - 0.2) < 0.001,
              "AppKit's delay \(delay) s, NSInitialToolTipDelay \(UserDefaults.standard.integer(forKey: "NSInitialToolTipDelay")) ms")
    }

    // MARK: Resizing the panel

    /// The side panel's divider dragged as a person drags it, over pages laid out for their width (`/responsive`:
    /// a red edge at the page's right, its columns by width; `?heavy=1` with 3,000 cards of text to lay out again):
    /// a new width every 16 ms, from the widest to the narrowest and two thirds of the way back. Every 4 ms the
    /// check reads the frame on screen for where the page's right edge is against the panel's width (a blank strip
    /// on the right while the page is narrower, the page cut off while it is wider); then how long after the last
    /// move the page on screen is laid out at the panel's width, and what the page says of its width and columns.
    /// `resize.json`, and the panel as it shows the page halfway through each drag and once it settles (`resize-*.png`).
    private func exerciseResize(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async {
        guard let window = view.window else { return check("resize: panel", false, "no window") }
        var windowFrame = window.frame
        windowFrame.size = NSSize(width: 1400, height: 900)
        window.setFrame(windowFrame, display: true)
        let scale = Double(window.backingScaleFactor)
        let frames = ResizeFrameLog()
        controller.frameObserver = { frame, _ in frames.add(frame) }
        // A QA app in the background has its timers coalesced; a drag moves every 16 ms.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Resize QA")
        defer {
            controller.frameObserver = nil
            ProcessInfo.processInfo.endActivity(activity)
        }
        var pages: [String: JSONValue] = [:]
        for (name, query) in [("light", ""), ("heavy", "?heavy=1")] {
            let address = base + "responsive" + query
            controller.addressInput = address
            controller.submitAddress()
            _ = await waitUntil(.seconds(20)) { controller.tab?.currentURL == address && !controller.isLoading }
            controller.workspace.layout.panelWidthRatio = 1
            _ = await waitUntil(.seconds(5), poll: .milliseconds(10)) {
                Self.pageEdge(in: view.viewSurface, scale: scale).map { abs($0 - Double(view.bounds.width)) <= 1 } ?? false
            }
            try? await Task.sleep(for: .milliseconds(500))
            let widest = Double(view.bounds.width)

            // The drag.
            var samples: [(view: Double, edge: Double?, frame: Double?)] = []
            let narrowing = 60, widening = 40
            frames.reset()
            let dragStart = DispatchTime.now().uptimeNanoseconds
            let clock = ContinuousClock(), dragBegan = clock.now
            for tick in 0...(narrowing + widening) {
                controller.workspace.layout.panelWidthRatio = tick <= narrowing
                    ? 1 - Double(tick) / Double(narrowing) : Double(tick - narrowing) / Double(narrowing)
                for sample in 1...4 {
                    try? await Task.sleep(until: dragBegan + .milliseconds(16 * tick + 4 * sample), tolerance: .zero, clock: clock)
                    let surface = view.viewSurface
                    samples.append((Double(view.bounds.width), Self.pageEdge(in: surface, scale: scale),
                                    surface.map { Double(IOSurfaceGetWidth($0)) / scale }))
                }
                if tick == narrowing / 2 || tick == narrowing + widening / 2, let surface = view.viewSurface {
                    Self.writePanelPNG(surface, panel: view.bounds.size, scale: scale,
                                       to: output.appending(path: "resize-\(name)-\(tick < narrowing ? "narrowing" : "widening").png"))
                }
            }
            let dragMs = Self.milliseconds(since: dragStart)
            let dragFrames = frames.snapshot

            // After the last move.
            let endedAt = DispatchTime.now().uptimeNanoseconds
            var settledMs: Double?
            _ = await waitUntil(.seconds(3), poll: .milliseconds(4)) {
                guard let edge = Self.pageEdge(in: view.viewSurface, scale: scale), abs(edge - Double(view.bounds.width)) <= 1 else {
                    return false
                }
                settledMs = Self.milliseconds(since: endedAt)
                return true
            }
            let final = Double(view.bounds.width)
            if let surface = view.viewSurface {
                Self.writePanelPNG(surface, panel: view.bounds.size, scale: scale, to: output.appending(path: "resize-\(name)-settled.png"))
            }
            let page = (try? await evaluate(controller, "JSON.stringify([innerWidth, window.qa.columns(), window.qa.resizes])"))
                .flatMap { try? JSONDecoder().decode([Int].self, from: Data($0.utf8)) } ?? []
            let columns = final >= 720 ? 3 : final >= 480 ? 2 : 1

            // How far the page on screen was from the panel's width while it moved.
            let gaps = samples.compactMap { sample in sample.edge.map { sample.view - $0 } }
            let distances = gaps.map(abs).sorted()
            func percentile(_ share: Double) -> Double {
                distances.isEmpty ? -1 : distances[min(distances.count - 1, Int(Double(distances.count) * share))]
            }
            let fitted = distances.filter { $0 <= 1 }.count
            // A frame whose page ends short of the frame's own edge shows a page laid out for another width.
            let misfit = samples.filter { sample in
                guard let edge = sample.edge, let frame = sample.frame else { return false }
                return abs(frame - edge) > 1
            }.count
            let pageWidth = page.first ?? -1, pageColumns = page.dropFirst().first ?? -1, resizeEvents = page.last ?? -1
            let settled: JSONValue = settledMs.map { .number($0) } ?? .null
            let blankStrip = gaps.filter { $0 > 1 }.count, cutOff = gaps.filter { $0 < -1 }.count
            let frameWidths = Set(dragFrames).count
            var result: [String: JSONValue] = [:]
            result["widestPt"] = .number(widest)
            result["narrowestPt"] = .number(samples.map(\.view).min() ?? 0)
            result["finalPt"] = .number(final)
            result["dragMs"] = .number(dragMs)
            result["samples"] = .integer(Int64(samples.count))
            result["samplesWithoutPageEdge"] = .integer(Int64(samples.count - gaps.count))
            result["fittedSamples"] = .integer(Int64(fitted))
            result["gapMedianPt"] = .number(percentile(0.5))
            result["gapP90Pt"] = .number(percentile(0.9))
            result["gapMaxPt"] = .number(distances.last ?? -1)
            result["blankStripSamples"] = .integer(Int64(blankStrip))
            result["cutOffSamples"] = .integer(Int64(cutOff))
            result["framesNotLaidOutAtTheirSize"] = .integer(Int64(misfit))
            result["framesShown"] = .integer(Int64(dragFrames.count))
            result["frameWidthsShown"] = .integer(Int64(frameWidths))
            result["settledMs"] = settled
            result["page"] = .string("innerWidth \(pageWidth), columns \(pageColumns), resize events \(resizeEvents)")
            pages[name] = .object(result)
            let settledText = settledMs.map { "\(Int($0)) ms" } ?? "never"
            check("resize (\(name)): the page is laid out at the panel's width once the divider stops",
                  settledMs != nil && pageWidth == Int(final.rounded()) && pageColumns == columns,
                  "settled \(settledText) after the last move; panel \(final) pt; "
                    + "page innerWidth \(pageWidth), \(pageColumns) columns for \(columns)")
            let median = percentile(0.5), ninety = percentile(0.9), largest = distances.last ?? -1
            check("resize (\(name)): every frame shown while the divider moves is the page laid out at its size",
                  !distances.isEmpty && misfit == 0,
                  "\(fitted) of \(gaps.count) samples at the panel's width; distance median \(median) pt, "
                    + "90% \(ninety) pt, max \(largest) pt over \(Int(dragMs)) ms; \(dragFrames.count) frames shown at "
                    + "\(frameWidths) widths; \(blankStrip) samples with a blank strip, \(cutOff) cut off; "
                    + "\(misfit) samples of a frame not laid out at its size")
        }
        record["resize"] = .object(pages)
        try? write(.object(pages), to: "resize.json")
        controller.workspace.layout.panelWidthRatio = nil
    }

    /// The right end of the page's red edge (`/responsive`) in the frame's middle row, in points: where the page laid
    /// out in that frame ends. Nil without a frame or an edge.
    nonisolated fileprivate static func pageEdge(in surface: IOSurfaceRef?, scale: Double) -> Double? {
        guard let surface else { return nil }
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface)
        let row = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
            + IOSurfaceGetHeight(surface) / 2 * IOSurfaceGetBytesPerRow(surface)
        for column in stride(from: width - 1, through: 0, by: -1) {
            let pixel = row + column * 4
            // Red in either byte order (BGRA or RGBA).
            if pixel[1] < 80, (pixel[2] > 200 && pixel[0] < 80) || (pixel[0] > 200 && pixel[2] < 80) {
                return Double(column + 1) / scale
            }
        }
        return nil
    }

    /// The panel as it shows a frame: from the top left over the view's white, cut at the panel's size.
    nonisolated fileprivate static func writePanelPNG(_ surface: IOSurfaceRef, panel: CGSize, scale: Double, to url: URL) {
        let width = Int(panel.width * scale), height = Int(panel.height * scale)
        let image = CIImage(ioSurface: surface)
        guard width > 0, height > 0, let frame = CIContext().createCGImage(image, from: image.extent),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(frame, in: CGRect(x: 0, y: height - frame.height, width: frame.width, height: frame.height))
        guard let shown = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: shown).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    // MARK: Panel

    private func openPanel(label: String, address: String?) async -> BrowserHostPaneController? {
        let previous = BrowserHostPaneController.current
        let launches = client.launchCount
        let postedAt = DispatchTime.now().uptimeNanoseconds
        NotificationCenter.default.post(name: BrowserHostQAFixture.openBrowserPanel, object: nil)
        guard await waitUntil(.seconds(10), { BrowserHostPaneController.current !== previous
                && BrowserHostPaneController.current?.view != nil }),
              let controller = BrowserHostPaneController.current else {
            check("open panel (\(label))", false, "no panel")
            return nil
        }
        if let address {
            controller.addressInput = address
            controller.submitAddress()
        }
        // A reused tab paints once it is shown again; a new one after its first load.
        var firstFrame: UInt64?
        let visible = await waitUntil(.seconds(30), poll: .milliseconds(5)) {
            if controller.hasTab, controller.view?.viewSurface != nil { firstFrame = DispatchTime.now().uptimeNanoseconds }
            return firstFrame != nil
        }
        record["open-\(label)"] = .object([
            "hostWasRunning": .bool(client.launchCount == launches),
            "openToFirstFrameMs": firstFrame.map { .number(Double($0 &- postedAt) / 1_000_000) } ?? .null
        ])
        check("open panel (\(label))", visible, "launched \(client.launchCount > launches), first frame \(firstFrame != nil)")
        return controller
    }

    private func closePanel() async {
        NotificationCenter.default.post(name: BrowserHostQAFixture.closeBrowserPanel, object: nil)
        try? await Task.sleep(for: .milliseconds(800))
    }

    // MARK: Exercise

    private func exercise(_ controller: BrowserHostPaneController) async {
        guard let view = controller.view, let tab = controller.tab else { return }
        do {
            _ = await waitUntil(.seconds(10)) { !controller.isLoading && controller.title == "Browser QA" }
            for domain in ["Runtime", "Page", "DOM"] { _ = try await tab.devTools.send("\(domain).enable") }

            // Keyboard: modifiers, arrows, function keys and text through the panel view.
            click(view, at: try await center(controller, "#name"))
            try? await Task.sleep(for: .milliseconds(200))
            flags(view, keyCode: 0x38, down: true)
            key(view, "A", keyCode: 0x00, modifiers: .shift)
            flags(view, keyCode: 0x38, down: false)
            key(view, "b", keyCode: 0x0B)
            key(view, String(UnicodeScalar(NSLeftArrowFunctionKey)!), keyCode: 0x7B)
            key(view, String(UnicodeScalar(NSF2FunctionKey)!), keyCode: 0x78)
            key(view, "\u{1B}", keyCode: 0x35)
            try? await Task.sleep(for: .milliseconds(300))
            let keys = try await evaluate(controller, "window.qa.keys.join(' ')")
            let value = try await evaluate(controller, "document.querySelector('#name').value")
            check("keys reach the page with DOM key codes", value == "Ab"
                    && keys.contains("Shift/ShiftLeft/16") && keys.contains("A/KeyA/65") && keys.contains("ArrowLeft/ArrowLeft/37")
                    && keys.contains("F2/F2/113") && keys.contains("Escape/Escape/27"),
                  "value \"\(value)\", keydown \(keys)")

            // Korean composition, as an input method calls the view.
            let noRange = NSRange(location: NSNotFound, length: 0)
            for marked in ["ㅎ", "한", "한ㄱ", "한글"] {
                view.setMarkedText(marked, selectedRange: NSRange(location: marked.utf16.count, length: 0), replacementRange: noRange)
            }
            view.insertText("한글", replacementRange: noRange)
            try? await Task.sleep(for: .milliseconds(300))
            let composed = try await evaluate(controller, "document.querySelector('#name').value")
            // The caret sits between A and b after ArrowLeft.
            check("Korean composition commits at the caret", composed == "A한글b", "value \"\(composed)\"")

            // Zoom through the panel's shortcuts.
            view.window?.makeFirstResponder(view)
            let ratio = try await evaluate(controller, "String(window.devicePixelRatio)")
            _ = view.performKeyEquivalent(with: commandKey("=", keyCode: 0x18))
            try? await Task.sleep(for: .milliseconds(500))
            let zoomed = try await evaluate(controller, "String(window.devicePixelRatio)")
            _ = view.performKeyEquivalent(with: commandKey("0", keyCode: 0x1D))
            try? await Task.sleep(for: .milliseconds(500))
            let reset = try await evaluate(controller, "String(window.devicePixelRatio)")
            check("⌘= zooms in and ⌘0 resets", (Double(zoomed) ?? 0) > (Double(ratio) ?? 0) && reset == ratio,
                  "devicePixelRatio \(ratio) → \(zoomed) → \(reset)")

            // Find.
            controller.findText = "needle"
            controller.findTextChanged()
            _ = await waitUntil(.seconds(3)) { controller.findResult?.isFinal == true }
            check("find in page", (controller.findResult?.matches ?? 0) == 3,
                  "matches \(controller.findResult?.matches ?? -1), active \(controller.findResult?.activeMatch ?? -1)")
            controller.closeFind()

            // Tooltip after hovering an element with a title.
            move(view, to: try await center(controller, "#tip"))
            _ = await waitUntil(.seconds(4)) { view.toolTip != nil }
            check("tooltip", view.toolTip == "Tooltip text", "toolTip \(view.toolTip ?? "none")")
        } catch {
            check("keyboard, zoom, find and tooltip", false, error.localizedDescription)
        }
        for (name, step) in [
            ("dialogs", exerciseDialogs), ("file chooser and drop", exerciseFileChooserAndDrop),
            ("download", exerciseDownload), ("URL policy", exercisePolicy), ("checkout", exerciseCheckout), ("tabs", exerciseTabs),
            ("passkey", exercisePasskey), ("accessibility", exerciseAccessibility)
        ] as [(String, (BrowserHostPaneController, BrowserHostView) async throws -> Void)] {
            do { try await step(controller, view) } catch { check(name, false, error.localizedDescription) }
        }
        do {
            // Cookies for the profile check after the host restarts.
            _ = try await evaluate(controller, "document.cookie = 'persistent=1; max-age=86400; path=/'; document.cookie = 'session=1; path=/'; document.cookie")
            try? await Task.sleep(for: .milliseconds(300))

            exerciseSurfaceSecurity()
        } catch {
            check("panel exercise", false, error.localizedDescription)
        }
    }

    private func exerciseDialogs(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async throws {
        _ = try await evaluate(controller, "setTimeout(() => { window.qa.alert = (alert('Hello'), 'shown') }, 0); 'ok'")
        _ = await waitUntil(.seconds(5)) { controller.javaScriptDialog != nil }
        // The dialog is the tab's, over its page: no sheet holds the window.
        let windowFree = controller.javaScriptDialog != nil && view.window?.attachedSheet == nil
        capturePanel(view, named: "dialog-alert.png")
        let alertAnswered = await answerDialog(controller, button: L10n.string("OK"))
        _ = try await evaluate(controller, "setTimeout(() => { window.qa.confirm = confirm('Sure?') }, 0); 'ok'")
        let confirmAnswered = await answerDialog(controller, button: L10n.string("Cancel"))
        _ = try await evaluate(controller, "setTimeout(() => { window.qa.prompt = prompt('Name?', 'x') }, 0); 'ok'")
        let promptAnswered = await answerDialog(controller, button: L10n.string("OK"), text: "프롬프트")
        try? await Task.sleep(for: .milliseconds(300))
        let results = try await evaluate(controller, "[window.qa.alert, String(window.qa.confirm), window.qa.prompt].join('|')")
        check("alert, confirm and prompt over the tab's page, not as window sheets",
              windowFree && alertAnswered && confirmAnswered && promptAnswered && results == "shown|false|프롬프트",
              "window free \(windowFree), page results \(results)")

        // beforeunload needs a user gesture on the page first.
        click(view, at: try await center(controller, "#arm-unload"))
        try? await Task.sleep(for: .milliseconds(200))
        let before = controller.addressInput
        _ = try await evaluate(controller, "setTimeout(() => location.href = '/second', 0); 'ok'")
        let stayed = await answerDialog(controller, button: L10n.string("Cancel"))
        try? await Task.sleep(for: .milliseconds(500))
        check("beforeunload sheet, Cancel keeps the page", stayed && controller.addressInput == before,
              "address \(controller.addressInput)")
        _ = try await evaluate(controller, "window.onbeforeunload = null; 'ok'")
    }

    private func exerciseFileChooserAndDrop(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async throws {
        let file = output.appending(path: "qa-upload.txt")
        try "upload body".write(to: file, atomically: true, encoding: .utf8)
        // The open panel is answered here so the run needs no clicks; the event and the result travel
        // the real host path.
        var seen: BrowserFileDialog?
        controller.eventObserver = { event in
            guard case .fileDialog(let tabID, let dialog) = event else { return }
            seen = dialog
            controller.tab?.send(.fileDialogResult(tab: tabID, dialog: dialog.id, paths: [file.path(percentEncoded: false)]))
        }
        controller.fileDialogOverride = true
        click(view, at: try await center(controller, "#file"))
        _ = await waitUntil(.seconds(3)) { seen != nil }
        try? await Task.sleep(for: .milliseconds(300))
        let chosen = try await evaluate(controller, "document.querySelector('#file').files[0]?.name ?? ''")
        check("file chooser event and result", chosen == "qa-upload.txt", "mode \(seen?.mode.rawValue ?? "none"), file \(chosen)")
        controller.fileDialogOverride = false
        controller.eventObserver = nil

        // Dropping a file, as the view sends it for a Finder drag.
        guard let tab = controller.tab else { return }
        let point = try await center(controller, "#drop")
        for phase in [BrowserDragInput.Phase.enter, .over, .drop] {
            tab.send(.drag(tab: tab.id, input: BrowserDragInput(
                phase: phase, x: point.x, y: point.y,
                files: phase == .enter ? [file.path(percentEncoded: false)] : [], operations: BrowserDragOperations.copy.rawValue
            )))
            try? await Task.sleep(for: .milliseconds(150))
        }
        try? await Task.sleep(for: .milliseconds(300))
        let dropped = try await evaluate(controller, "window.qa.dropped ?? ''")
        check("file dropped on the page", dropped == "qa-upload.txt:11", "dropped \(dropped)")
    }

    private func exerciseDownload(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async throws {
        click(view, at: try await center(controller, "#download"))
        let done = await waitUntil(.seconds(10)) { controller.downloads.contains { $0.state == .completed } }
        let download = controller.downloads.last
        let exists = download.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        check("download saved to Downloads", done && exists
                && download?.path.hasPrefix(MacBrowserHost.shared.paths.downloads.path(percentEncoded: false)) == true,
              "\(download?.path ?? "none") \(download?.state.rawValue ?? "")")
    }

    private func exercisePolicy(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async throws {
        guard let tab = controller.tab else { return }
        var blocked: [String] = []
        // Another app's address no app opens goes nowhere, as in Chrome, with no notice (since 2026-10-25; it was
        // refused with a notice before); a second request before the next input is ignored (Chrome's flood guard).
        var appRequests: [String] = []
        controller.eventObserver = { event in
            if case .navigationBlocked(_, let url) = event { blocked.append(url) }
            if case .externalAppHandled(_, let url, _, let outcome) = event { appRequests.append("\(url) \(outcome.rawValue)") }
        }
        controller.addressInput = "javascript:alert(1)"
        controller.submitAddress()
        let typedNotice = controller.notice
        _ = try? await tab.devTools.send("Page.navigate", ["url": .string("chrome://version")])
        _ = try? await evaluate(controller, "location.href = 'x-yardlet-qa://open'; 'ok'")
        _ = try? await evaluate(controller, "window.open('x-yardlet-qa://refused', '_blank'); 'ok'", userGesture: true)
        try? await Task.sleep(for: .milliseconds(800))
        let refusedOpenedNoTab = client.tabs(forSession: session).count == 1
        // A new-window request opens a new tab of the task, in front, as the Codex and Claude apps'
        // browsers do; the page that asked stays as it was.
        _ = try? await evaluate(controller, "window.open('/second', '_blank'); 'ok'", userGesture: true)
        let windowOpenTab = await waitUntil(.seconds(5)) { controller.tab !== tab && controller.addressInput.hasSuffix("/second") }
        let windowOpenAddress = controller.addressInput
        let openerKept = tab.currentURL == base
        // Its side-panel tab closes as ⌘W would; the panel goes back to the tab used before.
        controller.onCloseTab?(controller.key)
        _ = await waitUntil(.seconds(5)) { controller.tab === tab }
        // A target=_blank link clicked by the user does the same.
        click(view, at: try await center(controller, "#blank-link"))
        let linkTab = await waitUntil(.seconds(5)) { controller.tab !== tab && controller.addressInput.hasSuffix("/second") }
        let tabsAfterLink = client.tabs(forSession: session).count
        controller.onCloseTab?(controller.key)
        _ = await waitUntil(.seconds(5)) { controller.tab === tab }
        check("URL policy and new-window tabs",
              typedNotice != nil && blocked.contains { $0.hasPrefix("chrome://") } && !blocked.contains { $0.hasPrefix("x-yardlet-qa:") }
                && appRequests.count == 2 && appRequests.allSatisfy { $0.hasSuffix(" noApp") || $0.hasSuffix(" ignored") }
                && refusedOpenedNoTab && windowOpenTab && openerKept && linkTab && tabsAfterLink == 2
                && client.tabs(forSession: session).count == 1,
              "typed notice \(typedNotice ?? "none"), blocked \(blocked), other apps \(appRequests), window.open → new tab \(windowOpenAddress) "
                + "(opener kept \(openerKept)), target=_blank link → new tab (tabs \(tabsAfterLink)), back to \(client.tabs(forSession: session).count)")
        controller.eventObserver = nil
        controller.addressInput = base
        controller.submitAddress()
        _ = await waitUntil(.seconds(5)) { controller.title == "Browser QA" }
    }

    // MARK: A card checkout

    /// A card payment as a person makes it on a card site, with the card issuer's check (3-D Secure) on
    /// another site: the card form and a shipping address submit and the page goes on; the issuer's frames
    /// post to the issuer and back and tell the checkout by postMessage; the whole page posts to the issuer
    /// and back; a new window answers the page that opened it; and a wallet button's Payment Request. The
    /// browser stays up throughout. Submitting a card form ended the browser host until 2026-10-25:
    /// Chromium's autofill offered to save the card in Chrome's bubble, and a windowless tab has no Chrome
    /// window for it. A step that ends the host is retried as a person would, so the next steps still run.
    /// `checkout.json` keeps each step.
    private func exerciseCheckout(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async throws {
        var launches = client.launchCount
        var steps: [String: JSONValue] = [:]
        func intact() -> Bool { client.isHostRunning && client.launchCount == launches && controller.hasTab }
        func state() -> String {
            "title \"\(controller.title)\", host running \(client.isHostRunning), launches \(client.launchCount - launches), "
                + "ended \(client.lastTermination ?? "no"), panel error \(controller.errorMessage ?? "none")"
        }
        // A step that ended the host: Try again, as a person would, and go on with the next step.
        func recover() async {
            guard !intact() else { return }
            if !client.isHostRunning { _ = await waitUntil(.seconds(5)) { controller.errorMessage != nil } }
            controller.retry()
            _ = await waitUntil(.seconds(20)) { self.client.isHostRunning && controller.hasTab && !controller.isLoading }
            launches = client.launchCount
        }
        defer { try? write(.object(steps), to: "checkout.json") }
        func type(_ fields: [(String, String)]) async throws {
            guard let tab = controller.tab else { throw QAFailure("no tab") }
            for (field, text) in fields {
                click(view, at: try await center(controller, field))
                try? await Task.sleep(for: .milliseconds(150))
                _ = try await tab.devTools.send("Input.insertText", ["text": .string(text)])
            }
        }

        // The card form: typed field by field as a person does, then Pay.
        try await load(controller, base + "checkout", title: "Checkout")
        try await type([("#cc-name", "Yardlet QA"), ("#cc-number", "4242424242424242"), ("#cc-exp-month", "12"),
                        ("#cc-exp-year", "2034"), ("#cc-csc", "123")])
        click(view, at: try await center(controller, "#pay-button"))
        let paid = await waitUntil(.seconds(10)) { controller.title == "Paid" || !self.client.isHostRunning }
        // Chromium offers to save a card once the form is submitted; the host ended then.
        try? await Task.sleep(for: .seconds(2))
        steps["card"] = .string(state())
        check("checkout: submitting a card form keeps the browser", paid && controller.title == "Paid" && intact(), state())
        await recover()

        // A shipping address: Chromium offers to save that too, in another of Chrome's bubbles.
        try await load(controller, base + "checkout/address", title: "Checkout address")
        try await type([("#name", "Yardlet QA"), ("#street", "1 Infinite Loop"), ("#city", "Cupertino"), ("#state", "CA"),
                        ("#zip", "95014"), ("#country", "United States"), ("#phone", "4085551234")])
        click(view, at: try await center(controller, "#ship"))
        let shipped = await waitUntil(.seconds(10)) { controller.title == "Shipped" || !self.client.isHostRunning }
        try? await Task.sleep(for: .seconds(2))
        steps["address"] = .string(state())
        check("checkout: submitting an address form keeps the browser", shipped && controller.title == "Shipped" && intact(), state())
        await recover()

        // 3-D Secure 2 in frames: the hidden method frame, then the challenge frame, where the person confirms.
        try await load(controller, base + "checkout/frame", title: "Checkout frame")
        let challengeLoaded = await waitUntilAsync(.seconds(10)) {
            (try? await self.evaluate(controller, "String(window.qa.challenge)")) == "loaded"
        }
        let frame = try await evaluate(controller, """
            (() => { const r = document.querySelector('#challenge').getBoundingClientRect(); return r.x + ',' + r.y })()
            """).split(separator: ",").compactMap { Double($0) }
        if challengeLoaded, frame.count == 2 {
            // The issuer's Confirm sits at 20, 20 inside its frame (1 px border), 200 by 40.
            click(view, at: NSPoint(x: frame[0] + 1 + 120, y: frame[1] + 1 + 40))
        }
        let framed = await waitUntil(.seconds(10)) { controller.title == "Checkout frame done" }
        let messages = (try? await evaluate(controller, "window.qa.messages.join(' | ')")) ?? ""
        steps["frames"] = .string("challenge loaded \(challengeLoaded); messages \(messages); \(state())")
        check("checkout: the issuer's frames post to the issuer and back and tell the checkout", framed && intact(),
              "challenge loaded \(challengeLoaded), messages \(messages); \(state())")

        // 3-D Secure by redirect: the whole page posts to the issuer, which posts back to the merchant.
        try await load(controller, base + "checkout/redirect", title: "Checkout redirect")
        click(view, at: try await center(controller, "#go"))
        let atIssuer = await waitUntil(.seconds(10)) { controller.title == "Issuer check" && !controller.isLoading }
        let issuerAddress = controller.tab?.currentURL ?? ""
        if atIssuer { click(view, at: try await center(controller, "#confirm")) }
        let returned = await waitUntil(.seconds(10)) { controller.title == "Checkout returned" && !controller.isLoading }
        let answer = (try? await evaluate(controller, "document.querySelector('h1').textContent")) ?? ""
        steps["redirect"] = .string("issuer \(issuerAddress); answer \(answer); \(state())")
        check("checkout: the page posts to the issuer and the issuer posts back", atIssuer && returned && answer == "authenticated"
                && issuerAddress.hasPrefix("http://localhost:") && intact(),
              "at the issuer \(atIssuer) (\(issuerAddress)), back \(returned), answer \"\(answer)\"; \(state())")

        // The issuer in a new window that answers the page that opened it.
        try await load(controller, base + "checkout/popup", title: "Checkout popup")
        let checkout = controller.tab
        click(view, at: try await center(controller, "#open"))
        let answered = await waitUntil(.seconds(10)) { checkout?.title == "Checkout popup done" }
        try? await Task.sleep(for: .seconds(1))
        let popupTabs = client.tabs(forSession: session).filter { $0 !== checkout }
        let popupState = popupTabs.map { "\($0.title) \($0.currentURL ?? "")" }.joined(separator: "; ")
        let popupMessages = (try? await evaluate(controller, "window.qa.messages.join(' | ')")) ?? ""
        steps["popup"] = .string("answered \(answered); popup tabs \(popupState); messages \(popupMessages); \(state())")
        check("checkout: the issuer's new window answers the page that opened it and closes", answered && popupTabs.isEmpty && intact(),
              "answered \(answered), tabs left \(popupState.isEmpty ? "none" : popupState), messages \(popupMessages); \(state())")
        for popup in popupTabs { popup.close() }
        _ = await waitUntil(.seconds(5)) { controller.tab === checkout }

        // A wallet button's Payment Request: Chrome shows its payment sheet in the browser window.
        try await load(controller, base.replacingOccurrences(of: "127.0.0.1", with: "localhost") + "checkout/wallet",
                       title: "Checkout wallet")
        // Since 2026-10-25 the API is hidden and the page shows no button (BROWSER_HOST section 3).
        if (try? await evaluate(controller, "String(!document.getElementById('pay').hidden)")) == "true" {
            click(view, at: try await center(controller, "#pay"))
            _ = await waitUntilAsync(.seconds(8)) {
                let state = (try? await self.evaluate(controller, "window.qa.state")) ?? ""
                return state != "idle" && state != "started"
            }
        }
        let wallet = (try? await evaluate(controller, "window.qa.api + ' / ' + window.qa.state")) ?? ""
        let windows = client.chromiumWindowTitles
        _ = try? await evaluate(controller, "window.qa.request && window.qa.request.abort().catch(() => {}); 'ok'")
        if !windows.isEmpty { client.closeChromiumWindows() }
        try? await Task.sleep(for: .seconds(1))
        steps["wallet"] = .string("\(wallet); Chromium windows \(windows); \(state())")
        check("checkout: a wallet's payment request keeps the browser", intact(),
              "\(wallet); Chromium windows \(windows); \(state())")

        controller.addressInput = base
        controller.submitAddress()
        _ = await waitUntil(.seconds(5)) { controller.title == "Browser QA" }
    }

    /// The panel's window as AppKit draws it (the page itself is a layer of host frames and shows as
    /// drawn), for reading the strip and toolbar.
    private func capturePanel(_ view: BrowserHostView, named name: String) {
        guard let content = view.window?.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appending(path: name))
    }

    /// WebAuthn in the windowless browser, on localhost (a secure context and a valid relying party
    /// id; no passkey for it anywhere), from the QA page `/passkey`: what the page learns of the
    /// authenticators, whether Chromium shows its passkey dialog and which sheet (the host draws any
    /// window it opens into `host-windows/`), and how each request ends. Each request is aborted
    /// afterwards so nothing stays open. A passkey autofill request with no passkey must open no window,
    /// even once the person clicks into the sign-in field, as in Chrome; the other sheets are observed:
    /// the result is in `passkey` and the check's detail. A request that goes to a phone's QR code first
    /// makes Chromium ask macOS for Bluetooth, and macOS asks the person in a window of its own the first
    /// time an app identifier does, so those requests run only once this QA app's answer is known
    /// (`CBManager.authorization` reads it without asking).
    private func exercisePasskey(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async throws {
        let local = base.replacingOccurrences(of: "127.0.0.1", with: "localhost")
        controller.addressInput = local + "passkey"
        controller.submitAddress()
        _ = await waitUntil(.seconds(10)) { controller.title == "Passkey" }
        _ = try? await evaluate(controller, """
            (async () => { try { window.__caps = JSON.stringify({ secure: isSecureContext,
              uvpaa: await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable(),
              conditional: await PublicKeyCredential.isConditionalMediationAvailable(),
              caps: PublicKeyCredential.getClientCapabilities ? await PublicKeyCredential.getClientCapabilities() : null }) }
              catch (e) { window.__caps = 'error ' + e } })(); 'ok'
            """)
        var capabilities = ""
        for _ in 0..<25 where capabilities.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
            capabilities = (try? await evaluate(controller, "window.__caps || ''")) ?? ""
        }
        let bluetooth = CBManager.authorization
        let reachesPhoneFirst: Set = ["discoverableGet", "createAny"]
        let cases = ["conditionalGet", "discoverableGet", "getPlatformOnly", "createAny", "createPlatform"]
            .filter { bluetooth != .notDetermined || !reachesPhoneFirst.contains($0) }
        let agentTools = BrowserAgentTools(usesMacEditingCommands: true, tabs: BrowserAgentTabs { MacBrowserHost.shared.client })
        var results: [String: JSONValue] = [:]
        var agentHeard = false
        var agentCancelled = false
        var cancelledAs = ""
        for name in cases {
            let linesBefore = hostWindowLines().count
            let textsBefore = hostWindowTexts().count
            let started = DispatchTime.now().uptimeNanoseconds
            _ = try? await evaluate(controller, "window.passkey('\(name)')", userGesture: true)
            if name == "conditionalGet" {
                // The person clicks into the sign-in field, where Chrome offers saved passkeys.
                try? await Task.sleep(for: .milliseconds(500))
                if let field = try? await center(controller, "#user") { click(view, at: field) }
            }
            var outcome = "pending"
            for _ in 0..<30 where outcome == "pending" {
                try? await Task.sleep(for: .milliseconds(200))
                outcome = (try? await evaluate(controller, "window.qa.passkey")) ?? "?"
            }
            let settledMs = Self.milliseconds(since: started)
            try? await Task.sleep(for: .seconds(2))
            let order = Self.windowOrder(hostPID: client.hostProcessID)
            let windows = Array(hostWindowLines().dropFirst(linesBefore))
            let texts = Array(hostWindowTexts().dropFirst(textsBefore))
            var result: [String: JSONValue] = [
                "outcome": .string(outcome), "settledMs": .number(settledMs), "windowOrder": .string(order),
                "hostWindows": .array(windows.map { .string($0) }), "texts": .array(texts.map { .string($0) })
            ]
            if name == "getPlatformOnly" {
                // The agent drives this tab: its next tool says a passkey dialog waits, and it can cancel it.
                let heard = await agentTools.run(tool: AgentToolCatalog.evaluate, arguments: .object(["function": .string("() => 1")]),
                                                 sessionID: session)
                let heardText = heard.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: " ")
                agentHeard = heardText.localizedCaseInsensitiveContains("passkey")
                let cancel = await agentTools.run(tool: AgentToolCatalog.handleDialog, arguments: .object(["accept": .bool(false)]),
                                                  sessionID: session)
                let cancelText = cancel.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: " ")
                for _ in 0..<25 where cancelledAs.isEmpty || cancelledAs == "pending" {
                    try? await Task.sleep(for: .milliseconds(200))
                    cancelledAs = (try? await evaluate(controller, "window.qa.passkey")) ?? ""
                }
                agentCancelled = !cancel.isError && cancelledAs.hasPrefix("NotAllowedError")
                result["agentHeard"] = .string(heardText)
                result["agentCancel"] = .string(cancelText)
                result["afterAgentCancel"] = .string(cancelledAs)
            }
            capturePanel(view, named: "passkey-\(name).png")
            _ = try? await evaluate(controller, "window.qa.abort()")
            try? await Task.sleep(for: .milliseconds(800))
            result["afterAbort"] = .string((try? await evaluate(controller, "window.qa.passkey")) ?? "")
            results[name] = .object(result)
        }
        record["passkey"] = .object(results.merging([
            "capabilities": .string(capabilities), "bluetoothAuthorization": .integer(Int64(bluetooth.rawValue))
        ]) { $1 })
        func summary(_ name: String) -> String {
            guard case .object(let result)? = results[name] else { return "\(name) none" }
            let texts = result["texts"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " / ") ?? ""
            let firstLine = texts.split(separator: "\n").prefix(3).joined(separator: " ")
            return "\(name) → \(result["outcome"]?.stringValue ?? "?"), windows \(result["hostWindows"]?.arrayValue?.count ?? 0) [\(firstLine)]"
        }
        let skipped = bluetooth == .notDetermined ? "; not run before this QA app's Bluetooth answer is known: "
            + reachesPhoneFirst.sorted().joined(separator: ", ") : ""
        check("passkey requests observed", !capabilities.isEmpty,
              "capabilities \(capabilities); " + cases.map(summary).joined(separator: "; ") + skipped)
        if case .object(let conditional)? = results["conditionalGet"] {
            let windows = conditional["hostWindows"]?.arrayValue?.count ?? -1
            let outcome = conditional["outcome"]?.stringValue ?? "?"
            check("a passkey autofill request with no passkey opens no window", windows == 0 && outcome == "pending",
                  "windows \(windows), page \(outcome)")
        }
        check("the agent hears of a passkey dialog and can cancel it", agentHeard && agentCancelled,
              "heard \(agentHeard), cancelled \(agentCancelled) → page \(cancelledAs)")
        // A passkey dialog is its tab's, and closes when the tab's page moves, to another site or within the same one,
        // as in Chrome (`WebContentsModalDialogManager::DidFinishNavigation`; the request's document goes).
        var moves: [String] = []
        var movesClose = true
        for (name, address) in [("to another site", base), ("within the site", local + "passkey?moved")] {
            controller.addressInput = local + "passkey"
            controller.submitAddress()
            _ = await waitUntil(.seconds(10)) { controller.title == "Passkey" && !controller.isLoading }
            _ = try? await evaluate(controller, "window.passkey('getPlatformOnly')", userGesture: true)
            let opened = await waitUntil(.seconds(6)) { !self.client.chromiumWindows.isEmpty }
            let tabs = client.chromiumWindows.map { $0.tab.map(String.init) ?? "unknown" }
            let overThisTab = opened && client.chromiumWindows.allSatisfy { $0.tab == controller.tab?.id }
            controller.addressInput = address
            controller.submitAddress()
            let closed = await waitUntil(.seconds(4)) { self.client.chromiumWindows.isEmpty }
            moves.append("\(name): opened \(opened) over tabs \(tabs) (the panel's \(controller.tab?.id ?? -1)), closed after the move \(closed)")
            movesClose = movesClose && opened && overThisTab && closed
            if !closed {
                client.closeChromiumWindows()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        record["passkeyMoves"] = .string(moves.joined(separator: "; "))
        check("a passkey dialog is its tab's and closes when the page moves", movesClose, moves.joined(separator: "; "))
        await exerciseDevicePasskey(controller)
        controller.addressInput = base
        controller.submitAddress()
        _ = await waitUntil(.seconds(10)) { controller.title == "Browser QA" }
    }

    /// What decides between the phone's QR code and this Mac's own passkey (2026-10-27): Chromium goes to its
    /// passkey on this Mac (Touch ID) only when that authenticator holds a credential for the request, for the
    /// site's RP ID and, when the site lists the account's credentials, one of those (`TouchIdCredentialStore`,
    /// `StartGuidedFlowForMostLikelyTransportOrShowMechanismSelection`); otherwise it drops it, and with the phone
    /// left alone it opens on the QR code. A QA bundle has no Touch ID (no keychain group), so a CDP virtual
    /// authenticator on this device's transport stands in for it, with Chromium's own dialog on (`enableUI`), and
    /// its user verification stands in for the fingerprint. The requests list only credentials on this device, so
    /// Chromium does not reach for Bluetooth (macOS would ask the person about it in a window of its own).
    private func exerciseDevicePasskey(_ controller: BrowserHostPaneController) async {
        let local = base.replacingOccurrences(of: "127.0.0.1", with: "localhost")
        controller.addressInput = local + "passkey"
        controller.submitAddress()
        _ = await waitUntil(.seconds(10)) { controller.title == "Passkey" && !controller.isLoading }
        guard let cdp = controller.tab?.devTools else { return check("a passkey on this Mac decides the sheet", false, "no tab") }
        func credentialID() -> String { Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString() }
        let here = credentialID(), forAnotherSite = credentialID(), elsewhere = credentialID()
        let key = P256.Signing.PrivateKey().derRepresentation.base64EncodedString()
        var authenticator: String?
        do {
            _ = try await cdp.send("WebAuthn.enable", ["enableUI": .bool(true)])
            authenticator = try await cdp.send("WebAuthn.addVirtualAuthenticator",
                                               ["options": VaultPasskeyAuthenticator.options])["authenticatorId"]?.stringValue
            for (id, rp) in [(here, "localhost"), (forAnotherSite, "stripe.example")] {
                _ = try await cdp.send("WebAuthn.addCredential", ["authenticatorId": .string(authenticator ?? ""), "credential": .object([
                    "credentialId": .string(id), "isResidentCredential": .bool(true), "rpId": .string(rp), "privateKey": .string(key),
                    "userHandle": .string(Data("qa-user".utf8).base64EncodedString()), "signCount": .integer(0)
                ])])
            }
        } catch {
            return check("a passkey on this Mac decides the sheet", false, "virtual authenticator: \(error.localizedDescription)")
        }
        let cases: [(name: String, allow: String, verified: Bool)] = [
            ("this Mac holds the account's passkey", here, true),
            ("the fingerprint is refused", here, false),
            ("the account's passkey is not on this Mac", elsewhere, true),
            ("this Mac's passkey is another site's", forAnotherSite, true)
        ]
        var results: [String: JSONValue] = [:]
        var lines: [String] = []
        for item in cases {
            _ = try? await cdp.send("WebAuthn.setUserVerified", ["authenticatorId": .string(authenticator ?? ""),
                                                                 "isUserVerified": .bool(item.verified)])
            _ = try? await evaluate(controller, "window.qa.allow = [{ id: '\(item.allow)', transports: ['internal'] }]; 'ok'")
            let linesBefore = hostWindowLines().count
            let textsBefore = hostWindowTexts().count
            _ = try? await evaluate(controller, "window.passkey('getAllowed')", userGesture: true)
            var outcome = "pending"
            for _ in 0..<20 where outcome == "pending" {
                try? await Task.sleep(for: .milliseconds(200))
                outcome = (try? await evaluate(controller, "window.qa.passkey")) ?? "?"
            }
            try? await Task.sleep(for: .seconds(2))
            let windows = hostWindowLines().count - linesBefore
            let text = Array(hostWindowTexts().dropFirst(textsBefore)).joined(separator: " / ")
                .split(separator: "\n").prefix(3).joined(separator: " ")
            results[item.name] = .object(["outcome": .string(outcome), "windows": .integer(Int64(windows)), "text": .string(text)])
            lines.append("\(item.name) → \(outcome), windows \(windows) [\(text)]")
            _ = try? await evaluate(controller, "window.qa.abort()")
            if !client.chromiumWindows.isEmpty { client.closeChromiumWindows() }
            try? await Task.sleep(for: .milliseconds(800))
        }
        if let authenticator {
            _ = try? await cdp.send("WebAuthn.removeVirtualAuthenticator", ["authenticatorId": .string(authenticator)])
        }
        _ = try? await cdp.send("WebAuthn.disable", [:])
        record["devicePasskey"] = .object(results)
        func outcome(_ index: Int) -> String { results[cases[index].name]?["outcome"]?.stringValue ?? "?" }
        func windows(_ index: Int) -> Int64 { results[cases[index].name]?["windows"]?.integerValue ?? -1 }
        check("a passkey on this Mac signs once the fingerprint step passes, with no sheet before it",
              outcome(0) == "resolved" && windows(0) == 0 && outcome(1) != "resolved", lines.joined(separator: "; "))
        check("a passkey on this Mac for another account or site is left out of the request",
              outcome(2) != "resolved" && outcome(3) != "resolved", lines.joined(separator: "; "))
    }

    /// What ordinary sites ask of a browser beyond showing pages, on the QA page `/compat` (BROWSER_HOST
    /// section 11): a PDF in Chromium's viewer; permission requests answered from the panel's bar (a block
    /// settles the page's request, an allow for more than one download lets them through); a tab a page
    /// opened only to download closing back to its opener; a self-signed certificate left to Chromium's
    /// warning page and its Proceed; camera and microphone asked in the bar; other apps' addresses (mailto:,
    /// tel:) not refused; the Payment Request API hidden, so the page shows no wallet button; the agent
    /// hearing Chromium's sign-in window as one; closing a tab whose page asks before it is left asking as
    /// Chrome does. Downloads a page makes itself, a popup without a user gesture, fullscreen, the file
    /// pickers, a cross-site frame's cookies and storage and HTTP Basic authentication are recorded as they
    /// are. Everything goes to `compat` in result.json. Nothing here may ask macOS for anything: location,
    /// the clipboard, the camera and the microphone are blocked in the bar before a grant could reach the
    /// system, no other app opens, and print, which opens the system's print panel, is not run.
    private func exerciseCompat(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async throws {
        var results: [String: JSONValue] = [:]
        let compatPage = base + "compat"
        func outcome(_ kind: String, seconds: Int = 3) async -> String {
            var value = "pending"
            let deadline = ContinuousClock.now + .seconds(seconds)
            while value == "pending" || value.isEmpty, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(150))
                value = (try? await evaluate(controller, "window.qa.compat['\(kind)'] || ''")) ?? "?"
            }
            return value
        }
        func run(_ kind: String, gesture: Bool = true, seconds: Int = 3) async -> String {
            _ = try? await evaluate(controller, "window.compat('\(kind)')", userGesture: gesture)
            let value = await outcome(kind, seconds: seconds)
            results[kind] = .string(value)
            return value
        }
        func go(_ address: String, title: String? = nil, seconds: Int = 6) async {
            controller.addressInput = address
            controller.submitAddress()
            if let title {
                _ = await waitUntil(.seconds(seconds)) {
                    controller.tab?.currentURL == address && controller.title == title && !controller.isLoading
                }
            } else {
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
        let downloads = MacBrowserHost.shared.paths.downloads
        func downloaded() -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: downloads.path(percentEncoded: false))) ?? [])
        }
        /// `name` among `files`, also as "name (1).txt": the QA home's Downloads keeps earlier runs' files.
        func saved(_ name: String, in files: Set<String>) -> Bool {
            let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            return files.contains { $0 == name || ($0.hasPrefix(base + " (") && $0.hasSuffix(")." + ext)) }
        }
        func state() -> String {
            "title \"\(controller.title)\", address \(controller.addressInput), error \(controller.errorMessage ?? "none"), "
                + "notice \(controller.notice ?? "none")"
        }
        /// Waits for the panel's permission bar, answers it, and says what it asked.
        func answerPrompt(_ result: BrowserPermissionResult, picture: String) async -> String {
            guard await waitUntil(.seconds(5), { controller.permissionPrompt != nil }),
                  let prompt = controller.permissionPrompt else { return "no bar" }
            capturePanel(view, named: picture)
            let asked = prompt.permissions.joined(separator: ",")
            controller.answerPermission(result)
            return asked
        }

        // Other apps never open from the QA: what Yardlet would open is recorded (LaunchServices still names the app).
        let externalApps = client.externalApps
        let recorder = RecordingExternalApps(naming: externalApps)
        client.externalApps = recorder
        defer { client.externalApps = externalApps }
        var launched: [String] { recorder.launched }
        let agentTools = BrowserAgentTools(usesMacEditingCommands: true, tabs: BrowserAgentTabs { MacBrowserHost.shared.client })
        func agentText(_ result: AgentToolResult) -> String {
            result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: " ")
        }
        let compatKey = controller.key

        _ = await run("permissionStates", gesture: false)
        let features = await run("features", gesture: false)
        // Wallet buttons (Google Pay, Apple Pay) start the Payment Request API, whose sheet needs a Chrome window a
        // windowless tab does not have; with the API hidden, a checkout shows no such button, as in the Claude app.
        let wallet = await run("walletButton", gesture: false)
        check("compat: the Payment Request API is hidden, so the page shows no wallet button",
              features.contains("PaymentRequest=false") && wallet == "resolved hidden", "\(features); wallet button \(wallet)")
        // The page says where the server's HTTPS port is: the app never reads the server's files, since a file
        // another process wrote under ~/Desktop stops open() in macOS's folder protection (sandboxd).
        let tlsOrigin = (try? await evaluate(controller, "window.qa.tls")) ?? ""

        // A popup a page opens with no user gesture (Chrome blocks it and says so in the address bar). It
        // runs first: a user gesture lets the page open windows for five seconds after it.
        // Chrome lists it under "Pop-ups blocked" in the address field, and opens it from there.
        let tabsBeforePopup = client.tabs(forSession: session).count
        let popup = await run("popupWithoutGesture", gesture: false)
        try? await Task.sleep(for: .seconds(2))
        let blocked = controller.blockedPopups
        capturePanel(view, named: "compat-popup-blocked.png")
        var openedFromList = false
        if let first = blocked.first {
            controller.openBlockedPopup(first)
            openedFromList = await waitUntil(.seconds(5)) {
                self.client.tabs(forSession: self.session).count == tabsBeforePopup + 1 && controller.addressInput.hasSuffix("/second?popup")
            }
        }
        let listLeft = client.tab(key: compatKey, forSession: session)?.blockedPopups ?? []
        results["popupWithoutGesture"] = .string("\(popup), tabs \(tabsBeforePopup) → \(client.tabs(forSession: session).count), "
            + "notice \(controller.notice ?? "none"), listed \(blocked), opened from the list \(openedFromList), left \(listLeft)")
        check("compat: a pop-up blocked without a click is listed in the panel and opens from there",
              popup == "resolved null" && blocked.count == 1 && blocked.first?.hasSuffix("/second?popup") == true && openedFromList
                && listLeft.isEmpty,
              "\(popup), listed \(blocked), opened from the list \(openedFromList), left \(listLeft)")
        if controller.addressInput != compatPage {
            controller.onCloseTab?(controller.key)
            _ = await waitUntil(.seconds(5)) { controller.addressInput == compatPage }
        }

        // Downloads the page makes itself: the first goes; the next ones on the same page are "more than
        // one download", which Chrome asks about. The bar's Allow lets them through, and Chromium keeps it.
        let before = downloaded()
        _ = await run("blobDownload")
        try? await Task.sleep(for: .seconds(2))
        _ = await run("dataDownload")
        let multipleAsked = await answerPrompt(.allow, picture: "compat-permission-downloads.png")
        try? await Task.sleep(for: .seconds(2))
        _ = await run("twoDownloads")
        try? await Task.sleep(for: .seconds(2))
        let pageDownloads = downloaded().subtracting(before)
        results["multipleDownloads"] = .string("asked \(multipleAsked), files \(pageDownloads.sorted())")
        check("compat: more than one download asks in the panel and goes once allowed",
              multipleAsked == "multipleDownloads"
                && ["qa-blob.csv", "qa-data.txt", "qa-multi-1.txt", "qa-multi-2.txt"].allSatisfy { saved($0, in: pageDownloads) },
              "bar \(multipleAsked), files \(pageDownloads.sorted())")

        // A target=_blank link to a file: the download goes, and the empty tab closes back to the page.
        let tabsBefore = client.tabs(forSession: session).count
        _ = await run("blankDownload")
        let backToPage = await waitUntil(.seconds(8)) {
            self.client.tabs(forSession: self.session).count == tabsBefore && controller.addressInput == compatPage
        }
        let blankFile = saved("qa-blank.txt", in: downloaded().subtracting(before))
        results["blankDownload"] = .string("file \(blankFile), tabs \(tabsBefore) → \(client.tabs(forSession: session).count), "
            + "shown \(controller.addressInput)")
        check("compat: a tab opened only to download closes back to its opener", blankFile && backToPage,
              "file \(blankFile), tabs \(tabsBefore) → \(client.tabs(forSession: session).count), shown \(controller.addressInput)")
        if !backToPage, controller.addressInput != compatPage {
            controller.onCloseTab?(controller.key)
            _ = await waitUntil(.seconds(5)) { controller.addressInput == compatPage }
        }

        _ = await run("fullscreen")
        _ = await run("thirdPartyFrame", gesture: false)
        var frame = ""
        for _ in 0..<25 where frame.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
            frame = (try? await evaluate(controller, "window.qa.compat.frame || ''")) ?? ""
        }
        results["thirdPartyFrame"] = .string(frame.isEmpty ? "no answer from the frame" : frame)

        // The file pickers; each dialog is answered with no file, as Cancel would.
        var dialogs: [String] = []
        controller.fileDialogOverride = true
        controller.eventObserver = { event in
            guard case .fileDialog(let tabID, let dialog) = event else { return }
            dialogs.append(dialog.mode.rawValue)
            controller.tab?.send(.fileDialogResult(tab: tabID, dialog: dialog.id, paths: nil))
        }
        for kind in ["multipleInput", "directoryInput", "openFilePicker", "saveFilePicker", "directoryPicker"] {
            let count = dialogs.count
            let value = await run(kind)
            try? await Task.sleep(for: .milliseconds(800))
            results[kind] = .string("\(value); dialog \(dialogs.count > count ? dialogs[count] : "none")")
        }
        controller.eventObserver = nil
        controller.fileDialogOverride = false

        // Permission requests the bar blocks: the page's request settles as refused.
        var refused: [String] = []
        for (kind, expected) in [("notification", "resolved denied"), ("geolocation", "GeolocationPositionError: 1"),
                                 ("clipboardRead", "NotAllowedError")] {
            _ = try? await evaluate(controller, "window.compat('\(kind)')", userGesture: true)
            let asked = await answerPrompt(.block, picture: "compat-permission-\(kind).png")
            let value = await outcome(kind, seconds: 4)
            results[kind] = .string("bar \(asked) → \(value)")
            if !value.hasPrefix(expected) { refused.append("\(kind): bar \(asked) → \(value)") }
        }
        check("compat: a permission request is asked in the panel and a block settles it", refused.isEmpty,
              refused.isEmpty ? "notifications, location and a clipboard read blocked from the bar" : refused.joined(separator: "; "))

        // Camera and microphone, asked in the bar as Chrome asks; each is blocked there, before a grant could
        // reach macOS's own prompt, and a site blocked once is refused without asking again. Before 2026-10-25
        // CEF refused both at once.
        var mediaFailures: [String] = []
        for kind in ["camera", "microphone"] {
            _ = try? await evaluate(controller, "window.compat('\(kind)')", userGesture: true)
            let asked = await answerPrompt(.block, picture: "compat-permission-\(kind).png")
            let value = await outcome(kind, seconds: 4)
            _ = try? await evaluate(controller, "window.compat('\(kind)')", userGesture: true)
            let again = await outcome(kind, seconds: 4)
            let askedAgain = await waitUntil(.seconds(1)) { controller.permissionPrompt != nil }
            if askedAgain { controller.answerPermission(.dismiss) }
            results[kind] = .string("bar \(asked) → \(value); again \(again), asked again \(askedAgain)")
            if asked != kind || !value.hasPrefix("NotAllowedError") || !again.hasPrefix("NotAllowedError") || askedAgain {
                mediaFailures.append("\(kind): bar \(asked) → \(value); again \(again), asked again \(askedAgain)")
            }
        }
        check("compat: camera and microphone are asked in the panel, and a block is kept for the site", mediaFailures.isEmpty,
              mediaFailures.isEmpty ? "both blocked from the bar, then refused without asking" : mediaFailures.joined(separator: "; "))

        // Other apps' addresses, clicked as a person clicks, by Chrome's rules: a mail link opens the mail app without
        // asking, from a new-window link too (no tab is left); a phone link asks "Open FaceTime?", Cancel opens
        // nothing, and Open with "Always allow" opens it and lets the next open without asking; an address no app
        // opens does nothing. What the agent's input leads to asks the person even then. Nothing opens for real.
        func clickLink(_ selector: String) async {
            if let point = try? await center(controller, selector) { click(view, at: point) }
        }
        func launches(after count: Int) async -> [String] {
            _ = await waitUntil(.seconds(2)) { launched.count > count }
            try? await Task.sleep(for: .milliseconds(300))
            return Array(launched.dropFirst(count))
        }
        func isRefused(_ url: String) -> Bool {
            controller.notice == L10n.format("Blocked %@: only http, https, file, about and data addresses open here.", url)
        }
        var appSteps: [String] = [], appFailures: [String] = []
        func step(_ name: String, _ ok: Bool, _ detail: String) {
            appSteps.append("\(name): \(detail)")
            if !ok { appFailures.append("\(name): \(detail)") }
        }
        var mark = launched.count
        await clickLink("#mailto")
        var opened = await launches(after: mark)
        let mailRefused = isRefused("mailto:qa@example.com")
        step("mail link", opened == ["mailto:qa@example.com"] && controller.externalAppQuestion == nil && !mailRefused,
             "opened \(opened), bar \(controller.externalAppQuestion?.app ?? "none"), notice \(controller.notice ?? "none")")
        let tabsBeforeBlank = client.tabs(forSession: session).count
        mark = launched.count
        await clickLink("#mailto-blank")
        opened = await launches(after: mark)
        step("mail link to a new tab", opened == ["mailto:qa-blank@example.com"] && client.tabs(forSession: session).count == tabsBeforeBlank,
             "opened \(opened), tabs \(tabsBeforeBlank) → \(client.tabs(forSession: session).count)")
        mark = launched.count
        await clickLink("#tel")
        let phoneAsked = await waitUntil(.seconds(3)) { controller.externalAppQuestion != nil }
        let phoneQuestion = controller.externalAppQuestion
        let phoneRefused = isRefused("tel:+15555550100")
        capturePanel(view, named: "compat-external-app.png")
        controller.answerExternalApp(open: false)
        try? await Task.sleep(for: .milliseconds(500))
        step("phone link, Cancel", phoneAsked && phoneQuestion?.offersAlwaysAllow == true && phoneQuestion?.byAgent == false && launched.count == mark,
             "asked \(phoneAsked): “Open \(phoneQuestion?.app ?? "?")?” from \(phoneQuestion?.origin ?? "?"), always-allow box \(phoneQuestion?.offersAlwaysAllow ?? false), "
                + "opened \(launched.dropFirst(mark))")
        await clickLink("#tel")
        let askedAgain = await waitUntil(.seconds(3)) { controller.externalAppQuestion != nil }
        controller.alwaysAllowExternalApp = true
        controller.answerExternalApp(open: true)
        opened = await launches(after: mark)
        step("phone link, Open with Always allow", askedAgain && opened == ["tel:+15555550100"], "asked \(askedAgain), opened \(opened)")
        mark = launched.count
        await clickLink("#tel")
        opened = await launches(after: mark)
        step("phone link always allowed", opened == ["tel:+15555550100"] && controller.externalAppQuestion == nil,
             "opened \(opened), bar \(controller.externalAppQuestion?.app ?? "none")")
        mark = launched.count
        await clickLink("#no-app")
        try? await Task.sleep(for: .seconds(1))
        step("an address no app opens", launched.count == mark && controller.externalAppQuestion == nil && !isRefused("yardlet-qa-no-app:test"),
             "opened \(launched.dropFirst(mark)), bar \(controller.externalAppQuestion?.app ?? "none"), notice \(controller.notice ?? "none")")
        // The agent clicks the always-allowed phone link: the person is asked, and the agent hears that only they answer.
        mark = launched.count
        _ = await agentTools.run(tool: AgentToolCatalog.evaluate, arguments: .object([
            "function": .string("() => { document.getElementById('tel').click(); return 'clicked' }")]), sessionID: session)
        let agentAsked = await waitUntil(.seconds(3)) { controller.externalAppQuestion?.byAgent == true }
        try? await Task.sleep(for: .milliseconds(300))
        let agentHeardApp = agentText(await agentTools.run(tool: AgentToolCatalog.consoleMessages, arguments: .object([:]), sessionID: session))
        controller.answerExternalApp(open: false)
        step("the agent's click on an always-allowed link", agentAsked && launched.count == mark && agentHeardApp.contains("only the person can answer"),
             "asked the person \(agentAsked), opened \(launched.dropFirst(mark)), the agent heard: \(agentHeardApp.suffix(220))")
        results["externalApps"] = .string(appSteps.joined(separator: "; "))
        check("compat: a mail or phone link is not refused as an address the browser does not open", !mailRefused && !phoneRefused,
              "mail refused \(mailRefused), phone refused \(phoneRefused)")
        check("compat: other apps' addresses follow Chrome: mail opens, others ask, Always allow is kept, the agent's input asks the person",
              appFailures.isEmpty, (appFailures.isEmpty ? appSteps : appFailures).joined(separator: "; "))

        results["windowOwners"] = await exerciseChromiumWindowOwners(controller, view)

        // HTTP Basic authentication: Chromium asks in a window of its own, as for passkeys. The agent hears it as
        // the site's sign-in window (before 2026-10-25 its tools called every such window a passkey dialog), and
        // closing it from the agent cancels the sign-in.
        let textsBefore = hostWindowTexts().count
        await go(base + "basic-auth", seconds: 4)
        let authTexts = hostWindowTexts().dropFirst(textsBefore).joined(separator: " / ")
        results["basicAuth"] = .string("\(state()); host window: \(authTexts.split(separator: "\n").prefix(6).joined(separator: " "))")
        let signInWindow = client.chromiumWindowTitles
        let heard = agentText(await agentTools.run(tool: AgentToolCatalog.consoleMessages, arguments: .object([:]), sessionID: session))
        let closedByAgent = agentText(await agentTools.run(tool: AgentToolCatalog.handleDialog,
                                                           arguments: .object(["accept": .bool(false)]), sessionID: session))
        let windowGone = await waitUntil(.seconds(3)) { self.client.chromiumWindowTitles.isEmpty }
        results["signInWindowForTheAgent"] = .string("windows \(signInWindow); heard: \(heard.suffix(400)); closed: \(closedByAgent); gone \(windowGone)")
        check("compat: the agent hears Chromium's sign-in window as a sign-in, not a passkey dialog",
              !signInWindow.isEmpty && !heard.contains("passkey") && heard.contains("sign-in") && windowGone,
              "windows \(signInWindow); heard: \(heard.suffix(300)); closed: \(closedByAgent); gone \(windowGone)")

        // A PDF opens in Chromium's viewer.
        let filesBeforePDF = downloaded()
        await go(base + "compat/doc.pdf", seconds: 5)
        // Chromium's viewer names the tab after the file; the blocked viewer left the address as its title.
        _ = await waitUntil(.seconds(5)) { controller.title == "doc.pdf" }
        let viewer = controller.title == "doc.pdf"
        let pdfDownloaded = downloaded().subtracting(filesBeforePDF).sorted()
        capturePanel(view, named: "compat-pdf.png")
        results["pdf"] = .string("\(state()); downloaded \(pdfDownloaded)")
        check("compat: a PDF opens in Chromium's viewer", viewer && controller.notice == nil && pdfDownloaded.isEmpty,
              "title \"\(controller.title)\", notice \(controller.notice ?? "none"), downloaded \(pdfDownloaded)")

        // A self-signed certificate: Chromium's warning page shows, not the panel's card, and its
        // Proceed goes on to the page.
        await go(tlsOrigin + "/compat", seconds: 4)
        let warning = controller.title
        let card = controller.errorMessage
        capturePanel(view, named: "compat-certificate.png")
        let proceed = (try? await evaluate(controller, """
            (() => { document.getElementById('details-button')?.click();
                     const link = document.getElementById('proceed-link');
                     if (!link) return 'no proceed link'; link.click(); return 'clicked' })()
            """, userGesture: true)) ?? "?"
        let proceeded = await waitUntil(.seconds(6)) { controller.title == "Compat" && !controller.isLoading }
        results["certificateError"] = .string("warning \"\(warning)\", card \(card ?? "none"), proceed \(proceed) → \(state())")
        check("compat: a certificate error shows Chromium's warning page and Proceed goes on", card == nil && proceeded,
              "title \"\(warning)\", card \(card ?? "none"), proceed \(proceed), then \(state())")

        // Closing a tab whose page asks before it is left, as a person closes it: Chrome's "Leave site?" asks
        // first, Cancel keeps the tab and its page, and Leave closes it in the host. Before 2026-10-25 the tab left
        // the panel at once and the host answered the page's question itself.
        await go(compatPage, title: "Compat")
        _ = try? await evaluate(controller, "window.onbeforeunload = e => { e.preventDefault(); e.returnValue = '' }; 'ok'", userGesture: true)
        let closing = controller.tab?.id ?? -1
        let closingKey = controller.key
        let logPath = MacBrowserHost.shared.paths.log
        // The QA home's host.log keeps earlier runs, whose tabs had the same numbers: only what follows counts.
        let logStart = ((try? String(contentsOf: logPath, encoding: .utf8)) ?? "").utf8.count
        func logSinceClose() -> String {
            String(decoding: ((try? String(contentsOf: logPath, encoding: .utf8)) ?? "").utf8.dropFirst(logStart), as: UTF8.self)
        }
        func sheetText() -> String {
            controller.javaScriptDialog.map { BrowserHostPaneController.dialogTitle($0) + " / " + $0.message } ?? ""
        }
        func isOpen() -> Bool { client.tab(key: closingKey, forSession: session) != nil }
        controller.onCloseTab?(closingKey)
        let asked = await waitUntil(.seconds(5)) { controller.javaScriptDialog?.kind == .beforeUnload }
        let question = sheetText()
        capturePanel(view, named: "compat-leave-site.png")
        let cancelled = asked ? await answerDialog(controller, button: L10n.string("Cancel")) : false
        try? await Task.sleep(for: .milliseconds(800))
        let kept = isOpen() && controller.key == closingKey
        controller.onCloseTab?(closingKey)
        let left = await answerDialog(controller, button: L10n.string("Leave"))
        let closedInHost = await waitUntil(.seconds(5)) { logSinceClose().contains("browser closed tab=\(closing)\n") }
        let gone = await waitUntil(.seconds(3)) { !isOpen() }
        results["beforeunloadOnTabClose"] = .string("asked \(asked) “\(question)”, cancel \(cancelled) → kept \(kept), "
            + "leave \(left) → browser closed \(closedInHost), gone \(gone)")
        check("compat: closing a tab whose page asks before it is left asks “Leave site?”, and Cancel keeps it",
              asked && cancelled && kept && left && closedInHost && gone,
              "asked \(asked) “\(question)”, cancel \(cancelled) → kept \(kept), leave \(left) → browser closed \(closedInHost), gone \(gone)")

        record["compat"] = .object(results)
        let lines = results.keys.sorted().map { "\($0): \(results[$0]?.stringValue ?? results[$0]?.readableText ?? "")" }
        check("compat observed", true, lines.joined(separator: " | "))
    }

    /// Chromium's windows belong to their tab (BROWSER_HOST section 3, "Chromium's windows and tabs"), shown with HTTP
    /// authentication's sign-in window, a web-modal dialog of its tab as the passkey dialog is: another task's window is
    /// not in this task's results and this task's agent cannot close it; this task's tabs and the person's panel take
    /// clicks, typing and moves meanwhile, the tab under the window takes none; a window over a tab no panel shows waits
    /// past the screens and its task's panel is set to show the tab; the panel that shows the tab shows the window over
    /// it, in front of the panel's window, and in front again after a click in Yardlet's window; the window goes and comes
    /// with its tab; each task's agent closes its own window alone.
    private func exerciseChromiumWindowOwners(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async -> JSONValue {
        let agentTools = BrowserAgentTools(usesMacEditingCommands: true, tabs: BrowserAgentTabs { MacBrowserHost.shared.client })
        let presenter = MacBrowserHost.shared.chromiumWindows
        func run(_ tool: String, _ arguments: [String: JSONValue] = [:], as task: UUID) async -> String {
            let result = await agentTools.run(tool: tool, arguments: .object(arguments), sessionID: task)
            return result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: " ")
        }
        func evaluate(_ tab: BrowserTab, _ expression: String) async -> String {
            let result = try? await tab.devTools.send("Runtime.evaluate", ["expression": .string(expression), "returnByValue": .bool(true)])
            return result?["result"]?["value"]?.stringValue ?? result?["result"]?["value"]?.readableText ?? ""
        }
        func window(over tab: BrowserTab) -> BrowserChromiumWindow? { client.chromiumWindows.first { $0.tab == tab.id } }
        func placement(over tab: BrowserTab) -> BrowserChromiumWindowPlacement? {
            window(over: tab).flatMap { window in presenter.placements.first { $0.window == window.id } }
        }
        /// Window `upper` is in front of window `lower`, as the window server orders them (metadata only).
        func inFront(_ upper: Int, of lower: Int) -> Bool {
            let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
            let numbers = list.compactMap { $0[kCGWindowNumber as String] as? Int }
            guard let upperIndex = numbers.firstIndex(of: upper), let lowerIndex = numbers.firstIndex(of: lower) else { return false }
            return upperIndex < lowerIndex
        }
        func match(_ pattern: String, in text: String) -> String? {
            guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
            return String(text[range]).components(separatedBy: "ref=").last?.trimmingCharacters(in: CharacterSet(charactersIn: "]"))
        }
        func windows() -> String {
            client.chromiumWindows.map { "\($0.title) #\($0.id) over \($0.tab.map(String.init) ?? "unknown")" }.joined(separator: ", ")
        }
        var steps: [String] = [], failures: [String] = []
        func step(_ name: String, _ ok: Bool, _ detail: String) {
            steps.append("\(name) \(ok ? "ok" : "FAILED"): \(detail)")
            if !ok { failures.append("\(name): \(detail)") }
        }
        let html = "<title>Owner QA</title><body style='margin:0'><input id=q style='position:fixed;left:10px;top:10px;width:300px;"
            + "height:30px'><button id=b style='position:fixed;left:10px;top:60px;width:120px;height:30px' "
            + "onclick=\"document.title='clicked'\">Press</button><script>window.downs=0;addEventListener('mousedown',()=>window.downs++)</script>"
        let page = "data:text/html," + (html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        let session = self.session, other = UUID()
        let model = BrowserHostQAFixture.model
        /// The task's panel the app left on a tab: where the person finds what waits when they come to the task.
        func panelTabKey(_ task: UUID) -> UUID? {
            model.flatMap { TaskSurfaceNavigationProjection.browserKey(inTab: $0.taskWorkspaces.state(for: task).panels.trailingSurfaceID) }
        }
        defer { client.closeTabs(forSession: other) }

        // Another task's tab, in the background as the agent's are, asks for a sign-in.
        guard let otherTab = try? client.newTab(forSession: other, url: page, viewport: .offscreenDefault, select: false) else {
            check("compat: Chromium's windows belong to their tab", false, "no tab for another task")
            return .null
        }
        _ = await waitUntil(.seconds(10)) { otherTab.title == "Owner QA" }
        otherTab.send(.navigate(tab: otherTab.id, url: base + "basic-auth?other-task"))
        let otherShown = await waitUntil(.seconds(8)) { window(over: otherTab) != nil }
        step("the window's tab", otherShown, "windows \(windows()); the other task's tab \(otherTab.id), the panel's \(controller.tab?.id ?? -1)")
        let waits = await waitUntil(.seconds(3)) { model?.browserWaits[other]?.tabKey == otherTab.key }
        step("a window over a tab no panel shows waits, its task waits in the browser, and its panel is set to show the tab",
             otherShown && placement(over: otherTab) == nil && waits && panelTabKey(other) == otherTab.key
                && model?.taskAttentionDetails[other]?.browserWait?.kind == .signIn,
             "placed \(placement(over: otherTab) != nil), the task's wait \(String(describing: model?.browserWaits[other])), "
                + "its panel on \(panelTabKey(other).map { $0 == otherTab.key ? "the tab" : "another tab" } ?? "nothing")")

        // This task's agent: the window is in none of its results, and it cannot close it.
        let heard = await run(AgentToolCatalog.consoleMessages, as: session)
        let refused = await run(AgentToolCatalog.handleDialog, ["accept": .bool(false)], as: session)
        try? await Task.sleep(for: .seconds(1))
        step("another task's agent neither hears of it nor closes it",
             !heard.contains("sign-in") && refused.contains("No JavaScript dialog is open") && window(over: otherTab) != nil,
             "heard: \(heard.suffix(200)); browser_handle_dialog: \(refused.suffix(160)); windows \(windows())")
        let ownerHeard = await run(AgentToolCatalog.consoleMessages, as: other)
        step("its own task's agent hears of it over its tab",
             ownerHeard.contains("sign-in window") && ownerHeard.contains("over tab \(otherTab.id)") && ownerHeard.contains("browser_handoff"),
             "heard: \(ownerHeard.suffix(420))")

        // This task's agent works in a tab of its own meanwhile: a click, typing, a move.
        let opened = await run(AgentToolCatalog.tabNew, as: session)
        let own = match(#""tabId":"[0-9]+"#, in: opened).flatMap { $0.split(separator: "\"").last.map(String.init) } ?? ""
        let loaded = await run(AgentToolCatalog.navigate, ["tabId": .string(own), "url": .string(page)], as: session)
        let snapshot = await run(AgentToolCatalog.snapshot, ["tabId": .string(own)], as: session)
        let textbox = match(#"textbox[^\n]*\[ref=@e[0-9]+\]"#, in: snapshot) ?? ""
        let button = match(#"button "Press"[^\n]*\[ref=@e[0-9]+\]"#, in: snapshot) ?? ""
        let clicked = await run(AgentToolCatalog.click, ["tabId": .string(own), "ref": .string(button)], as: session)
        let typed = await run(AgentToolCatalog.type, ["tabId": .string(own), "ref": .string(textbox), "text": .string("typed")], as: session)
        let values = await run(AgentToolCatalog.evaluate, ["tabId": .string(own),
                                                          "function": .string("() => document.title + '|' + document.getElementById('q').value")], as: session)
        let moved = await run(AgentToolCatalog.navigate, ["tabId": .string(own), "url": .string(base)], as: session)
        step("this task's agent clicks, types and moves its own tab meanwhile",
             values.contains("clicked|typed") && moved.contains("Loaded") && !values.contains("sign-in"),
             "tab \(own) \(loaded.prefix(60)); click \(button): \(clicked.prefix(80)); type \(textbox): \(typed.prefix(80)); "
                + "page: \(values.prefix(80)); move: \(moved.prefix(80))")
        // The person's panel takes a click meanwhile.
        _ = try? await self.evaluate(controller, "window.__downs = 0; addEventListener('mousedown', () => window.__downs++); 'ok'")
        click(view, at: NSPoint(x: 40, y: 40))
        try? await Task.sleep(for: .milliseconds(500))
        let downs = (try? await self.evaluate(controller, "String(window.__downs)")) ?? ""
        step("the person's panel takes a click meanwhile", downs == "1", "mousedowns \(downs)")
        // The tab under the window takes no input, as in Chrome (Chromium's web-modal dialog): the agent's click, typing and
        // key press are not sent and fail saying why; reading the page still works. Chromium shows the sign-in window over
        // a blank page of its own (chrome-error://chromewebdata/), which it has committed by then, so the counts start there.
        _ = await evaluate(otherTab, "window.downs = 0; window.keys = 0; addEventListener('mousedown', () => window.downs++); "
            + "addEventListener('keydown', () => window.keys++); 'ok'")
        let otherTabID = JSONValue.string(String(otherTab.id))
        var refusals: [String] = []
        for (tool, arguments) in [(AgentToolCatalog.click, ["tabId": otherTabID, "x": .number(60), "y": .number(75)]),
                                  (AgentToolCatalog.type, ["tabId": otherTabID, "ref": .string("@e1"), "text": .string("x")]),
                                  (AgentToolCatalog.pressKey, ["tabId": otherTabID, "key": .string("Enter")])] {
            let result = await agentTools.run(tool: tool, arguments: .object(arguments), sessionID: other)
            let said = result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: " ")
            if !(result.isError && said.contains("was not sent to tab \(otherTab.id)") && said.contains("sign-in window")
                 && said.contains("browser_handle_dialog") && said.contains("browser_handoff")) {
                refusals.append("\(tool): \(said.prefix(300))")
            }
        }
        let counts = await evaluate(otherTab, "window.downs + ',' + window.keys")
        let ownerRead = await run(AgentToolCatalog.snapshot, ["tabId": otherTabID], as: other)
        step("the tab under the window takes no input, and the agent's input to it fails saying why",
             refusals.isEmpty && counts == "0,0" && !ownerRead.contains("was not sent"),
             "refused: \(refusals.isEmpty ? "click, typing and key press, each naming the sign-in window" : refusals.joined(separator: "; ")); "
                + "mousedowns,keydowns \(counts); snapshot read: \(ownerRead.prefix(80))")

        // A tab of this task behind the panel's asks for a sign-in: its window waits until the panel shows the tab.
        let panelTab = controller.tab
        guard let behind = try? client.newTab(forSession: session, url: page, viewport: .offscreenDefault, select: false) else {
            check("compat: Chromium's windows belong to their tab", false, "no tab behind the panel's")
            return .null
        }
        _ = await waitUntil(.seconds(10)) { behind.title == "Owner QA" }
        behind.send(.navigate(tab: behind.id, url: base + "basic-auth?behind"))
        let behindShown = await waitUntil(.seconds(8)) { window(over: behind) != nil }
        _ = await waitUntil(.seconds(3)) { controller.workspace.browserTabs.tab(behind.key)?.wait != nil }
        step("a window over a tab behind the panel's waits, the panel stays on its tab, and the tab is marked",
             behindShown && placement(over: behind) == nil && controller.tab === panelTab
                && controller.workspace.browserTabs.tab(behind.key)?.wait?.kind == .signIn,
             "windows \(windows()); placed \(placement(over: behind) != nil); the panel's tab marked "
                + "\(String(describing: controller.workspace.browserTabs.tab(behind.key)?.wait))")
        controller.onShowTab?(behind.key)
        let panelShows = await waitUntil(.seconds(5)) { controller.tab === behind }
        _ = await waitUntil(.seconds(5)) { placement(over: behind)?.frame != nil }
        let panelWindow = view.window?.windowNumber ?? 0
        let panelRect = view.window.map { $0.convertToScreen(view.convert(view.bounds, to: nil)) } ?? .zero
        let placed = placement(over: behind)
        let id = window(over: behind)?.id ?? 0
        let frontAfterShow = await waitUntil(.seconds(3)) { inFront(id, of: panelWindow) }
        step("the panel that shows the tab shows the window over it, in front of the panel's window",
             panelShows && placed?.frame == BrowserRect(x: panelRect.minX, y: panelRect.minY, width: panelRect.width, height: panelRect.height)
                && placed?.above == panelWindow && frontAfterShow,
             "panel shows the tab \(panelShows); placement \(placed.map { "\($0)" } ?? "none") for the panel at \(panelRect) in window "
                + "\(panelWindow); in front \(frontAfterShow)")
        // The person's click on the page under the window does not reach it either.
        _ = await evaluate(behind, "window.downs = 0; addEventListener('mousedown', () => window.downs++); 'ok'")
        click(view, at: NSPoint(x: 40, y: 40))
        try? await Task.sleep(for: .milliseconds(500))
        let personDowns = await evaluate(behind, "String(window.downs)")
        step("the person's click on the page under the window does not reach it", personDowns == "0", "mousedowns \(personDowns)")
        // A click in Yardlet's window brings that window in front of the host's (here without the click itself, which
        // would take the person's screen); the window comes back in front of it.
        let presentsBefore = presenter.presentCount
        view.window?.orderFrontRegardless()
        let wentBehind = await waitUntil(.seconds(2)) { inFront(panelWindow, of: id) }
        let presentsMeanwhile = presenter.presentCount - presentsBefore
        presenter.yardletWasClicked()
        let frontAgain = await waitUntil(.seconds(3)) { inFront(id, of: panelWindow) }
        step("in front of Yardlet's window again after a click in it", wentBehind && frontAgain,
             "Yardlet's window in front after the click \(wentBehind) (placed \(presentsMeanwhile) times meanwhile), the window in "
                + "front again \(frontAgain)")
        // The window goes with its tab and comes back with it.
        if let panelTab { controller.onShowTab?(panelTab.key) }
        let wentWithTab = await waitUntil(.seconds(5)) { window(over: behind) == nil }
        controller.onShowTab?(behind.key)
        let cameBack = await waitUntil(.seconds(5)) { window(over: behind) != nil && placement(over: behind)?.frame != nil }
        step("the window goes and comes with its tab", wentWithTab && cameBack, "gone with the tab \(wentWithTab), back with it \(cameBack)")

        // Each task's agent closes its own window alone.
        otherTab.noteAgentActivity()
        _ = await waitUntil(.seconds(3)) { window(over: otherTab) != nil }
        let closedOwn = await run(AgentToolCatalog.handleDialog, ["accept": .bool(false)], as: session)
        let ownGone = await waitUntil(.seconds(3)) { window(over: behind) == nil }
        let otherStays = window(over: otherTab) != nil
        step("this task's agent closes its own window, not another task's", ownGone && otherStays,
             "\(closedOwn.prefix(160)); its window gone \(ownGone), the other task's stays \(otherStays)")
        let closedOther = await run(AgentToolCatalog.handleDialog, ["accept": .bool(false)], as: other)
        let otherGone = await waitUntil(.seconds(3)) { window(over: otherTab) == nil }
        step("the other task's agent closes its own", otherGone, "\(closedOther.prefix(160)); gone \(otherGone)")

        if let panelTab {
            controller.onShowTab?(panelTab.key)
            _ = await waitUntil(.seconds(5)) { controller.tab === panelTab }
        }
        behind.close()
        client.tabs(forSession: session).first { String($0.id) == own }?.close()
        try? await Task.sleep(for: .milliseconds(500))
        check("compat: Chromium's windows belong to their tab, and show over it", failures.isEmpty,
              (failures.isEmpty ? steps : failures).joined(separator: "; "))
        return .array(steps.map { .string($0) })
    }

    /// Lines the DEBUG host wrote for its own windows (`host-windows/windows.jsonl`).
    private func hostWindowLines() -> [String] {
        let text = (try? String(contentsOf: output.appending(path: "host-windows/windows.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    /// What the host's windows said, oldest first (`host-windows/window-text-N.txt`).
    private func hostWindowTexts() -> [String] {
        let folder = output.appending(path: "host-windows")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
            .filter { $0.hasPrefix("window-text-") }
            .sorted { (Int($0.dropFirst(12).dropLast(4)) ?? 0) < (Int($1.dropFirst(12).dropLast(4)) ?? 0) }
        return names.compactMap { try? String(contentsOf: folder.appending(path: $0), encoding: .utf8) }
    }

    /// On-screen windows front to back, as the window server orders them: this app's ("yardlet"), the
    /// host's ("host") and how many others came between (metadata only; no screen recording needed).
    private static func windowOrder(hostPID: Int?) -> String {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return "unknown" }
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        var parts: [String] = []
        var others = 0
        for window in list where (window[kCGWindowLayer as String] as? Int) == 0 {
            let owner = window[kCGWindowOwnerPID as String] as? Int
            let bounds = window[kCGWindowBounds as String] as? [String: Any]
            let size = "\(bounds?["Width"] ?? 0)x\(bounds?["Height"] ?? 0)"
            if owner == me || owner == hostPID {
                if others > 0 { parts.append("\(others) other"); others = 0 }
                parts.append((owner == me ? "yardlet " : "host ") + size)
            } else {
                others += 1
            }
        }
        return parts.joined(separator: " > ")
    }

    /// The side panel's browser tab titles, in the panel's order.
    private func panelBrowserTitles(_ workspace: TaskWorkspaceState) -> [String] {
        TaskSurfaceNavigationProjection.browserKeys(in: workspace.panels).map {
            TaskSidePanelTabs.browserTab($0, in: workspace.browserTabs).title
        }
    }

    /// The task's browser tabs as side-panel tabs of their own (docs/BROWSER_HOST.md, section 3, "Tabs"): a new tab (⌘T) is a
    /// panel tab that gets the pane's frames while the old one stops getting them; a tab the agent opens
    /// behind joins the panel's tabs without taking the pane; a page's icon reaches its tab; showing the
    /// first tab again shows its page; the agent fronting a tab shows it; the agent closing it moves
    /// the panel to the tab the browser fronted; ⌘⇧T opens the closed tab again as a new panel tab; and
    /// closing a tab moves the panel to the tab used before.
    private func exerciseTabs(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async throws {
        guard let first = controller.tab, let router = MacBrowserHost.shared.process?.frameRouter else { return }
        let workspace = controller.workspace
        let firstKey = controller.key
        func shows(_ key: UUID) -> Bool {
            workspace.panels.trailingSurfaceID == TaskSurfaceNavigationProjection.browserTabID(key)
        }
        controller.onNewTab?()
        let fronted = await waitUntil(.seconds(5)) {
            controller.key != firstKey && controller.tab != nil && controller.tab !== first && controller.isEditingAddress
        }
        guard let second = controller.tab else { return check("tabs: side-panel tabs", false, "no new tab") }
        let secondKey = controller.key
        controller.isEditingAddress = false
        controller.addressInput = base + "second"
        controller.submitAddress()
        let loaded = await waitUntil(.seconds(10)) { controller.title == "Second" }
        let framesMoved = router.display(for: second.id) === view.frameDisplay && router.display(for: first.id) == nil
        let painted = await waitUntil(.seconds(5)) { view.viewSurface != nil && view.tabID == second.id }
        let panelTwo = panelBrowserTitles(workspace) == ["Browser QA", "Second"] && shows(secondKey)
            && second.key == secondKey && client.tab(forSession: session) === second
        let icon = await waitUntil(.seconds(10)) { workspace.browserTabs.tab(secondKey)?.favicon != nil }

        // The agent opens a tab behind the panel's.
        let agentTab = try client.newTab(forSession: session, url: base + "a11y", viewport: .offscreenDefault, select: false)
        let agentJoined = await waitUntil(.seconds(10)) {
            self.panelBrowserTitles(workspace) == ["Browser QA", "Second", "Accessibility QA"]
                && workspace.browserTabs.tab(agentTab.key)?.favicon != nil
        }
        let panelKept = controller.tab === second && shows(secondKey)
        try? await Task.sleep(for: .milliseconds(300))
        capturePanel(view, named: "tabs-panel.png")

        controller.onShowTab?(firstKey)
        let back = await waitUntil(.seconds(5)) { controller.tab === first && controller.title == "Browser QA" }
        let framesBack = router.display(for: first.id) === view.frameDisplay && router.display(for: second.id) == nil
            && client.tab(forSession: session) === first

        // The agent fronts its tab (browser_tab_select): the panel, showing a browser tab, shows it.
        agentTab.select()
        let followsAgent = await waitUntil(.seconds(5)) { controller.tab === agentTab && shows(agentTab.key) }
        // The agent closes it (browser_tab_close): its panel tab goes, the panel shows the tab the
        // browser fronted in its place.
        let agentKey = agentTab.key
        agentTab.close()
        let agentClosed = await waitUntil(.seconds(5)) {
            !TaskSurfaceNavigationProjection.browserKeys(in: workspace.panels).contains(agentKey)
                && controller.tab != nil && controller.tab === self.client.tab(forSession: self.session)
        }
        func state() -> String {
            func short(_ key: UUID?) -> String { key.map { String($0.uuidString.prefix(4)) } ?? "-" }
            return "panel shows " + short(TaskSurfaceNavigationProjection.browserKey(inTab: workspace.panels.trailingSurfaceID))
                + ", pane key " + short(controller.key) + " tab \(controller.tab?.id ?? -1), engine front "
                + "\(client.tab(forSession: session)?.id ?? -1) " + short(client.tab(forSession: session)?.key)
        }
        let afterAgentClose = state()
        // ⌘⇧T opens it again as a new panel tab, shown.
        controller.reopenClosedTab()
        let reopened = await waitUntil(.seconds(10)) {
            self.panelBrowserTitles(workspace).last == "Accessibility QA" && controller.title == "Accessibility QA"
                && controller.key != agentKey
        }
        let reopenedKey = controller.key
        capturePanel(view, named: "tabs-panel-reopened.png")
        // What the engine and the panel held then, for reading a failure.
        func short(_ key: UUID) -> String { String(key.uuidString.prefix(4)) }
        let afterReopen = "engine " + client.tabs(forSession: session).map {
            "\($0.id):\(short($0.key)):\($0.title):\(URL(string: $0.currentURL ?? "")?.path() ?? "-")"
        }.joined(separator: " ") + "; panel " + TaskSurfaceNavigationProjection.browserKeys(in: workspace.panels).map(short)
            .joined(separator: " ") + "; shown " + short(controller.key) + " tab \(controller.tab?.id ?? -1)"
            + "; closed agent " + short(agentKey) + "; after the agent's close: " + afterAgentClose

        // Closing tabs: the panel moves to the tab used before (the reopened tab was shown after Second).
        controller.onCloseTab?(reopenedKey)
        let toUsedBefore = await waitUntil(.seconds(5)) { controller.key != reopenedKey && controller.tab != nil }
        let usedBefore = controller.key
        controller.onCloseTab?(secondKey)
        let closed = await waitUntil(.seconds(5)) {
            TaskSurfaceNavigationProjection.browserKeys(in: workspace.panels) == [firstKey] && controller.tab === first
        }
        check("tabs: side-panel tabs",
              fronted && loaded && framesMoved && painted && panelTwo && icon && agentJoined && panelKept && back
                && framesBack && followsAgent && agentClosed && reopened && toUsedBefore && closed
                && client.tabs(forSession: session).count == 1,
              "new tab in front \(fronted), loaded \(loaded), frames to the new tab \(framesMoved), painted \(painted), "
                + "panel tabs \(panelTwo), icon \(icon), agent tab joined \(agentJoined) behind \(panelKept), "
                + "back \(back) frames back \(framesBack), follows the agent's front \(followsAgent), "
                + "agent close \(agentClosed), ⌘⇧T \(reopened), close → used before \(toUsedBefore) "
                + "(\(usedBefore == firstKey ? "Browser QA" : usedBefore == secondKey ? "Second" : "other")), closed \(closed), "
                + "titles \(panelBrowserTitles(workspace)); after ⌘⇧T: \(afterReopen)")
    }

    /// Yardlet quitting with the task's tabs open, as `MacBrowserHost.terminateForApplicationShutdown`
    /// ends the host: the host closes each tab on its way out, and the panel keeps them, each to open
    /// again at its page at the next launch (2026-10-25, the panel lost them).
    private func exerciseQuitKeepsTabs(_ workspace: TaskWorkspaceState) async {
        let keys = TaskSurfaceNavigationProjection.browserKeys(in: workspace.panels)
        let open = client.tabs(forSession: session).map(\.key)
        // How many tabs the host reports closed on its way out, which the panel must not take for closes.
        var closes = 0
        if let process = MacBrowserHost.shared.process {
            let forward = process.eventHandler
            process.eventHandler = { event in
                if case .closed = event { closes += 1 }
                forward?(event)
            }
        }
        client.terminateHost()
        let ended = await waitUntil(.seconds(10)) { !self.client.isHostRunning }
        // What the host reported on its way out reaches the main thread once termination stops blocking it.
        try? await Task.sleep(for: .milliseconds(500))
        let kept = TaskSurfaceNavigationProjection.browserKeys(in: workspace.panels)
        let remembered = client.rememberedTabs(forSession: session)?.keys ?? []
        check("tabs: quitting keeps the panel's tabs", ended && !open.isEmpty && kept == keys && remembered == open,
              "host ended \(ended) (\(client.lastTermination ?? "running")), closes reported on the way out \(closes), "
                + "panel tabs \(keys.count) → \(kept.count), open \(open.count), remembered \(remembered.count)")
    }

    // MARK: Accessibility

    /// The page's accessibility as VoiceOver would read it, asked from the app itself (no
    /// accessibility permission needed): lazy enabling, the elements of a real page, frames,
    /// actions, a large page and turning off when unused.
    private func exerciseAccessibility(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async throws {
        defer { controller.eventObserver = nil }
        do {
            try await accessibilityChecks(controller, view)
        } catch {
            check("accessibility", false, error.localizedDescription)
        }
        // Later steps (and the crash drill's reopen) expect the QA page.
        try await load(controller, base, title: "Browser QA")
    }

    private func accessibilityChecks(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async throws {
        guard let bridge = controller.accessibility else { throw QAFailure("no accessibility bridge") }
        let voiceOver = NSWorkspace.shared.isVoiceOverEnabled
        record["voiceOverRunning"] = .bool(voiceOver)
        // Another accessibility client on this Mac may ask first; the tree must then say who asked.
        let asked = ["voiceOver", "children", "hitTest", "focusedElement"]
        check("accessibility stays off until something asks",
              !bridge.isEnabled || asked.contains(bridge.enableReason ?? ""),
              "VoiceOver \(voiceOver), enabled \(bridge.isEnabled) by \(bridge.enableReason ?? "nothing"), tree changes \(bridge.statistics.treeChanges)")
        record["accessibilityOnBeforeQA"] = .string(bridge.isEnabled ? bridge.enableReason ?? "?" : "off")

        var sentBytes = 0
        var largestSent = 0
        var lastScroll: (Double, Double)?
        var measureSizes = true
        var largeNodesReceived = 0
        controller.eventObserver = { event in
            if case .accessibilityTree(_, let change) = event {
                // Re-encoding a large page's change would itself stall the main thread; the host
                // logs those sizes instead.
                if measureSizes {
                    let size = (try? JSONEncoder().encode(change).count) ?? 0
                    sentBytes += size
                    largestSent = max(largestSent, size)
                } else {
                    largeNodesReceived += change.updates.reduce(0) { $0 + $1.nodes.count }
                }
            }
            if case .scrollOffset(_, let x, let y) = event { lastScroll = (x, y) }
        }

        try await load(controller, base + "a11y", title: "Accessibility QA")
        let askedAt = DispatchTime.now().uptimeNanoseconds
        _ = view.accessibilityChildren()
        let ready = await waitUntil(.seconds(10)) { self.find(bridge, role: "button", label: "Bottom button") != nil }
        record["accessibilityFirstTreeMs"] = .number(Self.milliseconds(since: askedAt))
        check("first accessibility query turns the tree on", ready && bridge.isEnabled,
              "enabled \(bridge.isEnabled), nodes \(bridge.tree.nodeCount)")
        _ = await waitUntil(.seconds(5)) { self.find(bridge, role: "button", label: "Inner button") != nil }

        let dump = dumpAccessibility(of: view)
        try write(dump, to: "accessibility-dump.json")
        let lines = Self.flatten(dump)
        let expected: [(String, String)] = [
            ("AXHeading", "Accessibility QA"), ("AXLink", "Second page"), ("AXTextField", "Email"),
            ("AXCheckBox", "I agree"), ("AXRadioButton", "Small"), ("AXRadioButton", "Large"),
            ("AXPopUpButton", "Fruit"), ("AXTextArea", "Notes"), ("AXButton", "Press me"), ("AXList", ""),
            ("AXTable", "Scores"), ("AXRow", ""), ("AXCell", "Kim"), ("AXImage", "Yardlet logo"),
            ("AXButton", "Inner button"), ("AXGroup", "Primary"), ("AXStaticText", "")
        ]
        let missing = expected.filter { role, label in
            !lines.contains { $0.role == role && (label.isEmpty || $0.label == label || $0.value == label) }
        }
        let fruit = lines.first { $0.role == "AXPopUpButton" }
        check("page elements appear with their roles", missing.isEmpty && fruit?.value == "Apple",
              "missing \(missing.map { "\($0.0) \($0.1)" }), fruit value \(fruit?.value ?? "none"), elements \(lines.count)")
        record["accessibilityElements"] = .integer(Int64(lines.count))

        // Frames: the element's screen frame, back in view points, matches the page's own box.
        try await compareFrame(controller, view, bridge, label: "Positioned box", selector: "#box", check: "frame of a positioned element")
        _ = try? await evaluate(controller, "window.scrollTo(0, 200); 'ok'")
        let changes = bridge.statistics.treeChanges + bridge.statistics.locationChanges
        _ = await waitUntil(.seconds(3)) { bridge.statistics.treeChanges + bridge.statistics.locationChanges > changes }
        try? await Task.sleep(for: .milliseconds(300))
        try await compareFrame(controller, view, bridge, label: "Positioned box", selector: "#box", check: "frame after scrolling")
        check("scroll offset event in view points", lastScroll.map { abs($0.1 - 200) < 1 } ?? false,
              "last offset \(lastScroll.map { "\($0.0), \($0.1)" } ?? "none") after scrolling to 200 CSS px at zoom 1")
        try await compareFrame(controller, view, bridge, label: "Inner button", selector: "#frame", inner: "#inner",
                               check: "frame inside an iframe")
        _ = try? await evaluate(controller, "window.scrollTo(0, 0); 'ok'")
        try? await Task.sleep(for: .milliseconds(600))

        // Hit test at the button's center.
        if let press = find(bridge, role: "button", label: "Press me") {
            let frame = bridge.element(for: press).accessibilityFrame()
            let hit = view.accessibilityHitTest(NSPoint(x: frame.midX, y: frame.midY)) as? BrowserAccessibilityElement
            check("hit test finds the element under a point", hit?.key == press,
                  "frame \(frame), hit \(hit.map { "\($0.accessibilityRole()?.rawValue ?? "") \($0.accessibilityLabel() ?? "")" } ?? "none")")
        }

        // AXPress clicks the element's center.
        if let press = find(bridge, role: "button", label: "Press me") {
            _ = bridge.element(for: press).accessibilityPerformPress()
            let pressed = await waitUntilAsync(.seconds(3)) { (try? await self.evaluate(controller, "String(window.qa.presses)")) == "1" }
            check("AXPress clicks the element", pressed, "presses \((try? await evaluate(controller, "String(window.qa.presses)")) ?? "?")")
        }

        // Setting a text field's value types it (input events run) and the tree follows.
        if let email = find(bridge, role: "textField", label: "Email") {
            let element = bridge.element(for: email)
            element.setAccessibilityValue("qa@example.com")
            let typed = await waitUntilAsync(.seconds(3)) {
                (try? await self.evaluate(controller, "document.querySelector('#email').value")) == "qa@example.com"
            }
            let reflected = await waitUntil(.seconds(3)) { element.accessibilityValue() as? String == "qa@example.com" }
            let inputs = (try? await evaluate(controller, "String(window.qa.inputs)")) ?? "?"
            check("setting a text field's value", typed && reflected && inputs != "0",
                  "page value set \(typed), tree value \(element.accessibilityValue() ?? "nil"), input events \(inputs)")
        }

        // AXPress inside the iframe clicks there too.
        if let inner = find(bridge, role: "button", label: "Inner button") {
            _ = try? await evaluate(controller, "document.querySelector('#frame').contentDocument.querySelector('#inner').onclick = () => { window.qa.inner = (window.qa.inner || 0) + 1 }; 'ok'")
            _ = bridge.element(for: inner).accessibilityPerformPress()
            let pressed = await waitUntilAsync(.seconds(3)) { (try? await self.evaluate(controller, "String(window.qa.inner || 0)")) == "1" }
            check("AXPress inside an iframe", pressed, "presses \((try? await evaluate(controller, "String(window.qa.inner || 0)")) ?? "?")")
        }

        // Focus moves to a check box; the tree reports it focused.
        view.window?.makeFirstResponder(view)
        if let agree = find(bridge, role: "checkBox", label: "I agree") {
            let element = bridge.element(for: agree)
            element.setAccessibilityFocused(true)
            let focused = await waitUntil(.seconds(3)) { element.isAccessibilityFocused() }
            let active = (try? await evaluate(controller, "document.activeElement.id")) ?? ""
            let viewFocus = (view.accessibilityFocusedUIElement as? BrowserAccessibilityElement)?.key == agree
            check("focus moves to an element", focused && active == "agree" && viewFocus,
                  "tree focus \(focused), page focus \(active), view reports \(viewFocus)")
        }

        // A <select> chooses an option (the native menu is bypassed here).
        if let fruit = find(bridge, role: "comboBoxSelect", label: "Fruit") ?? find(bridge, role: "popUpButton", label: "Fruit") {
            bridge.optionsMenuOverride = { titles in titles.firstIndex(of: "Cherry") }
            let element = bridge.element(for: fruit)
            let options = bridge.tree.options(of: fruit).compactMap { bridge.tree.node($0)?.name }
            _ = element.accessibilityPerformPress()
            let chose = await waitUntil(.seconds(3)) { element.accessibilityValue() as? String == "Cherry" }
            let changesSeen = (try? await evaluate(controller, "String(window.qa.changes)")) ?? "?"
            check("a <select> offers its options and chooses one", chose && changesSeen == "1" && options == ["Apple", "Banana", "Cherry"],
                  "options \(options), value \(element.accessibilityValue() ?? "nil"), change events \(changesSeen)")
            bridge.optionsMenuOverride = nil
        }

        // AXScrollToVisible brings an element far down the page into view.
        if let bottom = find(bridge, role: "button", label: "Bottom button") {
            let element = bridge.element(for: bottom)
            element.accessibilityPerformAction(BrowserAccessibilityElement.scrollToVisible)
            let visible = await waitUntil(.seconds(3)) {
                guard let rect = bridge.viewRect(of: bottom) else { return false }
                return view.bounds.contains(NSPoint(x: rect.midX, y: rect.midY))
            }
            let scrollY = (try? await evaluate(controller, "String(Math.round(window.scrollY))")) ?? "?"
            check("scroll to visible", visible && (Double(scrollY) ?? 0) > 500,
                  "in view \(visible), scrollY \(scrollY), rect \(bridge.viewRect(of: bottom).map { "\($0)" } ?? "none")")
        }
        record["accessibilityQAPage"] = .object([
            "nodes": .integer(Int64(bridge.tree.nodeCount)), "sentBytes": .integer(Int64(sentBytes)),
            "largestChangeBytes": .integer(Int64(largestSent)),
            "applyMs": .number(bridge.statistics.applyMilliseconds),
            "slowestApplyMs": .number(bridge.statistics.slowestApplyMilliseconds)
        ])

        // A large page: tree size and the time until the whole tree is usable.
        measureSizes = false
        let applyBefore = bridge.statistics.applyMilliseconds
        let loadStarted = DispatchTime.now().uptimeNanoseconds
        // The longest the main thread was busy while the large tree arrived (decode and apply).
        var longestStall = 0.0
        let stallProbe = Task { @MainActor in
            var last = DispatchTime.now().uptimeNanoseconds
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                let now = DispatchTime.now().uptimeNanoseconds
                longestStall = max(longestStall, Double(now - last) / 1_000_000 - 10)
                last = now
            }
        }
        defer { stallProbe.cancel() }
        try await load(controller, base + "large", title: "Large page")
        let complete = await waitUntil(.seconds(30), poll: .milliseconds(250)) {
            self.find(bridge, role: "button", label: "Last button") != nil
        }
        let treeMs = Self.milliseconds(since: loadStarted)
        stallProbe.cancel()
        let walkStarted = DispatchTime.now().uptimeNanoseconds
        let exposed = bridge.tree.exposedNodes()
        let walkMs = Self.milliseconds(since: walkStarted)
        let dumpStarted = DispatchTime.now().uptimeNanoseconds
        let largeDump = Self.flatten(dumpAccessibility(of: view))
        let dumpMs = Self.milliseconds(since: dumpStarted)
        record["accessibilityLargePage"] = .object([
            "nodes": .integer(Int64(bridge.tree.nodeCount)), "exposed": .integer(Int64(exposed.count)),
            "loadToTreeMs": .number(treeMs), "nodesReceived": .integer(Int64(largeNodesReceived)),
            "applyMs": .number(bridge.statistics.applyMilliseconds - applyBefore),
            "slowestApplyMs": .number(bridge.statistics.slowestApplyMilliseconds),
            "exposedWalkMs": .number(walkMs), "fullElementDumpMs": .number(dumpMs),
            "longestMainThreadStallMs": .number(longestStall),
            "dumpedElements": .integer(Int64(largeDump.count))
        ])
        check("large page tree", complete && exposed.count > 5000,
              "nodes \(bridge.tree.nodeCount), exposed \(exposed.count), load→tree \(Int(treeMs)) ms, main-thread stall \(Int(longestStall)) ms")

        // Unused, the tree turns off; the next query turns it on with the whole tree again.
        if !voiceOver {
            let idle = BrowserHostPaneController.accessibilityIdleTimeout
            let off = await waitUntil(idle + .seconds(5)) { !bridge.isEnabled }
            let turnedOffTree = bridge.tree.isEmpty
            _ = view.accessibilityChildren()
            let back = await waitUntil(.seconds(15)) { self.find(bridge, role: "button", label: "Last button") != nil }
            check("tree turns off when unused and comes back when asked", off && turnedOffTree && back,
                  "off \(off) after \(idle), cleared \(turnedOffTree), back \(back), enables \(bridge.statistics.enableCount)")
        }
    }

    // MARK: Panel-less tab (the agent's)

    /// A tab no panel shows, used as the agent's tools use it: scroll with wheel input, then CDP
    /// calls, with idle gaps. Records the page's visibility and each call's time.
    private func exercisePanelLessTab() async {
        let session = UUID()
        guard let tab = try? client.openTab(forSession: session, url: base + "a11y", viewport: .offscreenDefault) else {
            return check("panel-less tab", false, "could not open")
        }
        defer { tab.close() }
        func timed(_ method: String, _ params: [String: JSONValue] = [:]) async -> (Double, JSONValue?) {
            let started = DispatchTime.now().uptimeNanoseconds
            let result = try? await tab.devTools.send(method, params, timeout: .seconds(20))
            return (Self.milliseconds(since: started), result)
        }
        func evaluate(_ expression: String) async -> String {
            let result = try? await tab.devTools.send("Runtime.evaluate", ["expression": .string(expression), "returnByValue": .bool(true)],
                                                    timeout: .seconds(20))
            return result?["result"]?["value"]?.stringValue ?? ""
        }
        _ = await waitUntilAsync(.seconds(15)) { await evaluate("document.readyState") == "complete" }
        client.noteAgentActivity(forSession: session)
        let visibleAtStart = await evaluate("document.visibilityState")
        var samples: [String: [Double]] = [:]
        for index in 0..<10 {
            client.noteAgentActivity(forSession: session)
            tab.send(.wheel(tab: tab.id, input: BrowserWheelInput(x: 400, y: 300, deltaX: 0, deltaY: index.isMultiple(of: 2) ? -400 : 400)))
            try? await Task.sleep(for: .milliseconds(30))
            for (name, method, params) in [
                ("evaluate", "Runtime.evaluate", ["expression": JSONValue.string("window.scrollY"), "returnByValue": .bool(true)]),
                ("layoutMetrics", "Page.getLayoutMetrics", [:]),
                ("screenshot", "Page.captureScreenshot", ["format": .string("jpeg"), "quality": .integer(40)])
            ] as [(String, String, [String: JSONValue])] {
                samples[name, default: []].append(await timed(method, params).0)
            }
            try? await Task.sleep(for: .seconds(1))
        }
        let visibleAtEnd = await evaluate("document.visibilityState")
        var summary: [String: JSONValue] = ["visibilityAtStart": .string(visibleAtStart), "visibilityAtEnd": .string(visibleAtEnd)]
        for (name, values) in samples {
            let sorted = values.sorted()
            summary[name] = .object(["medianMs": .number(sorted[sorted.count / 2]), "maxMs": .number(sorted.last ?? 0),
                                     "all": .array(values.map { .number(($0 * 10).rounded() / 10) })])
        }
        let slowest = samples.values.flatMap { $0 }.max() ?? 0
        check("panel-less tab answers CDP promptly", slowest < 1000 && visibleAtStart == "visible",
              "visibility \(visibleAtStart) → \(visibleAtEnd), slowest call \(Int(slowest)) ms, medians "
                + samples.map { "\($0.key) \(Int($0.value.sorted()[$0.value.count / 2]))" }.sorted().joined(separator: ", "))

        // Power: an animated page paints while the agent works, stops once the agent is idle for
        // the visible window, and paints again at its next call.
        var frames = 0
        let counter = tab.addEventObserver { event in if case .frame = event { frames += 1 } }
        defer { tab.removeEventObserver(counter) }
        client.noteAgentActivity(forSession: session)
        _ = try? await tab.devTools.send("Page.navigate", ["url": .string(base + "animation")], timeout: .seconds(10))
        try? await Task.sleep(for: .seconds(1))
        frames = 0
        try? await Task.sleep(for: .seconds(1))
        let framesWhileUsed = frames
        try? await Task.sleep(for: client.agentVisibleWindow + .seconds(1))
        let hiddenState = await evaluate("document.visibilityState")
        frames = 0
        try? await Task.sleep(for: .seconds(2))
        let framesWhileIdle = frames
        client.noteAgentActivity(forSession: session)
        let resumedAt = DispatchTime.now().uptimeNanoseconds
        let shownState = await evaluate("document.visibilityState")
        let resumeMs = Self.milliseconds(since: resumedAt)
        frames = 0
        try? await Task.sleep(for: .seconds(1))
        let framesAfterResume = frames
        summary["framesPerSecondWhileUsed"] = .integer(Int64(framesWhileUsed))
        summary["framesIn2sWhileIdle"] = .integer(Int64(framesWhileIdle))
        summary["framesPerSecondAfterResume"] = .integer(Int64(framesAfterResume))
        summary["firstCallAfterResumeMs"] = .number(resumeMs)
        record["panelLessTab"] = .object(summary)
        check("idle agent tab stops painting and resumes on use",
              framesWhileUsed > 20 && framesWhileIdle <= 2 && framesAfterResume > 20 && hiddenState == "hidden"
                && shownState == "visible",
              "frames/s used \(framesWhileUsed), idle 2 s \(framesWhileIdle), after resume \(framesAfterResume); "
                + "visibility \(hiddenState) → \(shownState) in \(Int(resumeMs)) ms")
    }

    private func load(_ controller: BrowserHostPaneController, _ url: String, title: String) async throws {
        controller.addressInput = url
        controller.submitAddress()
        guard await waitUntil(.seconds(15), { controller.title == title && !controller.isLoading }) else {
            throw QAFailure("\(url) did not load")
        }
    }

    /// Looks up an exposed element; like any accessibility client's read, it keeps the tree on.
    private func find(_ bridge: BrowserAccessibilityBridge, role: String, label: String) -> BrowserAccessibilityKey? {
        bridge.noteAccessibilityQuery()
        return bridge.tree.exposedNodes().first { key in
            guard let node = bridge.tree.node(key), node.role == role else { return false }
            return bridge.tree.label(of: key) == label
        }
    }

    /// Compares an element's accessibility frame (converted back into view points) with the page's
    /// own box for `selector` (plus `inner` inside an iframe).
    private func compareFrame(_ controller: BrowserHostPaneController, _ view: BrowserHostView, _ bridge: BrowserAccessibilityBridge,
                              label: String, selector: String, inner: String? = nil, check name: String) async throws {
        let roles = ["button"]
        guard let key = roles.lazy.compactMap({ self.find(bridge, role: $0, label: label) }).first,
              let window = view.window else { throw QAFailure("no element \(label)") }
        let screen = bridge.element(for: key).accessibilityFrame()
        let inView = view.convert(window.convertFromScreen(screen), from: nil)
        let script = inner.map { inner in """
            (() => { const f = document.querySelector('\(selector)'); const o = f.getBoundingClientRect();
              const r = f.contentDocument.querySelector('\(inner)').getBoundingClientRect();
              return [o.x + f.clientLeft + r.x, o.y + f.clientTop + r.y, r.width, r.height].join(',') })()
            """ } ?? "(() => { const r = document.querySelector('\(selector)').getBoundingClientRect(); return [r.x, r.y, r.width, r.height].join(',') })()"
        let page = try await evaluate(controller, script).split(separator: ",").compactMap { Double($0) }
        guard page.count == 4 else { throw QAFailure("no page box for \(selector)") }
        let error = [abs(inView.minX - page[0]), abs(inView.minY - page[1]), abs(inView.width - page[2]), abs(inView.height - page[3])].max() ?? 99
        check(name, error <= 1.5,
              "accessibility \(Self.describe(inView)), page \(page.map { String(format: "%.1f", $0) }), largest difference \(String(format: "%.2f", error)) pt")
    }

    private static func describe(_ rect: NSRect) -> String {
        String(format: "[%.1f, %.1f, %.1f, %.1f]", rect.minX, rect.minY, rect.width, rect.height)
    }

    /// The view's accessibility tree as an accessibility client reads it.
    private func dumpAccessibility(of view: BrowserHostView) -> JSONValue {
        func describe(_ object: Any, depth: Int) -> JSONValue {
            guard let element = object as? NSAccessibilityElement, depth < 64 else { return .null }
            var entry: [String: JSONValue] = ["role": .string(element.accessibilityRole()?.rawValue ?? "")]
            if let subrole = element.accessibilitySubrole() { entry["subrole"] = .string(subrole.rawValue) }
            if let description = element.accessibilityRoleDescription() { entry["roleDescription"] = .string(description) }
            if let label = element.accessibilityLabel() { entry["label"] = .string(label) }
            if let value = element.accessibilityValue() { entry["value"] = .string("\(value)") }
            if let help = element.accessibilityHelp() { entry["help"] = .string(help) }
            let frame = element.accessibilityFrame()
            entry["frame"] = .array([frame.minX, frame.minY, frame.width, frame.height].map { .number(Double($0)) })
            let children = (element.accessibilityChildren() ?? []).map { describe($0, depth: depth + 1) }
            if !children.isEmpty { entry["children"] = .array(children) }
            return .object(entry)
        }
        let children = (view.accessibilityChildren() ?? []).map { describe($0, depth: 0) }
        return .object(["role": .string(view.accessibilityRole()?.rawValue ?? ""),
                        "label": .string(view.accessibilityLabel() ?? ""), "children": .array(children)])
    }

    private struct DumpLine { var role: String; var label: String; var value: String }

    private static func flatten(_ dump: JSONValue) -> [DumpLine] {
        var lines: [DumpLine] = []
        func visit(_ value: JSONValue) {
            lines.append(DumpLine(role: value["role"]?.stringValue ?? "", label: value["label"]?.stringValue ?? "",
                                  value: value["value"]?.stringValue ?? ""))
            if case .array(let children)? = value["children"] { children.forEach(visit) }
        }
        if case .array(let children)? = dump["children"] { children.forEach(visit) }
        return lines
    }

    private func waitUntilAsync(_ timeout: Duration, _ condition: @escaping @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// Sends a surface from Yardlet itself, which is not the launched host: it must be refused.
    private func exerciseSurfaceSecurity() {
        guard let process = MacBrowserHost.shared.process, let portName = process.portNameForQA,
              let surface = IOSurfaceCreate([kIOSurfaceWidth: 4, kIOSurfaceHeight: 4, kIOSurfaceBytesPerElement: 4,
                                             kIOSurfacePixelFormat: 0x4247_5241] as CFDictionary) else { return }
        var port: mach_port_t = 0
        guard yardlet_surface_port_look_up(portName, &port) == KERN_SUCCESS else { return }
        let before = process.rejectedSurfaceMessages
        let token = process.tokenForQA
        _ = token.withUnsafeBufferPointer { yardlet_surface_port_send(port, surface, $0.baseAddress!) }
        let wrong = [UInt8](repeating: 7, count: token.count)
        _ = wrong.withUnsafeBufferPointer { yardlet_surface_port_send(port, surface, $0.baseAddress!) }
        let forged = UInt64(IOSurfaceGetID(surface))
        let accepted = process.surface(for: forged) != nil
        check("surfaces from another process are refused", !accepted && process.rejectedSurfaceMessages >= before + 2,
              "rejected \(process.rejectedSurfaceMessages - before)")
    }

    private func crashDrill(_ controller: BrowserHostPaneController) async {
        MacBrowserHost.shared.process?.kill()
        // A killed host leaves its code-sign clone behind; run-check.sh allows this many.
        record["intentionalHostKills"] = .integer(1)
        let shown = await waitUntil(.seconds(10)) { controller.errorMessage != nil && !controller.hasTab }
        check("host crash shows an error in the panel", shown, controller.errorMessage ?? "none")
        controller.retry()
        let back = await waitUntil(.seconds(20)) { controller.hasTab && controller.title == "Browser QA" }
        check("try again reopens the page", back, "host running \(client.isHostRunning)")
    }

    private func checkFileLocations() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appending(path: "Library/Application Support")
        let outside = ["CEF", "Google"].filter {
            FileManager.default.fileExists(atPath: support.appending(path: $0).path(percentEncoded: false))
        }
        let profile = MacBrowserHost.shared.paths.profile
        let hasProfile = FileManager.default.fileExists(atPath: profile.appending(path: "Cookies").path(percentEncoded: false))
        check("Chromium files stay under Yardlet/Browser", outside.isEmpty && hasProfile,
              "outside \(outside), profile cookies \(hasProfile)")
    }

    // MARK: Native sheets

    /// Answers the page's dialog over the panel as its button would (OK, Leave and Reload accept).
    private func answerDialog(_ controller: BrowserHostPaneController, button title: String, text: String? = nil) async -> Bool {
        guard await waitUntil(.seconds(5), { controller.javaScriptDialog != nil }),
              let dialog = controller.javaScriptDialog else { return false }
        if let text { controller.dialogText = text }
        controller.answerJavaScriptDialog(accept: [L10n.string("OK"), L10n.string("Leave"), L10n.string("Reload")].contains(title))
        return await waitUntil(.seconds(3)) { controller.javaScriptDialog?.id != dialog.id }
    }

    private static func subviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(subviews(of:))
    }

    // MARK: Synthetic input

    private func click(_ view: BrowserHostView, at point: NSPoint) {
        guard let down = mouse(.leftMouseDown, view, point), let up = mouse(.leftMouseUp, view, point) else { return }
        view.mouseDown(with: down)
        view.mouseUp(with: up)
    }

    private func move(_ view: BrowserHostView, to point: NSPoint) {
        guard let event = mouse(.mouseMoved, view, point) else { return }
        view.mouseMoved(with: event)
    }

    private func mouse(_ type: NSEvent.EventType, _ view: BrowserHostView, _ point: NSPoint) -> NSEvent? {
        guard let window = view.window else { return nil }
        return NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    private func key(_ view: BrowserHostView, _ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        guard let window = view.window else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters.lowercased(), isARepeat: false,
                                               keyCode: keyCode) else { continue }
            if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
        }
    }

    private func flags(_ view: BrowserHostView, keyCode: UInt16, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = down ? .maskShift : []
        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        view.flagsChanged(with: nsEvent)
    }

    private func commandKey(_ characters: String, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                         keyCode: keyCode)!
    }

    // MARK: CDP

    private func evaluate(_ controller: BrowserHostPaneController, _ expression: String,
                          userGesture: Bool = false) async throws -> String {
        guard let tab = controller.tab else { throw QAFailure("no tab") }
        let result = try await tab.devTools.send("Runtime.evaluate", [
            "expression": .string(expression), "returnByValue": .bool(true), "userGesture": .bool(userGesture)
        ])
        return result["result"]?["value"]?.stringValue ?? result["result"]?["value"]?.readableText ?? ""
    }

    /// The middle of an element's first box: an inline element that wraps onto a second line has a bounding box
    /// around both lines, whose middle can be the paragraph's other words (the tooltip check's `#tip` at the panel's
    /// width since 2026-10-26).
    private func center(_ controller: BrowserHostPaneController, _ selector: String) async throws -> NSPoint {
        let value = try await evaluate(controller, """
            (() => { const r = document.querySelector('\(selector)').getClientRects()[0]; return (r.x + r.width / 2) + ',' + (r.y + r.height / 2) })()
            """)
        let parts = value.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { throw QAFailure("no element \(selector)") }
        return NSPoint(x: parts[0], y: parts[1])
    }

    // MARK: Record

    private func phase(_ name: String) async {
        let entry: [String: JSONValue] = [
            "name": .string(name), "atMs": .number(Self.milliseconds(since: start)),
            "hostRunning": .bool(client.isHostRunning), "openTabs": .integer(Int64(client.openTabCount))
        ]
        phases.append(.object(entry))
        try? write(.object(entry), to: "markers/\(name).json")
        try? await Task.sleep(for: .seconds(6))
    }

    private func check(_ name: String, _ ok: Bool, _ detail: String) {
        checks.append(.object(["check": .string(name), "ok": .bool(ok), "detail": .string(detail)]))
        record["checks"] = .array(checks)
        record["phases"] = .array(phases)
        try? write(.object(record), to: "result.json")
    }

    private func write(_ value: JSONValue, to name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: output.appending(path: name), options: .atomic)
    }

    private func finish() async {
        record["checks"] = .array(checks)
        record["phases"] = .array(phases)
        try? write(.object(record), to: "result.json")
        try? "done".write(to: output.appending(path: "markers/finished"), atomically: true, encoding: .utf8)
        client.terminateHost()
        try? await Task.sleep(for: .seconds(1))
        // The fixture's tasks look active, so NSApp.terminate would stop at the quit warning.
        _exit(0)
    }

    private func waitUntil(_ timeout: Duration, poll: Duration = .milliseconds(25),
                           _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: poll)
        }
        return true
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
    }
}

/// Other apps' addresses in a QA run: named as the Mac names their apps, recorded instead of opened.
@MainActor
private final class RecordingExternalApps: BrowserExternalApps {
    private let names: any BrowserExternalApps
    private(set) var launched: [String] = []
    init(naming names: any BrowserExternalApps) { self.names = names }
    func appName(for url: URL) -> String? { names.appName(for: url) }
    func open(_ url: URL) { launched.append(url.absoluteString) }
}

private struct QAFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - Picking an element and marking up its capture

extension BrowserHostQARunner {
    /// The browser panel's element picking for the composer and the markup of its capture, on
    /// `/pick`: picking outlines the element under the pointer (the panel's frames, before
    /// and while), a click attaches the element to the task's composer with a selector that finds it
    /// alone, its HTML, styles and capture, and ends picking; while picking the page does not get the
    /// click, after it the page does; Escape and the button end picking with nothing attached; no typed,
    /// hidden, password or vault-filled value leaves in the context, and typed values do not show in the
    /// capture though the page shows them; the capture's markup (the presenter replaced, so nothing opens
    /// on the screen) takes the capture's place in the draft, and the next message names each capture.
    fileprivate func exerciseVisualContext(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async throws {
        guard let draft = BrowserHostQAFixture.composerDraft else { throw QAFailure("no composer draft") }
        draft.browserComments = []
        let toComposer = controller.onPickElement
        check("visual context: the browser toolbar offers picking for the task's composer", toComposer != nil,
              "composer \(toComposer != nil)")
        var picked: [BrowserComment] = []
        controller.onPickElement = { comment in
            picked.append(comment)
            toComposer?(comment)
        }
        defer { controller.onPickElement = toComposer }
        func rect(_ selector: String) async -> [Double] {
            (try? await evaluate(controller, """
                (() => { const r = document.querySelector('\(selector)').getBoundingClientRect(); return [r.x, r.y, r.width, r.height].join(',') })()
                """))?.split(separator: ",").compactMap { Double($0) } ?? []
        }
        func clicks() async -> String { (try? await evaluate(controller, "String(window.qa.clicks)")) ?? "" }
        func startPicking() async -> Bool {
            controller.togglePickingElement()
            let on = await waitUntil(.seconds(3)) { controller.isPickingElement }
            // The page's inspect mode is on once Chromium answers.
            try? await Task.sleep(for: .milliseconds(500))
            return on
        }
        func pick(_ selector: String) async -> BrowserComment? {
            let before = picked.count
            guard await startPicking(), let point = try? await center(controller, selector) else { return nil }
            move(view, to: point)
            try? await Task.sleep(for: .milliseconds(300))
            click(view, at: point)
            _ = await waitUntil(.seconds(10)) { picked.count > before }
            return picked.count > before ? picked.last : nil
        }
        let scale = view.window?.backingScaleFactor ?? 2
        let ratio = Double((try? await evaluate(controller, "String(devicePixelRatio)")) ?? "") ?? scale

        // The outline under the pointer: the button's padding, in the panel's frames.
        let target = await rect("[data-qa=target]")
        guard target.count == 4 else { throw QAFailure("no target button") }
        let probe = NSPoint(x: target[0] + 6, y: target[1] + target[3] / 2)
        move(view, to: NSPoint(x: 4, y: 4))
        try? await Task.sleep(for: .milliseconds(400))
        let plain = Self.red(in: view.frameDisplay.currentSurface, at: probe, scale: scale)
        guard await startPicking() else { throw QAFailure("picking did not start") }
        let middle = NSPoint(x: target[0] + target[2] / 2, y: target[1] + target[3] / 2)
        move(view, to: middle)
        try? await Task.sleep(for: .milliseconds(700))
        let lit = Self.red(in: view.frameDisplay.currentSurface, at: probe, scale: scale)
        if let surface = view.frameDisplay.currentSurface { Self.writePNG(surface, to: output.appending(path: "visual-context-hover.png")) }
        check("visual context: picking outlines the element under the pointer", (lit ?? 0) - (plain ?? 0) > 25,
              "red at the button's edge \(plain.map(String.init) ?? "-") before, \(lit.map(String.init) ?? "-") while picking")
        click(view, at: middle)
        _ = await waitUntil(.seconds(10)) { !picked.isEmpty }
        guard let button = picked.first else { throw QAFailure("the click attached nothing") }
        let selector = BrowserCommentPrompt.quoted(button.selector)
        let finds = (try? await evaluate(controller, """
            (() => { const f = document.querySelectorAll(\(selector)); return String(f.length === 1 && f[0] === document.querySelector('[data-qa=target]')) })()
            """)) == "true"
        let capture = button.image.flatMap { NSBitmapImageRep(data: (try? Data(contentsOf: $0)) ?? Data()) }
        let expectedWidth = (target[2] + 2 * BrowserElementPicker.margin) * ratio
        check("visual context: a click attaches the element with a selector, its HTML, styles and capture",
              finds && !controller.isPickingElement && button.target == "button \"Save changes\""
                && button.html.contains("data-qa=\"target\"") && button.styles.contains { $0.name == "background-color" }
                && button.pageURL.hasSuffix("/pick") && abs(Double(capture?.pixelsWide ?? 0) - expectedWidth) <= 2 * ratio
                && draft.browserComments.map(\.id) == [button.id],
              "selector \(button.selector) finds it \(finds); target \(button.target); \(button.html.count) characters of HTML; "
                + "\(button.styles.count) styles; capture \(capture?.pixelsWide ?? 0)×\(capture?.pixelsHigh ?? 0) px "
                + "(expected width \(Int(expectedWidth))); picking \(controller.isPickingElement); in the draft \(draft.browserComments.count)")
        if let capture, let png = capture.representation(using: .png, properties: [:]) {
            try? png.write(to: output.appending(path: "visual-context-capture.png"))
        }

        // The page does not get a click made to pick, and does once picking ended.
        let count = await pick("#count")
        let duringPick = await clicks()
        if let point = try? await center(controller, "#count") { click(view, at: point) }
        try? await Task.sleep(for: .milliseconds(300))
        let afterPick = await clicks()
        check("visual context: picking takes the click from the page, and the page has its clicks back after",
              count?.target == "button \"Count\"" && duringPick == "0" && afterPick == "1",
              "picked \(count?.target ?? "nothing"); page clicks \(duringPick) while picking, \(afterPick) after")

        // Escape and the button end picking with nothing attached.
        let attached = picked.count
        _ = await startPicking()
        key(view, "\u{1b}", keyCode: 53)
        let escaped = await waitUntil(.seconds(3)) { !controller.isPickingElement }
        _ = await startPicking()
        controller.togglePickingElement()
        let toggled = !controller.isPickingElement
        try? await Task.sleep(for: .milliseconds(400))
        if let point = try? await center(controller, "#count") { click(view, at: point) }
        try? await Task.sleep(for: .milliseconds(300))
        let afterStop = await clicks()
        check("visual context: Escape and the button end picking with nothing attached and leave the page its clicks",
              escaped && toggled && picked.count == attached && afterStop == "2",
              "Escape ended it \(escaped); the button ended it \(toggled); attached \(picked.count - attached); page clicks \(afterStop)")

        // Typed, hidden, password and vault-filled values stay on the page.
        _ = try? await evaluate(controller, """
            (() => { const n = document.querySelector('#name'); n.value = 'typed-name-1'; n.setAttribute('value', 'typed-attr-1');
              document.querySelector('#pw').value = 'typed-pass-2'; document.querySelector('#notes').value = 'typed-note-4';
              document.querySelector('#reveal').textContent = 'vault-secret-6'; return 'ok' })()
            """)
        MacAgentToolService.shared.broker.noteVaultValues(["vault-secret-6"])
        try? await Task.sleep(for: .milliseconds(300))
        let name = await rect("#name"), form = await rect("#account")
        let shownOnPage = Self.darkPixels(in: view.frameDisplay.currentSurface, rect: name, inset: 6, scale: scale)
        let account = await pick("#account")
        let text = account.map { DiffCommentPrompt.message(comments: [], browserComments: [$0], browserImageNumbers: [1], request: "") } ?? ""
        let secrets = ["typed-name-1", "typed-attr-1", "typed-pass-2", "csrf-hidden-3", "typed-note-4", "default-note-5", "vault-secret-6"]
        let leaked = secrets.filter(text.contains)
        var inCapture = -1
        if let image = account?.image.flatMap({ NSBitmapImageRep(data: (try? Data(contentsOf: $0)) ?? Data()) }),
           name.count == 4, form.count == 4 {
            let left = max(0, form[0] - BrowserElementPicker.margin), top = max(0, form[1] - BrowserElementPicker.margin)
            let pixels = Double(image.pixelsWide) / (min(Double(view.bounds.width), form[0] + form[2] + BrowserElementPicker.margin) - left)
            inCapture = Self.darkPixels(in: image, rect: [(name[0] - left) * pixels, (name[1] - top) * pixels,
                                                          name[2] * pixels, name[3] * pixels], inset: 6 * pixels)
        }
        let restored = (try? await evaluate(controller, """
            String(getComputedStyle(document.querySelector('#name')).color === 'rgb(0, 0, 0)' && window.__yardletPickHidden === undefined)
            """)) == "true"
        check("visual context: no typed, hidden, password or vault-filled value leaves with the element or shows in its capture",
              account != nil && leaked.isEmpty && text.contains("[saved value]") && shownOnPage > 0 && inCapture == 0 && restored,
              "left with it: \(leaked.isEmpty ? "none" : leaked.joined(separator: ", ")); vault value scrubbed \(text.contains("[saved value]")); "
                + "typed name's dark pixels on the page \(shownOnPage), in the capture \(inCapture); page restored \(restored)")
        try? text.write(to: output.appending(path: "visual-context-message.txt"), atomically: true, encoding: .utf8)

        // Marking up the capture: the presenter is replaced, so the editor draws offscreen and opens nothing.
        let present = ImageMarkupPresenter.open
        defer { ImageMarkupPresenter.open = present }
        var opened: [URL] = []
        ImageMarkupPresenter.open = { [output] url, _, saved in
            opened.append(url)
            guard let image = ImageMarkupRenderer.image(at: url) else { return }
            let model = ImageMarkupModel(image: image)
            let size = model.size
            model.tool = .rectangle
            model.drag(from: CGPoint(x: size.width * 0.06, y: size.height * 0.12), to: CGPoint(x: size.width * 0.94, y: size.height * 0.88))
            model.endDrag()
            model.tool = .arrow
            model.color = .blue
            model.drag(from: CGPoint(x: size.width * 0.98, y: size.height * 0.02), to: CGPoint(x: size.width * 0.7, y: size.height * 0.4))
            model.endDrag()
            model.tool = .pen
            model.color = .yellow
            for step in 0...12 {
                let x = size.width * (0.15 + 0.05 * Double(step))
                model.drag(from: CGPoint(x: size.width * 0.15, y: size.height * 0.75), to: CGPoint(x: x, y: size.height * (0.75 + 0.08 * sin(Double(step)))))
            }
            model.endDrag()
            let host = NSHostingView(rootView: ImageMarkupEditor(model: model) { _ in })
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: ImageMarkupEditor.windowSize(for: image)),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appending(path: "visual-context-markup-editor.png"))
            }
            window.close()
            if let copy = ImageMarkupRenderer.saveCopy(image, marks: model.marks) { saved(copy) }
        }
        let first = draft.browserComments.first
        // What the comment chip's click does (`BrowserCommentChip`).
        if let first, let image = first.image {
            ImageMarkupPresenter.open(image, view.window) { draft.replaceCapture(of: first.id, with: $0) }
        }
        let marked = draft.browserComments.first?.image
        if let marked, let data = try? Data(contentsOf: marked) { try? data.write(to: output.appending(path: "visual-context-marked.png")) }
        let original = first?.image.map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
        let message = draft.submission
        let numbered = (1...draft.browserComments.count).allSatisfy { message.text.contains("Element screenshot: image \($0) of this message") }
        check("visual context: the marked-up capture takes the capture's place and each capture goes with the next message",
              opened == [first?.image].compactMap { $0 } && marked != nil && marked != first?.image && original
                && message.imageURLs.count == draft.browserComments.count && message.imageURLs.first == marked?.standardizedFileURL
                && numbered && message.text.contains(BrowserCommentPrompt.header),
              "editor opened for \(opened.map(\.lastPathComponent)); capture replaced \(marked != first?.image); original kept \(original); "
                + "\(message.imageURLs.count) images for \(draft.browserComments.count) comments; numbered \(numbered)")
        try? message.text.write(to: output.appending(path: "visual-context-draft-message.txt"), atomically: true, encoding: .utf8)
        // The composer with its chips: in the narrow QA window the panel covers the conversation, so it closes first.
        let window = view.window
        await closePanel()
        try? await Task.sleep(for: .seconds(1))
        if let content = window?.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appending(path: "visual-context-composer.png"))
        }
        // The captures and the marked copy are this run's own files in the composer's private folder.
        let made = Set((picked.compactMap(\.image) + [marked].compactMap { $0 }).map { $0.deletingLastPathComponent() })
        made.filter { ComposerAttachmentIntake.isPastedImage($0.appending(path: "image.png")) }
            .forEach { try? FileManager.default.removeItem(at: $0) }
        draft.browserComments = []
    }

    /// The red of the frame's pixel at a point of the page (BGRA), or nil without a frame.
    nonisolated fileprivate static func red(in surface: IOSurfaceRef?, at point: NSPoint, scale: Double) -> Int? {
        guard let surface else { return nil }
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let x = Int(point.x * scale), y = Int(point.y * scale)
        guard x >= 0, y >= 0, x < IOSurfaceGetWidth(surface), y < IOSurfaceGetHeight(surface) else { return nil }
        let pixel = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self) + y * IOSurfaceGetBytesPerRow(surface) + x * 4
        return Int(pixel[2])
    }

    /// Dark pixels (text) inside a field's rectangle of page points, its border left out, in the panel's frame.
    nonisolated fileprivate static func darkPixels(in surface: IOSurfaceRef?, rect: [Double], inset: Double, scale: Double) -> Int {
        guard let surface, rect.count == 4 else { return -1 }
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        let left = max(0, Int((rect[0] + inset) * scale)), right = min(IOSurfaceGetWidth(surface), Int((rect[0] + rect[2] - inset) * scale))
        let top = max(0, Int((rect[1] + inset) * scale)), bottom = min(IOSurfaceGetHeight(surface), Int((rect[1] + rect[3] - inset) * scale))
        guard right > left, bottom > top else { return -1 }
        var dark = 0
        for row in top..<bottom {
            for column in left..<right {
                let pixel = base + row * rowBytes + column * 4
                if (Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 3 < 160 { dark += 1 }
            }
        }
        return dark
    }

    /// Dark pixels inside a rectangle of an image's pixels, `inset` pixels in from its edges.
    fileprivate static func darkPixels(in image: NSBitmapImageRep, rect: [Double], inset: Double) -> Int {
        let left = max(0, Int(rect[0] + inset)), right = min(image.pixelsWide, Int(rect[0] + rect[2] - inset))
        let top = max(0, Int(rect[1] + inset)), bottom = min(image.pixelsHigh, Int(rect[1] + rect[3] - inset))
        guard right > left, bottom > top else { return -1 }
        var dark = 0
        for row in top..<bottom {
            for column in left..<right {
                guard let color = image.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                if (color.redComponent + color.greenComponent + color.blueComponent) / 3 < 160.0 / 255 { dark += 1 }
            }
        }
        return dark
    }

    /// The frame as the panel shows it, for the review images.
    nonisolated fileprivate static func writePNG(_ surface: IOSurfaceRef, to url: URL) {
        let image = CIImage(ioSurface: surface)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}

/// The widths of the page frames a panel placed while its divider moved, for the resize check.
private final class ResizeFrameLog: @unchecked Sendable {
    private let lock = NSLock()
    private var widths: [Int] = []

    func add(_ frame: BrowserFrame) { lock.withLock { widths.append(frame.pixelWidth) } }
    func reset() { lock.withLock { widths = [] } }
    var snapshot: [Int] { lock.withLock { widths } }
}

/// Counts the frames a display placed, and on which thread, for the rail preview check.
private final class PreviewFrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var latencies: [Double] = []
    private var onMain = 0

    func add(latency: Double, onMain: Bool) {
        lock.withLock {
            latencies.append(latency)
            if onMain { self.onMain += 1 }
        }
    }

    func reset() {
        lock.withLock {
            latencies = []
            onMain = 0
        }
    }

    func snapshot() -> (frames: Int, onMain: Int, medianLatency: Double) {
        lock.withLock {
            let sorted = latencies.sorted()
            return (sorted.count, onMain, sorted.isEmpty ? 0 : sorted[sorted.count / 2])
        }
    }
}
#endif
