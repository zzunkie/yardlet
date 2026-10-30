#if DEBUG
import AppKit
import Foundation

/// QA for the memory saver's discards against the real browser host (docs/BROWSER_HOST.md §3 "Memory saver"), run by
/// `run-check.sh … --ui-fixture-browser-check-only=memory-saver --ui-fixture-browser-memory-saver=4
/// --ui-fixture-browser-agent-visible=1`: Chrome's four hours become four seconds. One task's tabs, with no panel:
/// two pages holding memory with a frame from another site, a page whose policy allows no script, and the pages Chrome
/// keeps (sound playing, a form typed into, a page and the pop-up it opened, which share a renderer, and a PDF). The
/// first three are discarded and the rest kept, each for its reason; the browser's processes and memory before and
/// after go to `result.json` (and run-check.sh samples them at the phase markers). A discarded tab loads its page
/// again for the agent and for a panel, with its history; turning the saver off loads the rest. Then the agent's tabs
/// no panel showed on screen go soon after its turn (`runAgentTabs`).
@MainActor
final class BrowserHostMemorySaverQA {
    private let output: URL
    private let base: String
    private var record: [String: JSONValue] = [:]
    private var checks: [JSONValue] = []
    private var client: BrowserHostClient { MacBrowserHost.shared.client }

    init(output: URL, base: String) {
        self.output = output
        self.base = base
    }

    func run() async {
        try? FileManager.default.createDirectory(at: output.appending(path: "markers"), withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(3))
        client.isMemorySaverOn = false
        let session = UUID()
        guard let first = await tab(session, "saver/page?n=1", title: "Saver 1"),
              await navigate(first, "saver/page?n=2", title: "Saver 2"),
              let second = await tab(session, "saver/page?n=3", title: "Saver 3"),
              let noScript = await tab(session, "saver/csp", title: "Saver CSP"),
              let media = await tab(session, "saver/media", title: "Saver media"),
              let form = await tab(session, "saver/form", title: "Saver form"),
              let opener = await tab(session, "saver/page?n=4", title: "Saver 4"),
              let pdf = await tab(session, "compat/doc.pdf", title: nil)
        else { return await finish() }

        let playing = await value(media, "start()", userGesture: true)
        check("the media page plays sound", playing == .string("playing"), Self.describe(playing))
        _ = await value(form, "document.getElementById('name').focus(); 1")
        _ = try? await form.devTools.send("Input.insertText", ["text": .string("typed by the person")], timeout: .seconds(10))
        let typed = await value(form, "document.getElementById('name').value")
        check("the form has a typed value", typed == .string("typed by the person"), Self.describe(typed))
        _ = await value(opener, "window.open('/saver/next') ? 1 : 0", userGesture: true)
        let popupOpened = await waitUntil(.seconds(10)) { self.client.tabs(forSession: session).count == 8 }
        let opened = [first, second, noScript, media, form, opener, pdf]
        let popup = client.tabs(forSession: session).first { tab in !opened.contains { $0 === tab } }
        check("the opener's pop-up is another tab of the task", popupOpened && popup != nil,
              "tabs \(client.tabs(forSession: session).count)")
        _ = await waitUntil(.seconds(10)) { popup?.title == "Saver next" && popup?.isLoading == false }

        // Everything hidden past the saver's time (the agent's window is one second).
        try? await Task.sleep(for: .seconds(2))
        let before = measure()
        record["before"] = before.json
        await phase("saver-1-live")

        client.isMemorySaverOn = true
        let discarded = await waitUntil(.seconds(40)) { [first, second, noScript].allSatisfy(\.isDiscarded) }
        check("hidden pages are discarded: two holding memory with another site's frame, one whose policy allows no script",
              discarded, [first, second, noScript].map { "\($0.title) \($0.isDiscarded) \($0.discardRefusal ?? "-")" }.joined(separator: ", "))
        // Sound is "audible" for its first minute (the browser process's signal), then "media" (the renderer's answer).
        let kept: [(BrowserTab?, Set<String>, String)] = [
            (media, ["audible", "media"], "sound plays"), (form, ["form"], "a form typed into"),
            (opener, ["shared"], "its pop-up shares its renderer"), (popup, ["shared"], "its opener shares its renderer"),
            (pdf, ["pdf"], "a PDF")
        ]
        _ = await waitUntil(.seconds(20)) { kept.allSatisfy { $0.0?.discardRefusal != nil } }
        for (tab, reasons, why) in kept {
            check("kept: \(why)", tab?.isDiscarded == false && tab?.discardRefusal.map(reasons.contains) == true,
                  "discarded \(String(describing: tab?.isDiscarded)), reason \(tab?.discardRefusal ?? "none")")
        }
        check("a discard is no crash", [first, second, noScript].allSatisfy { $0.crash == nil },
              [first, second, noScript].map { $0.crash?.errorCode ?? "-" }.joined(separator: ", "))
        try? await Task.sleep(for: .seconds(3))
        let after = measure()
        record["afterDiscard"] = after.json
        check("the discards end renderer processes and free their memory",
              after.processes <= before.processes - 3 && after.footprint + (100 << 20) < before.footprint,
              "processes \(before.processes) → \(after.processes), footprint \(before.footprint >> 20) → \(after.footprint >> 20) MiB")
        await phase("saver-2-discarded")

        // The agent uses a discarded tab: its page loads again before the tool reads it, with its history.
        let agentTabs = BrowserAgentTabs { MacBrowserHost.shared.client }
        if let page = try? agentTabs.page(for: session, tabID: String(first.id)) {
            await page.untilRestored()
        }
        let state = await value(first, "document.title + '|' + history.length + '|' + (window.held ? window.held.length : 0)")
        check("the agent's tool finds the page loaded again, with its history", !first.isDiscarded
              && state == .string("Saver 2|2|40") && first.canGoBack, "\(Self.describe(state)), back \(first.canGoBack)")
        first.send(.navigation(tab: first.id, action: .back))
        let wentBack = await waitUntil(.seconds(15)) { first.title == "Saver 1" && !first.isLoading }
        check("Back goes to the page before the discard", wentBack, first.title)

        // A panel shows a discarded tab: it loads again.
        client.attachPanel(to: second)
        await second.untilRestored()
        let shown = await waitUntil(.seconds(15)) { !second.isDiscarded && second.title == "Saver 3" && !second.isLoading }
        let held = await value(second, "String(window.held ? window.held.length : 0)")
        check("a panel shows a discarded tab's page again", shown && held == .string("40"), "\(second.title) \(Self.describe(held))")
        client.detachPanel(from: second)

        // Turned off, the tabs it discarded load again.
        client.isMemorySaverOn = false
        await noScript.untilRestored()
        let back = await waitUntil(.seconds(15)) { !noScript.isDiscarded && noScript.title == "Saver CSP" && !noScript.isLoading }
        check("turning the saver off loads the discarded tabs again", back, "\(noScript.title) \(noScript.isDiscarded)")
        try? await Task.sleep(for: .seconds(3))
        record["afterRestore"] = measure().json
        await phase("saver-3-restored")
        client.closeTabs(forSession: session)
        await runAgentTabs()
        await finish()
    }

