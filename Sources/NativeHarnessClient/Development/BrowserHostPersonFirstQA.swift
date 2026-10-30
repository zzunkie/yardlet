#if DEBUG
import AppKit
import Foundation
import YardletAgentTools

/// QA for the person's screen in the browser (docs/BROWSER_HOST.md, section 3, "Tabs that wait on the person";
/// docs/AGENT_BROWSER_TOOLS.md, section 2, "The tab the person uses"), against the real browser host, run by
/// `run-check.sh … --ui-fixture-browser-check-only=person-first`:
/// a dialog or file chooser of a tab the person does not see waits in its tab (no sheet holds the window, nothing is
/// cancelled), its task and tab are marked and it is announced once, and it shows when the panel shows the tab; while
/// the person uses a tab, the agent's new tab, tab choice and tools without a tabId leave the panel on it. The agent's
/// calls go through the Yardlet MCP broker for the task the QA window shows. Checks land in `result.json`.
@MainActor
final class BrowserHostPersonFirstQA {
    private let output: URL
    private let session: UUID
    private var record: [String: JSONValue] = [:]
    private var checks: [JSONValue] = []
    private var client: BrowserHostClient { MacBrowserHost.shared.client }
    private var broker: AgentToolBroker { MacAgentToolService.shared.broker }
    private var model: AppModel? { BrowserHostQAFixture.model }
    private var token = ""