    /// Tabs the agent opened with its tools that no panel showed on screen (one of them in a panel off screen) go once
    /// its turn has ended and the unseen time (the saver's seconds here) has passed; with the level's time an hour, a
    /// tab the agent opened that a panel showed on screen and a tab the person opened stay. The agent's next use of an
    /// unseen tab loads it again.
    private func runAgentTabs() async {
        client.memorySaverTiming.hiddenBeforeDiscard = .seconds(3600)
        client.memorySaverTiming.urgentProtection = .seconds(3600)
        client.isMemorySaverOn = true
        let session = UUID()
        let agentTabs = BrowserAgentTabs { MacBrowserHost.shared.client }
        guard let unseen = await agentTab(agentTabs, session, "saver/page?n=5", title: "Saver 5"),
              let offScreen = await agentTab(agentTabs, session, "saver/page?n=6", title: "Saver 6"),
              let seen = await agentTab(agentTabs, session, "saver/page?n=7", title: "Saver 7"),
              let persons = await tab(session, "saver/page?n=8", title: "Saver 8")
        else { return }
        client.attachPanel(to: offScreen, occluded: true)
        client.detachPanel(from: offScreen, occluded: true)
        client.attachPanel(to: seen)
        client.detachPanel(from: seen)
        let idle = client.memorySaverTiming.unseenAgentTabIdle
        try? await Task.sleep(for: idle * 2)
        let before = measure()
        record["agentTabsBefore"] = before.json
        let tabs = [unseen, offScreen, seen, persons]
        check("the agent's tabs stay while its turn goes on", tabs.allSatisfy { !$0.isDiscarded },
              tabs.map { "\($0.title) \($0.isDiscarded)" }.joined(separator: ", "))
        await phase("saver-4-agent-turn")

        await agentTabs.endAgentEmulation(for: session)
        let gone = await waitUntil(idle + .seconds(30)) { unseen.isDiscarded && offScreen.isDiscarded }
        check("the agent's tabs no panel showed on screen go once its turn ended", gone,
              [unseen, offScreen].map { "\($0.title) \($0.isDiscarded) \($0.discardRefusal ?? "-")" }.joined(separator: ", "))
        try? await Task.sleep(for: idle)
        check("a tab a panel showed on screen and the person's tab wait for the level's time",
              !seen.isDiscarded && !persons.isDiscarded && seen.discardRefusal == nil && persons.discardRefusal == nil,
              [seen, persons].map { "\($0.title) \($0.isDiscarded) \($0.discardRefusal ?? "-")" }.joined(separator: ", "))
        try? await Task.sleep(for: .seconds(3))
        let after = measure()
        record["agentTabsAfter"] = after.json
        check("the unseen agent tabs' renderers end and free their memory",
              after.processes <= before.processes - 2 && after.footprint < before.footprint,
              "processes \(before.processes) → \(after.processes), footprint \(before.footprint >> 20) → \(after.footprint >> 20) MiB")
        await phase("saver-5-agent-tabs-discarded")

        if let page = try? agentTabs.page(for: session, tabID: String(unseen.id)) {
            await page.untilRestored()
        }
        let state = await value(unseen, "document.title + '|' + (window.held ? window.held.length : 0)")
        check("the agent's next use loads an unseen tab again", !unseen.isDiscarded && state == .string("Saver 5|40"),
              Self.describe(state))
        client.isMemorySaverOn = false
        client.closeTabs(forSession: session)
    }