    /// A page with a file field, a button that asks, and what the page learns of the answers.
    private static let page: String = {
        let html = "<title>Person QA</title><body style='margin:0'>"
            + "<input id=file type=file style='position:fixed;left:10px;top:10px;width:260px;height:30px'>"
            + "<button id=ask style='position:fixed;left:10px;top:60px;width:120px;height:30px' "
            + "onclick=\"window.answer=confirm('Go on?')\">Ask</button>"
            + "<textarea id=note style='position:fixed;left:10px;top:110px;width:260px;height:60px'></textarea>"
            + "<script>window.answer=null;window.picked=null;document.getElementById('file').addEventListener('change',"
            + "e=>{window.picked=e.target.files[0]?e.target.files[0].name:''})</script>"
        return "data:text/html," + (html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
    }()

    init(output: URL, panelSession: UUID) {
        self.output = output
        session = panelSession
    }

    func run() async {
        try? FileManager.default.createDirectory(at: output.appending(path: "markers"), withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(3))
        guard let launch = broker.agentToolServer(for: session, workspaceRoots: [output]) else {
            check("the broker issues a task its tools", false, "no launch")
            return await finish()
        }
        token = launch.environment[AgentToolEnvironment.token] ?? ""
        guard let controller = await openPanel(), let view = controller.view, let front = controller.tab else { return await finish() }
        front.send(.navigate(tab: front.id, url: Self.page))
        _ = await waitUntil(.seconds(10)) { front.title == "Person QA" }
        await exerciseAnotherTask(view)
        await exerciseTabBehind(controller, view)
        await exerciseFileChooser(controller, view)
        await exerciseThePersonsTab(controller, view)
        await finish()
    }

    // MARK: A tab of a task the person is not in

    /// The person is elsewhere (another task's tab, which no panel shows): the page's question waits in its tab.
    private func exerciseAnotherTask(_ view: BrowserHostView) async {
        let other = UUID()
        defer { client.closeTabs(forSession: other) }
        guard let tab = try? client.newTab(forSession: other, url: Self.page, viewport: .offscreenDefault, select: false) else {
            return check("another task: its tab opens", false, "no tab")
        }
        _ = await waitUntil(.seconds(10)) { tab.title == "Person QA" }
        await evaluate(tab, "setTimeout(() => { window.answer = confirm('Go on?') }, 0); 'ok'")
        let asked = await waitUntil(.seconds(5)) { tab.javaScriptDialog != nil }
        let waits = await waitUntil(.seconds(3)) { self.model?.browserWaits[other]?.wait.kind == .javaScriptDialog }
        let wait = model?.browserWaits[other]
        let announced = wait.map { model?.browserWaitAnnouncements.contains(AppModel.notice($0)) == true } ?? false
        let panelKey = model.flatMap { TaskSurfaceNavigationProjection.browserKey(inTab: $0.taskWorkspaces.state(for: other).panels.trailingSurfaceID) }
        check("another task: its page's dialog waits in its tab, holding no window, and its task waits in the browser",
              asked && waits && view.window?.attachedSheet == nil
                && model?.taskAttentionDetails[other]?.browserWait?.kind == .javaScriptDialog,
              "dialog \(tab.javaScriptDialog?.message ?? "none"), the task's wait \(String(describing: wait)), "
                + "sheet \(view.window?.attachedSheet != nil)")
        check("another task: one notification names the task and the tab, and its panel is left on the tab",
              announced && panelKey == tab.key && model?.browserWaitAnnouncements.filter({ $0.contains(tab.key.uuidString) }).count == 1,
              "announced \(model?.browserWaitAnnouncements ?? []), its panel on \(panelKey == tab.key ? "the tab" : "another tab")")
        try? await Task.sleep(for: .seconds(2))
        check("another task: the dialog is not cancelled while nobody looks", tab.javaScriptDialog != nil,
              "still open \(tab.javaScriptDialog != nil)")
        tab.send(.javaScriptDialogResult(tab: tab.id, dialog: tab.javaScriptDialog?.id ?? -1, accepted: true, text: nil))
        let answer = await value(tab, "String(window.answer)")
        let cleared = await waitUntil(.seconds(3)) { self.model?.browserWaits[other] == nil }
        check("another task: answered, the page has its answer and the task no longer waits", answer == "true" && cleared,
              "page \(answer), the task's wait \(String(describing: model?.browserWaits[other]))")
    }

    // MARK: A tab behind the panel's

    /// The same task, the panel on another tab: the dialog waits, the tab is marked, and it shows over the page when the
    /// panel shows the tab; going away and coming back keeps it.
    private func exerciseTabBehind(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async {
        guard let front = controller.tab,
              let behind = try? client.newTab(forSession: session, url: Self.page, viewport: .offscreenDefault, select: false) else {
            return check("tab behind: it opens", false, "no tab")
        }
        _ = await waitUntil(.seconds(10)) { behind.title == "Person QA" }
        await evaluate(behind, "setTimeout(() => { window.answer = confirm('Go on?') }, 0); 'ok'")
        let marked = await waitUntil(.seconds(5)) { controller.workspace.browserTabs.tab(behind.key)?.wait?.kind == .javaScriptDialog }
        check("tab behind: its dialog waits, the panel stays on its tab, and the tab is marked",
              marked && controller.tab === front && controller.javaScriptDialog == nil && view.window?.attachedSheet == nil,
              "mark \(String(describing: controller.workspace.browserTabs.tab(behind.key)?.wait)), panel on \(controller.tab?.id ?? -1)")
        capture(view, named: "person-first-marked-tab.png")
        controller.onShowTab?(behind.key)
        let shown = await waitUntil(.seconds(5)) { controller.tab === behind && controller.javaScriptDialog != nil }
        capture(view, named: "person-first-dialog.png")
        controller.onShowTab?(front.key)
        let hidden = await waitUntil(.seconds(5)) { controller.tab === front && controller.javaScriptDialog == nil }
        try? await Task.sleep(for: .milliseconds(500))
        let kept = behind.javaScriptDialog != nil
        controller.onShowTab?(behind.key)
        let back = await waitUntil(.seconds(5)) { controller.tab === behind && controller.javaScriptDialog != nil }
        check("tab behind: the dialog shows over the page with its tab, hides with it and is there again on return",
              shown && hidden && kept && back, "shown \(shown), hidden \(hidden), kept \(kept), back \(back)")
        controller.answerJavaScriptDialog(accept: true)
        let answer = await value(behind, "String(window.answer)")
        let unmarked = await waitUntil(.seconds(3)) { controller.workspace.browserTabs.tab(behind.key)?.wait == nil }
        check("tab behind: the person's OK reaches the page and the mark goes", answer == "true" && unmarked, "page \(answer)")
        controller.onShowTab?(front.key)
        _ = await waitUntil(.seconds(5)) { controller.tab === front }
    }

    // MARK: File choosers

    @MainActor
    private final class RecordingChooser: BrowserFileChooserPresenting {
        private(set) var presented: Int?
        private(set) var presentations: [Int] = []
        private(set) var dismissals = 0
        private var answer: (@MainActor ([String]?) -> Void)?

        func present(_ dialog: BrowserFileDialog, over view: NSView, answer: @escaping @MainActor ([String]?) -> Void) {
            guard presented != dialog.id else { return }
            presented = dialog.id
            presentations.append(dialog.id)
            self.answer = answer
        }

        func dismiss() {
            if presented != nil { dismissals += 1 }
            presented = nil
            answer = nil
        }

        func choose(_ paths: [String]?) {
            let answer = self.answer
            presented = nil
            self.answer = nil
            answer?(paths)
        }
    }

    /// A chooser the page opened in a tab the panel does not show waits there, uncancelled, and opens over the panel when
    /// it shows the tab, again after the panel went elsewhere; one the agent's click opened waits in a bar.
    private func exerciseFileChooser(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async {
        let chooser = RecordingChooser()
        let native = controller.fileChooser
        controller.fileChooser = chooser
        defer { controller.fileChooser = native }
        guard let front = controller.tab,
              let behind = try? client.newTab(forSession: session, url: Self.page, viewport: .offscreenDefault, select: false) else {
            return check("file chooser: a tab opens", false, "no tab")
        }
        _ = await waitUntil(.seconds(10)) { behind.title == "Person QA" }
        await evaluate(behind, "document.getElementById('file').click(); 'ok'", userGesture: true)
        let waiting = await waitUntil(.seconds(5)) { behind.fileDialog != nil }
        try? await Task.sleep(for: .seconds(2))
        check("file chooser: in a tab the panel does not show it waits, opens nothing and is not cancelled",
              waiting && behind.fileDialog != nil && chooser.presentations.isEmpty && view.window?.attachedSheet == nil
                && controller.workspace.browserTabs.tab(behind.key)?.wait?.kind == .fileChooser,
              "waiting \(behind.fileDialog != nil), presented \(chooser.presentations), panel on \(controller.tab?.id ?? -1)")
        controller.onShowTab?(behind.key)
        let opened = await waitUntil(.seconds(5)) { chooser.presented == behind.fileDialog?.id && chooser.presented != nil }
        controller.onShowTab?(front.key)
        let away = await waitUntil(.seconds(5)) { controller.tab === front && chooser.presented == nil }
        let pending = behind.fileDialog != nil
        controller.onShowTab?(behind.key)
        let again = await waitUntil(.seconds(5)) { chooser.presented != nil && chooser.presentations.count == 2 }
        check("file chooser: it opens over the panel with its tab, goes unanswered with it, and opens again on return",
              opened && away && pending && again, "opened \(opened), away \(away) pending \(pending), again \(again), "
                + "presentations \(chooser.presentations.count), dismissals \(chooser.dismissals)")
        let file = output.appending(path: "person-first-upload.txt")
        try? "upload body".write(to: file, atomically: true, encoding: .utf8)
        chooser.choose([file.path(percentEncoded: false)])
        var picked = "null"
        for _ in 0..<30 where picked == "null" {
            try? await Task.sleep(for: .milliseconds(100))
            picked = await value(behind, "String(window.picked)")
        }
        check("file chooser: the person's file reaches the page", picked == "person-first-upload.txt", "page \(picked)")

        // The agent's click opens a chooser in the tab the panel shows: a bar offers it, the system's panel does not open.
        let snapshot = await call(AgentToolCatalog.snapshot, ["tabId": .string(String(behind.id))])
        let ref = Self.ref(in: snapshot.text, role: "button", name: "Choose File") ?? Self.ref(in: snapshot.text, role: "button", name: "파일 선택")
        let clicked = await call(AgentToolCatalog.click, ["tabId": .string(String(behind.id)), "ref": .string(ref ?? "@e1")])
        let barred = await waitUntil(.seconds(5)) { controller.fileDialog != nil && controller.fileDialogByAgent }
        check("file chooser: one the agent's click opened waits in a bar over the shown tab, the system's panel unopened",
              barred && chooser.presentations.count == 2, "bar \(barred), presentations \(chooser.presentations.count); "
                + clicked.text.prefix(300))
        let uploaded = await call(AgentToolCatalog.fileUpload, ["tabId": .string(String(behind.id)),
                                                                "paths": .array([.string(file.path(percentEncoded: false))])])
        let barGone = await waitUntil(.seconds(5)) { controller.fileDialog == nil }
        check("file chooser: the agent's answer takes the bar away", barGone && !uploaded.isError, uploaded.text.prefix(300).description)
        controller.onShowTab?(front.key)
        _ = await waitUntil(.seconds(5)) { controller.tab === front }
    }

    // MARK: The tab the person uses

    /// The person uses the panel's tab; the agent opens a tab in front, works without a tabId and selects another: the
    /// panel stays, the agent's tab is marked; once the person stops, the agent's choice shows again.
    private func exerciseThePersonsTab(_ controller: BrowserHostPaneController, _ view: BrowserHostView) async {
        client.personUseWindow = .seconds(8)
        defer { client.personUseWindow = .seconds(30) }
        guard let person = controller.tab else { return check("person's tab: the panel shows a tab", false, "none") }
        let address = person.currentURL
        click(view, at: NSPoint(x: 100, y: 140))
        let using = client.personUse(of: person) != nil
        let opened = await call(AgentToolCatalog.tabNew, ["foreground": .bool(true)])
        let own = client.agentTab(forSession: session)
        let navigated = await call(AgentToolCatalog.navigate, ["url": .string(Self.page)])
        _ = await waitUntil(.seconds(10)) { own?.title == "Person QA" }
        let marked = await waitUntil(.seconds(3)) { own.map { controller.workspace.browserTabs.tab($0.key)?.isAgentUsing == true } ?? false }
        capture(view, named: "person-first-agent-tab.png")
        check("person's tab: the agent's new tab in front and its navigation without a tabId stay behind the person's tab",
              using && controller.tab === person && own !== person && own?.title == "Person QA" && person.currentURL == address && marked,
              "using \(using), panel on \(controller.tab?.id ?? -1), agent's tab \(own?.id ?? -1) marked \(marked); "
                + opened.text.prefix(240) + " / " + navigated.text.prefix(120))
        // The person goes on using their tab.
        click(view, at: NSPoint(x: 100, y: 140))
        let onTheirs = await call(AgentToolCatalog.snapshot, ["tabId": .string(String(person.id))])
        check("person's tab: a tool on the tab the person uses says so", onTheirs.text.contains("The person is using this tab"),
              String(onTheirs.text.suffix(320)))
        let listed = await call(AgentToolCatalog.tabList)
        check("person's tab: the tab list names the panel's tab and the person's use",
              listed.text.contains("\"personUsing\":true") && listed.text.contains("\"shownInPanel\":true"), listed.text.prefix(500).description)

        try? await Task.sleep(for: .seconds(9))
        let selected = await call(AgentToolCatalog.tabSelect, ["tabId": .string(String(own?.id ?? -1))])
        let follows = await waitUntil(.seconds(5)) { controller.tab === own }
        check("person's tab: once the person stops, the agent's choice shows in the panel, as before", follows,
              "panel on \(controller.tab?.id ?? -1); " + selected.text)
        broker.taskTurnEnded(session)
    }

    // MARK: Panel and page

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

    private func evaluate(_ tab: BrowserTab, _ expression: String, userGesture: Bool = false) async {
        _ = try? await tab.devTools.send("Runtime.evaluate", [
            "expression": .string(expression), "returnByValue": .bool(true), "userGesture": .bool(userGesture)
        ], timeout: .seconds(10))
    }

    private func value(_ tab: BrowserTab, _ expression: String) async -> String {
        let result = try? await tab.devTools.send("Runtime.evaluate", [
            "expression": .string(expression), "returnByValue": .bool(true)
        ], timeout: .seconds(10))
        return result?["result"]?["value"]?.stringValue ?? "no answer"
    }

    private func capture(_ view: BrowserHostView, named name: String) {
        guard let content = view.window?.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appending(path: name))
    }

    /// The person's click in the panel's page, as the view takes it.
    private func click(_ view: BrowserHostView, at point: NSPoint) {
        guard let window = view.window else { return }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: 1) else { continue }
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }

    private func call(_ tool: String, _ arguments: [String: ToolJSON] = [:]) async -> AgentToolResult {
        await broker.handle(AgentToolCall(token: token, session: session.uuidString, tool: tool, arguments: .object(arguments)))
    }

    private static func ref(in snapshot: String, role: String, name: String) -> String? {
        let line = snapshot.split(separator: "\n").first { $0.contains("- \(role)") && $0.contains(name) }
        return line.flatMap { line in
            line.range(of: #"\[ref=(@e\d+)\]"#, options: .regularExpression).map { String(line[$0].dropFirst(5).dropLast()) }
        }
    }

    private func waitUntil(_ timeout: Duration, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    // MARK: Record

    private func check(_ name: String, _ ok: Bool, _ detail: String) {
        checks.append(.object(["check": .string(name), "ok": .bool(ok), "detail": .string(String(detail.prefix(800)))]))
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