    // MARK: Measuring

    private struct Measure {
        var processes: Int
        var footprint: UInt64
        var json: JSONValue {
            .object(["processes": .integer(Int64(processes)), "footprintMiB": .integer(Int64(footprint >> 20))])
        }
    }

    /// The browser host and every Chromium process under it: how many, and their footprint (Activity Monitor's
    /// Memory column).
    private func measure() -> Measure {
        guard let host = client.hostProcessID else { return Measure(processes: 0, footprint: 0) }
        let table = LiveProcessTable()
        let entries = table.entries()
        var tree: Set<Int32> = [Int32(host)]
        var grew = true
        while grew {
            grew = false
            for entry in entries where !tree.contains(entry.processID) && tree.contains(entry.parentID) {
                tree.insert(entry.processID)
                grew = true
            }
        }
        let footprint = tree.compactMap { table.usage(of: $0)?.memoryBytes }.reduce(0, +)
        return Measure(processes: tree.count, footprint: footprint)
    }

    // MARK: Pieces

    private func tab(_ session: UUID, _ path: String, title: String?) async -> BrowserTab? {
        let url = base + path
        let tab = client.tabs(forSession: session).isEmpty
            ? try? client.openTab(forSession: session, url: url, viewport: .offscreenDefault)
            : try? client.newTab(forSession: session, url: url, viewport: .offscreenDefault, select: false)
        guard let tab, await waitUntil(.seconds(20), { tab.currentURL == url && !tab.isLoading && (title == nil || tab.title == title) })
        else {
            check("the page \(path) loads", false, "not loaded")
            return nil
        }
        return tab
    }

    /// A tab the agent's tools open (`browser_tab_new`), at `path`.
    private func agentTab(_ agentTabs: BrowserAgentTabs, _ session: UUID, _ path: String, title: String) async -> BrowserTab? {
        guard let info = try? agentTabs.newTab(for: session, foreground: false),
              let tab = client.tabs(forSession: session).first(where: { String($0.id) == info.id }) else {
            check("the agent opens a tab for \(path)", false, "no tab")
            return nil
        }
        tab.noteAgentActivity()
        return await navigate(tab, path, title: title) ? tab : nil
    }

    private func navigate(_ tab: BrowserTab, _ path: String, title: String) async -> Bool {
        tab.send(.navigate(tab: tab.id, url: base + path))
        let loaded = await waitUntil(.seconds(20)) { tab.title == title && !tab.isLoading }
        if !loaded { check("the page \(path) loads", false, tab.title) }
        return loaded
    }

    private func value(_ tab: BrowserTab, _ expression: String, userGesture: Bool = false) async -> JSONValue? {
        let result = try? await tab.devTools.send("Runtime.evaluate", [
            "expression": .string(expression), "returnByValue": .bool(true), "awaitPromise": .bool(true),
            "userGesture": .bool(userGesture)
        ], timeout: .seconds(10))
        return result?["result"]?["value"]
    }

    private static func describe(_ value: JSONValue?) -> String {
        guard let value, let data = try? JSONEncoder().encode(value) else { return "none" }
        return String(decoding: data, as: UTF8.self)
    }

    private func phase(_ name: String) async {
        try? JSONEncoder().encode(JSONValue.object(["name": .string(name)]))
            .write(to: output.appending(path: "markers/\(name).json"))
        try? await Task.sleep(for: .seconds(6))
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
        checks.append(.object(["check": .string(name), "ok": .bool(ok), "detail": .string(String(detail.prefix(600)))]))
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
        endBrowserQA(checks: checks)
    }
}
#endif
